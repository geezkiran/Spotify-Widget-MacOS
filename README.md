<div align="center">

# ◈ Spotify Widget

**A native macOS menu bar app and Desktop/Notification Center widget for Spotify.**

Now-playing artwork as the backdrop, sliding track titles, playback controls, and Liked Songs — right on your desktop.

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-1ED760?style=flat-square&logo=apple&logoColor=white)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5-1ED760?style=flat-square&logo=swift&logoColor=white)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-1ED760?style=flat-square)](#license)

</div>

<br>

```
┌──────────────────────────────────────────┐
│  ⊕                                ⏮  ⏸  ⏭  │
│                                            │
│  Midnight City                            │
│  M83                                      │
│  ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▭▭▭▭▭▭▭▭▭▭▭▭▭▭▭▭▭▭▭▭▭  │
└──────────────────────────────────────────┘
```

<br>

## What it is

Spotify Widget is a lightweight, menu-bar-only macOS app (no Dock icon) built with SwiftUI and WidgetKit. It drives Spotify's desktop app directly, so a WidgetKit widget can show what's playing in Notification Center or on the desktop — with live artwork, a sliding-text now-playing display, playback controls, a progress bar, and a Liked Songs heart, all synced through an App Group with the main app.

**Features**

- 🎧 Small and medium desktop/Notification Center widgets, backed by the current track's artwork
- 🏝 A notch player on MacBooks with a notch: while music plays, the cover and a moving waveform appear on either side of the notch, at the notch's height (toggle with **Show in Notch** in the menu)
- ⏯ Play/pause, skip forward, and skip back — from the widget or the menu bar
- ❤️ Save or remove the current track from Liked Songs, via Spotify's Web API (PKCE sign-in, no password shared with the app)
- 🪟 A clean menu bar item showing the current track, with the same controls
- 🔁 Launch at login, one click
- 🌓 Designed for macOS's widget glass — content stays legible whether the desktop is focused or not

<br>

## Requirements

| | |
|---|---|
| **macOS** | 14.0 (Sonoma) or later |
| **Spotify** | The Spotify desktop app, installed and running — playback is driven via Apple Events, not the web player |
| **Xcode** | 15 or later (only needed if you're building from source) |
| **Account** | Spotify Free or Premium works for playback control; Liked Songs requires being signed into the Spotify desktop app |

<br>

## Install

### Option A — Build with Xcode (recommended)

1. **Clone the repo**

   ```sh
   git clone https://github.com/geezkiran/Spotify-Widget-MacOS.git
   cd Spotify-Widget-MacOS
   ```

2. **Generate the Xcode project**

   The `.xcodeproj` isn't committed — it's generated from [`project.yml`](project.yml) with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

   ```sh
   brew install xcodegen   # if you don't already have it
   xcodegen generate
   ```

3. **Point signing at your own Apple ID / team**

   `project.yml` is checked in with the original author's team ID and App Group. Widgets share data with the main app through an App Group, so both targets must use **your own** team, and the App Group identifier must match on both.

   Open `project.yml` and update:

   ```yaml
   settings:
     base:
       DEVELOPMENT_TEAM: YOUR_TEAM_ID       # from developer.apple.com/account
   targets:
     SpotifyWidget:
       entitlements:
         properties:
           com.apple.security.application-groups:
             - YOUR_TEAM_ID.com.kiran.spotifywidget
     SpotifyWidgetExtension:
       entitlements:
         properties:
           com.apple.security.application-groups:
             - YOUR_TEAM_ID.com.kiran.spotifywidget
   ```

   Re-run `xcodegen generate` after editing. A free Apple ID works fine for local, unsigned-for-distribution builds — you just need *a* team ID to satisfy App Groups and Automation entitlements.

4. **Open and run**

   ```sh
   open SpotifyWidget.xcodeproj
   ```

   Select the **SpotifyWidget** scheme, choose **My Mac** as the destination, and hit **Run** (⌘R). The app launches with no Dock icon — look for the music note in your menu bar.

5. **Add the widget**

   Right-click the desktop (or open Notification Center) → **Edit Widgets** → search **Spotify Widget** → drag in the small or medium size.

### Option B — Download a build

If a signed release build is attached to this repo's [Releases](../../releases) page, download the `.app`, move it to `/Applications`, and open it. (Building from source is the reliable path until a notarized release is published.)

<br>

## First run

1. Launch **Spotify** desktop app and start playing something.
2. Launch **Spotify Widget** — you'll see a menu bar icon appear.
3. macOS will prompt for **Automation access** so the app can read and control Spotify. If you miss the prompt, grant it manually:

   ```
   System Settings → Privacy & Security → Automation → Spotify Widget → Spotify
   ```

   The menu bar item also has a **"Grant Automation Access…"** shortcut when access is missing.

4. *(Optional)* Click **Connect Spotify Account…** in the menu bar to enable the Liked Songs heart. This opens Spotify's own sign-in page (PKCE OAuth) — the app never sees your password.
5. Add the widget to your desktop or Notification Center (see step 5 above) and it will pick up playback automatically.

<br>

## How it works

```
┌────────────────────┐        AppleScript / Apple Events        ┌──────────────┐
│   Spotify Widget    │ ────────────────────────────────────▶   │   Spotify.app │
│  (menu bar process)  │ ◀────────────────────────────────────   └──────────────┘
└──────────┬──────────┘        now playing · play/pause/skip
           │
           │  App Group (shared container)
           ▼
┌──────────────────────┐
│ SpotifyWidgetExtension │   WidgetKit timeline → desktop / Notification Center
└──────────────────────┘
```

- The menu bar app polls and observes Spotify's playback-state notifications, then writes a snapshot (track, artwork, position, liked state) into a shared **App Group** container.
- The widget extension reads that snapshot to render its timeline — it never talks to Spotify directly.
- Widget button taps (play/pause/skip/like) go through an `AppIntent`, which signals the main app over a local Darwin notification to actually issue the command.
- Liked Songs uses Spotify's Web API over OAuth PKCE, since AppleScript can't touch your library.

<br>

## Project layout

```
SpotifyWidget/                 Menu bar app target
  SpotifyWidgetApp.swift         App entry point, menu bar UI
  NotchPlayer.swift              Now-playing strip around the notch (cover + waveform)
  PlayerController.swift         Orchestrates polling, refresh, commands
  SpotifyProvider.swift          AppleScript bridge to Spotify.app
  SpotifyAccount.swift           OAuth (PKCE) + Liked Songs via Web API
  ArtworkCache.swift             Downloads & caches album art
  CommandListener.swift          Receives commands from the widget

SpotifyWidgetExtension/        WidgetKit extension target
  NowPlayingWidget.swift         Widget configuration & timeline provider
  Intents.swift                  AppIntents for play/pause/skip/like
  Views/NowPlayingView.swift     Widget UI (small & medium layouts)

Shared/                        Code shared by both targets
  NowPlaying.swift                Snapshot model written to the App Group
  SharedStore.swift               App Group read/write helpers
  SharedViews.swift               SlidingText, LikeIconShape, etc.
  PlayerCommand.swift             Command enum sent widget → app
  AppGroup.swift                  App Group identifier

project.yml                    XcodeGen project definition
```

<br>

## Troubleshooting

| Symptom | Fix |
|---|---|
| Widget shows "Needs access" | Grant Automation access: `System Settings → Privacy & Security → Automation → Spotify Widget → Spotify` |
| Widget shows "Spotify isn't open" | Launch the Spotify desktop app — the widget doesn't work against the web player |
| Widget is stuck / not updating | Menu bar → **Reload Widget**, or quit and relaunch Spotify Widget |
| Build fails with a provisioning/App Group error | Make sure `DEVELOPMENT_TEAM` and the App Group ID in `project.yml` match your own team, then re-run `xcodegen generate` |
| Liked Songs heart doesn't appear | Click **Connect Spotify Account…** in the menu bar to sign in |
| "The app owner needs Premium…" error | Spotify's Web API library endpoints require the developer app owner's account to have Premium and the connecting account to be added under User Management in that app's dashboard |

<br>

## License

MIT — see [LICENSE](LICENSE) if present, or treat as MIT by default.

<br>

<div align="center">

Built with SwiftUI · WidgetKit · AppleScript · the Spotify Web API

</div>
