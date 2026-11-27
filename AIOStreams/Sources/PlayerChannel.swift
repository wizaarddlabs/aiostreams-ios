import AetherEngineFeatures
import AVFoundation
import Combine
import UIKit

/// Carries the page's `player-*` and `now-playing` messages to AetherEngine and the engine's
/// reports back, in the shapes the desktop app's `core/src/playback.rs` reads and writes.
@MainActor
final class PlayerChannel {
    let engine: AetherEngine
    private let send: ([String: Any]) -> Void
    private let overlay: SubtitleOverlayView
    private let thumbnails: ThumbnailStore
    private let nowPlaying: NowPlaying
    /// Shows the video beneath the page, or hides it once nothing plays.
    var showVideo: (Bool) -> Void = { _ in }
    /// A title loaded or stopped, which changes whether Picture in Picture can be offered.
    /// The page's player asks for the stats over the video, or for them to go.
    var statsOverlay: (Bool) -> Void = { _ in }
    var mediaChanged: () -> Void = {}

    /// A title is loaded and hasn't ended.
    var hasMedia: Bool { loadedURL != nil && !ended }
    /// The style the page chose, which the Picture in Picture window's captions follow.
    var subtitleLook: SubtitleLook { overlay.look }

    /// The window's own close button pauses, as other apps' do.
    func pauseFromPictureInPicture() { change(["paused": true]) }

    private var bag = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    /// The url the page asked for, exactly as it sent it, which its thumbnails name.
    private var loadedURL: String?
    /// The headers the title loaded with, which reading its subtitle index needs too.
    private var loadedHeaders: [String: String] = [:]
    /// The page's last load, which a source that fabricates byte ranges is loaded again from.
    private var lastLoad: [String: Any]?
    /// A catch-up archive read straight through, and how far into the programme the session
    /// playing it starts: the page's positions are the programme's, the engine's from that start.
    private var archive: CatchUpArchive?
    private var archiveOffset: Double = 0
    /// Seek bar pictures past what the session holds, from a reader of their own on the same
    /// source, as the official apps make theirs over a second connection. Not for live or a
    /// catch-up archive, which can't be read from anywhere but their start.
    private var frames: FrameExtractor?
    private var framesAllowed = false
    /// The web app's Sound settings: the channel cap, dialogue boost, night mode and binaural.
    private var shaping = AudioShaping()
    private var indexTask: Task<[SubtitleIndex.Timeline]?, Never>?
    private var lineWatch: Task<Void, Never>?
    private var wantsPaused = false
    private var volume: Double = 1
    private var muted = false
    private var speed: Double = 1
    private var ended = false
    private var restarted = false
    private var lastStatus: Int?
    /// Where each added subtitle came from, by its track id.
    private var subtitleURLs: [Int: String] = [:]
    private var subtitleFiles = 0
    /// The languages a stream's own AVPlayer subtitles are picked from, once, as they arrive.
    private var nativePickLanguages: [String] = []
    /// The user's subtitle types, best first (normal, sdh, forced, signs).
    private var nativePickTypes: [String] = []
    private var nativePicked = false
    /// AVPlayer's own subtitle lines, read for the overlay.
    private lazy var captions = NativeCaptions { [weak self] cues in
        guard let self, self.engine.videoRoute == .remoteBypass else { return }
        self.overlay.setCues(cues)
    }
    private var thumbnailBusy = false
    private var wantedThumbnail: (url: String, positionMs: Double)?
    private var thumbnailCount = 0

    init(engine: AetherEngine, overlay: SubtitleOverlayView, thumbnails: ThumbnailStore, send: @escaping ([String: Any]) -> Void) {
        self.engine = engine
        self.overlay = overlay
        self.thumbnails = thumbnails
        self.send = send
        nowPlaying = NowPlaying(engine: engine)
        nowPlaying.onKey = { [weak self] key in self?.send(["type": "media-key", "key": key]) }
        observe()
    }

    // MARK: - From the engine

