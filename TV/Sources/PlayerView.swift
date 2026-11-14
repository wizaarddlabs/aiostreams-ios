import AetherEngineFeatures
import AVKit
import Combine
import SwiftUI

/// One engine for the app's life, as AetherEngine is built to be reused across titles.
@MainActor
enum SharedEngine {
    static let engine: AetherEngine = {
        do {
            let engine = try AetherEngine()
            // Nothing else here plays sound, so the session is released when playback ends.
            engine.deactivatesAudioSessionOnStop = true
            return engine
        } catch {
            fatalError("AetherEngine could not start: \(error)")
        }
    }()
}

/// Plays one request and reports it to the server as the web app's `PlaybackReporter` does.
@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var paused = false
    @Published private(set) var waiting = true
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var audioTracks: [TrackInfo] = []
    @Published private(set) var subtitleTracks: [TrackInfo] = []
    @Published private(set) var activeAudio: Int?
    @Published private(set) var activeSubtitle: Int?
    @Published private(set) var failure: String?
    @Published private(set) var finished = false
    @Published private(set) var chapters: [ChapterInfo] = []
    /// How far ahead of the start the stream is held, in seconds.
    @Published private(set) var buffered: Double = 0
    @Published private(set) var speed: Double = 1
    @Published private(set) var fit: Fit = .fit
    /// The intros, recaps and credits the server knows for this title.
    @Published private(set) var segments: [MediaSegment] = []
    /// The episode after this one, which the up next offer plays.
    @Published private(set) var nextEpisode: Item?
    /// What the pause screen says about the title, read where the item came without it.
    @Published private(set) var overview: String?
    /// Seconds the subtitles are shown later (negative: earlier) than the file says.
    @Published private(set) var subtitleDelay: Double = 0
    /// Seconds the sound is held back (negative: brought forward) against the picture.
    @Published private(set) var audioDelay: Double = 0

    func setSubtitleDelay(_ seconds: Double) {
        subtitleDelay = (seconds * 10).rounded() / 10
        overlay.delay = subtitleDelay
    }

    func setAudioDelay(_ seconds: Double) {
        audioDelay = (seconds * 100).rounded() / 100
        engine.setAudioDelay(audioDelay)
    }

    enum Fit: String, CaseIterable {
        case fit = "Fit", crop = "Crop", stretch = "Stretch"

        var gravity: AVLayerVideoGravity {
            switch self {
            case .fit: return .resizeAspect
            case .crop: return .resizeAspectFill
            case .stretch: return .resize
            }
        }
    }

    let engine: AetherEngine
    let overlay: SubtitleOverlayView
    let request: PlayRequest
    /// A channel or another source with no end: played at its live edge, with no seeking.
    let isLive: Bool
    private let client: JellyfinClient
    private var bag = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var progressTimer: Timer?
    private var reported = false
    private var stopped = false

    private let audioLanguages: [String]
    private let subtitleLanguages: [String]
    private let speakers: SpatialSpeakerLayout?
    private let animeUpscaling: Bool
    private let rules: PlayerRules
    /// The server's segments, before the file's chapters are weighed against them.
    private var serverSegments: [MediaSegment] = []
    private let userId: String?

    init(request: PlayRequest, client: JellyfinClient, audioLanguages: [String] = [], subtitleLanguages: [String] = [],
         look: SubtitleLook = SubtitleLook(), speakers: SpatialSpeakerLayout? = .l714, animeUpscaling: Bool = false,
         userId: String? = nil, rules: PlayerRules = PlayerRules()) {
        self.request = request
        isLive = request.source.isInfiniteStream == true || request.item.isChannel
        self.client = client
        self.audioLanguages = audioLanguages
        self.subtitleLanguages = subtitleLanguages
        self.speakers = speakers
        self.animeUpscaling = animeUpscaling
        self.rules = rules
        self.userId = userId
        engine = SharedEngine.engine
        overlay = SubtitleOverlayView()
        overlay.look = look
        baseLook = look
        observe()
    }

    private func observe() {
        engine.$state
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .playing: self.setPaused(false)
                case .paused: self.setPaused(true)
                case .ended: self.finished = true
                case .error(let message):
                    AppLog.warn("player", "error: \(message)")
                    self.failure = message
                default: break
                }
            }
            .store(in: &bag)
        Publishers.CombineLatest3(engine.$isBuffering, engine.$isSeeking, engine.$hasFirstFrameReadyForDisplay)
            .sink { [weak self] buffering, seeking, ready in self?.waiting = buffering || seeking || !ready }
            .store(in: &bag)
        engine.clock.$currentTime
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.position = $0 }
            .store(in: &bag)
        engine.$duration.sink { [weak self] in
            self?.duration = $0
            // The last chapter runs to the end, which a later duration moves.
            self?.combineSegments()
        }.store(in: &bag)
        engine.$mediaChapters.sink { [weak self] in
            self?.chapters = $0
            self?.combineSegments()
        }.store(in: &bag)
        engine.clock.$bufferedPosition
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.buffered = $0 }
            .store(in: &bag)
        engine.$audioTracks.sink { [weak self] in self?.audioTracks = $0 }.store(in: &bag)
        engine.$subtitleTracks.sink { [weak self] in self?.subtitleTracks = $0 }.store(in: &bag)
        engine.$activeAudioTrackIndex.sink { [weak self] in self?.activeAudio = $0 }.store(in: &bag)
        engine.$activeSubtitleTrackIndex.sink { [weak self] in self?.activeSubtitle = $0 }.store(in: &bag)
        engine.$subtitleCues.sink { [weak self] in self?.overlay.setCues($0) }.store(in: &bag)
        engine.clock.$sourceTime.sink { [weak self] in self?.overlay.setTime($0) }.store(in: &bag)
        Publishers.CombineLatest(engine.$sourceVideoWidth, engine.$sourceVideoHeight)
            .sink { [weak self] width, height in
                guard let self else { return }
                let aspect = self.engine.sourceVideoPixelAspectRatio
                self.overlay.videoSize = CGSize(width: Double(width) * (aspect > 0 ? aspect : 1), height: Double(height))
            }
            .store(in: &bag)
    }

    func start() {
        guard loadTask == nil else { return }
        guard let url = client.streamURL(itemId: request.item.id, source: request.source) else {
            failure = "This version has no address to play."
            return
        }
        var options = LoadOptions()
        options.httpHeaders = request.source.requiredHttpHeaders ?? [:]
        // The engine writes the display criteria itself, following the Apple TV's Match Content setting.
        options.matchContentEnabled = Self.window?.avDisplayManager.isDisplayCriteriaMatchingEnabled ?? true
        // Serves Dolby Vision profile 8 as profile 5 on a TV without Dolby Vision; ignored on one with it.
        options.forceDolbyVisionOnNonDVDisplay = true
        options.externalSubtitles = serverSubtitles()
        // The account's languages and subtitle mode, as the web app passes them to its players.
        options.preferredAudioLanguages = audioLanguages
        options.preferredSubtitleLanguages = subtitleLanguages
        // TrueHD Atmos and DTS:X with their heights, rendered for the receiver's speakers and sent to it
        // as Dolby MAT (tvOS 26 and later); off, they play as their 7.1 channels.
        options.objectAudioRendering = speakers.map { .render($0) } ?? .off
        options.isLive = isLive

        // The engine is shared: a title starts in sync, whatever the last one was set to.
        engine.setAudioDelay(0)
        overview = request.item.overview
        Task { [weak self] in await self?.loadExtras() }
        AppLog.info("player", "load \(request.item.id) source=\(request.source.ownId) host=\(url.host ?? "?")")
        loadTask = Task { [weak self] in
            guard let self else { return }
            var loadOptions = options
            do {
                // Anime upscaling, decided before the load so the first frame is already upscaled.
                if self.animeUpscaling, !self.request.isTrailer, await self.isAnime() {
                    loadOptions.upscalesLowResolutionVideo = true
                    loadOptions.upscaleScaler = .lineArt
                    AppLog.info("player", "anime upscaling on")
                }
                let start = self.isLive ? nil : self.request.startMs.map { $0 / 1000 }
                try await self.engine.load(url: url, startPosition: start, options: loadOptions)
                self.engine.play()
                self.report("/Sessions/Playing")
                self.progressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report("/Sessions/Playing/Progress", event: "TimeUpdate") }
                }
            } catch is CancellationError {
            } catch {
                AppLog.warn("player", "load failed: \(error)")
                self.failure = error.localizedDescription
            }
        }
    }

    /// The segments and the next episode, alongside the load.
    private func loadExtras() async {
        guard !isLive, !request.isTrailer, let userId else { return }
        let item = request.item
        if overview == nil {
            let full: ItemsResult? = try? await client.get("/Items", ["userId": userId, "Ids": item.id, "Fields": "Overview"])
            overview = full?.items?.first?.overview
        }
        let found: SegmentsResult? = try? await client.get("/MediaSegments/\(item.id)", ["userId": userId])
        serverSegments = (found?.items ?? []).filter { $0.end > $0.start }
        combineSegments()
        // The episode after this one, as the web app finds it; one not yet out isn't offered.
        guard item.isEpisode, let series = item.seriesId else { return }
        let around: ItemsResult? = try? await client.get("/Shows/\(series)/Episodes", ["userId": userId, "AdjacentTo": item.id])
        var episodes = around?.items ?? []
        // Filler and recap episodes the server marks are passed over, as the settings say.
        let rules = rules
        let skipped = { (episode: Item) in
            episode.id != item.id
                && ((rules.skipFillers && episode.aiostreams?.filler == true) || (rules.skipRecaps && episode.aiostreams?.recap == true))
        }
        // A run of skipped episodes needs the rest of the show.
        if episodes.contains(where: skipped) {
            let all: ItemsResult? = try? await client.get("/Shows/\(series)/Episodes", ["userId": userId])
            episodes = all?.items ?? episodes
        }
        guard let at = episodes.firstIndex(where: { $0.id == item.id }) else { return }
        for next in episodes[(at + 1)...] {
            // Not out yet, or (with Mark unaired) out only on a date still to come: nothing to play on to.
            let airsLater = rules.markUnaired && (parseDate(next.premiereDate) ?? .distantPast) > Date()
            if next.locationType == "Virtual" || airsLater { return }
            if !skipped(next) {
                nextEpisode = next
                return
            }
        }
    }

    /// The server's segments and the ones the file's chapters name: for each kind, the chapters'
    /// where Skip by the file's chapters is on, else the server's, the other filling what's left.
    private func combineSegments() {
        let named = MediaSegment.named(chapters: chapters.map { (title: $0.name, start: $0.startSeconds) }, duration: duration)
        var kinds = Set<String>()
        var combined: [MediaSegment] = []
        for source in rules.chapterSkips ? [named, serverSegments] : [serverSegments, named] {
            let added = source.filter { !kinds.contains($0.type) }
            kinds.formUnion(added.map(\.type))
            combined += added
        }
        segments = combined.sorted { $0.start < $1.start }
    }

    /// Anime by the web app's test: an anime database id on the title, its season or its show. A
    /// season can carry them from the server's anime database when its show has none.
    private func isAnime() async -> Bool {
        guard !isLive, let userId else { return false }
        let item = request.item
        let ids = [item.id, item.seasonId, item.seriesId].compactMap { $0 }
        let result: ItemsResult? = try? await client.get("/Items", [
            "userId": userId, "Ids": ids.joined(separator: ","), "Fields": "ProviderIds",
        ])
        return (result?.items ?? []).contains(where: \.hasAnimeIds)
    }

    /// The configuration's subtitle addons' files, registered as tracks the user can pick.
    private func serverSubtitles() -> [ExternalSubtitleTrack] {
        (request.source.mediaStreams ?? []).compactMap { stream in
            guard stream.type == "Subtitle", stream.isExternal == true,
                  let address = stream.deliveryUrl, let url = client.absolute(address) else { return nil }
            return ExternalSubtitleTrack(
                url: url,
                name: stream.displayTitle ?? stream.title,
                language: stream.language,
                isForced: stream.isForced ?? false,
                httpHeaders: [:]
            )
        }
    }

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
    }

    private func setPaused(_ value: Bool) {
        let changed = value != paused
        paused = value
        if changed, reported { report("/Sessions/Playing/Progress", event: value ? "Pause" : "Unpause") }
    }

    func togglePause() { engine.togglePlayPause() }

    // MARK: Holding left or right

    /// Where a held left or right, or a swipe, has scrubbed to, while it lasts.
    @Published private(set) var scrubTarget: Double? {
        didSet {
            if let scrubTarget { wantPreview(scrubTarget) } else if oldValue != nil { endPreviews() }
        }
    }
    /// A frame from where the scrub would land, shown over the bar.
    @Published private(set) var preview: CGImage?
    private var previewBusy = false
    private var previewWanted: Double?

    /// The scrub is over: its frame goes, and the engine closes the decoders that made the frames,
    /// which on a 4K title cost 100 to 160 MB each.
    private func endPreviews() {
        preview = nil
        let engine = engine
        Task { await engine.releaseScrubPreviewDecoders() }
    }

    /// Asks the engine for a frame at `seconds`; while one is being made, only the latest ask waits.
    private func wantPreview(_ seconds: Double) {
        // Only a session whose bytes the engine holds can make frames; others show the time alone.
        guard engine.supportsCacheBackedStills else { return }
        previewWanted = seconds
        guard !previewBusy else { return }
        previewBusy = true
        Task { [weak self] in
            guard let self else { return }
            let image = await self.engine.scrubThumbnail(atSeconds: seconds, maxWidth: 480)
            self.previewBusy = false
            guard self.scrubTarget != nil else { return }
            if let image { self.preview = image }
            if let wanted = self.previewWanted, wanted != seconds { self.wantPreview(wanted) }
        }
    }
    /// How many times faster than playback the scrub moves, for its badge; negative backwards.
    @Published private(set) var scrubSpeed = 0
    private var scrubTask: Task<Void, Never>?
    private var scrubDirection = 0
    var scrubbing: Bool { scrubTask != nil }

    /// Scrubs while left or right is held, faster the longer it's held: 10x, then 30x after
    /// 1.5 s, 60x after 3 s and 120x from 5 s. Letting go seeks there once.
    /// Asking again in the same direction carries on; the other way turns round from where it got to.
    func startScrub(_ direction: Int) {
        if scrubTask != nil && scrubDirection == direction { return }
        scrubTask?.cancel()
        scrubDirection = direction
        scrubTarget = scrubTarget ?? position
        let tick = 0.2
        scrubTask = Task { [weak self] in
            var held = 0.0
            while !Task.isCancelled {
                guard let self else { return }
                let rate: Double = held < 1.5 ? 10 : held < 3 ? 30 : held < 5 ? 60 : 120
                self.scrubSpeed = direction * Int(rate)
                let next = (self.scrubTarget ?? self.position) + Double(direction) * rate * tick
                self.scrubTarget = min(max(next, 0), max(self.duration - 1, 0))
                held += tick
                try? await Task.sleep(for: .milliseconds(Int(tick * 1000)))
            }
        }
    }

    func endScrub() {
        scrubTask?.cancel()
        scrubTask = nil
        scrubDirection = 0
        if let target = scrubTarget { seek(to: target) }
        scrubTarget = nil
        scrubSpeed = 0
    }

    // MARK: Swiping while paused

    private var swipeFrom: Double?

    /// A swipe across the remote while paused: the whole surface is a quarter of the video,
    /// and never less than two minutes, so a few quick swipes cross any of it.
    func startSwipe() {
        swipeFrom = scrubTarget ?? position
        scrubTarget = swipeFrom
    }

    func swipe(_ share: Double) {
        guard let swipeFrom else { return }
        let span = max(duration / 4, 120)
        scrubTarget = min(max(swipeFrom + share * span, 0), max(duration - 1, 0))
    }

    /// Lifting the finger seeks there once; playback stays paused.
    func endSwipe() {
        swipeFrom = nil
        if let target = scrubTarget { seek(to: target) }
        scrubTarget = nil
    }

    func seek(to seconds: Double) {
        let target = min(max(seconds, 0), max(duration - 1, 0))
        position = target
        Task { await engine.seek(to: target) }
    }

    func setSpeed(_ value: Double) {
        speed = value
        engine.setRate(Float(value))
    }

    // MARK: Subtitle lift

    /// The user's subtitle style, which the lift raises from.
    private var baseLook = SubtitleLook()
    /// The share of the screen the subtitles are kept above now.
    private var lift: Double = 0
    private var liftTask: Task<Void, Never>?

    /// Keeps the subtitles above `share` of the screen's height, which the controls cover, or back
    /// to their own height at 0, sliding over the web app's 300 ms (SUBTITLE_LIFT_MS).
    func liftSubtitles(_ share: Double) {
        let target = min(max(share, 0), 0.9)
        guard abs(target - lift) > 0.001 else { return }
        liftTask?.cancel()
        let from = lift
        let start = Date()
        liftTask = Task { [weak self] in
            while !Task.isCancelled {
                let done = min(1, Date().timeIntervalSince(start) / 0.3)
                // The web app's ease, 1 - (1 - t)^3.
                let value = from + (target - from) * (1 - pow(1 - done, 3))
                self?.applyLift(value)
                if done >= 1 { return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func applyLift(_ value: Double) {
        lift = value
        var look = baseLook
        // Percent from the top where the bottom line sits: the higher of the user's own and the controls'.
        look.position = min(baseLook.position, 100 - value * 100)
        overlay.look = look
    }

    func setFit(_ value: Fit) {
        fit = value
        engine.videoGravity = value.gravity
        overlay.gravity = value.gravity
    }

    func skip(_ seconds: Double) {
        let target = min(max(position + seconds, 0), max(duration - 1, 0))
        position = target
        Task { await engine.seek(to: target) }
    }

    func selectAudio(_ id: Int) {
        engine.selectAudioTrack(index: id)
        report("/Sessions/Playing/Progress", event: "AudioTrackChange")
    }

    func selectSubtitle(_ id: Int?) {
        if let id { engine.selectSubtitleTrack(index: id) } else { engine.clearSubtitle() }
        report("/Sessions/Playing/Progress", event: "SubtitleTrackChange")
    }

    private func body(_ extra: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = [
            "ItemId": request.item.id,
            "MediaSourceId": request.source.ownId,
            "PositionTicks": Int64(position * 1000 * JellyfinClient.ticksPerMs),
            "IsPaused": paused,
            "CanSeek": !isLive,
            "PlayMethod": "DirectPlay",
        ]
        if let session = request.playSessionId { body["PlaySessionId"] = session }
        return body.merging(extra) { _, new in new }
    }

    private func report(_ path: String, event: String? = nil) {
        guard !stopped, !request.isTrailer else { return }
        if path == "/Sessions/Playing" { reported = true }
        let payload = body(event.map { ["EventName": $0] } ?? [:])
        let client = client
        Task { await client.fire(path, body: payload) }
    }

    /// Saves the position on the server and hands the screen back to the app.
    func stop() {
        guard !stopped else { return }
        progressTimer?.invalidate()
        loadTask?.cancel()
        if reported {
            let payload = body()
            let client = client
            Task { await client.fire("/Sessions/Playing/Stopped", body: payload) }
        }
        stopped = true
        bag.removeAll()
        overlay.clear()
        // The plain stop returns the TV to its default mode for the app's own screens.
        engine.stop()
    }
}

/// The engine's picture with the subtitles over it.
struct VideoSurface: UIViewRepresentable {
    let model: PlayerModel

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        let video = AetherPlayerView()
        for view in [video, model.overlay] as [UIView] {
            view.frame = container.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(view)
        }
        model.engine.bind(view: video)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

