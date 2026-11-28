import SwiftUI

// Live TV, after the web app's (app/live-tv, features/live-tv/live-tv.ts): the server's channels by
// group, as a list with what's on now and next, or as a guide of the coming hours. Choosing a
// channel plays it live.

/// Channels played on this Apple TV, newest first, which the Recent group lists.
enum RecentChannels {
    private static let key = "live.recent"
    private static let limit = 30

    static var ids: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func note(_ id: String) {
        UserDefaults.standard.set(Array(([id] + ids.filter { $0 != id }).prefix(limit)), forKey: key)
    }
}

struct LiveTVView: View {
    let view: Item

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @State private var groups: [ChannelGroup] = [ChannelGroup(id: ChannelGroup.all, name: L("All channels"))]
    @State private var group = UserDefaults.standard.string(forKey: "live.group") ?? ChannelGroup.all
    @State private var guide = UserDefaults.standard.string(forKey: "live.view") == "guide"
    @State private var channels: [Item] = []
    @State private var total = 0
    @State private var loaded = false
    @State private var loading = false
    /// Programmes by channel, from the half hour before now to six hours on.
    @State private var schedules: [String: [Item]] = [:]
    @State private var now = Date()
    /// The guide's day, from today: earlier days for catch-up, as far back as the server's guide goes.
    @State private var day = 0
    /// The days the server's guide covers (/LiveTv/GuideInfo), back as far as channels keep programmes.
    @State private var guideRange: (from: Date, to: Date)?
    /// The earliest programme the server keeps for the listed channels, for catch-up: a server's
    /// guide info can start today while its channels keep days of programmes behind.
    @State private var pastFrom: Date?
    @State private var lookedBack = false
    @State private var choice: VersionChoice?

    private static let page = 100

