import SwiftUI

// The web app's home (pages/home.tsx, components/hero.tsx) as a TV shows it by default:
// a rotating hero over the first rows, then Continue watching, Next up and each library.

/// The web app's hero picks: the heads of the Movies and Shows libraries, interleaved.
private let heroPerLibrary = 8
private let heroMax = 10

/// What's partway through, then the next episodes, one card a show, most recently watched or aired first,
/// as the web app merges them (lib/jellyfin/queries.ts `mergeRows`).
func mergeRows(_ resume: [Item], _ nextUp: [Item]) -> [Item] {
    var seen = Set<String>()
    let kept = (resume + nextUp).filter { item in
        let keys = [item.id, item.seriesId].compactMap { $0 }
        guard !keys.contains(where: seen.contains) else { return false }
        seen.formUnion(keys)
        return true
    }
    // The later of when it was last watched and, for a next episode, when it aired (not still to come),
    // as the web app sorts it since Android v0.15.0; a next episode with no watch time stays last.
    let watched = { (item: Item) -> Date in
        guard let last = parseDate(item.aiostreams?.showWatchedAt ?? item.userData?.lastPlayedDate) else { return .distantPast }
        let aired = min(parseDate(item.premiereDate) ?? .distantPast, Date())
        return max(last, aired)
    }
    // Stable, so next episodes without a time stay after what's partway through.
    return kept.enumerated()
        .sorted { a, b in
            let (x, y) = (watched(a.element), watched(b.element))
            return x != y ? x > y : a.offset < b.offset
        }
        .map(\.element)
}