    private func observe() {
        engine.$state
            .sink { [weak self] state in self?.stateChanged(state) }
            .store(in: &bag)
        engine.$isBuffering.removeDuplicates()
            .sink { [weak self] in self?.state(["buffering": $0]) }
            .store(in: &bag)
        engine.$isSeeking.removeDuplicates()
            .sink { [weak self] seeking in
                guard let self else { return }
                self.state(["seeking": seeking])
                // mpv's playback-restart: the picture shows from the new place.
                if !seeking, self.restarted { self.event("restart") }
            }
            .store(in: &bag)
        engine.$duration.removeDuplicates()
            .sink { [weak self] duration in
                guard let self, duration > 0 else { return }
                self.state(["durationMs": JSON.finite((self.archive?.length ?? duration) * 1000)])
            }
            .store(in: &bag)
        engine.clock.$currentTime
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] seconds in
                guard let self, self.loadedURL != nil else { return }
                self.state(["positionMs": JSON.finite((seconds + self.archiveOffset) * 1000)])
            }
            .store(in: &bag)
        engine.$residentRanges
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] ranges in
                guard let self else { return }
                let shift = self.archiveOffset
                self.state(["buffered": ranges.map { ["startMs": JSON.finite(($0.lowerBound + shift) * 1000), "endMs": JSON.finite(($0.upperBound + shift) * 1000)] }])
            }
            .store(in: &bag)
        Publishers.CombineLatest(engine.$audioTracks, engine.$subtitleTracks)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.pickNativeSubtitle()
                self?.sendTracks()
            }
            .store(in: &bag)
        // A stream whose subtitles AVPlayer would draw itself: its lines are read off the item and
        // drawn in the overlay, in the page's style, AVPlayer's own rendering held back.
        // Only there: elsewhere AVPlayer's rendering is what Picture in Picture shows.
        Publishers.CombineLatest(engine.$currentAVPlayerItem, engine.$videoRoute)
            .receive(on: RunLoop.main)
            .sink { [weak self] item, route in self?.captions.attach(to: route == .remoteBypass ? item : nil) }
            .store(in: &bag)
        engine.$activeAudioTrackIndex.removeDuplicates()
            .sink { [weak self] index in self?.state(["audio": JSON.id(index)]) }
            .store(in: &bag)
        engine.$activeSubtitleTrackIndex.removeDuplicates()
            .sink { [weak self] index in self?.state(["subtitle": JSON.id(index)]) }
            .store(in: &bag)
        engine.$mediaChapters
            .sink { [weak self] _ in self?.sendChapters() }
            .store(in: &bag)
        engine.$subtitleCues
            .sink { [weak self] cues in self?.overlay.setCues(cues) }
            .store(in: &bag)
        overlay.follow(engine, into: &bag)
        engine.clock.$sourceTime
            .sink { [weak self] seconds in self?.overlay.setTime(seconds) }
            .store(in: &bag)
        Publishers.CombineLatest(engine.$sourceVideoWidth, engine.$sourceVideoHeight)
            .sink { [weak self] width, height in
                guard let self else { return }
                let aspect = self.engine.sourceVideoPixelAspectRatio
                self.overlay.videoSize = CGSize(width: Double(width) * (aspect > 0 ? aspect : 1), height: Double(height))
            }
            .store(in: &bag)
        engine.$hasFirstFrameReadyForDisplay.removeDuplicates()
            .sink { [weak self] ready in
                guard let self, ready, !self.restarted else { return }
                self.restarted = true
                self.event("restart")
            }
            .store(in: &bag)
        engine.sourceAuthorizationRefused
            .sink { [weak self] status in self?.lastStatus = status }
            .store(in: &bag)
    }

    private func stateChanged(_ state: PlaybackState) {
        switch state {
        case .idle:
            self.state(["idle": true, "paused": wantsPaused])
        case .loading:
            self.state(["idle": false])
        case .playing:
            self.state(["idle": false, "paused": false])
        case .paused:
            self.state(["idle": false, "paused": true])
        case .seeking:
            break
        case .ended:
            end("eof", error: nil)
        case .error(let message):
            if loadSequentially() { return }
            end("error", error: message)
        @unknown default:
            break
        }
        nowPlaying.update(playing: state == .playing)
    }

    private func state(_ fields: [String: Any]) {
        var message = fields
        message["type"] = "player-state"
        send(message)
    }

    private func event(_ name: String) {
        send(["type": "player-event", "name": name])
    }

    /// The engine's seek, or for a catch-up archive read straight through, where the session can't
    /// reach: the archive asked for again from that minute.
    private func seek(to seconds: Double, exact: Bool) {
        guard let archive, var message = lastLoad else {
            Task { await engine.seek(to: seconds, exact: exact) }
            return
        }
        let local = seconds - archiveOffset
        // What the session holds up to where it has read lands from its cache.
        if local >= 0, let held = engine.residentRanges.last, held.contains(local) {
            Task { await engine.seek(to: local, exact: exact) }
            return
        }
        let offset = archive.offset(for: seconds)
        AppLog.info("player", "catch-up: reopening the archive \(Int(offset))s in")
        message["url"] = archive.address(from: offset)
        message["archiveOffsetS"] = offset
        message["sequential"] = true
        message["startMs"] = 0
        load(message)
    }

    /// Once per title: a source the engine found fabricating byte ranges, loaded again to read
    /// straight through. True when it did.
    private func loadSequentially() -> Bool {
        guard engine.errorInfo?.kind == .sourceFabricatesRanges, !ended, var message = lastLoad,
              JSON.flag(message["sequential"]) != true, JSON.flag(message["live"]) != true else { return false }
        AppLog.warn("player", "origin fabricates ranges; loading again as sequential")
        message["sequential"] = true
        load(message)
        return true
    }

    private func end(_ reason: String, error: String?) {
        guard !ended, loadedURL != nil else { return }
        ended = true
        var message: [String: Any] = ["type": "player-ended", "reason": reason, "error": JSON.orNull(error)]
        if reason == "error" {
            if let lastStatus { message["status"] = lastStatus }
            if let info = engine.errorInfo { message["cause"] = info.message }
            AppLog.warn("player", "ended with an error: \(error ?? "?") status=\(lastStatus.map(String.init) ?? "-")")
        } else {
            AppLog.info("player", "ended reason=\(reason)")
        }
        send(message)
    }

    private func trackJSON(_ track: TrackInfo, type: String) -> [String: Any]? {
        guard track.id >= 0 else { return nil }
        var json: [String: Any] = [
            "id": String(track.id),
            "type": type,
            "default": track.isDefault,
            "forced": track.isForced,
            "hearingImpaired": track.isHearingImpaired,
            "visualImpaired": track.isVisualImpaired,
            "external": track.isExternal,
        ]
        if !track.name.isEmpty { json["title"] = track.name }
        if let language = track.language, !language.isEmpty { json["language"] = language }
        if !track.codec.isEmpty { json["codec"] = track.codec }
        if let url = subtitleURLs[track.id] { json["url"] = url }
        return json
    }

    /// On a remote HLS stream the subtitles are AVPlayer's renditions, listed once its playlist is
    /// read and left unpicked by the user's languages. With subtitles set to Always, the
    /// first in the user's languages is picked as they arrive; a choice in the player replaces it.
    private func pickNativeSubtitle() {
        guard !nativePicked, !nativePickLanguages.isEmpty, engine.videoRoute == .remoteBypass,
              !engine.subtitleTracks.isEmpty else { return }
        nativePicked = true
        guard engine.activeSubtitleTrackIndex == nil else { return }
        // The user's types, best first, as the web app ranks them; forced-only tracks never lead.
        let order = nativePickTypes.isEmpty ? ["normal", "sdh", "forced", "signs"] : nativePickTypes
        func rank(_ track: TrackInfo) -> Int {
            let type = Self.subtitleType(track)
            return type == "forced" ? order.count + 1 : (order.firstIndex(of: type) ?? order.count)
        }
        for wanted in nativePickLanguages.map(Self.languageKey) {
            let matching = engine.subtitleTracks.filter { $0.language.map(Self.languageKey) == wanted }
            if let track = matching.min(by: { rank($0) < rank($1) }), !track.isForced {
                AppLog.info("subtitles", "picked the stream's \(track.language ?? "?") \(Self.subtitleType(track)) subtitles")
                engine.selectSubtitleTrack(index: track.id)
                return
            }
        }
    }

    /// A track's type as the web app tells them apart: forced, SDH (for the hard of hearing),
    /// signs and songs, or normal.
    static func subtitleType(_ track: TrackInfo) -> String {
        let name = track.name.lowercased()
        if track.isForced { return "forced" }
        if track.isHearingImpaired || name.contains("sdh") || name.contains("hearing") || name.contains("cc") { return "sdh" }
        if name.contains("sign") || name.contains("song") { return "signs" }
        return "normal"
    }

    /// A language tag or code as one key, so "en", "eng" and "en-US" match, as do the
    /// bibliographic codes Jellyfin keeps ("ger") and the terminology ones ("deu").
    static func languageKey(_ tag: String) -> String {
        let base = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        let bibliographic = ["ger": "de", "fre": "fr", "chi": "zh", "dut": "nl", "cze": "cs", "gre": "el", "per": "fa",
                             "rum": "ro", "slo": "sk", "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "geo": "ka",
                             "ice": "is", "mac": "mk", "mao": "mi", "may": "ms", "tib": "bo", "wel": "cy"]
        if let code = bibliographic[base] { return code }
        return Locale.Language(identifier: base).languageCode?.identifier(.alpha2) ?? base
    }

    private func sendTracks() {
        let tracks = engine.audioTracks.compactMap { trackJSON($0, type: "audio") }
            + engine.subtitleTracks.compactMap { trackJSON($0, type: "subtitle") }
        send(["type": "player-tracks", "tracks": tracks])
    }

    private func sendChapters() {
        let chapters: [[String: Any]] = engine.mediaChapters.map { chapter in
            var json: [String: Any] = ["startMs": JSON.finite(chapter.startSeconds * 1000)]
            if !chapter.name.isEmpty { json["title"] = chapter.name }
            return json
        }
        send(["type": "player-chapters", "chapters": chapters])
    }

    private func sendAll() {
        var full: [String: Any] = [
            "idle": loadedURL == nil,
            "paused": loadedURL == nil ? wantsPaused : engine.state != .playing,
            "buffering": engine.isBuffering,
            "seeking": engine.isSeeking,
            "volume": volume,
            "maxVolume": 1.0,
            "muted": muted,
            "speed": speed,
            "audio": JSON.id(engine.activeAudioTrackIndex),
            "subtitle": JSON.id(engine.activeSubtitleTrackIndex),
        ]
        if loadedURL != nil {
            full["positionMs"] = JSON.finite((engine.currentTime + archiveOffset) * 1000)
            if engine.duration > 0 { full["durationMs"] = JSON.finite((archive?.length ?? engine.duration) * 1000) }
        }
        state(full)
        sendTracks()
        sendChapters()
    }

    private func reject(_ reason: String) {
        AppLog.warn("player", "refused: \(reason)")
        send(["type": "error", "message": reason])
    }

    // MARK: - From the page

    /// False for a message that isn't the player's.
    func handle(_ type: String, _ message: [String: Any]) -> Bool {
        switch type {
        case "player-load": load(message)
        case "player-stop": stop()
        case "player-set": change(message)
        case "player-seek":
            guard let ms = JSON.number(message["positionMs"]) else { break }
            let exact = (JSON.number(message["snapMs"]) ?? 0) <= 0
            seek(to: max(ms, 0) / 1000, exact: exact)
        case "player-subtitle-add": addSubtitle(message)
        case "subtitle-file": addSubtitleFile(message)
        case "player-style": style(message)
        case "player-sync": sendAll()
        case "player-thumbnail": thumbnail(message)
        case "player-subtitle-index":
            // Every line of the file's own subtitles, which the page's subtitle sync matches against.
            Task { [weak self] in
                guard let self else { return }
                let current = self.generation
                let tracks = await self.subtitleTimelines()
                guard current == self.generation else { return }
                self.send(["type": "player-subtitle-index", "tracks": tracks.map { $0 as Any } ?? NSNull()])
            }
        case "player-subtitle-lines":
            lineWatch?.cancel()
            guard let track = message["track"] as? String else { break }
            lineWatch = Task { [weak self] in
                guard let self else { return }
                let current = self.generation
                let tracks = await self.subtitleTimelines()
                guard !Task.isCancelled, current == self.generation else { return }
                self.send(["type": "player-subtitle-lines", "track": track, "lines": tracks?[track] ?? []])
            }
        case "player-stats-overlay":
            // A page of stats, or none; the app has the one page.
            statsOverlay(message["page"] is String)
        case "player-skips", "player-controls", "player-unqueue":
            break
        case "player-settings":
            if let delay = JSON.number(message["audioDelayMs"]) { engine.setAudioDelay(delay / 1000) }
            setShaping(message)
            if let on = JSON.flag(message["upscaling"]) { setUpscaling(on) }
        case "now-playing":
            nowPlaying.setItem(message["item"] as? [String: Any])
        default:
            return false
        }
        return true
    }

    /// The Sound settings as the engine shapes audio, which a playing title takes up where it is.
    private func setShaping(_ message: [String: Any]) {
        let channels = ["stereo": 2, "5.1": 6, "7.1": 8][message["audioChannels"] as? String ?? "auto"]
        let next = AudioShaping(
            maxChannels: channels,
            dialogueGainDB: JSON.number(message["dialogueBoost"]) ?? 0,
            compressor: JSON.flag(message["nightMode"]) == true ? .night : nil,
            binaural: JSON.flag(message["binaural"]) == true
        )
        guard next != shaping else { return }
        shaping = next
        AppLog.info("player", "audio shaping \(next.summary)")
        if loadedURL != nil { engine.setAudioShaping(next) }
    }

    /// An http(s) address, or a finished download's file inside the app's downloads folder,
    /// which the page names by the path the queue reported.
    static func playable(_ text: String) -> URL? {
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return url
        }
        return DownloadQueue.shared.localFile(text)
    }

    /// A page that loads again never owns the video the last one started.
    func pageLoading() {
        if loadedURL != nil { stop() }
        nowPlaying.setItem(nil)
    }

    private func load(_ message: [String: Any]) {
        guard var text = message["url"] as? String, var url = Self.playable(text)
        else { return reject("only http(s) urls and downloaded files play") }
        let headers = (message["headers"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        let startMs = JSON.number(message["startMs"]) ?? 0
        let mode = message["subtitleMode"] as? String ?? "default"

        var options = LoadOptions()
        options.httpHeaders = headers
        options.isLive = JSON.flag(message["live"]) ?? false
        // An origin that answers byte ranges with other bytes, as IPTV catch-up archives do, is
        // read straight through from its start, its length taken from the server (AE#958).
        let sequential = JSON.flag(message["sequential"]) == true && !options.isLive
        let length = JSON.number(message["durationMs"]).flatMap { $0 > 0 ? $0 / 1000 : nil }
        if let shifted = JSON.number(message["archiveOffsetS"]), archive != nil {
            // A reopen of the same archive from a later minute.
            archiveOffset = shifted
        } else {
            archive = sequential ? CatchUpArchive(text, length: length) : nil
            archiveOffset = 0
            // A place to start from is reached by asking for the archive from that minute.
            if let archive, startMs > 0 {
                archiveOffset = archive.offset(for: startMs / 1000)
                if archiveOffset > 0, let shifted = Self.playable(archive.address(from: archiveOffset)) {
                    text = archive.address(from: archiveOffset)
                    url = shifted
                } else {
                    archiveOffset = 0
                }
            }
        }
        if sequential {
            options.sequentialOrigin = true
            options.declaredDurationSeconds = length.map { max($0 - archiveOffset, 1) }
        }
        options.preferredAudioLanguages = JSON.strings(message["audioLanguages"])
        options.audioShaping = shaping
        // ASS and SSA events keep their markup, for libass to draw them as styled.
        options.preserveASSMarkup = true
        // TrueHD Atmos and DTS:X with their heights, which iOS plays as Spatial Audio (OS 26 and later).
        options.objectAudioRendering = .render(.l714)
        // Anime upscaling: the page asks for it on a title it knows is anime, with its setting on.
        options.upscalesLowResolutionVideo = upscaling
        options.upscaleScaler = .lineArt
        // Forced-only and none leave full subtitles off; the page picks forced ones itself.
        if mode == "default" || mode == "always" || mode == "smart" {
            options.preferredSubtitleLanguages = JSON.strings(message["subtitleLanguages"])
        }
        // A remote HLS stream's subtitles are AVPlayer's own, which arrive after the load and which
        // the engine leaves unpicked: the first in the user's languages is picked once they do.
        nativePickLanguages = mode == "always" ? JSON.strings(message["subtitleLanguages"]) : []
        nativePickTypes = JSON.strings(message["subtitleTypes"])
        nativePicked = false

        if JSON.number(message["archiveOffsetS"]) == nil { lastLoad = message }
        dropFrames()
        framesAllowed = !options.isLive && !sequential
        generation += 1
        let current = generation
        loadTask?.cancel()
        loadedURL = text
        loadedHeaders = headers
        indexTask?.cancel()
        indexTask = nil
        lineWatch?.cancel()
        playingUpscaled = nil
        ended = false
        restarted = false
        lastStatus = nil
        subtitleURLs = [:]
        thumbnails.clear()
        wantedThumbnail = nil
        overlay.clear()
        showVideo(true)
        mediaChanged()
        state(["idle": false])
        AppLog.info("player", "load live=\(options.isLive) sequential=\(sequential) archive=\(archive != nil) from=\(Int(archiveOffset))s start=\(Int(startMs)) url=\(url.host ?? "?")")

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                // A straight read can't start partway.
                let from = startMs > 0 && !sequential ? startMs / 1000 : nil
                try await self.engine.load(url: url, startPosition: from, options: options)
                guard current == self.generation else { return }
                self.applyTransport()
                self.event("loaded")
                self.playingUpscaled = options.upscalesLowResolutionVideo
                self.applyUpscaling()
                if self.wantsPaused { self.engine.pause() } else { self.engine.play() }
            } catch is CancellationError {
                // A newer load took its place.
            } catch {
                guard current == self.generation else { return }
                if self.loadSequentially() { return }
                self.end("error", error: error.localizedDescription)
            }
        }
    }

    /// Whether the line-art scaler runs, as the page's player settings last said. A change while a
    /// title plays rebuilds it where it is, which the engine does without starting it over.
    private var upscaling = false
    /// What the title playing was loaded or last rebuilt with; nil until a load finishes.
    private var playingUpscaled: Bool?

    private func setUpscaling(_ on: Bool) {
        upscaling = on
        applyUpscaling()
    }

    /// Brings the title playing in line with the setting. One still loading catches up once it has.
    private func applyUpscaling() {
        guard let current = playingUpscaled, current != upscaling else { return }
        let on = upscaling
        playingUpscaled = on
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.engine.reloadAtCurrentPosition { $0.upscalesLowResolutionVideo = on; $0.upscaleScaler = .lineArt }
            } catch {
                AppLog.warn("player", "upscaling not changed: \(error)")
            }
        }
    }

    /// The file's own subtitle tracks' lines, by the page's track id, read from the container's index.
    /// Only where the index's tracks match the engine's own, in number and in picture or text, so a
    /// track's lines are never another's. Ported from the 9pbpsvr6f9-alt/aiostreams-ios fork.
    private func subtitleTimelines() async -> [String: [[String: Double]]]? {
        guard let text = loadedURL, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let current = generation
        if indexTask == nil {
            let headers = loadedHeaders
            indexTask = Task {
                do { return try await SubtitleIndex.read(url: url, headers: headers) } catch {
                    AppLog.info("subtitles", "no subtitle index: \(error)")
                    return nil
                }
            }
        }
        guard let timelines = await indexTask?.value, !timelines.isEmpty, current == generation else { return nil }
        var own = engine.subtitleTracks.filter { !$0.isExternal }.sorted { $0.id < $1.id }
        // The page can ask before the engine has published its tracks.
        for _ in 0..<20 where own.isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, current == generation else { return nil }
            own = engine.subtitleTracks.filter { !$0.isExternal }.sorted { $0.id < $1.id }
        }
        let pictureCodecs = ["pgssub", "dvdsub", "dvbsub", "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"]
        guard own.count == timelines.count,
              zip(own, timelines).allSatisfy({ pictureCodecs.contains($0.codec.lowercased()) == $1.isPicture }) else { return nil }
        return Dictionary(uniqueKeysWithValues: zip(own, timelines).map { track, timeline in
            (String(track.id), timeline.lines.map { ["startMs": $0.start, "endMs": $0.end] })
        })
    }

    private func dropFrames() {
        let old = frames
        frames = nil
        framesAllowed = false
        if let old { Task { await old.shutdown() } }
    }

    private func stop() {
        dropFrames()
        playingUpscaled = nil
        loadedHeaders = [:]
        indexTask?.cancel()
        indexTask = nil
        lineWatch?.cancel()
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        loadedURL = nil
        engine.stop()
        overlay.clear()
        thumbnails.clear()
        showVideo(false)
        mediaChanged()
        state(["idle": true])
    }

    private func applyTransport() {
        engine.volume = muted ? 0 : Float(min(max(volume, 0), 1))
        if speed != 1 { engine.setRate(Float(speed)) }
    }

    private func change(_ message: [String: Any]) {
        var echo: [String: Any] = [:]
        if let paused = JSON.flag(message["paused"]) {
            wantsPaused = paused
            if loadedURL != nil, engine.isSessionReady {
                paused ? engine.pause() : engine.play()
            } else {
                echo["paused"] = paused
            }
        }
        if let value = JSON.number(message["volume"]) {
            volume = value
            echo["volume"] = value
        }
        if let value = JSON.flag(message["muted"]) {
            muted = value
            echo["muted"] = value
        }
        if message["volume"] != nil || message["muted"] != nil {
            engine.volume = muted ? 0 : Float(min(max(volume, 0), 1))
        }
        if let value = JSON.number(message["speed"]), value > 0 {
            speed = value
            engine.setRate(Float(value))
            echo["speed"] = value
        }
        if let audio = message["audio"] as? String, let id = Int(audio) {
            engine.selectAudioTrack(index: id)
        }
        if let subtitle = message["subtitle"] {
            if subtitle is NSNull {
                engine.clearSubtitle()
            } else if let text = subtitle as? String, let id = Int(text) {
                engine.selectSubtitleTrack(index: id)
            }
        }
        if let delay = JSON.number(message["subtitleDelayMs"]) {
            overlay.delay = delay / 1000
        }
        if !echo.isEmpty { state(echo) }
    }

    private func addSubtitle(_ message: [String: Any]) {
        guard let text = message["url"] as? String, let url = Self.playable(text)
        else { return reject("only http(s) and downloaded subtitles load") }
        if let replace = JSON.number(message["replace"]) {
            engine.removeExternalSubtitleTrack(id: Int(replace))
            subtitleURLs[Int(replace)] = nil
        }
        let language = (message["language"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let track = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(
            url: url,
            name: message["title"] as? String,
            language: language,
            // The media's headers belong to its own server, not the subtitles'.
            httpHeaders: [:]
        ))
        subtitleURLs[track.id] = text
        engine.selectSubtitleTrack(index: track.id)
        sendTracks()
    }

    /// The page never names a path to open, so a file it adds is written here first.
    private func addSubtitleFile(_ message: [String: Any]) {
        guard let name = message["name"] as? String else { return reject("subtitle file without a name") }
        let ext = (name as NSString).pathExtension.lowercased()
        guard ["srt", "vtt", "ass", "ssa", "sub", "sup"].contains(ext) else { return reject("\(name) is not a subtitle file") }
        guard let data = Data(base64Encoded: message["data"] as? String ?? "", options: .ignoreUnknownCharacters) else {
            return reject("\(name) could not be read")
        }
        guard data.count <= 10 << 20 else { return reject("\(name) is too big") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        subtitleFiles += 1
        let file = folder.appendingPathComponent("\(subtitleFiles).\(ext)")
        do {
            try data.write(to: file)
        } catch {
            return reject("\(name) could not be saved")
        }
        let track = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(
            url: file,
            name: String(name.prefix(200)),
            formatHint: ext
        ))
        engine.selectSubtitleTrack(index: track.id)
        sendTracks()
    }

    private func style(_ message: [String: Any]) {
        let gravity: AVLayerVideoGravity
        switch message["fit"] as? String {
        case "crop": gravity = .resizeAspectFill
        case "stretch": gravity = .resize
        default: gravity = .resizeAspect
        }
        // The page sends its style every frame while the controls lift the subtitles.
        if overlay.gravity != gravity {
            engine.videoGravity = gravity
            overlay.gravity = gravity
        }
        if let look = message["subtitles"] as? [String: Any] {
            let next = SubtitleLook(json: look)
            if next != overlay.look { overlay.look = next }
        }
    }

    private func thumbnail(_ message: [String: Any]) {
        guard let url = message["url"] as? String else { return }
        // Without a position the page only readies the file, which the engine already has open.
        guard let positionMs = JSON.number(message["positionMs"]) else { return }
        guard url == loadedURL else {
            send(["type": "player-thumbnail", "url": url, "src": NSNull()])
            return
        }
        wantedThumbnail = (url, positionMs)
        pumpThumbnails()
    }

    /// One keyframe at a time, always the latest one wanted.
    private func pumpThumbnails() {
        guard !thumbnailBusy, let wanted = wantedThumbnail else { return }
        wantedThumbnail = nil
        thumbnailBusy = true
        let current = generation
        Task { [weak self] in
            guard let self else { return }
            // The engine's position, which a catch-up archive opened partway starts from.
            let seconds = max(wanted.positionMs / 1000 - self.archiveOffset, 0)
            var image = await self.engine.scrubThumbnail(atSeconds: seconds, maxWidth: 320)
            // Not held yet: from the source itself, over a reader of its own.
            if image == nil, current == self.generation, self.framesAllowed {
                if self.frames == nil { self.frames = self.engine.makeFrameExtractor() }
                image = await self.frames?.thumbnail(at: seconds, maxWidth: 320)
            }
            self.thumbnailBusy = false
            if current == self.generation, let image,
               let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.7) {
                self.thumbnailCount += 1
                let path = "/thumbnail/\(self.thumbnailCount).jpg"
                self.thumbnails.put(path, jpeg)
                self.send(["type": "player-thumbnail", "url": wanted.url, "positionMs": wanted.positionMs, "src": path])
            }
            self.pumpThumbnails()
        }
    }

    var diagnostics: String {
        [
            "Engine: \(AppInfo.player)",
            "State: \(engine.state)",
            "Route: \(engine.videoRoute.rawValue)",
            "Audio: \(engine.audioDelivery.rawValue) \(engine.activeAudioDecoder ?? "")",
            // Whether Dialogue boost, Night mode, the channel cap and binaural reach the sound.
            "Audio shaping: \(shaping.summary) (\(engine.audioShapingState))",
            "Video: \(engine.sourceVideoCodecName ?? "?") \(engine.sourceVideoWidth)x\(engine.sourceVideoHeight) \(engine.videoFormat)",
            "Decoder: \(engine.activeVideoDecoder ?? "?")",
        ].joined(separator: "\n")
    }
}