    private var showsGuide: Bool { guide && loaded && !channels.isEmpty }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsGuide {
                // The guide scrolls by itself, both ways, in the screen below the controls.
                VStack(alignment: .leading, spacing: Theme.px(20)) {
                    PageTitle(text: L("Live TV"))
                    controls
                    GuideView(channels: channels, schedules: schedules, window: window, now: now, play: play,
                              playFromStart: { programme in
                                  // An earlier programme the channel keeps plays from its start.
                                  choice = VersionChoice(item: programme, startMs: 0, mode: .straight)
                              },
                              more: { if channels.count < total { Task { await more() } } })
                }
                .padding(.bottom, Theme.px(24))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                page
            }
        }
        .edgeToEdge()
        .playFlow($choice)
        .task { await loadGroups() }
        .task { await loadGuideRange() }
        // Another day: its programmes, for the channels already listed.
        .onChange(of: day) { _, _ in
            schedules = [:]
            Task { await loadSchedules(for: channels.map(\.id)) }
        }
        .task(id: group) { await reload() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
            }
        }
    }

    private var page: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.px(20)) {
                PageTitle(text: L("Live TV"))
                controls
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, Theme.px(40))
                } else if channels.isEmpty {
                    Text(L("No channels in this group."))
                        .font(Theme.font(Theme.base))
                        .foregroundStyle(Theme.gray400)
                        .pagePadding()
                        .focusable()
                } else {
                    ForEach(channels) { channel in
                        ChannelRow(channel: channel, slots: slots(channel), now: now) { play(channel) }
                            .pagePadding()
                            .onAppear { if channel.id == channels.last?.id { Task { await more() } } }
                    }
                }
            }
            .padding(.bottom, Theme.px(64))
        }
    }

    // MARK: Groups and view

    private var controls: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.px(8)) {
                Button { setGuide(false) } label: { Label(L("List"), systemImage: "list.bullet") }
                    .buttonStyle(SoftPillStyle(selected: !guide))
                Button { setGuide(true) } label: { Label(L("Guide"), systemImage: "calendar.day.timeline.left") }
                    .buttonStyle(SoftPillStyle(selected: guide))
                if guide && dayOffsets.count > 1 {
                    // The day the guide shows, as the web app's day picker.
                    Menu {
                        ForEach(dayOffsets, id: \.self) { offset in
                            Button { day = offset } label: {
                                if offset == day { Label(dayName(offset), systemImage: "checkmark") } else { Text(dayName(offset)) }
                            }
                        }
                    } label: {
                        Label(dayName(day), systemImage: "calendar")
                    }
                    .buttonStyle(SoftPillStyle(selected: day != 0))
                }
                Rectangle().fill(.white.opacity(0.15)).frame(width: Theme.px(1), height: Theme.px(24))
                    .padding(.horizontal, Theme.px(8))
                ForEach(groups) { item in
                    Button(item.name) { choose(item.id) }
                        .buttonStyle(SoftPillStyle(selected: item.id == group))
                }
            }
            .pagePadding()
            .padding(.vertical, Theme.px(8))
        }
        .edgeToEdge()
        .focusSection()
    }

    private func setGuide(_ on: Bool) {
        guide = on
        UserDefaults.standard.set(on ? "guide" : "list", forKey: "live.view")
    }

    private func choose(_ id: String) {
        group = id
        UserDefaults.standard.set(id, forKey: "live.group")
    }

    /// Favourites and Recent where there are any, then all channels, then the server's genres.
    private func loadGroups() async {
        guard let client = session.client, let userId = session.userId else { return }
        async let favourites: ItemsResult? = try? client.get("/LiveTv/Channels", [
            "userId": userId, "IsFavorite": "true", "Limit": "1", "EnableTotalRecordCount": "true",
        ])
        async let genres: ItemsResult? = try? client.get("/Genres", [
            "userId": userId, "ParentId": view.id, "SortBy": "SortName",
        ])
        var list: [ChannelGroup] = []
        if (await favourites?.totalRecordCount ?? 0) > 0 { list.append(ChannelGroup(id: ChannelGroup.favourites, name: L("Favourites"))) }
        if !RecentChannels.ids.isEmpty { list.append(ChannelGroup(id: ChannelGroup.recent, name: L("Recent"))) }
        list.append(ChannelGroup(id: ChannelGroup.all, name: L("All channels")))
        list += (await genres?.items ?? []).map { ChannelGroup(id: $0.id, name: $0.name ?? "") }
        groups = list
        // A group that's gone, such as Favourites emptied elsewhere, goes back to all channels.
        if !list.contains(where: { $0.id == group }) { choose(ChannelGroup.all) }
    }

    // MARK: Channels

    private func reload() async {
        channels = []
        total = 0
        schedules = [:]
        loaded = false
        await more()
    }

    private func more() async {
        guard !loading, let client = session.client, let userId = session.userId else { return }
        if loaded && channels.count >= total { return }
        loading = true
        defer { loading = false }
        let asked = group
        var found: [Item] = []
        if group == ChannelGroup.recent {
            let ids = RecentChannels.ids
            let result: ItemsResult? = ids.isEmpty ? nil : try? await client.get("/Items", ["userId": userId, "Ids": ids.joined(separator: ",")])
            let byId = Dictionary((result?.items ?? []).map { ($0.id, $0) }) { first, _ in first }
            found = ids.compactMap { byId[$0] }.filter(\.isChannel)
            total = found.count
        } else {
            let result: ItemsResult? = try? await client.get("/LiveTv/Channels", [
                "userId": userId,
                "StartIndex": String(channels.count),
                "Limit": String(Self.page),
                "IsFavorite": group == ChannelGroup.favourites ? "true" : nil,
                "GenreIds": [ChannelGroup.favourites, ChannelGroup.all].contains(group) ? nil : group,
                "AddCurrentProgram": "true",
                "EnableTotalRecordCount": "true",
            ])
            found = result?.items ?? []
            total = result?.totalRecordCount ?? 0
            if found.isEmpty { total = channels.count }
        }
        guard asked == group else { return }
        channels += found
        loaded = true
        if !lookedBack {
            lookedBack = true
            Task { await findPastRange(Array(found.prefix(20)).map(\.id)) }
        }
        await loadSchedules(for: found.map(\.id))
    }

    /// The window the guide shows: the chosen day, midnight to midnight, as the web app's guide;
    /// today runs at least six hours on from now, past midnight late in the evening.
    private var window: (start: Date, end: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: day, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, day == 0 ? max(end, now.addingTimeInterval(6 * 3600)) : end)
    }

    /// Days from today the guide covers: back to the server's first, on to its last (a week where
    /// it doesn't say), as the web app's `dayOffsets`.
    private var dayOffsets: [Int] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let days = { (from: Date, to: Date) in calendar.dateComponents([.day], from: from, to: to).day ?? 0 }
        var back = 0, ahead = 7
        if let range = guideRange {
            if range.from < today { back = days(calendar.startOfDay(for: range.from), today) }
            if range.to > today { ahead = max(1, days(today, range.to)) }
        }
        if let pastFrom, pastFrom < today { back = max(back, days(calendar.startOfDay(for: pastFrom), today)) }
        return Array(-back..<ahead)
    }

    private func dayName(_ offset: Int) -> String {
        switch offset {
        case 0: return L("Today")
        case 1: return L("Tomorrow")
        case -1: return L("Yesterday")
        default:
            let date = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: now)) ?? now
            return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(AppLanguage.locale))
        }
    }

    /// How far back the channels' programmes go, up to a month: the earliest the server returns
    /// for the first channels listed, so catch-up reaches the days the provider keeps.
    private func findPastRange(_ ids: [String]) async {
        guard !ids.isEmpty, let client = session.client, let userId = session.userId else { return }
        let iso = ISO8601DateFormatter()
        let today = Calendar.current.startOfDay(for: Date())
        let result: ItemsResult? = try? await client.post("/LiveTv/Programs", body: [
            "UserId": userId,
            "ChannelIds": ids,
            "MinEndDate": iso.string(from: today.addingTimeInterval(-31 * 86_400)),
            "MaxStartDate": iso.string(from: today),
            "SortBy": ["StartDate"],
            "Limit": 1,
        ])
        pastFrom = result?.items?.compactMap(\.starts).min()
    }

    private func loadGuideRange() async {
        guard let client = session.client else { return }
        struct GuideInfo: Decodable {
            let startDate: String?
            let endDate: String?
        }
        guard let info: GuideInfo = try? await client.get("/LiveTv/GuideInfo"),
              let from = parseDate(info.startDate), let to = parseDate(info.endDate) else { return }
        guideRange = (from, to)
    }

    private func loadSchedules(for ids: [String]) async {
        guard !ids.isEmpty, let client = session.client, let userId = session.userId else { return }
        let iso = ISO8601DateFormatter()
        let (start, end) = window
        let asked = day
        for batch in stride(from: 0, to: ids.count, by: 50).map({ Array(ids[$0..<min($0 + 50, ids.count)]) }) {
            let result: ItemsResult? = try? await client.post("/LiveTv/Programs", body: [
                "UserId": userId,
                "ChannelIds": batch,
                "MinEndDate": iso.string(from: start),
                "MaxStartDate": iso.string(from: end),
                "SortBy": ["StartDate"],
                "Fields": ["Overview", "Genres"],
            ])
            guard asked == day else { return }
            for programme in result?.items ?? [] {
                guard let channel = programme.channelId else { continue }
                schedules[channel, default: []].append(programme)
            }
        }
    }

    /// What's on now and next: from the guide where it has the channel, else what the list sent.
    private func slots(_ channel: Item) -> (now: Slot?, next: Slot?) {
        let list = (schedules[channel.id] ?? []).filter { ($0.ends ?? .distantPast) > now }
        if let first = list.first {
            let current = (first.starts ?? .distantFuture) <= now ? first : nil
            let next = current == nil ? first : list.dropFirst().first
            return (current.map(Slot.init), next.map(Slot.init))
        }
        if let current = channel.currentProgram, (current.ends ?? .distantFuture) > now {
            return (Slot(name: current.name ?? "", start: current.starts, end: current.ends), nil)
        }
        return (nil, nil)
    }

    private func play(_ channel: Item) {
        RecentChannels.note(channel.id)
        choice = VersionChoice(item: channel, startMs: nil, mode: .straight)
    }
}

