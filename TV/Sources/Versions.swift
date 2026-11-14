import SwiftUI

// The web app's version picker (components/version-picker.tsx) as a TV shows it: a panel over
// the page with the title's art faded into its header, how many versions there are, Resume or
// From the start, and a card per version with its name and the server's description.

struct VersionsView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    let choice: VersionChoice
    let play: (PlayRequest) -> Void

    @State private var info: PlaybackInfo?
    @State private var error: String?
    @State private var opening: String?
    @State private var fromStart = false
    @FocusState private var focusedVersion: String?

    private var item: Item { choice.item }
    private var resumeMs: Double? { (choice.startMs ?? 0) > 0 ? choice.startMs : nil }
    private var sources: [MediaSource] { info?.mediaSources ?? [] }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                list
            }
            .frame(width: Theme.px(896))
            .frame(maxHeight: Theme.px(612))
            // The art sits behind the header, under everything the panel lists.
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    Color(white: 17 / 255)
                    banner
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.px(16), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.px(16), style: .continuous)
                    .stroke(.white.opacity(0.1), lineWidth: Theme.px(1))
            )
            .shadow(color: .black.opacity(0.6), radius: Theme.px(40))
        }
        .foregroundStyle(.white)
        .task { await load(refresh: false) }
        .onExitCommand { dismiss() }
    }

    /// The title's art, faded into the panel behind its header.
    private var banner: some View {
        ZStack {
            RemoteImage(url: session.client?.backdrop(item, height: 540))
                .opacity(0.25)
            LinearGradient(
                colors: [Color(white: 17 / 255).opacity(0.3), Color(white: 17 / 255).opacity(0.7), Color(white: 17 / 255)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.px(180))
        .clipped()
        .allowsHitTesting(false)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.px(12)) {
            VStack(alignment: .leading, spacing: Theme.px(4)) {
                Text(item.isEpisode ? (item.seriesName ?? item.displayTitle) : (item.name ?? ""))
                    .font(Theme.font(Theme.xl, .semibold))
                    .lineLimit(1)
                if let line = item.isEpisode ? item.displayTitle : item.productionYear.map(String.init) {
                    Text(line).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray400).lineLimit(1)
                }
            }
            HStack(spacing: Theme.px(8)) {
                Text(info == nil ? "Finding versions" : sources.count == 1 ? "1 version" : "\(sources.count) versions")
                    .font(Theme.font(Theme.sm))
                    .foregroundStyle(Theme.gray400)
                Spacer()
                Button {
                    Task { await load(refresh: true) }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(CircleIconStyle())
                .disabled(info == nil && error == nil)
            }
            .focusSection()
            if let resumeMs {
                HStack(spacing: Theme.px(4)) {
                    Button("Resume from \(clock(resumeMs))") { fromStart = false }
                        .buttonStyle(SegmentStyle(selected: !fromStart))
                    Button("From the start") { fromStart = true }
                        .buttonStyle(SegmentStyle(selected: fromStart))
                }
                .padding(Theme.px(4))
                .background(Capsule().fill(.black.opacity(0.4)))
                .focusSection()
            }
        }
        .padding(.horizontal, Theme.px(20))
        .padding(.top, Theme.px(20))
        .padding(.bottom, Theme.px(12))
    }

    @ViewBuilder private var list: some View {
        if !sources.isEmpty {
            ScrollView {
                LazyVStack(spacing: Theme.px(8)) {
                    ForEach(sources, id: \.ownId) { source in
                        Button {
                            Task { await open(source) }
                        } label: {
                            VersionCard(source: source, opening: opening == source.ownId)
                        }
                        .buttonStyle(VersionCardStyle())
                        .disabled(opening != nil)
                        .focused($focusedVersion, equals: source.ownId)
                    }
                }
                .padding(.horizontal, Theme.px(20))
                .padding(.vertical, Theme.px(12))
            }
            .scrollClipDisabled()
            .focusSection()
            .onAppear { focusedVersion = sources.first?.ownId }
        } else if let error {
            VStack(spacing: Theme.px(16)) {
                ErrorText(text: error)
                Button("Try again") { Task { await load(refresh: true) } }.buttonStyle(SoftPillStyle())
            }
            .padding(Theme.px(40))
        } else if info != nil {
            VStack(spacing: Theme.px(16)) {
                Text("No playable versions found. Only streams with a link play: use debrid or Usenet.")
                    .font(Theme.font(Theme.base))
                    .foregroundStyle(Theme.gray400)
                    .multilineTextAlignment(.center)
                Button("Search again") { Task { await load(refresh: true) } }.buttonStyle(SoftPillStyle())
            }
            .padding(Theme.px(40))
        } else {
            VStack(spacing: Theme.px(12)) {
                ProgressView()
                Text("Searching your addons…").font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray400)
            }
            .padding(Theme.px(48))
        }
    }

    private func load(refresh: Bool) async {
        guard let client = session.client, let userId = session.userId else { return }
        error = nil
        if refresh { info = nil }
        do {
            var result = try await client.playbackInfo(userId: userId, itemId: item.id, refresh: refresh)
            // Versions only the app's own player could open from YouTube aren't offered here.
            result.mediaSources = result.mediaSources?.filter { $0.aiostreams?.ytId == nil }
            info = result
            // A title's only version plays without being listed, as the web app does, unless the
            // list was asked for (Choose a version) or reloaded.
            if !refresh, choice.mode != .list, let only = sources.first, sources.count == 1 {
                await open(only)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Naming the version again gets its subtitles from the configuration's subtitle addons.
    private func open(_ source: MediaSource) async {
        guard let client = session.client, let userId = session.userId else { return }
        opening = source.ownId
        defer { opening = nil }
        var chosen = source
        var playSession = info?.playSessionId
        if let named = try? await client.playbackInfo(userId: userId, itemId: item.id, sourceId: source.ownId),
           let match = named.mediaSources?.first(where: { $0.ownId == source.ownId }) ?? named.mediaSources?.first {
            chosen = match
            playSession = named.playSessionId ?? playSession
        }
        play(PlayRequest(item: item, source: chosen, playSessionId: playSession, startMs: fromStart ? 0 : choice.startMs))
    }

    private func clock(_ ms: Double) -> String {
        let seconds = Int(ms / 1000)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// One version: a round play icon, its name, and the server's description, line for line.
private struct VersionCard: View {
    @Environment(\.isFocused) private var focused
    let source: MediaSource
    let opening: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.px(12)) {
            ZStack {
                Circle().fill(focused ? Color.white : Color.white.opacity(0.1))
                if opening {
                    ProgressView().scaleEffect(0.6)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: Theme.px(14)))
                        .foregroundStyle(focused ? Color.black : Color.white)
                }
            }
            .frame(width: Theme.px(36), height: Theme.px(36))
            VStack(alignment: .leading, spacing: Theme.px(4)) {
                Text(source.label)
                    .font(Theme.font(Theme.base, .medium))
                    .multilineTextAlignment(.leading)
                if let description = source.aiostreams?.description, !description.isEmpty {
                    Text(description)
                        .font(Theme.font(Theme.sm))
                        .foregroundStyle(Theme.gray300)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(Theme.px(2))
                } else if let size = source.size, size > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(Theme.font(Theme.sm))
                        .foregroundStyle(Theme.gray300)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.px(12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The card's border and faint fill, its ring inside the border when focused.
private struct VersionCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Card(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct Card<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label
        let pressed: Bool

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.px(12), style: .continuous)
            label
                .background(shape.fill(Color.white.opacity(focused ? 0.06 : 0.03)))
                .overlay(shape.stroke(focused ? Theme.ring : Color.white.opacity(0.05), lineWidth: focused ? Theme.px(2) : Theme.px(1)))
                .opacity(pressed ? 0.85 : 1)
        }
    }
}

/// A half of the Resume / From the start toggle: white when chosen.
private struct SegmentStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Segment(label: configuration.label, selected: selected)
    }

    private struct Segment<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label
        let selected: Bool

        var body: some View {
            label
                .font(Theme.font(Theme.sm, .medium))
                .foregroundStyle(selected ? Color.black : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.px(32))
                .background(Capsule().fill(selected ? Color.white : (focused ? Color.white.opacity(0.12) : Color.clear)))
                .focusRing(focused)
        }
    }
}
