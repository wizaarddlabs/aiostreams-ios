import AetherEngineFeatures
import SwiftUI

// The web app's player as a TV shows it: the title over the top, a purple progress bar with
// chapter marks, and a row of controls, which hide while the video plays. Hidden, the remote
// drives playback itself; shown, its buttons and the bar take focus.

struct PlayerScreen: View {
    let request: PlayRequest
    let close: () -> Void
    /// Lists an episode's versions, for one whose next episode has none that carries on.
    var listVersions: (Item) -> Void = { _ in }

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @State private var model: PlayerModel?
    /// The episode a version is being found for, to play on in.
    @State private var finding: Item?

    var body: some View {
        Group {
            if let model {
                PlayerChrome(model: model, close: finish, playNext: { next in Task { await playOn(next) } }, finding: finding)
                    // A new title starts the controls over.
                    .id(model.request.id)
            } else {
                Color.black
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            if let finding {
                HStack(spacing: Theme.px(12)) {
                    ProgressView()
                    Text("Finding a version of \(finding.displayTitle)…").font(Theme.font(Theme.base, .medium))
                }
                .padding(.horizontal, Theme.px(20))
                .padding(.vertical, Theme.px(12))
                .background(Capsule().fill(Color(white: 17 / 255).opacity(0.95)))
                .padding(.bottom, Theme.px(40))
            }
        }
        .onAppear { if model == nil { start(request) } }
    }

    private func start(_ request: PlayRequest) {
        guard let client = session.client else { return }
        let player = PlayerModel(
            request: request,
            client: client,
            audioLanguages: request.audioLanguages ?? prefs.audioLanguages,
            subtitleLanguages: prefs.subtitleLanguages,
            look: prefs.subtitleLook,
            speakers: prefs.speakers,
            animeUpscaling: prefs.animeUpscaling,
            userId: session.userId,
            rules: prefs.playerRules
        )
        model = player
        player.start()
    }

    /// Plays the next episode here, in the version that carries on from this one: the same binge
    /// group, else the only or first one where allowed. Without one, its versions are listed.
    private func playOn(_ next: Item) async {
        guard finding == nil, let current = model, let client = session.client, let userId = session.userId else { return }
        finding = next
        defer { finding = nil }
        let info = try? await client.playbackInfo(userId: userId, itemId: next.id)
        let sources = (info?.mediaSources ?? []).filter { $0.aiostreams?.ytId == nil }
        let group = current.request.source.aiostreams?.bingeGroup
        let carried = group.flatMap { group in sources.first { $0.aiostreams?.bingeGroup == group } }
            ?? (sources.count == 1 || prefs.nextFallbackFirst ? sources.first : nil)
        guard let source = carried else {
            listVersions(next)
            finish()
            return
        }
        // Named again, the version brings its subtitles from the configuration's subtitle addons.
        var chosen = source
        var playSession = info?.playSessionId
        if let named = try? await client.playbackInfo(userId: userId, itemId: next.id, sourceId: source.ownId),
           let match = named.mediaSources?.first(where: { $0.ownId == source.ownId }) ?? named.mediaSources?.first {
            chosen = match
            playSession = named.playSessionId ?? playSession
        }
        LastVersions.set(next.id, chosen.ownId)
        current.stop()
        let startMs = next.userData?.played == true ? nil : next.resumeMs
        start(PlayRequest(item: next, source: chosen, playSessionId: playSession, startMs: startMs))
    }

    private func finish() {
        model?.stop()
        close()
    }
}

/// Episodes played on by themselves since anyone last pressed anything, for "Are you still watching?".
@MainActor
enum UnattendedPlays {
    static var count = 0
}

private enum PlayerFocus: Hashable {
    case surface, bar, play, back, forward, tracks, audio, chapters, speed, fit, skip, next, keepWatching, stop, sync, episodes
}

private enum PlayerPanel: Hashable {
    case tracks, audio, chapters, speed, sync, episodes
}

private struct PlayerChrome: View {
    @ObservedObject var model: PlayerModel
    let close: () -> Void
    let playNext: (Item) -> Void
    let finding: Item?

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    /// The segment a skip button is offered for.
    @State private var offer: MediaSegment?
    /// The first seconds of an offered segment, when its button shows over hidden controls.
    @State private var offerFresh = false
    @State private var freshTask: Task<Void, Never>?
    /// "Skipped intro", after a skip the settings made.
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?
    /// Back hid the up next offer; seeking back before it brings it back.
    @State private var upNextDismissed = false
    @State private var askingStill = false
    @State private var countdownLeft: Double = 15
    @State private var playingOn = false