struct ChannelGroup: Identifiable, Equatable {
    static let favourites = "favourites"
    static let recent = "recent"
    static let all = "all"

    let id: String
    let name: String
}

/// A programme's name and times.
struct Slot {
    var name: String
    var start: Date?
    var end: Date?

    init(name: String, start: Date?, end: Date?) {
        self.name = name
        self.start = start
        self.end = end
    }

    init(_ programme: Item) {
        self.init(name: programme.name ?? "", start: programme.starts, end: programme.ends)
    }
}

/// A channel's logo, fitted into its box, or its number where it has none.
struct ChannelLogo: View {
    @EnvironmentObject private var session: Session
    let channel: Item

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous).fill(Theme.gray800)
            if let tag = channel.tag("Primary"), let client = session.client {
                AsyncImage(url: client.image(channel.id, .primary, tag: tag, width: 240)) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit().padding(Theme.px(6))
                    } else if case .failure = phase {
                        // A logo the server lists but can't send: the number, as without one.
                        Text(channel.channelNumber ?? String((channel.name ?? "?").prefix(2)))
                            .font(Theme.font(Theme.base, .semibold))
                            .foregroundStyle(Theme.gray300)
                    }
                }
            } else {
                Text(channel.channelNumber ?? String((channel.name ?? "?").prefix(2)))
                    .font(Theme.font(Theme.base, .semibold))
                    .foregroundStyle(Theme.gray300)
            }
        }
    }
}

