import Foundation

// The subset of the Jellyfin API an AIOStreams server speaks that the web app itself uses
// (packages/web/src/lib/queries.ts), with the server's `aiostreams` extension fields.

struct UserData: Decodable, Hashable {
    var playbackPositionTicks: Int64?
    var playedPercentage: Double?
    var played: Bool?
    var isFavorite: Bool?
    var unplayedItemCount: Int?
    var lastPlayedDate: String?
}

struct ItemExtension: Decodable, Hashable {
    var genreRequired: Bool?
    /// When the show an episode belongs to was last watched, which the server adds to Next up.
    var showWatchedAt: String?
    /// Marks a server with the fillers feature puts on an episode, which playing on can skip.
    var filler: Bool?
    var recap: Bool?
}

struct Item: Decodable, Identifiable, Hashable {
    var id: String
    var name: String?
    var type: String?
    var seriesName: String?
    var seriesId: String?
    var seasonId: String?
    var indexNumber: Int?
    var parentIndexNumber: Int?
    var overview: String?
    var productionYear: Int?
    var runTimeTicks: Int64?
    var officialRating: String?
    var communityRating: Double?
    var genres: [String]?
    var tags: [String]?
    var collectionType: String?
    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    var parentBackdropItemId: String?
    var parentBackdropImageTags: [String]?
    var seriesPrimaryImageTag: String?
    var parentThumbItemId: String?
    var parentThumbImageTag: String?
    var parentLogoItemId: String?
    var parentLogoImageTag: String?
    var locationType: String?
    var premiereDate: String?
    var taglines: [String]?
    var people: [Person]?
    var status: String?
    var userData: UserData?
    var aiostreams: ItemExtension?
    // Live TV: a channel's number and what's on it now; a programme's channel and times.
    var channelNumber: String?
    var channelId: String?
    var channelName: String?
    var startDate: String?
    var endDate: String?
    var episodeTitle: String?
    var currentProgram: Programme?
    var providerIds: [String: String]?
    var remoteTrailers: [RemoteTrailer]?

    /// An image tag by Jellyfin's type name. The decoder's key strategy also lowers the first
    /// letter of dictionary keys, so `ImageTags.Primary` arrives as `primary`.
    func tag(_ kind: String) -> String? {
        imageTags?[kind.prefix(1).lowercased() + kind.dropFirst()] ?? imageTags?[kind]
    }

    var isEpisode: Bool { type == "Episode" }
    var isSeries: Bool { type == "Series" }
    var isFolder: Bool { type == "CollectionFolder" || type == "BoxSet" || type == "Folder" }
    var isChannel: Bool { type == "TvChannel" }

    /// An episode not started, which the web app's spoiler blur hides until it has focus.
    var unstarted: Bool { isEpisode && userData?.played != true && (userData?.playbackPositionTicks ?? 0) == 0 }

    /// An anime database's id marks anime, as the web app tells (lib/playback/upscaling.ts). The
    /// decoder lowers the first letter of these keys, so they're matched without case.
    var hasAnimeIds: Bool {
        let keys = Set((providerIds ?? [:]).filter { !$0.value.isEmpty }.keys.map { $0.lowercased() })
        if !keys.isDisjoint(with: ["anilist", "kitsu", "myanimelist", "anidb"]) { return true }
        // Or an Anime genre or tag, as the web app also counts since Android v0.15.0.
        return ((genres ?? []) + (tags ?? [])).contains { $0.lowercased() == "anime" }
    }

    var starts: Date? { parseDate(startDate) }
    var ends: Date? { parseDate(endDate) }

    /// Where playback picks up. A title watched before and started again resumes too, as the web app
    /// reads the position whatever the watched mark says.
    var resumeMs: Double? {
        guard let ticks = userData?.playbackPositionTicks, ticks > 0 else { return nil }
        return Double(ticks) / 10_000
    }

    var runtimeMinutes: Int? {
        runTimeTicks.map { Int($0 / 600_000_000) }.flatMap { $0 > 0 ? $0 : nil }
    }