struct HomeView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @State private var hero: [Item] = []
    @State private var resume: [Item] = []
    @State private var nextUp: [Item] = []
    /// Episodes of shows you follow airing soon (Jellyfin's Shows/Upcoming), as the web app's row.
    @State private var upcoming: [Item] = []
    @Environment(\.openRoute) private var openRoute
    @Environment(\.openPlace) private var openPlace
    /// Favourite channels, then ones played here lately, with what's on: on a server with Live TV.
    @State private var channels: [Item] = []
    @State private var airing: [String: Item] = [:]
    @State private var libraries: [HomeRow] = []
    @State private var loading = true
    @State private var error: String?
    @State private var choice: VersionChoice?

    /// The focused card's title, which a following hero shows.
    @State private var followed: Item?

    /// Hero: rotates through featured titles, or follows the focused card, pinned over the rows.
    private var following: Bool { prefs.heroMode != "rotate" }

    var body: some View {
        Group {
            if following && !hero.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HeroCarousel(items: hero, play: play, followed: followed ?? hero.first,
                                 height: prefs.heroMode == "corner" ? Theme.px(360) : Theme.px(456))
                    ScrollView { rows }
                        .edgeToEdge()
                }
            } else {
                ScrollView { rows }
                    .edgeToEdge()
            }
        }
        .environment(\.cardFocused, { item in if following { followed = item } })
        .task { if libraries.isEmpty && hero.isEmpty { await load() } }
        .refreshOnReturn { await load() }
        .reloadOnWatchChange { await load() }
        .playFlow($choice) { Task { await load() } }
    }

    private var rows: some View {
            LazyVStack(alignment: .leading, spacing: Theme.px(40)) {
                if !hero.isEmpty && !following {
                    HeroCarousel(items: hero, play: play)
                        // Rows sit just under it.
                        .padding(.bottom, -Theme.px(32))
                } else {
                    Color.clear.frame(height: Theme.px(16))
                }
                // With "Merge continue watching and next up" on, one row holds both, as the web app's.
                let merging = prefs.flag("mergeNextUp", false)
                let continuing = merging ? mergeRows(resume, nextUp) : resume
                if !continuing.isEmpty {
                    // Activity is in the rail, so the row needs no button of its own.
                    WideRow(title: "Continue watching", items: continuing, play: play) { EmptyView() }
                }
                if !merging && !nextUp.isEmpty {
                    WideRow(title: "Next up", items: nextUp, play: play) { EmptyView() }
                }
                if !channels.isEmpty {
                    LiveRow(channels: channels, airing: airing, play: playChannel) {
                        Button { openPlace(.live) } label: {
                            Label("All channels", systemImage: "play.tv")
                        }
                        .buttonStyle(SoftPillStyle())
                    }
                }
                if !upcoming.isEmpty {
                    // Nothing to play yet, so a card opens its show.
                    WideRow(title: "Upcoming", items: upcoming, upcoming: true, play: openShow) { EmptyView() }
                }
                ForEach(libraries) { row in
                    ItemRow(row: row)
                }
                if loading && hero.isEmpty && libraries.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, Theme.px(200))
                }
                if !loading && hero.isEmpty && resume.isEmpty && libraries.isEmpty {
                    VStack(spacing: Theme.px(16)) {
                        Text(error ?? "Nothing here yet. Add catalogs to your configuration.")
                            .font(Theme.font(Theme.base))
                            .foregroundStyle(Theme.gray400)
                        Button("Try again") { Task { await load() } }
                            .buttonStyle(SoftPillStyle())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.px(200))
                }
            }
            .padding(.bottom, Theme.px(64))
    }

    /// The Live TV row's channels, as the web app's: favourites, then those played here lately.
    private func loadChannels(client: JellyfinClient, userId: String) async {
        let limit = 20
        let favourites: ItemsResult? = try? await client.get("/LiveTv/Channels", [
            "userId": userId, "IsFavorite": "true", "Limit": String(limit), "AddCurrentProgram": "true",
        ])
        let recentIds = RecentChannels.ids
        var recents: [Item] = []
        if !recentIds.isEmpty {
            let found: ItemsResult? = try? await client.get("/Items", ["userId": userId, "Ids": recentIds.joined(separator: ",")])
            let byId = Dictionary((found?.items ?? []).map { ($0.id, $0) }) { first, _ in first }
            recents = recentIds.compactMap { byId[$0] }.filter(\.isChannel)
        }
        var seen = Set<String>()
        let row = (favourites?.items ?? []) + recents
        channels = Array(row.filter { seen.insert($0.id).inserted }.prefix(limit))
        // What's on each now, in one ask, as recent channels come without it.
        guard !channels.isEmpty else { return }
        let now: ItemsResult? = try? await client.post("/LiveTv/Programs", body: [
            "UserId": userId, "ChannelIds": channels.map(\.id), "IsAiring": true, "Fields": ["Overview"],
        ])
        airing = Dictionary((now?.items ?? []).compactMap { programme in programme.channelId.map { ($0, programme) } }) { first, _ in first }
    }

    private func playChannel(_ channel: Item) {
        RecentChannels.note(channel.id)
        choice = VersionChoice(item: channel, startMs: nil, mode: .straight)
    }

    /// An upcoming episode's show, or the title itself.
    private func openShow(_ item: Item) {
        if let series = item.seriesId {
            openRoute(.item(Item(id: series, name: item.seriesName, type: "Series")))
        } else {
            openRoute(.item(item))
        }
    }

    private func play(_ item: Item) {
        Task { choice = await playChoice(for: item, session: session) }
    }

    private func load() async {
        guard let client = session.client, let userId = session.userId else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            async let resumeResult: ItemsResult = client.get("/UserItems/Resume", ["userId": userId, "Limit": "24", "MediaTypes": "Video"])
            async let nextResult: ItemsResult = client.get("/Shows/NextUp", ["userId": userId, "Limit": "24", "EnableResumable": "false"])
            async let upcomingResult: ItemsResult = client.get("/Shows/Upcoming", ["userId": userId, "Limit": "24"])
            async let viewsResult: ItemsResult = client.get("/UserViews", ["userId": userId])
            resume = (try? await resumeResult.items) ?? []
            nextUp = (try? await nextResult.items) ?? []
            upcoming = (try? await upcomingResult.items) ?? []
            let allViews = try await viewsResult.items ?? []
            let views = allViews.filter(isBrowsable)
            if allViews.contains(where: { $0.collectionType == "livetv" }) {
                Task { await loadChannels(client: client, userId: userId) }
            }

            // Each library's head, in the configuration's order, as each arrives.
            var heads: [Int: (Item, [Item])] = [:]
            await withTaskGroup(of: (Int, Item, [Item]).self) { group in
                for (index, view) in views.enumerated() {
                    group.addTask {
                        let genre = await openingGenre(client, userId: userId, view: view)
                        let result: ItemsResult? = try? await client.get("/Items", [
                            "userId": userId,
                            "ParentId": view.id,
                            "IncludeItemTypes": libraryTypes(view),
                            "GenreIds": genre,
                            "Recursive": "true",
                            "Limit": "24",
                            "Fields": "Overview,Genres",
                        ])
                        return (index, view, result?.items ?? [])
                    }
                }
                for await (index, view, items) in group {
                    heads[index] = (view, items)
                    libraries = heads.keys.sorted().compactMap { key in
                        guard let entry = heads[key], !entry.1.isEmpty else { return nil }
                        return HomeRow(id: entry.0.id, title: entry.0.name ?? "Library", items: entry.1, library: entry.0)
                    }
                }
            }
            hero = heroPicks(views: views, heads: heads, client: client)
        } catch let failure as JellyfinError where failure.status == 401 {
            session.expired()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The Movies and Shows libraries' heads, or the first library's, taking turns; only titles with a backdrop.
    private func heroPicks(views: [Item], heads: [Int: (Item, [Item])], client: JellyfinClient) -> [Item] {
        let lists = heads.keys.sorted().compactMap { heads[$0] }
        var sources = ["movies", "tvshows"].compactMap { kind in lists.first { $0.0.collectionType == kind }?.1 }
        if sources.isEmpty, let first = lists.first?.1 { sources = [first] }
        let candidates = sources.map { Array($0.prefix(heroPerLibrary)) }
        var picks: [Item] = []
        var seen = Set<String>()
        for index in 0..<(candidates.map(\.count).max() ?? 0) {
            for list in candidates where index < list.count && picks.count < heroMax {
                let item = list[index]
                guard !seen.contains(item.id), client.backdrop(item, height: 100) != nil,
                      item.backdropImageTags?.isEmpty == false || item.parentBackdropImageTags?.isEmpty == false else { continue }
                seen.insert(item.id)
                picks.append(item)
            }
        }
        return picks
    }
}