/// One channel in the list: its logo, number and name, what's on with how far through it is, and what's next.
private struct ChannelRow: View {
    @EnvironmentObject private var prefs: Preferences
    let channel: Item
    let slots: (now: Slot?, next: Slot?)
    let now: Date
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: Theme.px(16)) {
                ChannelLogo(channel: channel)
                    .frame(width: Theme.px(96), height: Theme.px(54))
                VStack(alignment: .leading, spacing: Theme.px(2)) {
                    HStack(spacing: Theme.px(8)) {
                        if let number = channel.channelNumber {
                            Text(number).foregroundStyle(Theme.gray400).monospacedDigit()
                        }
                        Text(channel.name ?? "").lineLimit(1)
                    }
                    .font(Theme.font(Theme.base, .semibold))
                    if let current = slots.now {
                        Text(current.name).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray200).lineLimit(1)
                    }
                    if let next = slots.next {
                        Text(next.start.map { L("Next %@: %@", prefs.time($0), next.name) } ?? L("Next: %@", next.name))
                            .font(Theme.font(Theme.xs))
                            .foregroundStyle(Theme.gray400)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Theme.px(16))
                if let current = slots.now {
                    VStack(alignment: .trailing, spacing: Theme.px(6)) {
                        if let start = current.start, let end = current.end {
                            Text(verbatim: "\(prefs.time(start)) – \(prefs.time(end))")
                                .font(Theme.font(Theme.xs))
                                .foregroundStyle(Theme.gray400)
                                .monospacedDigit()
                        }
                        Capsule().fill(.white.opacity(0.15))
                            .frame(width: Theme.px(120), height: Theme.px(4))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Theme.brand500)
                                    .frame(width: Theme.px(120) * airedShare(from: current.start, to: current.end, now: now))
                            }
                    }
                }
            }
            .padding(.horizontal, Theme.px(16))
            .padding(.vertical, Theme.px(10))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RowStyle())
    }
}

// MARK: - Guide

/// The programme with focus, which only the details above the grid follow, so a focus move
/// redraws them alone rather than every row.
@MainActor
private final class GuideFocus: ObservableObject {
    @Published var programme: Item?
}

/// Where the grid is scrolled, which the channels down the side and the times across the top
/// follow, without the grid redrawing for it.
@MainActor
private final class GuideScroll: ObservableObject {
    @Published var offset: CGPoint = .zero
    @Published var height: CGFloat = 0
    @Published var width: CGFloat = 0
}

/// Channels down the side and the coming hours across, each programme as wide as it lasts. The
/// grid scrolls both ways and builds only the rows in sight; the channels and the times follow it.
private struct GuideView: View {
    let channels: [Item]
    let schedules: [String: [Item]]
    let window: (start: Date, end: Date)
    let now: Date
    let play: (Item) -> Void
    let playFromStart: (Item) -> Void
    /// Loads the next channels as the grid nears its last.
    let more: () -> Void

    @StateObject private var focus = GuideFocus()
    @StateObject private var scrolled = GuideScroll()
    /// Where the grid is scrolled: half an hour before now as it opens, once the window is known.
    @State private var scroll = ScrollPosition(edge: .leading)

    static let minute = Theme.px(4)
    static let rowHeight = Theme.px(56)
    static let gap = Theme.px(4)
    static let channelWidth = Theme.px(200)
    static let timesHeight = Theme.px(28)
    /// Above the first row and below the last, for the focus ring.
    static let inset = Theme.px(6)

    static func top(_ index: Int) -> CGFloat { inset + CGFloat(index) * (rowHeight + gap) }

