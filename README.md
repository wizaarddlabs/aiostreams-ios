# AIOStreams for iOS/iPadOS and Apple TV

An unofficial iPhone, iPad and Apple TV port of the [AIOStreams](https://github.com/Viren070/AIOStreams) app, playing through [AetherEngine](https://github.com/superuser404notfound/AetherEngine).

### Apple TV

<p>
  <img src="docs/screenshots/tv-home.jpg" width="49%" alt="Apple TV home: the rotating hero over Continue watching">
  <img src="docs/screenshots/tv-show.jpg" width="49%" alt="A show's page with season pills and episodes">
</p>
<p>
  <img src="docs/screenshots/tv-versions.jpg" width="49%" alt="The version picker">
  <img src="docs/screenshots/tv-player.jpg" width="49%" alt="The player, with subtitles lifted above its controls">
</p>
<p>
  <img src="docs/screenshots/tv-movie.jpg" width="32%" alt="A movie's page">
  <img src="docs/screenshots/tv-signin.jpg" width="32%" alt="Who's watching? sign-in">
  <img src="docs/screenshots/tv-settings.jpg" width="32%" alt="Settings, synced with the web app">
</p>

### iPhone and iPad

<p>
  <img src="docs/screenshots/iphone-home.jpg" width="24%" alt="iPhone home">
  <img src="docs/screenshots/iphone-show.jpg" width="24%" alt="A show on iPhone">
  <img src="docs/screenshots/iphone-movie.jpg" width="24%" alt="A movie on iPhone">
  <img src="docs/screenshots/iphone-versions.jpg" width="24%" alt="Versions on iPhone">
</p>
<p>
  <img src="docs/screenshots/ipad-home.jpg" width="49%" alt="iPad home">
  <img src="docs/screenshots/ipad-show.jpg" width="49%" alt="A show on iPad">
</p>

The iPhone and iPad app resizes: Split View and Slide Over on iPad, and iPhone Duo's inner and outer displays and Split View. To use all of the Duo's inner display, it needs building with Xcode 27.1 or later, which the workflow picks up once GitHub's runners have it.

The screenshots come from Apple's simulators connected to a demo server with a made-up catalogue. Every title, poster and video in them is drawn by `tools/demo-server`. To retake them, run the **Screenshots** workflow from the Actions tab, or `scripts/screenshots.sh` on a Mac.

It follows the design of the official Android and desktop apps, which are a web view over a native player. Their source is public under AGPL-3.0, so this port builds from that source rather than from the APK.

- The page is AIOStreams' own web app (`packages/web`, standalone build). It draws every screen and the player's controls.
- The page talks to the app through `window.aiostreamsApp`, the same bridge (protocol 2) the Android and desktop apps use. The page itself is almost unchanged: `web/ios-host.patch` adds one small host (`platform: 'ios'`) so the page knows it's on iOS.
- The video is drawn by AetherEngine beneath a transparent `WKWebView`. AetherEngine replaces mpv and ExoPlayer and brings FFmpeg demuxing, VideoToolbox and dav1d decoding, HDR10, HDR10+, Dolby Vision and HLG, and Atmos.
- The engine leaves subtitle drawing to the app. A native layer between the video and the page draws them, in the style chosen in the page's subtitle settings.

```
┌──────────────────────────────┐
│ WKWebView (transparent)      │  aiostreams://localhost/  ← bundled web app
│   window.aiostreamsApp  ⇅    │  JSON messages: player-load, player-state, …
├──────────────────────────────┤
│ SubtitleOverlayView          │  engine.subtitleCues @ clock.sourceTime
├──────────────────────────────┤
│ AetherPlayerView             │  AetherEngine
└──────────────────────────────┘
```

## Getting an IPA

You need macOS to build it; this repository has no prebuilt binary. Either:

**GitHub Actions (no Mac needed).** Push this repository to GitHub. The `Build IPA` workflow runs on a `macos-26` runner and uploads `AIOStreams.ipa` as a workflow artifact. Pushing a `v*` tag also attaches it to a release.

**Locally on a Mac** with Xcode 27 (26.3 is AetherEngine's best-effort floor), Node 24, pnpm 11 and XcodeGen:

```bash
brew install xcodegen
```

```bash
scripts/make-ipa.sh
```

The app's version comes from the release tags: a build of the commit tagged `v0.2.8` is 0.2.8, and the build number is the commit count. Set `APP_VERSION` or `BUILD_NUMBER` to override them. The script needs the full history and tags (not a shallow clone).

**AltStore and SideStore.** Add this source to get the iPhone and iPad app and its updates in the app:

```
https://github.com/wizaarddlabs/aiostreams-ios/releases/latest/download/altstore.json
```

Each release attaches it, listing every release from v0.2.10 on. Apple TV isn't in it: neither installs on tvOS.

The IPA is unsigned. Sign it when you install it with AltStore, SideStore, Sideloadly, or your own developer certificate. With a free Apple ID, apps expire after 7 days and must be refreshed.

To run it from Xcode instead, run `scripts/build-web.sh`, then `xcodegen generate`, open `AIOStreams.xcodeproj`, choose your team under Signing, and run it on a device.

## What maps to what

| Page message | iOS app |
| --- | --- |
| `player-load` (url, headers, start, languages) | `engine.load(url:startPosition:options:)` with `httpHeaders`, `isLive`, preferred languages |
| `player-set` (paused, volume, speed, audio, subtitle, delay) | `play`/`pause`, `volume`, `setRate`, `selectAudioTrack`, `selectSubtitleTrack`/`clearSubtitle`, overlay delay |
| `player-seek` | `engine.seek(to:exact:)` |
| `player-subtitle-add`, `subtitle-file` | `addExternalSubtitleTrack` |
| `player-style` (fit, subtitle look) | `videoGravity`, the overlay's style |
| `player-thumbnail` | `scrubThumbnail(atSeconds:)`, served at `/thumbnail/…` |
| `now-playing`, `media-key` | Now Playing info and lock screen controls |
| `fullscreen` | landscape, no status bar or home indicator |
| `player-state` / `player-tracks` / `player-chapters` / `player-event` / `player-ended` | the engine's published state |

## Apple TV

tvOS has no WebKit, so the web app can't run there. The Apple TV app (`TV/`) is native SwiftUI instead. It talks to the server's Jellyfin API with the same requests the web app makes (`packages/web/src/lib/queries.ts`), and plays with the same AetherEngine. The engine handles the HDR and Dolby Vision display switching itself, following the Apple TV's Match Content setting.

- **Connecting:** enter the server address from the configure page (Save & Install → Jellyfin apps → Connect). Sign in with Quick Connect (approve the code on the configure page), by picking a user, or with a name and password.
- **Browsing:** Home has Continue Watching, Next Up and a row for each library. There's also search, library grids, and details pages with seasons and episodes.
- **Skipping and the next episode:** intros, recaps, credits, previews and ads the server knows (its configuration's Skip intro and credits) get a skip button, or are skipped automatically, per Settings → Skipping and the next episode. Near the end, or at the credits, the next episode is offered with a countdown and plays on in the version that matches, asking "Are you still watching?" after a run of episodes. The settings are shared with the web app.
- **Anime upscaling:** with Settings → Video → Anime upscaling on, anime up to 1080p plays through AetherEngine's line-art scaler (Anime4K). A title counts as anime when it, its season or its show has an AniList, Kitsu, MyAnimeList or AniDB id, as in the web app. On iPhone and iPad, the web app's own Anime upscaling setting drives the same scaler.
- **People:** a title's cast lead to their page, with their films and shows on the server.
- **Settings shared with the web app:** besides playback, subtitles and skipping: the hero (rotating, or following the focused card), poster size and text, combined search results, blurring episodes not started, merging Continue watching and Next up, the theme's accent and background colours, skipping by the file's chapters, and passing over filler, recap and unaired episodes. The player's skip step, time left, clock and showing the controls on pause and skip are kept on the Apple TV.
- **In the player:** an Episodes panel to move to another episode of the season, a Sync panel to shift subtitles and sound against the picture, and the overview while paused.
- **Trailers:** a title with a trailer gets a Trailer button. YouTube trailers play through the same lookup the iPhone, Android and desktop apps use, in the title's original language where the account's audio language is Original. Watching one doesn't change the title's progress.
- **Live TV:** on a server with channels, Live TV appears in the sidebar. Browse channels by group (Favourites, Recent, All channels and the server's genres) as a list of what's on now and next, or as a guide of the coming six hours. Channels play live, with no seeking.
- **Versions:** the streams your addons found, in the order the server sorted them. Picking one also fetches its subtitles from your subtitle addons.
- **Player:** play/pause, click left or right to skip 10 s, hold them to fast forward or rewind (faster the longer you hold), and press down for the controls, with their own buttons for audio and for subtitles. While paused, with the bar selected, swipe across the remote to move along it. Playback resumes where you left off and reports progress to the server.

It shares `Support.swift` and `SubtitleOverlayView.swift` with the iOS app. The build makes `AIOStreams-tvOS.ipa` alongside the iPhone one. AltStore and SideStore don't install on Apple TV. Use Xcode with a paired Apple TV, or another signing tool that supports tvOS.

Not in the Apple TV app yet: Live TV reminders, and playing earlier programmes from the guide.

## Not done yet

- **Stats overlay.** mpv's stats pages have no AetherEngine equivalent here.
- **Desktop-only settings.** Cards such as mpv config, video output and audio devices may still show; the app answers each with an empty list.

## Updating

`web/AIOSTREAMS_REF` pins the AIOStreams commit the web app is built from, so the patch applies cleanly. To move to a newer one, change it and check that `git apply` of `web/ios-host.patch` still succeeds. If it doesn't, regenerate the patch. `project.yml` pins AetherEngine to an exact version.

## Optional AetherEngine components

AetherEngine compiles some components only when a build asks for them, and XcodeGen can't set that itself, so the apps build the engine through a small local package. There are two, with the same module name, so the app code is the same either way:

| Package | Components | Used by |
| --- | --- | --- |
| `Packages/AetherEngineFeatures` | Dolby Vision Profile 7 FEL, by curve fold only (`DolbyVisionFelCurves`) | Every build unless told otherwise, and all public releases |
| `Packages/AetherEngineHeights` | The same, plus TrueHD Atmos and DTS:X height channels (`TrueHDObjectAudio`, `DTSXObjectAudio`) | Builds made with `HEIGHT_CHANNELS=on` |

- **FEL by curve fold:** the enhancement layer is folded into the Profile 8.1 picture on Apple's own video path, which applies it with its licensed decoder. The engine's software dual-layer composer (`DualLayerDolbyVision`), whose steps are covered by Dolby patents, is left off in both.
- **Height channels:** TrueHD Atmos and DTS:X are rendered with their heights. On Apple TV they reach an Atmos receiver as Dolby MAT, with the speaker layout in Settings → Audio, which only appears in these builds. iPhone and iPad play them as Spatial Audio. Needs iOS or tvOS 26. Without them, these tracks play as their 7.1 channels.

To build with height channels:

- **Locally:** run `HEIGHT_CHANNELS=on scripts/make-ipa.sh`.
- **On GitHub:** open Actions → Build IPA → Run workflow and tick **Height channels**. The IPAs are attached to that run, not to a release.

Pushes, tags and releases always build without them.

AetherEngine notes that these components may be subject to third-party patent licensing, which is the responsibility of whoever builds and distributes the app with them. That's why public releases leave height channels out.

## Licence

AGPL-3.0, like AIOStreams (`LICENSE`). AetherEngine is LGPL-3.0 with an App Store exception, and is linked statically from its tagged release. FFmpeg is LGPL-2.1+ and is embedded as dynamic frameworks. The engine also compiles in libdovi and Anime4K's line-art kernels, both MIT. The apps' licence screens list them all.

This is an unofficial port, not affiliated with AIOStreams or AetherEngine.
