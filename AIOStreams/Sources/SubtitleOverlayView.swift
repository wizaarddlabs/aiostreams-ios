import AetherEngineFeatures
import AVFoundation
import Combine
import UIKit

/// The page's subtitle style, in the units mpv and libass share (sizes at a 720-line script).
struct SubtitleLook: Equatable {
    var scale: Double = 1
    var bold = false
    var color = UIColor.white
    var outlineColor = UIColor.black
    var outlineSize: Double = 3
    var shadowSize: Double = 0
    var fontFamily: String?
    var backColor = UIColor.clear
    var box = false
    /// Draws the page's style over a styled file's own colours.
    var forceStyle = false
    /// Percent of the height from the top where the bottom line sits.
    var position: Double = 100

    /// mpv's `sub-font-size` default, at 720 lines.
    static let baseFontSize = 55.0

    init() {}

    init(json: [String: Any]) {
        scale = JSON.number(json["scale"]) ?? 1
        bold = json["bold"] as? Bool ?? false
        color = JSON.color(json["color"]) ?? .white
        outlineColor = JSON.color(json["outlineColor"]) ?? .black
        outlineSize = JSON.number(json["outlineSize"]) ?? 0
        shadowSize = JSON.number(json["shadowSize"]) ?? 0
        fontFamily = SubtitleLook.family(json["font"] as? String)
        backColor = JSON.color(json["backColor"]) ?? .clear
        box = json["box"] as? Bool ?? false
        forceStyle = (json["override"] as? String) == "force"
        position = JSON.number(json["position"]) ?? 100
    }

    /// The page's font names, as iOS knows them.
    static func family(_ name: String?) -> String? {
        switch name {
        case "serif": return "Georgia"
        case "monospace", "serif-monospace": return "Menlo"
        case "casual": return "Chalkboard SE"
        case "cursive": return "Snell Roundhand"
        default: return nil
        }
    }
}

/// Draws the engine's subtitle cues over the video and beneath the page, against the source clock.
final class SubtitleOverlayView: UIView {
    var look = SubtitleLook() {
        didSet {
            guard look != oldValue else { return }
            if look.forceStyle != oldValue.forceStyle, let engine = assEngine { chooseASS(engine) }
            if look.scale != oldValue.scale || look.position != oldValue.position {
                applyASSLayout()
                renderASS()
            }
            setNeedsDisplay()
        }
    }
    /// Seconds the subtitles show later than the file says.
    var delay: Double = 0 { didSet { refresh() } }
    /// Off while the page's mini player or a menu covers the picture.
    var shown = true { didSet { isHidden = !shown } }
    var videoSize: CGSize = .zero { didSet { if videoSize != oldValue { setNeedsDisplay() } } }
    var gravity: AVLayerVideoGravity = .resizeAspect { didSet { setNeedsDisplay() } }

    private var cues: [SubtitleCue] = []
    private var time: Double = 0
    private var visible: [Int] = []

    /// libass, while the active track is ASS or SSA and the page's style doesn't override it.
    private var ass: AssRenderer?
    private var assHeader: String?
    private var assFrame: AssRenderer.Frame?
    private var assScale: CGFloat = 1
    private var assRendering = false
    private var assWanted = false
    private var assFonts: [FontAttachment] = []
    private weak var assEngine: AetherEngine?
    /// The active track's events are raw ASS lines (the engine keeps their markup for libass),
    /// which, when the page's style overrides them, are drawn here as their words alone.
    private var rawASS = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setCues(_ cues: [SubtitleCue]) {
        self.cues = cues
        ass?.feed(cues)
        refresh(force: true)
        renderASS()
    }

    func setTime(_ seconds: Double) {
        time = seconds
        if ass != nil { renderASS() } else { refresh() }
    }