    private var layout: GuideLayout { GuideLayout(window: window) }

    /// Opens at the time of day it is now, half an hour back: now, today; the same hour another day.
    private func openAtNow() {
        let intoDay = now.timeIntervalSince(Calendar.current.startOfDay(for: now))
        let at = layout.x(window.start.addingTimeInterval(intoDay))
        scroll.scrollTo(point: CGPoint(x: max(0, at - 30 * Self.minute), y: scrolled.offset.y))
    }

    /// Scrolls a channel down the side fully into sight, as the grid's rows go with it.
    private func reveal(_ index: Int) {
        let top = Self.top(index) - Self.inset, bottom = Self.top(index) + Self.rowHeight + Self.inset
        let y = scrolled.offset.y, height = scrolled.height
        if top < y {
            scroll.scrollTo(point: CGPoint(x: scrolled.offset.x, y: max(0, top)))
        } else if height > 0, bottom > y + height {
            scroll.scrollTo(point: CGPoint(x: scrolled.offset.x, y: bottom - height))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(12)) {
            GuideDetails(focus: focus)
                .frame(height: Theme.px(72), alignment: .topLeading)
                .pagePadding()
            HStack(spacing: Self.gap) {
                Color.clear.frame(width: Self.channelWidth, height: Self.timesHeight)
                GuideTimes(scrolled: scrolled, layout: layout, now: now)
            }
            .padding(.leading, pageInset)
            HStack(alignment: .top, spacing: Self.gap) {
                GuideChannels(scrolled: scrolled, channels: channels, play: play, reveal: reveal)
                    .frame(width: Self.channelWidth)
                    .padding(.leading, pageInset)
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: Self.gap) {
                        ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                            GuideRow(channel: channel, programmes: schedules[channel.id] ?? [], layout: layout, now: now,
                                     focus: focus, scrolled: scrolled, play: play, playFromStart: playFromStart)
                                .onAppear { if index >= channels.count - 10 { more() } }
                        }
                    }
                    .padding(.vertical, Self.inset)
                    .padding(.trailing, pageMargin)
                }
                .scrollIndicators(.hidden)
                // Kept inside its frame: the page lets scroll views draw past theirs.
                .scrollClipDisabled(false)
                .clipped()
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: CGRect.self) { geometry in
                    CGRect(origin: geometry.contentOffset, size: geometry.containerSize)
                } action: { _, visible in
                    scrolled.offset = visible.origin
                    scrolled.height = visible.height
                    scrolled.width = visible.width
                }
                // Opens half an hour before now, with the earlier programmes a channel keeps to the left;
                // again once the window is known, as the guide loads after the grid first draws.
                .onAppear { openAtNow() }
                .onChange(of: window.start) { _, _ in openAtNow() }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .focusSection()
    }
}

/// Where a time falls across the guide.
private struct GuideLayout {
    let window: (start: Date, end: Date)

    var width: CGFloat { CGFloat(window.end.timeIntervalSince(window.start) / 60) * GuideView.minute }

    func x(_ date: Date) -> CGFloat {
        CGFloat(min(max(date.timeIntervalSince(window.start), 0), window.end.timeIntervalSince(window.start)) / 60) * GuideView.minute
    }
}

/// What the programme with focus is, above the grid.
private struct GuideDetails: View {
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject var focus: GuideFocus

    var body: some View {
        if let programme = focus.programme {
            VStack(alignment: .leading, spacing: Theme.px(4)) {
                HStack(spacing: Theme.px(10)) {
                    Text(programme.name ?? "").font(Theme.font(Theme.lg, .semibold)).lineLimit(1)
                    if let start = programme.starts, let end = programme.ends {
                        Text(verbatim: "\(prefs.time(start)) – \(prefs.time(end))")
                            .font(Theme.font(Theme.sm))
                            .foregroundStyle(Theme.gray400)
                    }
                    if let channel = programme.channelName {
                        Text(channel).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray400)
                    }
                }
                if let overview = programme.overview {
                    Text(overview).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray300).lineLimit(2)
                }
            }
        } else {
            Text(L("Choose a programme on now to watch its channel, or an earlier one marked ↺ to watch it from the start. Choosing one still to come reminds you as it starts."))
                .font(Theme.font(Theme.sm))
                .foregroundStyle(Theme.gray400)
        }
    }
}