    @State private var shown = true
    @State private var panel: PlayerPanel?
    @State private var hideTask: Task<Void, Never>?
    @State private var controlsTop: CGFloat?

    /// The share of the screen under the top of the controls, with a little room above them.
    private var liftShare: Double {
        guard let controlsTop else { return 0 }
        let height = UIScreen.main.bounds.height
        return height > 0 ? Double(1 - (controlsTop - Theme.px(8)) / height) : 0
    }
    @FocusState private var focus: PlayerFocus?
    /// A hold the press watcher reported, which only its letting go ends.
    @State private var pressHeld = false
    /// The last few left or right moves, which come quickly over and over while a direction is held.
    @State private var lastMove: (direction: Int, at: Date, count: Int)?
    @State private var moveHoldEnd: Task<Void, Never>?
    /// A swipe along the bar in progress, or just finished.
    @State private var swiping = false
    @State private var swipeSettled: Task<Void, Never>?

    private var canScrub: Bool {
        !model.isLive && panel == nil && model.failure == nil && (!shown || focus == .bar || focus == .surface)
    }

    /// A move left or right, which reads as a hold once it repeats quickly, for remotes and
    /// directions that repeat their move while held. Returns whether it went to a scrub.
    private func moved(_ direction: Int) -> Bool {
        if pressHeld || swiping { return true }
        let now = Date()
        var count = 1
        if let last = lastMove, last.direction == direction, now.timeIntervalSince(last.at) < 0.4 {
            count = last.count + 1
        }
        lastMove = (direction, now, count)
        guard model.scrubbing || count >= 3, canScrub else { return false }
        model.startScrub(direction)
        moveHoldEnd?.cancel()
        moveHoldEnd = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, !pressHeld else { return }
            model.endScrub()
            lastMove = nil
            wake()
        }
        return true
    }

