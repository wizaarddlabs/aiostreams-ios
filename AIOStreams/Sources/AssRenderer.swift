import AetherEngineFeatures
import CoreGraphics
import Foundation

/// libass, for ASS and SSA tracks drawn as their authors styled them: positions, fonts, sizes,
/// colours, borders, rotation and karaoke, as the official Android app (libass) and desktop app
/// (mpv) draw them. The engine hands over the track's script header and each event as the raw
/// Matroska event line (`LoadOptions.preserveASSMarkup`), and the file's embedded fonts.
///
/// Every libass call runs on one serial queue: a library, its renderer and its track are not
/// safe to use from two threads at once.
final class AssRenderer {
    /// A rendered frame: the picture, and where it sits in the frame it was rendered for, in pixels.
    struct Frame {
        let image: CGImage
        let rect: CGRect
    }

    private let queue = DispatchQueue(label: "io.github.aiostreams-ios.ass", qos: .userInteractive)
    private let library: OpaquePointer
    private let renderer: OpaquePointer
    private var track: UnsafeMutablePointer<ASS_Track>?
    private var fed = Set<Int>()
    private var fontNames = Set<String>()
    private var frameSize: (Int32, Int32) = (0, 0)
    private var storageSize: (Int32, Int32) = (0, 0)
    private var layout: (scale: Double, position: Double) = (1, 0)
    private var last: Frame?

    init?() {
        guard let library = ass_library_init() else { return nil }
        guard let renderer = ass_renderer_init(library) else {
            ass_library_done(library)
            return nil
        }
        self.library = library
        self.renderer = renderer
        // The fonts a file embeds are handed over by the engine, not read out of the track.
        ass_set_extract_fonts(library, 0)
        Self.setFonts(renderer)
    }

    deinit {
        let (library, renderer, track) = (library, renderer, track)
        queue.async {
            if let track { ass_free_track(track) }
            ass_renderer_done(renderer)
            ass_library_done(library)
        }
    }