    func clear() {
        cues = []
        assFrame = nil
        refresh(force: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderASS()
    }

    // MARK: ASS and SSA through libass

    /// Keeps libass on the active track while it's ASS or SSA, with the file's fonts.
    func follow(_ engine: AetherEngine, into bag: inout Set<AnyCancellable>) {
        assEngine = engine
        Publishers.Merge3(
            engine.$activeSubtitleTrackIndex.map { _ in () },
            engine.$subtitleTracks.map { _ in () },
            engine.$sidecarASSHeader.map { _ in () }
        )
        // After the change lands: a @Published sends before it stores.
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak engine] in
            guard let self, let engine else { return }
            self.chooseASS(engine)
        }
        .store(in: &bag)
        engine.$fontAttachments
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fonts in
                self?.assFonts = fonts
                self?.ass?.add(fonts: fonts)
            }
            .store(in: &bag)
    }

    private func chooseASS(_ engine: AetherEngine) {
        let track = engine.subtitleTracks.first { $0.id == engine.activeSubtitleTrackIndex }
        let styled = track.map { AssRenderer.handles(codec: $0.codec) } ?? false
        rawASS = styled
        let header = styled && !look.forceStyle ? (track?.assHeader ?? engine.sidecarASSHeader) : nil
        guard header != assHeader else { return }
        assHeader = header
        assFrame = nil
        if let header {
            if ass == nil {
                ass = AssRenderer()
                ass?.add(fonts: assFonts)
                applyASSLayout()
            }
            ass?.load(header: header)
            ass?.feed(cues)
        } else {
            ass = nil
        }
        refresh(force: true)
        renderASS()
    }

    /// The page's Size and Position on libass: its position is where the bottom line sits, as a
    /// percent of the height from the top, and libass's runs from the bottom.
    private func applyASSLayout() {
        ass?.setLayout(scale: look.scale, position: 100 - look.position)
    }

    /// One frame at a time from libass, always for the latest time.
    private func renderASS() {
        guard let ass else { return }
        guard !assRendering else {
            assWanted = true
            return
        }
        let video = videoRect
        guard video.width > 0, video.height > 0 else { return }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        assScale = scale
        assRendering = true
        let size = CGSize(width: (video.width * scale).rounded(), height: (video.height * scale).rounded())
        ass.render(at: time - delay, size: size, video: videoSize) { [weak self] frame in
            guard let self else { return }
            self.assRendering = false
            if frame?.image !== self.assFrame?.image {
                self.assFrame = frame
                self.setNeedsDisplay()
            }
            if self.assWanted {
                self.assWanted = false
                self.renderASS()
            }
        }
    }

    private var showing: [SubtitleCue] {
        let at = time - delay
        return cues.filter { $0.startTime <= at && at < $0.endTime }
    }

    private func refresh(force: Bool = false) {
        let ids = showing.map(\.id)
        if force || ids != visible {
            visible = ids
            setNeedsDisplay()
        }
    }

    /// Where the picture sits in the view.
    private var videoRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        switch gravity {
        case .resize: return bounds
        case .resizeAspectFill:
            let scale = max(bounds.width / videoSize.width, bounds.height / videoSize.height)
            let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
            return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        default:
            return AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        }
    }

    override func draw(_ rect: CGRect) {
        if ass != nil {
            // libass draws the whole frame, placed on the picture as the script asks.
            if let frame = assFrame {
                let video = videoRect
                let at = CGRect(
                    x: video.minX + frame.rect.minX / assScale, y: video.minY + frame.rect.minY / assScale,
                    width: frame.rect.width / assScale, height: frame.rect.height / assScale
                )
                UIImage(cgImage: frame.image).draw(in: at)
            }
            return
        }
        let cues = showing
        guard !cues.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
        let video = videoRect.intersection(bounds).isNull ? bounds : videoRect
        // Text is sized to what shows of the picture, so a cropped fill doesn't push lines off screen.
        let shownVideo = video.intersection(bounds)
        var bottomStack: [NSAttributedString] = []
        var placed: [(NSAttributedString, Int, CGPoint?)] = []
        let line = bottomLine(video: shownVideo)

        for cue in cues {
            switch cue.body {
            case .image(let image):
                drawImage(image, in: video, below: line, context: context)
            case .text(let raw):
                // A file's ASS tags in plain text are its instructions, not its words.
                let (text, alignment) = SubtitleTags.clean(rawASS ? AssRenderer.eventText(raw) : raw)
                let string = attributed(runs: nil, text: text, height: shownVideo.height)
                route(string, placement: cue.placement ?? alignment.map { SubtitleTextPlacement(alignment: $0, position: nil) },
                      bottom: &bottomStack, placed: &placed)
            case .richText(let runs):
                let string = attributed(runs: runs, text: nil, height: shownVideo.height)
                let alignment = SubtitleTags.clean(runs.map(\.text).joined()).alignment
                route(string, placement: cue.placement ?? alignment.map { SubtitleTextPlacement(alignment: $0, position: nil) },
                      bottom: &bottomStack, placed: &placed)
            @unknown default:
                break
            }
        }

        // Bottom lines stack upwards from the page's chosen height.
        var bottom = line
        for string in bottomStack.reversed() {
            let size = measure(string, width: shownVideo.width * 0.92)
            let origin = CGPoint(x: shownVideo.midX - size.width / 2, y: bottom - size.height)
            drawText(string, at: CGRect(origin: origin, size: size), context: context)
            bottom -= size.height
        }

        for (string, alignment, anchor) in placed {
            let size = measure(string, width: shownVideo.width * 0.92)
            let column = (alignment - 1) % 3 // 0 left, 1 centre, 2 right
            let row = (alignment - 1) / 3 // 0 bottom, 1 middle, 2 top
            let margin = shownVideo.height * 0.04
            var point: CGPoint
            if let anchor {
                point = CGPoint(x: video.minX + video.width * anchor.x, y: video.minY + video.height * anchor.y)
            } else {
                let x = [shownVideo.minX + margin, shownVideo.midX, shownVideo.maxX - margin][column]
                let y = [shownVideo.maxY - margin, shownVideo.midY, shownVideo.minY + margin][row]
                point = CGPoint(x: x, y: y)
            }
            let x = [point.x, point.x - size.width / 2, point.x - size.width][column]
            let y = [point.y - size.height, point.y - size.height / 2, point.y][row]
            drawText(string, at: CGRect(x: x, y: y, width: size.width, height: size.height), context: context)
        }
    }

    /// Where the lowest unplaced line's bottom sits. The page's height is a share of the screen
    /// while its controls lift the subtitles over them (`useLiftSubtitles` measures the window),
    /// and of the picture otherwise; the higher of the two clears the controls and stays on the
    /// picture where it can, as on a letterboxed or portrait video.
    private func bottomLine(video: CGRect) -> CGFloat {
        let share = min(max(look.position, 0), 100) / 100
        let onPicture = min(video.minY + video.height * share, video.maxY - video.height * 0.03)
        let onScreen = min(bounds.height * share, bounds.maxY - bounds.height * 0.03)
        return min(onPicture, onScreen)
    }

    private func route(
        _ string: NSAttributedString,
        placement: SubtitleTextPlacement?,
        bottom: inout [NSAttributedString],
        placed: inout [(NSAttributedString, Int, CGPoint?)]
    ) {
        let alignment = placement?.alignment ?? 2
        if placement?.position == nil, alignment == 2 || !(1...9).contains(alignment) {
            bottom.append(string)
        } else {
            placed.append((string, (1...9).contains(alignment) ? alignment : 2, placement?.position))
        }
    }

    private func font(size: CGFloat, bold: Bool, italic: Bool) -> UIFont {
        var descriptor: UIFontDescriptor
        if let family = look.fontFamily {
            descriptor = UIFontDescriptor(fontAttributes: [.family: family])
        } else {
            descriptor = UIFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor
        }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold || look.bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = descriptor.withSymbolicTraits(traits) { descriptor = styled }
        // libass, which draws mpv's subtitles in the other apps, makes a font's line (ascender to
        // descender) the size it's given, where UIKit makes its em that size. Sized as libass does,
        // each step matches the web and Android apps instead of reading about a fifth larger.
        let nominal = UIFont(descriptor: descriptor, size: size)
        let line = nominal.ascender - nominal.descender
        return line > 0 ? UIFont(descriptor: descriptor, size: size * size / line) : nominal
    }

    private func attributed(runs: [SubtitleTextRun]?, text: String?, height: CGFloat) -> NSAttributedString {
        let size = CGFloat(SubtitleLook.baseFontSize * look.scale) * height / 720
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let result = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph]
        if let runs {
            for run in runs {
                var attributes = base
                attributes[.font] = font(size: size, bold: run.isBold, italic: run.isItalic)
                var colour = look.color
                if !look.forceStyle, let c = run.color {
                    colour = UIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
                }
                attributes[.foregroundColor] = colour
                if run.isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if run.isStruckThrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        } else if let text {
            var attributes = base
            attributes[.font] = font(size: size, bold: false, italic: false)
            attributes[.foregroundColor] = look.color
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        // Tags taken out of the line as a whole, as one can fall across a styled run's edge.
        SubtitleTags.strip(result)
        return result
    }

    private func measure(_ string: NSAttributedString, width: CGFloat) -> CGSize {
        let pad = outlineWidth(for: string) * 2
        let rect = string.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return CGSize(width: ceil(rect.width) + pad, height: ceil(rect.height) + pad)
    }

    private func outlineWidth(for string: NSAttributedString) -> CGFloat {
        CGFloat(look.outlineSize) * bounds.height / 720
    }

    private func drawText(_ string: NSAttributedString, at rect: CGRect, context: CGContext) {
        let outline = outlineWidth(for: string)
        let inner = rect.insetBy(dx: outline, dy: outline)
        if look.box {
            // Behind each line, hugging its text, as the web app's cue background and the Android
            // app's caption background draw it, not one window round the whole cue.
            context.setFillColor(look.backColor.cgColor)
            let pad = max(outline * 2, font(of: string) * 0.25)
            for line in lineRects(string, width: inner.width) {
                context.fill(line.offsetBy(dx: inner.minX, dy: inner.minY).insetBy(dx: -pad, dy: 0))
            }
        }
        context.saveGState()
        if look.shadowSize > 0 {
            let offset = CGFloat(look.shadowSize) * bounds.height / 720
            context.setShadow(offset: CGSize(width: offset, height: offset), blur: offset, color: UIColor.black.withAlphaComponent(0.8).cgColor)
        }
        if outline > 0, !look.box {
            // The outline first, then the fill over it, as libass draws a border.
            let stroked = NSMutableAttributedString(attributedString: string)
            let whole = NSRange(location: 0, length: stroked.length)
            stroked.addAttributes(
                [.strokeColor: look.outlineColor, .strokeWidth: 200 * outline / max(font(of: string), 1)],
                range: whole
            )
            // A styled file's dark text (a sign's black over a white border, whose border colour the
            // cue doesn't carry) gets a light outline where the outline would be dark too, so it reads.
            if look.outlineColor.luminance < 0.3 {
                stroked.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
                    if let colour = value as? UIColor, colour.luminance < 0.3 {
                        stroked.addAttribute(.strokeColor, value: UIColor.white, range: range)
                    }
                }
            }
            // Round joins, as libass strokes: a mitred join runs out into a spike at the sharp
            // corners of letters such as M and N.
            context.setLineJoin(.round)
            context.setLineCap(.round)
            stroked.draw(with: inner, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            context.setShadow(offset: .zero, blur: 0)
        }
        string.draw(with: inner, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        context.restoreGState()
    }

    /// Where each laid-out line's text sits, alignment included, in the string's own box.
    private func lineRects(_ string: NSAttributedString, width: CGFloat) -> [CGRect] {
        let storage = NSTextStorage(attributedString: string)
        let layout = NSLayoutManager()
        layout.usesFontLeading = true
        let container = NSTextContainer(size: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var rects: [CGRect] = []
        let text = string.string as NSString
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { fragment, _, _, glyphs, _ in
            // The line's text without the break or spaces it ends on: a line break's glyph reaches to
            // the end of the line, which stretched a short line's band to the cue's widest.
            var characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            while characters.length > 0,
                  let scalar = UnicodeScalar(text.character(at: characters.location + characters.length - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) {
                characters.length -= 1
            }
            guard characters.length > 0 else { return }
            let visible = layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            // The glyphs' own bounds, so a centred line's band is centred, but the fragment's height,
            // so the bands of a cue's lines meet.
            let bounds = layout.boundingRect(forGlyphRange: visible, in: container)
            guard bounds.width > 0 else { return }
            rects.append(CGRect(x: bounds.minX, y: fragment.minY, width: bounds.width, height: fragment.height))
        }
        return rects
    }

    private func font(of string: NSAttributedString) -> CGFloat {
        guard string.length > 0, let font = string.attribute(.font, at: 0, effectiveRange: nil) as? UIFont else { return 1 }
        return font.pointSize
    }

    private func drawImage(_ image: SubtitleImage, in video: CGRect, below line: CGFloat, context: CGContext) {
        // `position` is normalised against the subtitle canvas, laid onto the picture.
        var frame = CGRect(
            x: video.minX + image.position.minX * video.width,
            y: video.minY + image.position.minY * video.height,
            width: image.position.width * video.width,
            height: image.position.height * video.height
        )
        // A picture in the lower half rises with the line, as the Android app lifts it, no higher than the top.
        if frame.midY > video.midY, frame.maxY > line {
            frame.origin.y = max(min(frame.minY, video.minY), frame.minY - (frame.maxY - line))
        }
        UIImage(cgImage: image.cgImage).draw(in: frame)
    }
}

/// ASS override tags left in a text subtitle, as an SRT made from an ASS file often keeps them:
/// `{\an8}` and the like are its instructions, never its words. The blocks are taken out, stray
/// forms whose brace or backslash went missing too (`\an8}`, `an8}` at a line's start), and `\N`
/// and `\h` become a line break and a space. The last `\anN` is where the line asks to sit (1
/// bottom left to 9 top right). A backslash can come as the full-width `＼`.
enum SubtitleTags {
    private static let tags = try! NSRegularExpression(pattern:
        #"\{[^{}]*[\\＼][^{}]*\}|\{?[\\＼]+(?:an?\d+|pos\([^)]*\)|move\([^)]*\)|[ibus][01]|fad?e?\([^)]*\))\}?|(?:^|(?<=\s))\{?an\d\}"#)
    private static let alignment = try! NSRegularExpression(pattern: #"(?:[\\＼]+|\{)an(\d)"#)
    private static let breaks = try! NSRegularExpression(pattern: #"[\\＼][Nn]"#)
    private static let hardSpace = try! NSRegularExpression(pattern: #"[\\＼]h"#)

    static func clean(_ text: String) -> (text: String, alignment: Int?) {
        let line = NSMutableAttributedString(string: text)
        let found = alignmentOf(text)
        strip(line)
        return (line.string.trimmingCharacters(in: .whitespaces), found)
    }

    static func alignmentOf(_ text: String) -> Int? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = alignment.matches(in: text, range: range).last,
              let digits = Range(match.range(at: 1), in: text), let value = Int(text[digits]),
              (1...9).contains(value) else { return nil }
        return value
    }

    /// Takes the tags out of a styled line in place, whichever runs they fall across.
    static func strip(_ line: NSMutableAttributedString) {
        let text = line.string
        guard text.contains("\\") || text.contains("＼") || text.contains("{") || text.contains("}") else { return }
        for match in tags.matches(in: text, range: NSRange(location: 0, length: line.length)).reversed() {
            line.deleteCharacters(in: match.range)
        }
        for match in breaks.matches(in: line.string, range: NSRange(location: 0, length: line.length)).reversed() {
            line.replaceCharacters(in: match.range, with: "\n")
        }
        for match in hardSpace.matches(in: line.string, range: NSRange(location: 0, length: line.length)).reversed() {
            line.replaceCharacters(in: match.range, with: " ")
        }
        // A tag at the start leaves the line's first space behind.
        while line.length > 0, line.string.first == " " { line.deleteCharacters(in: NSRange(location: 0, length: 1)) }
    }
}

private extension UIColor {
    /// Relative luminance, 0 for black to 1 for white.
    var luminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return 1 }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