// MARK: - Hero

private enum HeroAction: Hashable { case play, info }

/// One title at a time over the top of Home, turning every 9 seconds while nothing in it has focus.
/// Right past its last button turns to the next title; left past its first, to the one before.
struct HeroCarousel: View {
    @EnvironmentObject private var session: Session
    let items: [Item]
    let play: (Item) -> Void
    /// The focused card's title, which the hero shows instead of rotating (Hero: follows the card).
    var followed: Item? = nil
    var height: CGFloat = HeroCarousel.height

    @State private var index = 0
    @FocusState private var focus: HeroAction?

    /// `max(36rem, 53vh)` on a 720-line TV.
    static let height = Theme.px(576)
    @EnvironmentObject private var prefs: Preferences

    private var item: Item { followed ?? items[min(index, items.count - 1)] }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            shade
            details
                .id(item.id)
                .transition(.opacity)
            if items.count > 1 && followed == nil { dots }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        // Under the rail, as the web app's hero is.
        .padding(.leading, -Theme.px(80))
        .clipped()
        .animation(.easeInOut(duration: 0.6), value: index)
        .task(id: "\(index)-\(focus == nil)") {
            guard focus == nil, items.count > 1, followed == nil else { return }
            try? await Task.sleep(for: .seconds(prefs.heroSeconds))
            guard !Task.isCancelled, focus == nil else { return }
            index = (index + 1) % items.count
        }
        .onChange(of: items.map(\.id)) { _, _ in index = 0 }
    }

    /// The backdrop sits right, no wider than 2.6 times its height, fading in from the left.
    private var backdrop: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width, height * 2.6)
            RemoteImage(url: session.client?.backdrop(item, height: 1080))
                .frame(width: width, height: height)
                .mask(
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: .black, location: Theme.px(192) / width)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .id(item.id)
                .transition(.opacity)
        }
    }

    private var shade: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: Theme.background, location: 0),
                    .init(color: Theme.background.opacity(0.7), location: 0.35),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(
                stops: [
                    .init(color: Theme.background, location: 0),
                    .init(color: Theme.background.opacity(0.6), location: 0.5),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: height * 2 / 3)
        }
        .allowsHitTesting(false)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.px(16)) {
            TitleLogo(item: item, maxHeight: Theme.px(112), maxWidth: Theme.px(384), titleSize: 48)
            HeroMeta(item: item)
            if let overview = item.overview, !overview.isEmpty {
                Text(overview)
                    .font(Theme.font(Theme.base))
                    .foregroundStyle(Theme.gray300)
                    .lineLimit(3)
                    .frame(maxWidth: Theme.px(672), alignment: .leading)
            }
            HStack(spacing: Theme.px(8)) {
                if item.playable {
                    Button { play(item) } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryPillStyle())
                    .focused($focus, equals: .play)
                }
                NavigationLink(value: Route.item(item)) {
                    Label("More info", systemImage: "info.circle")
                }
                .buttonStyle(item.playable ? AnyButtonStyle(SecondaryPillStyle()) : AnyButtonStyle(PrimaryPillStyle()))
                .focused($focus, equals: .info)
            }
            .onMoveCommand { direction in
                guard items.count > 1, followed == nil else { return }
                let first: HeroAction = item.playable ? .play : .info
                if direction == .right, focus == .info {
                    index = (index + 1) % items.count
                    focus = items[index].playable ? .play : .info
                } else if direction == .left, focus == first, index > 0 {
                    index -= 1
                    focus = .info
                }
            }
            .focusSection()
        }
        .frame(maxWidth: Theme.px(768), alignment: .leading)
        .padding(.leading, Theme.px(80) + pageInset)
        .padding(.bottom, Theme.px(56))
    }

    private var dots: some View {
        HStack(spacing: Theme.px(6)) {
            ForEach(items.indices, id: \.self) { at in
                Capsule()
                    .fill(at == index ? Color.white : Color.white.opacity(0.35))
                    .frame(width: at == index ? Theme.px(24) : Theme.px(6), height: Theme.px(6))
            }
        }
        .padding(.trailing, Theme.px(16))
        .padding(.bottom, Theme.px(56))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Wraps a button style chosen at run time.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// A title's logo artwork where it has one; its name in large type otherwise.
struct TitleLogo: View {
    @EnvironmentObject private var session: Session
    let item: Item
    let maxHeight: CGFloat
    let maxWidth: CGFloat
    let titleSize: CGFloat

    var body: some View {
        if let url = session.client?.logo(item, width: Int(maxWidth * 2)) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .leading)
                case .failure:
                    title
                default:
                    Color.clear.frame(width: maxWidth, height: maxHeight)
                }
            }
        } else {
            title
        }
    }

    private var title: some View {
        Text(item.isEpisode ? (item.seriesName ?? item.displayTitle) : (item.name ?? ""))
            .font(Theme.font(titleSize, .bold))
            .lineLimit(2)
            .frame(maxWidth: Theme.px(640), alignment: .leading)
    }
}