/// The half hours across the top, with a line where now is, moved along with the grid.
private struct GuideTimes: View {
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject var scrolled: GuideScroll
    let layout: GuideLayout
    let now: Date

    var body: some View {
        let window = layout.window
        ZStack(alignment: .topLeading) {
            ForEach(0..<Int(window.end.timeIntervalSince(window.start) / 1800), id: \.self) { index in
                let time = window.start.addingTimeInterval(Double(index) * 1800)
                Text(prefs.time(time))
                    .font(Theme.font(Theme.xs, .medium))
                    .foregroundStyle(Theme.gray400)
                    .fixedSize()
                    .offset(x: layout.x(time) + Theme.px(4))
            }
            if now >= window.start && now < window.end {
                Rectangle().fill(Theme.ring).frame(width: Theme.px(2), height: GuideView.timesHeight).offset(x: layout.x(now))
            }
        }
        .frame(width: layout.width, height: GuideView.timesHeight, alignment: .topLeading)
        .offset(x: -scrolled.offset.x)
        // Drawn over a space as wide as the screen leaves, never sizing it: the hours run far wider,
        // and as the space's own width they would push the whole page off the screen's left edge.
        .frame(width: 0, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: GuideView.timesHeight, alignment: .leading)
        .clipped()
    }
}

/// The channels down the side: only those in sight, placed where the grid's rows are.
private struct GuideChannels: View {
    @ObservedObject var scrolled: GuideScroll
    let channels: [Item]
    let play: (Item) -> Void
    let reveal: (Int) -> Void