    /// "S02E04 · Name" for an episode, as the web app writes it; the name otherwise.
    var displayTitle: String {
        guard isEpisode else { return name ?? "" }
        return [episodeCode, name ?? ""].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var episodeCode: String? {
        guard let episode = indexNumber else { return nil }
        let e = String(format: "E%02d", episode)
        return parentIndexNumber.map { String(format: "S%02d", $0) + e } ?? e
    }

    /// Jellyfin can't play a virtual item, such as an episode not yet aired.
    var playable: Bool { isSeries || isChannel || ((type == "Movie" || isEpisode) && locationType != "Virtual") }

    /// "1h 12m left", from where playback stopped.
    var timeLeft: String? {
        guard let total = runTimeTicks, let at = userData?.playbackPositionTicks, at > 0, total > at else { return nil }
        let minutes = Int((total - at) / 600_000_000)
        guard minutes > 0 else { return nil }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m left" : "\(minutes)m left"
    }

    var runtimeText: String? {
        guard let minutes = runtimeMinutes else { return nil }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

/// A trailer the server knows for a title, usually on YouTube.
struct RemoteTrailer: Decodable, Hashable {
    var url: String?
    var name: String?

    /// The YouTube video's id, from any of its address shapes, as the web app reads it.
    var youTubeId: String? {
        guard let url, let parsed = URLComponents(string: url), let host = parsed.host?.lowercased() else { return nil }
        let bare = host.replacingOccurrences(of: #"^(www|m)\."#, with: "", options: .regularExpression)
        let id: String?
        if bare == "youtu.be" {
            id = String(parsed.path.dropFirst())
        } else if bare == "youtube.com" || bare == "youtube-nocookie.com" {
            id = parsed.queryItems?.first { $0.name == "v" }?.value
                ?? parsed.path.range(of: #"^/(embed|shorts|v)/[^/]+"#, options: .regularExpression)
                    .map { String(parsed.path[$0].split(separator: "/").last ?? "") }
        } else {
            id = nil
        }
        guard let id, id.range(of: #"^[\w-]{11}$"#, options: .regularExpression) != nil else { return nil }
        return id
    }
}

/// What a channel shows now, as the channel list sends it along (`AddCurrentProgram`).
struct Programme: Decodable, Hashable {
    var id: String
    var name: String?
    var episodeTitle: String?
    var startDate: String?
    var endDate: String?

    var starts: Date? { parseDate(startDate) }
    var ends: Date? { parseDate(endDate) }
}

/// How far through its slot a programme is, from 0 to 1.
func airedShare(from start: Date?, to end: Date?, now: Date) -> Double {
    guard let start, let end, end > start else { return 0 }
    return min(1, max(0, now.timeIntervalSince(start) / end.timeIntervalSince(start)))
}

struct Person: Decodable, Hashable, Identifiable {
    var id: String
    var name: String?
    var role: String?
    var type: String?
    var primaryImageTag: String?
}

struct ItemsResult: Decodable {
    var items: [Item]?
    var totalRecordCount: Int?
}

struct SourceExtension: Decodable, Hashable {
    /// The version's own id; the first version otherwise carries the item's.
    var id: String?
    var name: String?
    var description: String?
    var ytId: String?
    /// Versions of one release across episodes share it, which the next episode carries on in.
    var bingeGroup: String?
}

/// A stretch of a title the server knows: an intro, recap, credits, preview or ad (Jellyfin's
/// media segments, which the AIOStreams server fills from IntroDB, AniSkip and others).
struct MediaSegment: Decodable, Hashable, Identifiable {
    var type: String
    var startTicks: Int64
    var endTicks: Int64

    var id: String { "\(type):\(startTicks)" }
    var start: Double { Double(startTicks) / 10_000_000 }
    var end: Double { Double(endTicks) / 10_000_000 }

    private enum CodingKeys: String, CodingKey { case type, startTicks, endTicks }

    init(type: String, start: Double, end: Double) {
        self.type = type
        startTicks = Int64(start * 10_000_000)
        endTicks = Int64(end * 10_000_000)
    }

    // A whole chapter title, or the words before its first punctuation, lowercased and stripped of
    // numbers, names a kind (upstream lib/playback/chapters.ts): "OP 2" and "OP - Song" match, but
    // "The Opening of the Gates" doesn't.
    private static let kinds: [(String, String)] = [
        ("Intro", #"^(op|opening|opening (credits|song|theme)|title sequence|main titles?)$"#),
        ("Outro", #"^(ed|ending|ending (credits|song|theme)|end credits|credits|closing credits|outro)$"#),
        ("Recap", #"^(recap|previously|previously on)$"#),
        ("Preview", #"^(preview|next episode preview|next episode|next time)$"#),
    ]
    /// Names the cold open in some releases, so it counts only when nothing names the opening.
    private static let looseIntro = #"^(intro|introduction)$"#
    /// Past this a named chapter also holds the programme, except credits, which run long on films.
    private static let namedMax: Double = 180

    private static func plain(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: #"[^a-z]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func names(_ title: String, _ pattern: String) -> Bool {
        let lead = title.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 '’").inverted).first ?? title
        return [plain(title), plain(lead)].contains { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    private static func kind(_ title: String) -> String? {
        kinds.first { names(title, $0.1) }?.0
    }

    /// The segments a file's chapters name: each chapter runs until the next starts.
    static func named(chapters: [(title: String, start: Double)], duration: Double) -> [MediaSegment] {
        let sorted = chapters.sorted { $0.start < $1.start }
        let hasOpening = sorted.contains { kind($0.title) == "Intro" }
        return sorted.enumerated().compactMap { index, chapter in
            let type = kind(chapter.title) ?? (!hasOpening && names(chapter.title, looseIntro) ? "Intro" : nil)
            let end = index + 1 < sorted.count ? sorted[index + 1].start : duration
            guard let type, end > chapter.start else { return nil }
            if type != "Outro" && end - chapter.start > namedMax { return nil }
            return MediaSegment(type: type, start: chapter.start, end: end)
        }
    }

    /// Jellyfin's types, which a server may send by name or by number.
    private static let numbered = [1: "Commercial", 2: "Preview", 3: "Recap", 4: "Outro", 5: "Intro"]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let name = try? container.decode(String.self, forKey: .type) {
            type = name
        } else {
            type = Self.numbered[(try? container.decode(Int.self, forKey: .type)) ?? 0] ?? "Unknown"
        }
        startTicks = (try? container.decode(Int64.self, forKey: .startTicks)) ?? 0
        endTicks = (try? container.decode(Int64.self, forKey: .endTicks)) ?? 0
    }
}

struct SegmentsResult: Decodable {
    var items: [MediaSegment]?
}

struct MediaStream: Decodable, Hashable {
    var type: String?
    var index: Int?
    var displayTitle: String?
    var title: String?
    var language: String?
    var codec: String?
    var isExternal: Bool?
    var isForced: Bool?
    var deliveryUrl: String?
}

struct MediaSource: Decodable, Identifiable, Hashable {
    var id: String
    var name: String?
    var path: String?
    var size: Int64?
    var container: String?
    var requiredHttpHeaders: [String: String]?
    /// A live source, with no end and no seeking.
    var isInfiniteStream: Bool?
    var mediaStreams: [MediaStream]?
    var aiostreams: SourceExtension?

    /// The web app keys every version by its own id.
    var ownId: String { aiostreams?.id ?? id }
    var label: String { aiostreams?.name ?? name ?? "Version" }
}

struct PlaybackInfo: Decodable {
    var mediaSources: [MediaSource]?
    var playSessionId: String?
    var errorCode: String?
}

struct PublicSystemInfo: Decodable {
    var serverName: String?
    var version: String?
}

struct PublicUser: Decodable, Identifiable, Hashable {
    var id: String
    var name: String?
    var hasPassword: Bool?
    var primaryImageTag: String?
}

struct AuthResult: Decodable {
    struct User: Decodable {
        var id: String
        var name: String?
    }

    var accessToken: String
    var user: User
}

struct QuickConnectState: Decodable {
    var secret: String
    var code: String?
    var authenticated: Bool?
}

struct JellyfinError: LocalizedError {
    var status: Int
    var message: String
    var errorDescription: String? { message }
}

/// A minimal client for the Jellyfin API this server speaks.
struct JellyfinClient: Sendable {
    let base: URL
    var token: String?
    let deviceId: String
    let deviceName: String

    static let clientName = "AIOStreams tvOS"
    static let ticksPerMs: Double = 10_000

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // Jellyfin names fields in PascalCase.
        decoder.keyDecodingStrategy = .custom { path in
            let key = path.last!.stringValue
            return AnyKey(key.prefix(1).lowercased() + key.dropFirst())
        }
        return decoder
    }()

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// What a person types: a bare host, a full address, or the web app's own `/web` page.
    static func normalize(_ address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), components.host != nil else { return nil }
        // Kept encoded: a picker address carries an encrypted password that may hold an encoded slash.
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/web") { path.removeLast(4) }
        // A server's root holds the API under /jellyfin, as the web app reads it.
        components.percentEncodedPath = path.isEmpty ? "/jellyfin" : path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    var authorization: String {
        var parts = [
            "Client=\"\(Self.clientName)\"",
            "Device=\"\(deviceName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "AppleTV")\"",
            "DeviceId=\"\(deviceId)\"",
            "Version=\"\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")\"",
        ]
        if let token { parts.append("Token=\"\(token)\"") }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    func url(_ path: String, _ query: [String: String?] = [:]) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath += path
        let items = query.compactMap { key, value in value.flatMap { $0.isEmpty ? nil : URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty { components.queryItems = items.sorted { $0.name < $1.name } }
        return components.url!
    }

    func get<T: Decodable>(_ path: String, _ query: [String: String?] = [:]) async throws -> T {
        try await send("GET", path, query: query, body: nil)
    }

    func post<T: Decodable>(_ path: String, _ query: [String: String?] = [:], body: [String: Any]? = nil) async throws -> T {
        try await send("POST", path, query: query, body: body)
    }

    /// An answer as plain JSON, for objects sent back whole, such as a user's configuration.
    func json(_ method: String, _ path: String, _ query: [String: String?] = [:], body: [String: Any]? = nil) async throws -> [String: Any] {
        let data = try await raw(method, path, query: query, body: body)
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// A request whose answer has no body worth reading.
    func call(_ method: String, _ path: String, _ query: [String: String?] = [:]) async throws {
        _ = try await raw(method, path, query: query, body: nil)
    }

    /// For reports whose answer nobody reads.
    func fire(_ path: String, body: [String: Any]) async {
        _ = try? await raw("POST", path, query: [:], body: body)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, query: [String: String?], body: [String: Any]?) async throws -> T {
        let data = try await raw(method, path, query: query, body: body)
        do {
            return try Self.decoder.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
        } catch {
            AppLog.warn("api", "\(path): could not read the answer: \(error)")
            throw JellyfinError(status: 0, message: "The server sent something unexpected.")
        }
    }

    private func raw(_ method: String, _ path: String, query: [String: String?], body: [String: Any]?) async throws -> Data {
        var request = URLRequest(url: url(path, query))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw JellyfinError(status: 0, message: "Can't reach the server.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message: String
            switch status {
            case 401: message = "Signed out. Sign in again."
            case 403: message = "The server refused this."
            case 404: message = "Not found on this server."
            case 429: message = "Too many requests. Try again shortly."
            default: message = "Request failed (\(status))."
            }
            throw JellyfinError(status: status, message: message)
        }
        return data
    }

    // MARK: - Images

    enum ImageKind: String { case primary = "Primary", backdrop = "Backdrop", thumb = "Thumb", logo = "Logo" }

    func image(_ itemId: String, _ kind: ImageKind, tag: String?, height: Int) -> URL {
        let path = kind == .backdrop ? "/Items/\(itemId)/Images/Backdrop/0" : "/Items/\(itemId)/Images/\(kind.rawValue)"
        return url(path, ["tag": tag, "fillHeight": String(height), "quality": "90"])
    }

    /// A portrait poster for titles, a still for episodes.
    func poster(_ item: Item, height: Int) -> URL? {
        if item.isEpisode {
            if let tag = item.tag("Primary") { return image(item.id, .primary, tag: tag, height: height) }
            if let id = item.parentThumbItemId { return image(id, .thumb, tag: item.parentThumbImageTag, height: height) }
            if let id = item.seriesId { return image(id, .primary, tag: item.seriesPrimaryImageTag, height: height) }
            return nil
        }
        return image(item.id, .primary, tag: item.tag("Primary"), height: height)
    }

    /// A title's logo artwork, or its show's, where it has one.
    func logo(_ item: Item, width: Int) -> URL? {
        if let tag = item.tag("Logo") { return image(item.id, .logo, tag: tag, width: width) }
        if let id = item.parentLogoItemId, let tag = item.parentLogoImageTag { return image(id, .logo, tag: tag, width: width) }
        return nil
    }

    /// A wide picture for a title: its own thumb, else its backdrop; an episode's still.
    func still(_ item: Item, height: Int) -> URL? {
        if item.isEpisode { return poster(item, height: height) }
        if let tag = item.tag("Thumb") { return image(item.id, .thumb, tag: tag, height: height) }
        return backdrop(item, height: height) ?? poster(item, height: height)
    }

    func image(_ itemId: String, _ kind: ImageKind, tag: String?, width: Int) -> URL {
        url("/Items/\(itemId)/Images/\(kind.rawValue)", ["tag": tag, "maxWidth": String(width), "quality": "90"])
    }

    func backdrop(_ item: Item, height: Int) -> URL? {
        if let tag = item.backdropImageTags?.first { return image(item.id, .backdrop, tag: tag, height: height) }
        if let id = item.parentBackdropItemId { return image(id, .backdrop, tag: item.parentBackdropImageTags?.first, height: height) }
        if let id = item.seriesId { return image(id, .backdrop, tag: nil, height: height) }
        return nil
    }

    // MARK: - Playback

    /// Every file plays as it is; text subtitles come as WebVTT addresses.
    private static let deviceProfile: [String: Any] = [
        "DirectPlayProfiles": [["Type": "Video"]],
        "SubtitleProfiles": [["Format": "vtt", "Method": "External"]],
    ]

    /// The version list, or with `sourceId` one version with its subtitles from subtitle addons.
    func playbackInfo(userId: String, itemId: String, sourceId: String? = nil, refresh: Bool = false) async throws -> PlaybackInfo {
        var body: [String: Any] = [
            "UserId": userId,
            "DeviceProfile": Self.deviceProfile,
            "EnableRequiredHttpHeaders": true,
        ]
        if let sourceId {
            body["MediaSourceId"] = sourceId
        } else {
            body["Fresh"] = true
            body["SkipSubtitles"] = true
        }
        if refresh { body["Refresh"] = true }
        return try await post("/Items/\(itemId)/PlaybackInfo", ["userId": userId], body: body)
    }

    /// The version's own address where it has one, which outlives this session; the stream route otherwise.
    func streamURL(itemId: String, source: MediaSource) -> URL? {
        if let path = source.path, let url = URL(string: path), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return url
        }
        return url("/Videos/\(itemId)/stream", ["static": "true", "MediaSourceId": source.ownId, "ApiKey": token])
    }

    /// A subtitle's address, which the server gives relative to its API.
    func absolute(_ deliveryUrl: String) -> URL? {
        if let url = URL(string: deliveryUrl), url.scheme != nil { return url }
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text + (deliveryUrl.hasPrefix("/") ? "" : "/") + deliveryUrl)
    }
}