    /// The system's fonts through CoreText, with the embedded ones added to the library; a font a
    /// script names that neither has falls back to a sans serif.
    private static func setFonts(_ renderer: OpaquePointer) {
        ass_set_fonts(renderer, nil, "Helvetica Neue", Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue), nil, 1)
    }

    /// The page's Size and Position, as the official apps apply them to ASS (mpv's
    /// `sub-ass-override=scale`): text scaled by `scale`, and lines the script doesn't place moved
    /// to `position`, 0 at the bottom of the picture to 100 at the top. Placed signs stay put.
    func setLayout(scale: Double, position: Double) {
        queue.async { [self] in
            guard scale != layout.scale || position != layout.position else { return }
            layout = (scale, position)
            ass_set_font_scale(renderer, scale)
            ass_set_line_position(renderer, min(max(position, 0), 100))
            last = nil
        }
    }

    /// A new track from the script's header, with no events yet.
    func load(header: String) {
        queue.async { [self] in
            if let track { ass_free_track(track) }
            fed.removeAll()
            last = nil
            guard let track = ass_new_track(library) else { return }
            // Real files write ReadOrder 0 on every event, so the cue ids say what's new instead.
            ass_set_check_readorder(track, 0)
            var bytes = Array(header.utf8)
            bytes.withUnsafeMutableBufferPointer { buffer in
                buffer.withMemoryRebound(to: CChar.self) {
                    ass_process_codec_private(track, $0.baseAddress, Int32($0.count))
                }
            }
            self.track = track
        }
    }

    /// The file's embedded fonts, as they arrive (after the first frame).
    func add(fonts: [FontAttachment]) {
        queue.async { [self] in
            var added = false
            for font in fonts where !fontNames.contains(font.filename) {
                fontNames.insert(font.filename)
                font.data.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return }
                    ass_add_font(library, font.filename, base, Int32(raw.count))
                }
                added = true
            }
            if added { Self.setFonts(renderer) }
        }
    }

    /// Events not fed before, each the raw Matroska event line of a cue.
    func feed(_ cues: [SubtitleCue]) {
        queue.async { [self] in
            guard let track else { return }
            for cue in cues where !fed.contains(cue.id) {
                guard case .text(let line) = cue.body else { continue }
                fed.insert(cue.id)
                let start = Int64((cue.startTime * 1000).rounded())
                let duration = max(Int64(((cue.endTime - cue.startTime) * 1000).rounded()), 0)
                var bytes = Array(line.utf8)
                bytes.withUnsafeMutableBufferPointer { buffer in
                    buffer.withMemoryRebound(to: CChar.self) {
                        ass_process_chunk(track, $0.baseAddress, Int32($0.count), start, duration)
                    }
                }
            }
        }
    }

    /// The frame at `seconds`, for a frame of `size` pixels over a picture of `video` pixels.
    /// nil where nothing shows. Calls back on the main queue.
    func render(at seconds: Double, size: CGSize, video: CGSize, completion: @escaping (Frame?) -> Void) {
        queue.async { [self] in
            let frame = renderNow(at: seconds, size: size, video: video)
            DispatchQueue.main.async { completion(frame) }
        }
    }

    private func renderNow(at seconds: Double, size: CGSize, video: CGSize) -> Frame? {
        guard let track, size.width >= 1, size.height >= 1 else { return nil }
        let frame = (Int32(size.width), Int32(size.height))
        if frame != frameSize {
            frameSize = frame
            ass_set_frame_size(renderer, frame.0, frame.1)
            last = nil
        }
        let storage = (Int32(video.width), Int32(video.height))
        if storage.0 > 0, storage.1 > 0, storage != storageSize {
            storageSize = storage
            ass_set_storage_size(renderer, storage.0, storage.1)
            last = nil
        }
        var changed: Int32 = 0
        let images = ass_render_frame(renderer, track, Int64((seconds * 1000).rounded()), &changed)
        if changed == 0, last != nil || images == nil { return last }
        // A layout change re-renders without libass saying so; `last` was dropped for it.
        last = images.flatMap(Self.blend)
        return last
    }

    /// libass's alpha bitmaps, each one colour, painted in order over a clear canvas the size of
    /// their bounds.
    private static func blend(_ first: UnsafeMutablePointer<ASS_Image>) -> Frame? {
        var bounds = CGRect.null
        var node: UnsafeMutablePointer<ASS_Image>? = first
        while let image = node {
            let i = image.pointee
            if i.w > 0, i.h > 0 {
                bounds = bounds.union(CGRect(x: Int(i.dst_x), y: Int(i.dst_y), width: Int(i.w), height: Int(i.h)))
            }
            node = i.next
        }
        guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1 else { return nil }
        let width = Int(bounds.width), height = Int(bounds.height)
        let originX = Int(bounds.minX), originY = Int(bounds.minY)
        // Premultiplied RGBA.
        var canvas = [UInt8](repeating: 0, count: width * height * 4)
        canvas.withUnsafeMutableBufferPointer { out in
            var node: UnsafeMutablePointer<ASS_Image>? = first
            while let image = node {
                let i = image.pointee
                node = i.next
                guard i.w > 0, i.h > 0, let bitmap = i.bitmap else { continue }
                let r = Int((i.color >> 24) & 0xFF), g = Int((i.color >> 16) & 0xFF), b = Int((i.color >> 8) & 0xFF)
                // libass's alpha is transparency: 0 is opaque.
                let opacity = 255 - Int(i.color & 0xFF)
                guard opacity > 0 else { continue }
                for y in 0..<Int(i.h) {
                    let row = bitmap + y * Int(i.stride)
                    var at = ((Int(i.dst_y) - originY + y) * width + (Int(i.dst_x) - originX)) * 4
                    for x in 0..<Int(i.w) {
                        let coverage = Int(row[x])
                        if coverage > 0 {
                            let a = coverage * opacity / 255
                            let keep = 255 - a
                            out[at] = UInt8((r * a + Int(out[at]) * keep) / 255)
                            out[at + 1] = UInt8((g * a + Int(out[at + 1]) * keep) / 255)
                            out[at + 2] = UInt8((b * a + Int(out[at + 2]) * keep) / 255)
                            out[at + 3] = UInt8(a + Int(out[at + 3]) * keep / 255)
                        }
                        at += 4
                    }
                }
            }
        }
        let data = Data(canvas) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }
        return Frame(image: image, rect: bounds)
    }

    /// A raw event line's words, for drawing it in the page's own style: the Matroska line is
    /// `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`, and only the text is said.
    static func eventText(_ line: String) -> String {
        let fields = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        return fields.count == 9 ? String(fields[8]) : line
    }

    /// Whether a track is drawn by libass.
    static func handles(codec: String) -> Bool {
        codec == "ass" || codec == "ssa"
    }
}