    var body: some View {
        ZStack {
            VideoSurface(model: model).ignoresSafeArea()

            // Holding left or right scrubs, while the controls are hidden or the bar has focus.
            PressHold(
                begin: { direction in
                    guard canScrub else { return false }
                    pressHeld = true
                    moveHoldEnd?.cancel()
                    model.startScrub(direction)
                    reveal(.bar)
                    return true
                },
                end: {
                    pressHeld = false
                    model.endScrub()
                    wake()
                }
            )
            .frame(width: 0, height: 0)

            // Swiping across the remote while paused, with the bar focused, slides along it.
            SwipeScrub(
                begin: {
                    guard !model.isLive, model.paused, shown, focus == .bar, panel == nil, model.failure == nil,
                          !model.scrubbing else { return false }
                    swiping = true
                    swipeSettled?.cancel()
                    model.startSwipe()
                    return true
                },
                change: { model.swipe($0) },
                end: {
                    model.endSwipe()
                    // The focus engine's own moves from the swipe can trail it; those aren't skips.
                    swipeSettled = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        if !Task.isCancelled { swiping = false }
                    }
                    wake()
                }
            )
            .frame(width: 0, height: 0)

            // Takes the remote while the controls are hidden.
            Color.clear
                .contentShape(Rectangle())
                .focusable(!shown && panel == nil)
                .focused($focus, equals: .surface)
                .onMoveCommand { direction in
                    input()
                    switch direction {
                    // Live, there's nothing to skip through: a press only shows the controls.
                    case .left where model.isLive, .right where model.isLive: reveal(.play)
                    case .left: if !moved(-1) { model.skip(-step) }; if prefs.showOnPauseAndSkip { reveal(.bar) }
                    case .right: if !moved(1) { model.skip(step) }; if prefs.showOnPauseAndSkip { reveal(.bar) }
                    default: reveal(.play)
                    }
                }
                .onTapGesture { input(); reveal(.play) }

            if model.waiting && model.failure == nil {
                ProgressView().scaleEffect(1.6)
            }
            if let failure = model.failure { failureCard(failure) }

            if shown {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }

            if let panel {
                HStack {
                    Spacer()
                    PlayerPanelView(model: model, panel: panel, play: { episode in
                        closePanel()
                        input()
                        playNext(episode)
                    }) { closePanel() }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if panel == nil && model.failure == nil {
                VStack(alignment: .trailing, spacing: Theme.px(12)) {
                    if let notice {
                        Text(notice)
                            .font(Theme.font(Theme.sm, .medium))
                            .padding(.horizontal, Theme.px(14))
                            .padding(.vertical, Theme.px(8))
                            .background(Capsule().fill(.black.opacity(0.7)))
                            .transition(.opacity)
                    }
                    if askingStill {
                        stillWatchingCard
                    } else if upNextShown, let next = model.nextEpisode {
                        upNextCard(next)
                    } else if skipShown, let offer {
                        Button { skip(offer) } label: {
                            Label(skipLabel(offer.type), systemImage: "forward.end.fill")
                        }
                        .buttonStyle(SkipStyle())
                        .focused($focus, equals: .skip)
                        .transition(.opacity)
                    }
                }
                // Its own focus section, no bigger than what it shows.
                .focusSection()
                .padding(.trailing, Theme.px(40))
                .padding(.bottom, shown ? Theme.px(150) : Theme.px(48))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .font(Theme.font(Theme.base))
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.2), value: shown)
        .animation(.easeOut(duration: 0.2), value: panel)
        .onPlayPauseCommand { input(); model.togglePause(); wake() }
        .onExitCommand {
            if askingStill { close() }
            else if panel != nil { closePanel() }
            else if upNextShown && (focus == .next || !shown) {
                upNextDismissed = true
                focus = shown ? .play : .surface
            } else if skipShown && focus == .skip && !shown {
                offerFresh = false
                focus = .surface
            }
            else if shown && model.failure == nil { hide() }
            else { close() }
        }
        .onAppear { focus = .play; wake() }
        .onChange(of: focus) { _, _ in if shown { wake() } }
        // The subtitles rise over the controls while they show, and settle back as they hide.
        .onChange(of: shown) { _, shown in model.liftSubtitles(shown ? liftShare : 0) }
        // At the end, the next episode plays on where Jellyfin's autoplay is on.
        .onChange(of: model.finished) { _, done in
            guard done else { return }
            if model.nextEpisode != nil && prefs.autoplayNext { playOn(auto: true) } else { close() }
        }
        .onChange(of: inside?.id) { _, _ in enter(inside) }
        .onChange(of: skipShown) { _, showing in
            if showing && !shown { focus = .skip }
            if !showing && focus == .skip { focus = shown ? .play : .surface }
        }
        .onChange(of: upNextShown) { _, showing in
            if showing && !shown { focus = .next }
            if !showing {
                countdownLeft = prefs.nextCountdown
                if focus == .next { focus = shown ? .play : .surface }
            }
        }
        .onChange(of: upNextDue) { _, due in if !due { upNextDismissed = false } }
        .onChange(of: askingStill) { _, asking in if asking { focus = .keepWatching } }
        .onAppear { countdownLeft = prefs.nextCountdown }
        // Counts down while the offer shows and the video plays, then plays on.
        .task(id: counting) {
            guard counting else { return }
            while countdownLeft > 0 {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                countdownLeft = max(0, countdownLeft - 0.25)
            }
            playOn(auto: true)
        }
        .onChange(of: model.paused) { _, paused in
            if paused { if prefs.showOnPauseAndSkip || shown { reveal(nil) } } else { wake() }
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(spacing: Theme.px(16)) {
            Image(systemName: "arrow.left").font(.system(size: Theme.px(20), weight: .medium))
            VStack(alignment: .leading, spacing: Theme.px(2)) {
                Text(model.request.item.isEpisode ? (model.request.item.seriesName ?? "") : (model.request.item.name ?? ""))
                    .font(Theme.font(17, .semibold))
                    .lineLimit(1)
                if model.request.item.isChannel, let programme = model.request.item.currentProgram?.name {
                    Text(programme)
                        .font(Theme.font(Theme.sm))
                        .foregroundStyle(Theme.gray300)
                        .lineLimit(1)
                }
                if model.request.item.isEpisode {
                    Text(model.request.item.displayTitle)
                        .font(Theme.font(Theme.sm))
                        .foregroundStyle(Theme.gray300)
                        .lineLimit(1)
                }
                // The pause screen: what it's about, while it waits.
                if model.paused && !model.isLive, let overview = model.overview, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.font(Theme.base))
                        .foregroundStyle(Theme.gray200)
                        .lineLimit(4)
                        .frame(maxWidth: Theme.px(720), alignment: .leading)
                        .padding(.top, Theme.px(10))
                        .transition(.opacity)
                }
            }
            Spacer()
            if prefs.showClock {
                // The time of day, as the web app's player shows it.
                TimelineView(.everyMinute) { context in
                    Text(prefs.time(context.date))
                        .font(Theme.font(17, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.gray200)
                }
            }
        }
        .padding(.horizontal, Theme.px(32))
        .padding(.top, Theme.px(28))
        .padding(.bottom, Theme.px(48))
        .background(
            LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: Bottom

    private var bottomBar: some View {
        VStack(spacing: Theme.px(14)) {
            if model.isLive {
                // A live source has no timeline to move along.
                Capsule().fill(Theme.brand500).frame(height: Theme.px(4))
            } else {
            ProgressTrack(model: model, focused: focus == .bar)
                .focusable(shown && panel == nil)
                .focused($focus, equals: .bar)
                .onMoveCommand { direction in
                    input()
                    switch direction {
                    case .left: if !moved(-1) { model.skip(-step) }
                    case .right: if !moved(1) { model.skip(step) }
                    case .down: if !swiping { focus = .play }
                    default: break
                    }
                    wake()
                }
                .onTapGesture { model.togglePause(); wake() }
                // Floats over the bar, so the controls stay where they are while it shows.
                .overlay(alignment: .bottomLeading) { scrubPreview }
            }
            HStack(spacing: Theme.px(8)) {
                Button { model.togglePause() } label: {
                    Image(systemName: model.paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(BigPlayStyle())
                .focused($focus, equals: .play)
                if model.isLive {
                    Text("LIVE")
                        .font(Theme.font(Theme.sm, .bold))
                        .padding(.horizontal, Theme.px(10))
                        .padding(.vertical, Theme.px(4))
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                        .padding(.leading, Theme.px(12))
                } else {
                    Button { model.skip(-step) } label: { Image(systemName: "gobackward.\(prefs.seekStep)") }
                        .buttonStyle(ControlIconStyle())
                        .focused($focus, equals: .back)
                    Button { model.skip(step) } label: { Image(systemName: "goforward.\(prefs.seekStep)") }
                        .buttonStyle(ControlIconStyle())
                        .focused($focus, equals: .forward)
                    HStack(spacing: 0) {
                        let at = model.scrubTarget ?? model.position
                        Text(clock(at))
                        // The time left, or the whole length, as the setting asks.
                        Text(prefs.showTimeLeft ? " / -" + clock(max(model.duration - at, 0)) : " / " + clock(model.duration))
                            .foregroundStyle(Theme.gray400)
                    }
                    .font(Theme.font(17, .medium))
                    .monospacedDigit()
                    .padding(.leading, Theme.px(12))
                }
                Spacer()
                if model.request.item.isEpisode {
                    Button { open(.episodes) } label: { Image(systemName: "list.and.film") }
                        .buttonStyle(ControlIconStyle())
                        .focused($focus, equals: .episodes)
                }
                // Audio and subtitles each have their own button, so a long subtitle list doesn't
                // bury the audio tracks.
                Button { open(.audio) } label: { Image(systemName: "speaker.wave.2") }
                    .buttonStyle(ControlIconStyle())
                    .focused($focus, equals: .audio)
                Button { open(.tracks) } label: { Image(systemName: "captions.bubble") }
                    .buttonStyle(ControlIconStyle())
                    .focused($focus, equals: .tracks)
                if !model.isLive {
                    Button { open(.sync) } label: { Image(systemName: "timer") }
                        .buttonStyle(ControlIconStyle())
                        .focused($focus, equals: .sync)
                }
                if !model.chapters.isEmpty {
                    Button { open(.chapters) } label: { Image(systemName: "list.bullet") }
                        .buttonStyle(ControlIconStyle())
                        .focused($focus, equals: .chapters)
                }
                if !model.isLive {
                    Button { open(.speed) } label: { Image(systemName: "gauge.with.dots.needle.50percent") }
                        .buttonStyle(ControlIconStyle())
                        .focused($focus, equals: .speed)
                }
                Button {
                    let all = PlayerModel.Fit.allCases
                    model.setFit(all[(all.firstIndex(of: model.fit)! + 1) % all.count])
                } label: {
                    Image(systemName: model.fit == .fit ? "rectangle.arrowtriangle.2.outward" : model.fit == .crop ? "crop" : "arrow.left.and.right.square")
                }
                .buttonStyle(ControlIconStyle())
                .focused($focus, equals: .fit)
            }
            .focusSection()
        }
        // Where the controls start, which the subtitles are kept above while they show.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).minY
        } action: { top in
            controlsTop = top
            if shown { model.liftSubtitles(liftShare) }
        }
        .padding(.horizontal, Theme.px(20))
        .padding(.bottom, Theme.px(16))
        .padding(.top, Theme.px(64))
        .background(
            LinearGradient(colors: [.black.opacity(0.9), .black.opacity(0.5), .clear], startPoint: .bottom, endPoint: .top)
        )
    }

    private static let previewWidth = Theme.px(240)
    private static let previewHeight = Theme.px(210)

    /// While scrubbing: a frame from where it would land, its time, and the speed, over that point of
    /// the bar. The frame comes in as the engine makes it; until then the time and speed show alone.
    @ViewBuilder private var scrubPreview: some View {
        if let target = model.scrubTarget {
            GeometryReader { geometry in
                let width = geometry.size.width
                let at = model.duration > 0 ? CGFloat(min(max(target / model.duration, 0), 1)) * width : 0
                let x = min(max(at - Self.previewWidth / 2, 0), max(width - Self.previewWidth, 0))
                VStack(spacing: Theme.px(6)) {
                    if let image = model.preview {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: Self.previewWidth, height: Self.previewWidth * 9 / 16)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous)
                                .stroke(.white.opacity(0.6), lineWidth: Theme.px(1.5)))
                    }
                    HStack(spacing: Theme.px(8)) {
                        Text(clock(target)).monospacedDigit()
                        if model.scrubSpeed != 0 {
                            HStack(spacing: Theme.px(4)) {
                                Image(systemName: model.scrubSpeed > 0 ? "forward.fill" : "backward.fill")
                                Text("\(abs(model.scrubSpeed))×").monospacedDigit()
                            }
                            .foregroundStyle(Theme.gray200)
                        }
                    }
                    .font(Theme.font(Theme.base, .semibold))
                    .padding(.horizontal, Theme.px(12))
                    .padding(.vertical, Theme.px(5))
                    .background(Capsule().fill(.black.opacity(0.7)))
                }
                .frame(width: Self.previewWidth, height: Self.previewHeight, alignment: .bottom)
                .offset(x: x, y: -Self.previewHeight - Theme.px(8))
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func failureCard(_ failure: String) -> some View {
        VStack(spacing: Theme.px(12)) {
            Text("This version didn't play").font(Theme.font(Theme.xl, .semibold))
            Text(failure).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray300).multilineTextAlignment(.center)
            Text("Press Back to pick another version.").font(Theme.font(Theme.xs)).foregroundStyle(Theme.gray400)
        }
        .padding(Theme.px(32))
        .frame(maxWidth: Theme.px(560))
        .background(RoundedRectangle(cornerRadius: Theme.px(16)).fill(Color(white: 17 / 255).opacity(0.95)))
    }

    /// The seek step the settings choose, in seconds.
    private var step: Double { Double(prefs.seekStep) }

    // MARK: Skipping and the next episode

    /// Someone's there: the run of episodes played on by themselves starts over.
    private func input() { UnattendedPlays.count = 0 }

    /// The segment playing now, short of its last second.
    private var inside: MediaSegment? {
        let at = model.position
        return model.segments.first { at >= $0.start && at < $0.end - 1 }
    }

    /// Credits that end the episode, which the next episode's offer takes over from.
    private func endsEpisode(_ segment: MediaSegment) -> Bool {
        let duration = model.duration
        return duration > 0 && segment.end >= duration * 0.9 && duration - segment.end <= 30
    }

    /// Where the next episode is offered: at the credits when they end the episode, else the
    /// chosen lead before the end. None for a short video, or with the offer off.
    private var promptAt: Double? {
        guard model.nextEpisode != nil, model.duration >= 40, prefs.nextPrompt != "off" else { return nil }
        if prefs.nextPrompt == "credits",
           let credits = model.segments.first(where: { $0.type == "Outro" && endsEpisode($0) }) {
            return credits.start
        }
        return model.duration - prefs.nextLead
    }

    private var upNextDue: Bool { model.started && (promptAt.map { model.position >= $0 } ?? false) }
    private var upNextShown: Bool { upNextDue && !upNextDismissed && !askingStill && !playingOn && finding == nil }
    private var counting: Bool { upNextShown && prefs.autoplayNext && !model.paused }

    private var skipShown: Bool {
        guard let offer, inside?.id == offer.id else { return false }
        // The next episode's offer stands in for skipping the credits.
        if offer.type == "Outro" && endsEpisode(offer) && upNextDue && !upNextDismissed { return false }
        return shown || offerFresh
    }

    /// A segment starting: skipped where the settings say, else offered for a few seconds.
    private func enter(_ segment: MediaSegment?) {
        freshTask?.cancel()
        offerFresh = false
        offer = nil
        guard let segment, !model.scrubbing, model.scrubTarget == nil else { return }
        switch prefs.segmentAction(segment.type) {
        case "skip":
            // Credits before the next episode's offer are left to it.
            if segment.type == "Outro" && endsEpisode(segment) && promptAt != nil { return }
            model.seek(to: segment.end)
            show(skippedLabel(segment.type))
        case "ask":
            offer = segment
            offerFresh = true
            freshTask = Task {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { offerFresh = false }
            }
        default:
            break
        }
    }

    private func skip(_ segment: MediaSegment) {
        input()
        offer = nil
        model.seek(to: segment.end)
        wake()
    }

    private func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { notice = nil }
        }
    }

    private func skipLabel(_ type: String) -> String {
        ["Intro": "Skip intro", "Recap": "Skip recap", "Outro": "Skip credits", "Preview": "Skip preview",
         "Commercial": "Skip ad"][type] ?? "Skip"
    }

    private func skippedLabel(_ type: String) -> String {
        ["Intro": "Skipped intro", "Recap": "Skipped recap", "Outro": "Skipped credits", "Preview": "Skipped preview",
         "Commercial": "Skipped ad"][type] ?? "Skipped"
    }

    /// Moves on to the next episode; by itself, after a run of them, it asks first.
    private func playOn(auto: Bool) {
        guard !playingOn else { return }
        guard let next = model.nextEpisode else { return close() }
        if auto {
            let limit = prefs.stillWatching
            if limit > 0 && UnattendedPlays.count + 1 >= limit {
                askingStill = true
                if !model.paused && !model.finished { model.togglePause() }
                return
            }
            UnattendedPlays.count += 1
        } else {
            input()
        }
        playingOn = true
        playNext(next)
    }

    private func upNextCard(_ next: Item) -> some View {
        HStack(spacing: Theme.px(14)) {
            if let client = session.client {
                RemoteImage(url: client.still(next, height: 180))
                    .frame(width: Theme.px(144), height: Theme.px(81))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous))
            }
            VStack(alignment: .leading, spacing: Theme.px(6)) {
                Text("Next episode").font(Theme.font(Theme.xs, .medium)).foregroundStyle(Theme.gray400)
                Text(next.displayTitle).font(Theme.font(Theme.base, .semibold)).lineLimit(1)
                Button { playOn(auto: false) } label: {
                    Label(counting ? "Playing in \(max(1, Int(countdownLeft.rounded(.up))))s" : "Play next",
                          systemImage: "play.fill")
                        .monospacedDigit()
                }
                .buttonStyle(SoftPillStyle(selected: true))
                .focused($focus, equals: .next)
            }
        }
        .padding(Theme.px(14))
        .frame(maxWidth: Theme.px(440), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.px(14), style: .continuous).fill(Color(white: 17 / 255).opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: Theme.px(14), style: .continuous).stroke(.white.opacity(0.1), lineWidth: Theme.px(1)))
        .transition(.opacity)
    }

    private var stillWatchingCard: some View {
        VStack(alignment: .leading, spacing: Theme.px(12)) {
            Text("Are you still watching?").font(Theme.font(Theme.lg, .semibold))
            HStack(spacing: Theme.px(8)) {
                Button("Keep watching") {
                    askingStill = false
                    playOn(auto: false)
                }
                .buttonStyle(SoftPillStyle(selected: true))
                .focused($focus, equals: .keepWatching)
                Button("Stop") { close() }
                    .buttonStyle(SoftPillStyle())
                    .focused($focus, equals: .stop)
            }
        }
        .padding(Theme.px(18))
        .background(RoundedRectangle(cornerRadius: Theme.px(14), style: .continuous).fill(Color(white: 17 / 255).opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: Theme.px(14), style: .continuous).stroke(.white.opacity(0.1), lineWidth: Theme.px(1)))
        .transition(.opacity)
    }

    // MARK: Showing and hiding

    /// Shows the controls, focusing `target` where given.
    private func reveal(_ target: PlayerFocus?) {
        shown = true
        if let target { focus = target }
        wake()
    }

    private func hide() {
        hideTask?.cancel()
        shown = false
        focus = .surface
    }

    /// Hides the controls a few seconds after the last press, while the video plays.
    private func wake() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !model.paused, panel == nil, model.failure == nil, !DemoMode.holdsControls,
                  model.scrubTarget == nil else { return }
            hide()
        }
    }

    private func open(_ which: PlayerPanel) {
        hideTask?.cancel()
        panel = which
    }

    private func closePanel() {
        let from = panel
        panel = nil
        switch from {
        case .tracks: focus = .tracks
        case .audio: focus = .audio
        case .chapters: focus = .chapters
        case .speed: focus = .speed
        case .sync: focus = .sync
        case .episodes: focus = .episodes
        case nil: break
        }
        wake()
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? max(seconds, 0) : 0)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The bar across the bottom: played in the accent, held ahead lighter, gaps at chapter starts.
private struct ProgressTrack: View {
    @ObservedObject var model: PlayerModel
    let focused: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let share = { (seconds: Double) -> CGFloat in
                model.duration > 0 ? CGFloat(min(max(seconds / model.duration, 0), 1)) * width : 0
            }
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white.opacity(0.35)).frame(width: share(model.buffered))
                Capsule().fill(Theme.ring).frame(width: share(model.scrubTarget ?? model.position))
                ForEach(model.chapters.dropFirst(), id: \.id) { chapter in
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: Theme.px(3))
                        .offset(x: share(chapter.startSeconds) - Theme.px(1.5))
                }
                Circle()
                    .fill(.white)
                    .frame(width: Theme.px(14), height: Theme.px(14))
                    .offset(x: share(model.scrubTarget ?? model.position) - Theme.px(7))
                    .opacity(focused || model.scrubTarget != nil ? 1 : 0)
            }
            .frame(height: focused ? Theme.px(8) : Theme.px(4))
            .frame(maxHeight: .infinity)
        }
        .frame(height: Theme.px(16))
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// The skip button over the video: white on dark, filling white with focus.
private struct SkipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Focused { focused in
            configuration.label
                .font(Theme.font(Theme.base, .semibold))
                .foregroundStyle(focused ? .black : .white)
                .padding(.horizontal, Theme.px(18))
                .frame(height: Theme.px(44))
                .background(Capsule().fill(focused ? Color.white : Color.black.opacity(0.65)))
                .overlay(Capsule().stroke(.white.opacity(focused ? 0 : 0.4), lineWidth: Theme.px(1)))
                .scaleEffect(focused ? 1.05 : 1)
                .animation(.easeOut(duration: 0.12), value: focused)
                .opacity(configuration.isPressed ? 0.85 : 1)
        }
    }
}