/// `2025 • ★ 8.3 • Drama, Crime`, or an episode's code and name for the first part.
struct HeroMeta: View {
    let item: Item

    var body: some View {
        var parts: [AnyView] = []
        if item.isEpisode {
            parts.append(AnyView(Text(item.displayTitle)))
        } else if let year = item.productionYear {
            parts.append(AnyView(Text(String(year))))
        }
        if let score = item.communityRating, score > 0 {
            parts.append(AnyView(HStack(spacing: Theme.px(4)) {
                Image(systemName: "star.fill").foregroundStyle(Theme.star).font(.system(size: Theme.px(12)))
                Text(String(format: "%.1f", score))
            }))
        }
        if let genres = item.genres, !genres.isEmpty {
            parts.append(AnyView(Text(genres.prefix(3).joined(separator: ", "))))
        }
        return MetaLine(parts: parts)
            .font(Theme.font(Theme.sm))
            .foregroundStyle(Theme.gray200)
    }
}

// MARK: - Rows

/// What's under way, as stills that play from the row: the web app's EpisodeRow.
struct WideRow<Action: View>: View {
    let title: String
    let items: [Item]
    /// Cards with the day each airs, and how long until then.
    var upcoming = false
    let play: (Item) -> Void
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(12)) {
            HStack {
                Text(title).font(Theme.font(Theme.xl, .semibold))
                Spacer()
                action()
            }
            .pagePadding()
            .focusSection()
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.px(16)) {
                    ForEach(items) { item in
                        WideCard(item: item, upcoming: upcoming) { play(item) }
                    }
                }
                .pagePadding()
                .padding(.vertical, Theme.px(8))
            }
            .edgeToEdge()
        }
        .focusSection()
    }
}

/// A 304 × 171 still with how far it got, its name and time left, and the episode or year under it.
struct WideCard: View {
    @Environment(\.cardFocused) private var cardFocused
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @FocusState private var focused: Bool
    let item: Item
    /// Not out yet: the air day over the still, and how long until it beside the name.
    var upcoming = false
    let action: () -> Void

    private var airs: Date? { upcoming ? parseDate(item.premiereDate) : nil }
    /// Spoiler blur: an episode not started, until it has focus.
    private var hidden: Bool { prefs.blurSpoilers && item.unstarted && !focused }

