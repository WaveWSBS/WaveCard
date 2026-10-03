# WaveCard 2.0 💳

> **The Apple Wallet card skinner for macOS — pure Swift, zero Python, zero jailbreak.**
> Re-skin the cards already in your Apple Wallet with your own artwork, over USB, in one click.

[![Release](https://img.shields.io/github/v/release/WaveWSBS/WaveCard?label=Release&color=6C5CE7)](https://github.com/WaveWSBS/WaveCard/releases)
[![macOS](https://img.shields.io/badge/macOS-14.0%2B-000000?logo=apple)](https://github.com/WaveWSBS/WaveCard/releases)
[![iOS](https://img.shields.io/badge/iPhone-iOS%2018%2B-000000?logo=apple)](https://github.com/WaveWSBS/WaveCard/releases)
[![Swift](https://img.shields.io/badge/core-Swift%20%2B%20CoreGraphics-F05138?logo=swift)](https://github.com/WaveWSBS/WaveCard)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

WaveCard talks straight to iPhone over USB using Apple's own `MobileDevice` and `AirTrafficHost` frameworks. It **sniffs** card passes out of the unified device log, **reads** the real factory artwork out of each `.pkpass` on the device, and **writes** your replacement artwork back — then clears Wallet's render cache so the new design actually shows up.

- 🖥️ **macOS app, no runtime dependencies** — no Python, no Homebrew, no `libimobiledevice`, no Xcode required to *use* it.
- 🔍 **Real-time card detection** — click **Scan Cards**, then double-click the Side button and pay. Cards appear by themselves.
- 🖼️ **True factory artwork extraction** — pulls the real `cardBackgroundCombined` art off the phone (PNG, vector PDF, or Apple's asset-broker sidecar), not a screenshot.
- 💾 **Automatic original backup** — the factory artwork is stored as a single PNG per card the first time it is read off your iPhone. Restore any card, or all of them, in one click.
- 📤 **PNG export** — save the stored originals out as ordinary image files, one card or a whole selected batch.
- ⚡ **100% Pure Swift core (Zero Python)** — scaling, aspect-fill, vector PDF generation, PKZip packaging with Apple `0x5A53` extra attributes, and binary `Books.plist` generation all run natively via `CoreGraphics` / `CGContext` / `CGPDFContext`. Two tiny Objective-C command-line helpers bridge the private frameworks.
- 📦 **~2.4 MB** universal DMG (Apple Silicon + Intel).

---

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Full Guide](#full-guide)
  - [1. Connect your iPhone](#1-connect-your-iphone)
  - [2. Scan for cards](#2-scan-for-cards)
  - [3. Fetch the factory artwork](#3-fetch-the-factory-artwork)
  - [4. Assign a custom skin](#4-assign-a-custom-skin)
  - [5. Make sure the original is stored](#5-make-sure-the-original-is-stored)
  - [6. Flash to iPhone](#6-flash-to-iphone)
  - [7. See it in Wallet](#7-see-it-in-wallet)
  - [Restore factory artwork](#restore-factory-artwork)
  - [Activity Console](#activity-console)
- [How It Works](#how-it-works)
- [Where your data lives](#where-your-data-lives)
- [Important notes & risks](#important-notes--risks)
- [Troubleshooting](#troubleshooting)
- [Building from source](#building-from-source)
- [Project layout](#project-layout)
- [Documentation](#documentation)
- [Credits](#credits)
- [License](#license)

---

## Requirements

| | |
|---|---|
| **Mac** | macOS 14.0 (Sonoma) or newer, Apple Silicon or Intel |
| **iPhone** | iOS 18 or newer, USB cable, unlocked |
| **Connection** | USB only — Wi-Fi pairing is intentionally disabled |
| **Build tools** *(only if compiling yourself)* | Xcode 15+ **or** Xcode Command Line Tools (`xcode-select --install`) |
| **Jailbreak** | Not required |

---

## Installation

1. Download **`WaveCard.dmg`** from [Releases](https://github.com/WaveWSBS/WaveCard/releases).
2. Open the DMG and drag **`WaveCard.app`** into your **Applications** folder.
3. Launch it. No first-run setup, no helper daemon, no `sudo`.

> [!NOTE]
> **First launch on macOS (Gatekeeper)**
> WaveCard is ad-hoc signed, so macOS may show an unidentified-developer prompt:
> - **UI:** right-click `WaveCard.app` in Applications ➔ **Open** ➔ **Open**
> - **Terminal:**
>   ```sh
>   sudo xattr -cr /Applications/WaveCard.app
>   ```

---

## Quick Start

1. Connect and unlock your iPhone; tap **Trust This Computer** if prompted.
2. In WaveCard, click **Scan Cards** in the toolbar.
3. On the iPhone: double-click the **Side button**, pass **Face ID**, and tap a card.
4. The card (and its real artwork) shows up in **Wallet Cards** automatically.
5. Drop an image on the card, or press **Set Skin**.
6. *(Recommended)* Press **Fetch All Originals** so every card has its factory copy stored before you flash.
7. Select the card and press **Flash to iPhone**.
8. Force-close **Wallet** on the iPhone and reopen it.

---

## Full Guide

The sidebar has two sections: **LIBRARY** → *Wallet Cards* and **SYSTEM** → *Activity Console* plus an **Originals Folder** shortcut that reveals `~/Documents/WaveCard/Originals` in Finder.

### 1. Connect your iPhone

Plug in USB and unlock the phone. The sidebar status turns green and shows `<model> · iOS <version>`. Use the refresh icon to re-poll.

### 2. Scan for cards

Press **Scan Cards** (or **Start Scanning Cards** in the empty state). WaveCard opens the device's unified log stream and waits for the pass lookup that Wallet performs.

On the iPhone you must actually **use** the card so the lookup happens:

> **Double-click iPhone Side button → Pass Face ID → Tap your card**

Each detected hash is validated (length, character set, blocklist of framework names) before being added, and the console prints `✓ Detected card: <hash>`.

No luck? **Add Card** lets you paste a hash manually — handy if you already have one from a previous session or a log.

### 3. Fetch the factory artwork

New cards show `Reading artwork from iPhone...`. WaveCard reads, in order, `cardBackgroundCombined@2x.png`, `@3x.png`, `.png`, `.pdf`, then falls back to Apple's asset-broker `.urls` sidecar for cards that keep no local PNG. Wallet's own composited `FrontFace` bitmap is explicitly rejected, so what you see really is the bank's art.

If a card shows **Fetch from iPhone**, press it to (re)read the artwork.

### 4. Assign a custom skin

- **Drag & drop** an image onto a card tile, or
- press **Set Skin** / **Choose Skin Image...**, or
- select multiple cards and press **Set Skin for All...**

PNG, JPEG, HEIC and WebP are supported. The image is aspect-filled and rendered to the exact sizes Wallet expects.

### 5. Make sure the original is stored

The backup *is* the factory artwork, pulled automatically the first time a card is read. It lands as one PNG at `~/Documents/WaveCard/Originals/<hash>.png` — outside the purgeable cache, so macOS cannot quietly delete it. Cards with a stored original show a green shield.

Press **Fetch All Originals** (toolbar) to pull the artwork for every card that has none yet. It runs in the background through the same serial queue as everything else, so it is safe to leave unattended. Export and restore only work on cards whose original is stored, so do this before flashing.

### 6. Flash to iPhone

Select one or more cards (**Select All** / **Deselect All** help) and press **Flash to iPhone**. Each card is rendered and written in a single batched AirTraffic sync, then Wallet's `FrontFace` / `PlaceHolder` / `Preview` render caches are invalidated. Progress is reported live in the banner and the console.

### 7. See it in Wallet

Force-close **Wallet** from the App Switcher (or lock and unlock the iPhone). If a card still looks stale, reboot the phone — the app warns you when cache invalidation was incomplete.

### Export originals as PNG

- **Single card:** the export icon on a card tile, or **Export Original as PNG** in the inspector, opens a save panel pre-filled with `<Card Name>-<hash8>.png`.
- **Everything selected:** **Export PNGs...** (toolbar) picks a folder and writes one PNG per selected card.

Exported files are the stored bytes written verbatim — no rescaling — so they stay usable as source material. If a card has no original stored yet, WaveCard reads it off the iPhone first rather than writing nothing. Existing filenames are never overwritten; collisions get a `-2` suffix.

### Restore factory artwork

- **Single card:** the restore icon on a card tile, or **Restore Original to iPhone** in the inspector.
- **Everything:** **Restore All** (toolbar), which asks for confirmation first.

Restore regenerates `@3x` / `@2x` / `.pdf` at Apple's exact card dimensions from the stored PNG, writes them in one batched sync, and invalidates Wallet's render caches. Only ever artwork files — `pass.json` is never rewritten, because doing so breaks the pass signature on iOS.

### Activity Console

A live, searchable log of every device operation with `INFO` / `SUCCESS` / `WARN` / `ERROR` levels, plus **Copy All** and **Clear**. This is the first place to look when something doesn't work.

---

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│ WaveCard.app (Swift + SwiftUI, universal)               │
│  ├── device_helper      (ObjC) MobileDevice.framework   │
│  │     • discover / pair / validate pairing             │
│  │     • os_trace_relay unified log stream ── scanner   │
│  │     • AFC streaming_zip_conduit ── Books staging     │
│  └── airtraffic_host    (ObjC) AirTrafficHost.framework  │
│        • "airlift" sync host: SyncAllowed → ReadyForSync │
│        → MetadataSyncFinished → per-asset completion     │
└─────────────────────────────────────────────────────────┘
```

**Detection.** `com.apple.syslog_relay` omits Wallet card paths on iOS 18, so WaveCard requests the *unified activity stream* from `com.apple.os_trace_relay` instead, decodes the binary frames in-process (5-byte header, big-endian lengths for plist replies, little-endian for activity records) and pre-filters for `Passes/Cards`, `.pkpass`, `.pkcache`, `passIDs` and friends. See [docs/wallet-card-detection.md](docs/wallet-card-detection.md).

**Extraction.** `/var/mobile/Library/Passes/Cards/<hash>.pkpass` is exported through the AirTraffic link, read over AFC, and the original bytes are written straight back so the pass never loses its Media copy.

**Writing.** WaveCard builds an uncompressed PKZip itself — `META-INF/com.apple.ZipMetadata.plist`, per-path directory entries, a `p0/p1/p2/link` symlink and `payload_N` entries — carrying Apple's `SZ_EXTRA_ID` (`0x5A53`) extra field and matching central-directory attributes, plus a binary `Books.plist` describing the book/asset relocation. That is staged over AFC into `Books/Sync/Books.plist`, synced by `airtraffic_host`, and cleaned up byte-for-byte against a preimage snapshot. Three leaves are written per card:

| Asset | Size |
|---|---|
| `cardBackgroundCombined@3x.png` | 1536 × 969 |
| `cardBackgroundCombined@2x.png` | 1024 × 646 |
| `cardBackgroundCombined.pdf` | vector, 3x box |

**Cache invalidation.** Wallet's `FrontFace`, `PlaceHolder` and `Preview` leaves are removed from `<hash>.cache` and `<hash>.pkcache` after every write and every restore.

---

## Where your data lives

| Path | Contents |
|---|---|
| `~/Documents/WaveCard/Originals/<hash>.png` | Stored factory artwork — this is the backup |
| `~/Library/Caches/com.WaveWSBS.wavecard/cards/<hash>/` | `custom.png` — throwaway render cache for assigned skins |
| `~/Library/Application Support/WaveCard/saved_cards.json` | Card library (label, hash, skin path) |
| `/var/mobile/Library/Passes/Cards/<hash>.pkpass` *(on iPhone)* | The pass itself |

Nothing is uploaded anywhere; WaveCard talks only to the connected iPhone.

---

## Important notes & risks

> [!WARNING]
> **This tool modifies system pass files on your iPhone. Back up your cards before you start.**
> - Flashing is a best-effort modification of Apple Wallet internals. It is **not** endorsed by Apple and may void issuer agreements.
> - **An iOS update can overwrite or invalidate a skinned card**, and a pass can occasionally stop rendering entirely. If a card breaks, restore it from its stored original or remove and re-add it from Wallet.
> - **Copy `~/Documents/WaveCard/Originals/` somewhere safe.** That folder is the only copy of your factory artwork; if it is lost, restoring a card means reading the artwork off the phone again, which is not possible once the pass no longer has it.
> - Cards are still functional payment instruments; only the artwork changes. Do not use WaveCard on cards you depend on for same-day travel until you have verified the result.
> - Keep your pass `pass.json` intact — WaveCard never rewrites it, and restore refuses to do so.
> - **Verified** on iPhone 15 Pro (iPhone16,1) / iOS 18.6.2 with macOS 26.6.2. Reported working across iOS 18–26; iPhone 17 / iOS 27 is not verified yet ([issue #28](https://github.com/WaveWSBS/WaveCard/issues/28)).
> - Use it on your own device and your own cards. Respect Apple's terms and your card issuer's rules.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Sidebar shows **No Device** | Reconnect the cable, unlock the iPhone, tap **Trust This Computer**. Wi-Fi is intentionally not supported — use USB. |
| `WaveCard scanner: Unlock the iPhone and trust this Mac, then retry.` | Unlock the phone, accept the trust prompt, retry **Scan Cards**. |
| Scan runs but nothing is found | You must open the card in Wallet: double-click Side button → Face ID → **tap the card**. Then paste the hash with **Add Card** if you have it. |
| `Artwork not found on device for [card]` | That pass keeps a vector-only or asset-broker artwork package; the canvas stays empty until you assign a skin. |
| Flashed, but Wallet looks unchanged | Force-close Wallet (App Switcher swipe-up) or reboot. The console warns `Cache invalidation warning… reboot may be needed` when it couldn't clear caches. |
| `Could not extract card files from device` / `expected assets absent from manifest` | Unlock the phone, keep it connected, and retry — an interrupted AirTraffic sync leaves a stale staging tree. |
| Buttons greyed out during scanning | Scanning blocks backup/restore on purpose. Press **Stop Scanning** first. |
| `Scanner failed to launch.` | Reinstall/relaunch the app; the bundled helper binary is missing from the bundle. |
| Gatekeeper blocks launch | Right-click ➔ **Open**, or `sudo xattr -cr /Applications/WaveCard.app`. |

Still stuck? Open an issue with your **iPhone model, iOS version, macOS version, WaveCard commit**, and the **Activity Console error line** — but *never* paste raw device logs or full card hashes.

---

## Building from source

```sh
git clone https://github.com/WaveWSBS/WaveCard.git
cd WaveCard
./build.sh
```

`build.sh` runs six stages and prints the result path:

1. `make clean && make all` — universal `device_helper` + `airtraffic_host` (ad-hoc signed)
2. scaffolds `build/WaveCard.app` (`Info.plist`, bundle id `com.WaveWSBS.wavecard`, version `2.0.0` / build `8`, min macOS `14.0`)
3. bundles the helpers and `AppIcon.icns` into `Contents/Resources`
4. compiles `Sources/Swift/*.swift` for `arm64` **and** `x86_64` and `lipo`s them into one universal binary
5. fixes permissions, strips `xattr`s and ad-hoc signs the bundle
6. builds `build/WaveCard.dmg` — styled via [`create-dmg`](https://github.com/create-dmg/create-dmg) when installed, otherwise a plain `hdiutil` image

Output: **`build/WaveCard.dmg`** (and `build/WaveCard.app`).

<details>
<summary>Requirements &amp; notes</summary>

- macOS 14+ with **Xcode 15+** or Command Line Tools (`xcode-select --install`).
- Nothing else: no Homebrew, no Python packages. `create-dmg` is optional.
- Set `SWIFT_SDK=/path/to/MacOSX.sdk` to override SDK selection.
- The helpers link Apple's private frameworks directly: `MobileDevice.framework/MobileDevice` and `AirTrafficHost.framework/AirTrafficHost`. This is why they are tiny Objective-C binaries and why the app ships without third-party tooling.

</details>

### Tests

```sh
xcrun clang -fobjc-arc -framework Foundation tests/test_os_trace.m -o /tmp/test_os_trace && /tmp/test_os_trace
swiftc -O -parse-as-library tests/test_card_hash_scanner.swift Sources/Swift/CardHashScanner.swift -o /tmp/test_card_hash_scanner && /tmp/test_card_hash_scanner
```

Covers fragmented/coalesced frames, both length byte orders, disconnects, malformed lengths, truncated records, multiline pass paths and hash validation. Fixtures use synthetic identifiers only.

### Project layout

```
WaveCard/
├── build.sh                     # one-shot universal build + DMG
├── Makefile                     # device_helper / airtraffic_host (universal, ad-hoc signed)
├── WaveCardApp.swift            # app entry point
├── Sources/
│   ├── device_helper.m          # MobileDevice: discovery, pairing, os_trace_relay, AFC staging
│   ├── airtraffic_host.m        # AirTrafficHost: "airlift" sync host
│   ├── os_trace.h               # unified-log frame decoder
│   ├── airlift_target.h         # staging name prefixes + target gate
│   └── Swift/
│       ├── AirliftBridge.swift  # device I/O, batch writes, cache invalidation
│       ├── AirliftZip.swift     # PKZip + Apple 0x5A53 extras + Books.plist
│       ├── CardAssetManager.swift   # artwork extraction, originals store, aspect-fill, PDF rendering
│       ├── CardRestoreManager.swift # rebuilds the asset suite from a stored original
│       ├── CardExporter.swift       # PNG export naming & writing
│       ├── CardHashScanner.swift    # pass-hash extraction & validation
│       ├── AppViewModel.swift       # app state, fetch / export / flash / restore pipelines
│       ├── MainContentView.swift    # NavigationSplitView shell, sheets, alerts
│       ├── AppSidebarView.swift     # device status + navigation
│       ├── CardsWorkspaceView.swift # card grid + toolbar
│       ├── CardItemView.swift       # Apple Wallet canvas, drag & drop
│       ├── CardInspectorView.swift  # per-card actions
│       └── LogsView.swift           # Activity Console
├── tests/                       # os_trace decoder + hash scanner + exporter tests
├── docs/wallet-card-detection.md
└── dmg_assets/                  # DMG background, icon, shipped README
```

---

## Documentation

- [How card detection works](docs/wallet-card-detection.md) — the unified-log bug, the fix, and the verified test environment.

---

## Credits

Developed by [@WaveWSBS](https://github.com/WaveWSBS) & [@Lumid-Off](https://github.com/Lumid-Off).

---

## License

MIT © 2026 Johnny Franks — see [LICENSE](LICENSE).

*WaveCard is an independent project and is not affiliated with or endorsed by Apple Inc. "Apple", "Wallet" and "Apple Pay" are trademarks of Apple Inc.*