/// The big white play button.
private struct BigPlayStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inner(label: configuration.label)
    }

    private struct Inner<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label

        var body: some View {
            label
                .font(.system(size: Theme.px(20), weight: .bold))
                .foregroundStyle(.black)
                .frame(width: Theme.px(52), height: Theme.px(52))
                .background(Circle().fill(.white))
                .focusRing(focused)
        }
    }
}

/// A bare icon in the control row, lit and ringed when focused.
private struct ControlIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inner(label: configuration.label)
    }

    private struct Inner<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label

        var body: some View {
            label
                .font(.system(size: Theme.px(22), weight: .regular))
                .foregroundStyle(focused ? Color.white : Color.white.opacity(0.85))
                .frame(width: Theme.px(44), height: Theme.px(44))
                .background(Circle().fill(focused ? Color.white.opacity(0.16) : .clear))
                .focusRing(focused)
        }
    }
}

/// A list beside the video: audio and subtitles, chapters, or speed.
private struct PlayerPanelView: View {
    @EnvironmentObject private var session: Session
    @ObservedObject var model: PlayerModel
    let panel: PlayerPanel
    /// Plays another episode, from the Episodes panel.
    let play: (Item) -> Void
    let done: () -> Void
    @State private var episodes: [Item] = []

    private static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.px(20)) {
                switch panel {
                case .tracks:
                    group("Subtitles") {
                        row("Off", on: model.activeSubtitle == nil) { model.selectSubtitle(nil) }
                        ForEach(model.subtitleTracks) { track in
                            row(label(track), on: track.id == model.activeSubtitle) { model.selectSubtitle(track.id) }
                        }
                    }
                case .audio:
                    group("Audio") {
                        if model.audioTracks.isEmpty {
                            Text("This version has one audio track.")
                                .font(Theme.font(Theme.sm))
                                .foregroundStyle(Theme.gray400)
                                .padding(.horizontal, Theme.px(12))
                                .focusable()
                        }
                        ForEach(model.audioTracks) { track in
                            row(label(track), detail: audioDetail(track), on: track.id == model.activeAudio) {
                                model.selectAudio(track.id)
                            }
                        }
                    }
                case .chapters:
                    group("Chapters") {
                        ForEach(model.chapters, id: \.id) { chapter in
                            row(chapter.name.isEmpty ? "Chapter \(chapter.id + 1)" : chapter.name,
                                detail: clock(chapter.startSeconds),
                                on: false) {
                                model.seek(to: chapter.startSeconds)
                                done()
                            }
                        }
                    }
                case .speed:
                    group("Speed") {
                        ForEach(Self.speeds, id: \.self) { value in
                            row(value == 1 ? "Normal" : String(format: "%g×", value), on: abs(model.speed - value) < 0.01) {
                                model.setSpeed(value)
                            }
                        }
                    }
                case .sync:
                    group("Subtitles") {
                        stepper(model.subtitleDelay, step: 0.1) { model.setSubtitleDelay($0) }
                    }
                    group("Audio") {
                        stepper(model.audioDelay, step: 0.05) { model.setAudioDelay($0) }
                    }
                    Text("Later shows subtitles, or plays the sound, after the picture; earlier, before it. Kept for this title.")
                        .font(Theme.font(Theme.xs))
                        .foregroundStyle(Theme.gray400)
                        .padding(.horizontal, Theme.px(12))
                case .episodes:
                    group(model.request.item.parentIndexNumber.map { "Season \($0)" } ?? "Episodes") {
                        if episodes.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                        ForEach(episodes) { episode in
                            row(episode.displayTitle, detail: episode.userData?.played == true ? "Watched" : episode.timeLeft,
                                on: episode.id == model.request.item.id) {
                                if episode.id != model.request.item.id { play(episode) }
                            }
                        }
                    }
                }
            }
            .padding(Theme.px(20))
        }
        .frame(width: Theme.px(400))
        .frame(maxHeight: .infinity)
        .background(Color(white: 11 / 255).opacity(0.95))
        .focusSection()
        .onExitCommand(perform: done)
        .task(id: panel) { if panel == .episodes { await loadEpisodes() } }
    }

    /// The season playing, as its show lists it.
    private func loadEpisodes() async {
        let item = model.request.item
        guard let client = session.client, let userId = session.userId, let series = item.seriesId else { return }
        let found: ItemsResult? = try? await client.get("/Shows/\(series)/Episodes", ["userId": userId, "SeasonId": item.seasonId])
        // One not out yet can't play.
        episodes = (found?.items ?? []).filter { $0.locationType != "Virtual" }
    }

    /// Earlier, the value, later, and back to zero.
    private func stepper(_ value: Double, step: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: Theme.px(8)) {
            Button { set(value - step) } label: { Image(systemName: "minus") }
                .buttonStyle(ControlIconStyle())
            Text(value == 0 ? "In sync" : String(format: "%+.2f s", value))
                .font(Theme.font(Theme.base, .semibold))
                .monospacedDigit()
                .frame(minWidth: Theme.px(110))
            Button { set(value + step) } label: { Image(systemName: "plus") }
                .buttonStyle(ControlIconStyle())
            Button("Reset") { set(0) }
                .buttonStyle(SoftPillStyle())
                .disabled(value == 0)
        }
        .padding(.horizontal, Theme.px(8))
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.px(4)) {
            Text(title)
                .font(Theme.font(Theme.sm, .semibold))
                .foregroundStyle(Theme.gray400)
                .padding(.horizontal, Theme.px(12))
                .padding(.bottom, Theme.px(4))
            content()
        }
    }

    private func row(_ text: String, detail: String? = nil, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.px(10)) {
                Image(systemName: "checkmark")
                    .font(.system(size: Theme.px(13), weight: .semibold))
                    .opacity(on ? 1 : 0)
                Text(text).font(Theme.font(15)).lineLimit(1)
                Spacer(minLength: Theme.px(8))
                if let detail {
                    Text(detail).font(Theme.font(Theme.xs)).foregroundStyle(Theme.gray400).monospacedDigit()
                }
            }
            .padding(.horizontal, Theme.px(12))
            .frame(height: Theme.px(40))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PanelRowStyle())
    }

    /// What tells audio tracks apart besides their language: the format, channels, Atmos or DTS:X,
    /// and commentary or audio description.
    private func audioDetail(_ track: TrackInfo) -> String? {
        let codecs = ["truehd": "TrueHD", "eac3": "DD+", "ac3": "DD", "dts": "DTS",
                      "aac": "AAC", "flac": "FLAC", "opus": "Opus", "mp3": "MP3", "pcm_s16le": "PCM", "pcm_s24le": "PCM"]
        var parts: [String] = []
        if let codec = codecs[track.codec.lowercased()] { parts.append(codec) }
        if track.isAtmos { parts.append("Atmos") } else if track.isDTSX { parts.append("DTS:X") }
        switch track.channels {
        case 1: parts.append("Mono")
        case 2: parts.append("Stereo")
        case 6: parts.append("5.1")
        case 8: parts.append("7.1")
        case let count where count > 2: parts.append("\(count) ch")
        default: break
        }
        if track.isCommentary { parts.append("Commentary") }
        if track.isVisualImpaired { parts.append("Audio description") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func label(_ track: TrackInfo) -> String {
        var parts: [String] = []
        if !track.name.isEmpty { parts.append(track.name) }
        if let language = track.language, !language.isEmpty, !track.name.localizedCaseInsensitiveContains(language) {
            parts.append(Locale.current.localizedString(forLanguageCode: language) ?? language)
        }
        if track.isForced { parts.append("Forced") }
        if track.isExternal { parts.append("Addon") }
        return parts.isEmpty ? "Track \(track.id)" : parts.joined(separator: " · ")
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct PanelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inner(label: configuration.label)
    }

    private struct Inner<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label

        var body: some View {
            label
                .foregroundStyle(focused ? Color.black : Color.white)
                .background(
                    RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous)
                        .fill(focused ? Color.white : Color.clear)
                )
        }
    }
}