    var body: some View {
        let step = GuideView.rowHeight + GuideView.gap
        let first = max(0, Int((scrolled.offset.y - GuideView.inset) / step))
        let count = Int(max(scrolled.height, Theme.px(600)) / step) + 2
        let last = min(channels.count, first + count)
        ZStack(alignment: .topLeading) {
            ForEach(first..<max(first, last), id: \.self) { index in
                GuideChannel(channel: channels[index]) { play(channels[index]) } focused: { reveal(index) }
                    .offset(y: GuideView.top(index) - scrolled.offset.y)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

private struct GuideChannel: View {
    let channel: Item
    let action: () -> Void
    let focused: () -> Void

    var body: some View {
        Button(action: action) {
            Focused { isFocused in
                HStack(spacing: Theme.px(10)) {
                    ChannelLogo(channel: channel)
                        .frame(width: Theme.px(56), height: Theme.px(36))
                    VStack(alignment: .leading, spacing: Theme.px(1)) {
                        if let number = channel.channelNumber {
                            Text(number).font(Theme.font(Theme.xs, .medium)).foregroundStyle(Theme.gray400)
                        }
                        Text(channel.name ?? "").font(Theme.font(Theme.sm, .medium)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.px(10))
                .frame(width: GuideView.channelWidth, height: GuideView.rowHeight)
                .onChange(of: isFocused) { _, on in if on { focused() } }
            }
        }
        .buttonStyle(RowStyle(radius: Theme.px(8)))
    }
}

/// "No guide for this channel": one cell as wide as the guide shows, kept beside the channels
/// wherever the guide is scrolled to, which plays the channel, as the web app's guide does. Without
/// it a channel with no programmes has nothing to land on, and moving down skips its row. Laid
/// out at the scrolled place rather than offset there, so landing on it doesn't scroll the guide.
private struct GuideEmptyCell: View {
    @ObservedObject var scrolled: GuideScroll
    let layout: GuideLayout
    let focus: GuideFocus
    let action: () -> Void

    var body: some View {
        let start = min(max(0, scrolled.offset.x), max(layout.width - Theme.px(200), 0))
        let width = min(max(scrolled.width, Theme.px(200)), layout.width - start)
        HStack(spacing: 0) {
            Color.clear.frame(width: start, height: GuideView.rowHeight)
            Button(action: action) {
                Focused { isFocused in
                    Text(L("No guide for this channel"))
                        .font(Theme.font(Theme.sm))
                        .foregroundStyle(Theme.gray400)
                        .padding(.horizontal, Theme.px(12))
                        .frame(width: max(width - GuideView.gap, Theme.px(4)), height: GuideView.rowHeight, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous).fill(Color.white.opacity(0.05))
                        )
                        // Nothing to describe above the grid.
                        .onChange(of: isFocused) { _, on in if on { focus.programme = nil } }
                }
            }
            .buttonStyle(RowStyle(radius: Theme.px(8)))
        }
    }
}

/// One channel's programmes across the guide.
private struct GuideRow: View {
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject private var reminders = LiveReminders.shared
    let channel: Item
    let programmes: [Item]
    let layout: GuideLayout
    let now: Date
    let focus: GuideFocus
    let scrolled: GuideScroll
    let play: (Item) -> Void
    let playFromStart: (Item) -> Void

    private struct Segment {
        var id: String
        var width: CGFloat
        var programme: Item?
    }

    /// The row laid out from the left: each programme as wide as its slot, with a space where
    /// the guide has nothing. Laid out rather than offset, so focus moves follow what's drawn.
    private var segments: [Segment] {
        let window = layout.window
        var list: [Segment] = []
        var cursor: CGFloat = 0
        for programme in programmes where (programme.ends ?? .distantPast) > window.start && (programme.starts ?? .distantFuture) < window.end {
            let start = max(layout.x(programme.starts ?? window.start), cursor)
            let end = layout.x(programme.ends ?? window.end)
            guard end - start >= Theme.px(4) else { continue }
            if start > cursor { list.append(Segment(id: "gap-\(programme.id)", width: start - cursor)) }
            list.append(Segment(id: programme.id, width: end - start, programme: programme))
            cursor = end
        }
        return list
    }

    var body: some View {
        let segments = segments
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous)
                .fill(.white.opacity(0.02))
                .frame(width: layout.width, height: GuideView.rowHeight)
            if segments.isEmpty {
                GuideEmptyCell(scrolled: scrolled, layout: layout, focus: focus) { play(channel) }
            }
            HStack(spacing: 0) {
                ForEach(segments, id: \.id) { segment in
                    if let programme = segment.programme {
                        cell(programme, width: segment.width)
                    } else {
                        Color.clear.frame(width: segment.width, height: GuideView.rowHeight)
                    }
                }
            }
        }
        .frame(width: layout.width, height: GuideView.rowHeight, alignment: .topLeading)
    }

    private func cell(_ programme: Item, width: CGFloat) -> some View {
        let airing = (programme.starts ?? .distantFuture) <= now && now < (programme.ends ?? .distantPast)
        let ended = (programme.ends ?? .distantFuture) <= now
        let kept = ended && programme.aiostreams?.catchup == true
        let reminded = reminders.isSet(programme.id)
        return Button {
            if airing {
                play(channel)
            } else if kept {
                playFromStart(programme)
            } else if !ended {
                // One still to come: a reminder as it starts, or not.
                reminders.toggle(programme, on: channel)
            }
        } label: {
            Focused { isFocused in
                // Too short to read, a programme is only its slot; focused, its details show above the grid.
                Group {
                    if width >= Theme.px(64) {
                        VStack(alignment: .leading, spacing: Theme.px(2)) {
                            HStack(spacing: Theme.px(4)) {
                                if kept { Image(systemName: "arrow.counterclockwise").font(.system(size: Theme.px(10), weight: .semibold)) }
                                if reminded { Image(systemName: "bell.fill").font(.system(size: Theme.px(10), weight: .semibold)).accessibilityLabel(L("Reminder")) }
                                Text(programme.name ?? "").font(Theme.font(Theme.sm, .medium)).lineLimit(1)
                            }
                            .opacity(ended && !kept ? 0.45 : 1)
                            if let begins = programme.starts {
                                Text(prefs.time(begins)).font(Theme.font(Theme.xs)).foregroundStyle(Theme.gray400).lineLimit(1)
                            }
                        }
                        .padding(.horizontal, Theme.px(10))
                    }
                }
                .frame(width: max(width - GuideView.gap, Theme.px(4)), height: GuideView.rowHeight, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous)
                        .fill(airing ? Theme.brand500.opacity(0.25) : Color.white.opacity(0.05))
                )
                .onChange(of: isFocused) { _, on in
                    if on {
                        focus.programme = programme
                    } else if focus.programme?.id == programme.id {
                        focus.programme = nil
                    }
                }
            }
        }
        .buttonStyle(RowStyle(radius: Theme.px(8)))
        .padding(.trailing, GuideView.gap)
    }
}