    static let size = CGSize(width: Theme.px(304), height: Theme.px(171))

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(8)) {
            Button(action: action) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: session.client?.still(item, height: Int(Self.size.height * 2)))
                        .frame(width: Self.size.width, height: Self.size.height)
                        .blur(radius: hidden ? Theme.px(12) : 0, opaque: true)
                        .animation(.easeOut(duration: 0.3), value: hidden)
                        .overlay(alignment: .topLeading) {
                            if let airs {
                                Text(airs.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                    .font(Theme.font(Theme.xs, .semibold))
                                    .padding(.horizontal, Theme.px(8))
                                    .padding(.vertical, Theme.px(3))
                                    .background(Capsule().fill(.black.opacity(0.75)))
                                    .padding(Theme.px(8))
                            }
                        }
                    if let progress = item.userData?.playedPercentage, progress > 0, item.userData?.played != true {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.25))
                                Rectangle().fill(Theme.brand500).frame(width: geometry.size.width * progress / 100)
                            }
                        }
                        .frame(height: Theme.px(4))
                    }
                }
                .frame(width: Self.size.width, height: Self.size.height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous))
            }
            .buttonStyle(CardStyle())
            .focused($focused)
            .onChange(of: focused) { _, on in if on { cardFocused(item) } }
            .itemMenu(item)
            VStack(alignment: .leading, spacing: Theme.px(2)) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.isEpisode ? (item.seriesName ?? "") : (item.name ?? ""))
                        .font(Theme.font(15, .semibold))
                        .lineLimit(1)
                    Spacer(minLength: Theme.px(8))
                    if let until = airs.map(untilLabel) ?? item.timeLeft {
                        Text(until).font(Theme.font(Theme.xs)).foregroundStyle(Theme.gray400)
                    }
                }
                Text(item.isEpisode ? item.displayTitle : item.productionYear.map(String.init) ?? "")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.gray400)
                    .lineLimit(1)
                    .blur(radius: hidden ? Theme.px(5) : 0)
                    .animation(.easeOut(duration: 0.3), value: hidden)
            }
            .padding(.horizontal, Theme.px(2))
            .frame(width: Self.size.width, alignment: .leading)
        }
    }
}

/// How long until a date, as the web app's Upcoming row says it: today, tomorrow, in 5 days, in 3 weeks.
func untilLabel(_ date: Date) -> String {
    let calendar = Calendar.current
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)).day ?? 0
    switch days {
    case ..<1: return "today"
    case 1: return "tomorrow"
    case ..<14: return "in \(days) days"
    default: return "in \(Int((Double(days) / 7).rounded())) weeks"
    }
}

/// Channels as wide cards: the logo over a dark tile, the channel's name and what's on, with how far
/// through it is. Selecting one plays it live.
struct LiveRow<Action: View>: View {
    let channels: [Item]
    let airing: [String: Item]
    let play: (Item) -> Void
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(12)) {
            HStack {
                Text("Live TV").font(Theme.font(Theme.xl, .semibold))
                Spacer()
                action()
            }
            .pagePadding()
            .focusSection()
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.px(16)) {
                    ForEach(channels) { channel in
                        ChannelCard(channel: channel, airing: airing[channel.id]) { play(channel) }
                    }
                }
                .pagePadding()
                .padding(.vertical, Theme.px(8))
            }
            .edgeToEdge()
        }
        .focusSection()
    }
}

private struct ChannelCard: View {
    let channel: Item
    let airing: Item?
    let action: () -> Void

    /// What's on: from the guide, else what the channel list sent along.
    private var programme: (name: String, start: Date?, end: Date?)? {
        if let airing { return (airing.name ?? "", airing.starts, airing.ends) }
        if let current = channel.currentProgram { return (current.name ?? "", current.starts, current.ends) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(8)) {
            Button(action: action) {
                ZStack(alignment: .bottom) {
                    ZStack {
                        Theme.gray900
                        ChannelLogo(channel: channel)
                            .frame(width: Theme.px(160), height: Theme.px(90))
                    }
                    .frame(width: WideCard.size.width, height: WideCard.size.height)
                    if let programme {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.25))
                                Rectangle().fill(Theme.brand500)
                                    .frame(width: geometry.size.width * airedShare(from: programme.start, to: programme.end, now: Date()))
                            }
                        }
                        .frame(height: Theme.px(4))
                    }
                }
                .frame(width: WideCard.size.width, height: WideCard.size.height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous))
            }
            .buttonStyle(CardStyle())
            VStack(alignment: .leading, spacing: Theme.px(2)) {
                HStack(spacing: Theme.px(6)) {
                    if let number = channel.channelNumber {
                        Text(number).foregroundStyle(Theme.gray400).monospacedDigit()
                    }
                    Text(channel.name ?? "").lineLimit(1)
                }
                .font(Theme.font(15, .semibold))
                Text(programme?.name ?? "Live")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.gray400)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.px(2))
            .frame(width: WideCard.size.width, alignment: .leading)
        }
    }
}

/// Told which card has focus, for a hero that follows it.
private struct CardFocusedKey: EnvironmentKey {
    static let defaultValue: (Item) -> Void = { _ in }
}

extension EnvironmentValues {
    var cardFocused: (Item) -> Void {
        get { self[CardFocusedKey.self] }
        set { self[CardFocusedKey.self] = newValue }
    }
}
