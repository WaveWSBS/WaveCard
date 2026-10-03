# WaveCard 2.0 💳

> **The Apple Wallet card skinner for macOS — pure Swift, zero Python, zero jailbreak.**
> Re-skin the cards already in your Apple Wallet with your own artwork, over USB, in one click.

[![Release](https://img.shields.io/github/v/release/WaveWSBS/WaveCard?label=Release&color=6C5CE7)](https://github.com/WaveWSBS/WaveCard/releases)
[![macOS](https://img.shields.io/badge/macOS-14.0%2B-000000?logo=apple)](https://github.com/WaveWSBS/WaveCard/releases)
[![iOS](https://img.shields.io/badge/iPhone-iOS%2018%2B-000000?logo=apple)](https://github.com/WaveWSBS/WaveCard/releases)
[![Dependencies](https://img.shields.io/badge/dependencies-none-6C5CE7)](https://github.com/WaveWSBS/WaveCard)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

WaveCard talks straight to iPhone over USB using Apple's own `MobileDevice` and `AirTrafficHost` frameworks. It **sniffs** card passes out of the unified device log, **reads** the real factory artwork out of each `.pkpass` on the device, and **writes** your replacement artwork back — then clears Wallet's render cache so the new design actually shows up.

- 🖥️ **macOS app, no runtime dependencies** — no Python, no Homebrew, no `libimobiledevice`, no Xcode required to *use* it.
- 🔍 **Real-time card detection** — click **Scan Cards**, then double-click the Side button and pay. Cards appear by themselves.
- 🖼️ **True factory artwork extraction** — pulls the real `cardBackgroundCombined` art off the phone (PNG, vector PDF, or Apple's asset-broker sidecar), not a screenshot, and keeps a copy on your Mac.
- 💾 **Originals on disk + one-click restore** — every factory card face is saved as a PNG in `~/Documents/WaveCard/Originals/` and can be rebuilt onto the phone at any time, individually or all at once.
- 📤 **Export anywhere** — pull the original artwork out as PNG files for archival, design reference, or anything else.
- ⚡ **100% Pure Swift core (Zero Python)** — scaling, aspect-fill, vector PDF generation, PKZip packaging with Apple `0x5A53` extra attributes, and binary `Books.plist` generation all run natively via `CoreGraphics` / `CGContext` / `CGPDFContext`. Two tiny Objective-C command-line helpers bridge the private frameworks.
- 📦 **~2.4 MB** universal DMG (Apple Silicon + Intel).

> **Formerly known as AirCard.** WaveCard 1.x shipped as *AirCard*; the project was renamed in v2.0. Old bookmarks and links to `AirCard` refer to this same tool — nothing to reinstall, just a new name.

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
  - [5. Flash to iPhone](#5-flash-to-iphone)
  - [6. See it in Wallet](#6-see-it-in-wallet)
  - [Export originals as PNG](#export-originals-as-png)
  - [Restore factory artwork](#restore-factory-artwork)
  - [Activity Console](#activity-console)
- [How It Works](#how-it-works)
- [Built With](#built-with)
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
4. The card shows up in **Wallet Cards** automatically.
5. Press **Fetch All Originals** so the factory art is saved to your Mac.
6. Drop an image on the card, or press **Set Skin**.
7. Select the card and press **Flash to iPhone**.
8. Force-close **Wallet** on the iPhone and reopen it.

---

## Full Guide

The sidebar has two sections: **LIBRARY** → *Wallet Cards*, and **SYSTEM** → *Activity Console* and *Originals Folder*.

### 1. Connect your iPhone

Plug in USB and unlock the phone. The sidebar status turns green and shows `<model> · iOS <version>`. Use the refresh icon to re-poll.

### 2. Scan for cards

Press **Scan Cards** (or **Start Scanning Cards** in the empty state). WaveCard opens the device's unified log stream and waits for the pass lookup that Wallet performs.

On the iPhone you must actually **use** the card so the lookup happens:

> **Double-click iPhone Side button → Pass Face ID → Tap your card**

Each detected hash is validated (length, character set, blocklist of framework names) before being added, and the console prints `✓ Detected card: <hash>`.

No luck? **Add Card** lets you paste a hash manually — handy if you already have one from a previous session or a log.

### 3. Fetch the factory artwork

New cards show `Reading artwork from iPhone...`. **Fetch All Originals** in the toolbar (or **Fetch from iPhone** on a single card) reads, in order, `cardBackgroundCombined@2x.png`, `@3x.png`, `.png`, then falls back to `cardBackgroundCombined.pdf` and finally Apple's asset-broker `.urls` sidecar for cards that keep no local PNG. The result is normalized to a PNG and saved to `~/Documents/WaveCard/Originals/<hash>.png`.

Wallet's own composited `FrontFace` bitmap is explicitly rejected, so what you store really is the bank's art. Once stored, the original is never re-read from the phone.

### 4. Assign a custom skin

- **Drag & drop** an image onto a card tile, or
- press **Set Skin** / **Choose Skin Image...**, or
- select multiple cards and press **Set Skin for All...**

PNG, JPEG, HEIC and WebP are supported. The image is aspect-filled and rendered to the exact sizes Wallet expects.

### 5. Flash to iPhone

Select one or more cards (**Select All** / **Deselect All** help) and press **Flash to iPhone**. Each card is rendered and written in a single batched AirTraffic sync, then Wallet's `FrontFace` / `PlaceHolder` / `Preview` render caches are invalidated. Progress is reported live in the banner and the console.

### 6. See it in Wallet

Force-close **Wallet** from the App Switcher (or lock and unlock the iPhone). If a card still looks stale, reboot the phone — the app warns you when cache invalidation was incomplete.

### Export originals as PNG

- **One card:** hover the tile (or open the inspector) ➔ **Export Original as PNG**
- **Several cards:** select them ➔ **Export PNGs...** and choose a folder

Files are named `<Card Label>-<hash8>.png` and written byte-for-byte as stored — handy for keeping an archive or using the real bank art as a design reference.

### Restore factory artwork

- **One card:** hover the tile ➔ the restore icon, or inspector ➔ **Restore Original to iPhone**
- **Every card that has an original:** toolbar ➔ **Restore All**, then confirm with **Restore All**

WaveCard rebuilds the full artwork suite (`@3x`, `@2x`, `.pdf`) from the stored PNG, writes it back in one batched sync, and clears Wallet's render caches. `pass.json` is never rewritten — doing so invalidates the pass signature on iOS and the card stops opening in Wallet.

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
│  │     • AFC + streaming_zip_conduit ── Books staging   │
│  └── airtraffic_host    (ObjC) AirTrafficHost.framework  │
│        • "airlift" sync host: SyncAllowed → ReadyForSync │
│        → MetadataSyncFinished → per-asset completion     │
└─────────────────────────────────────────────────────────┘
```

**Detection.** `com.apple.syslog_relay` omits Wallet card paths on iOS 18, so WaveCard requests the *unified activity stream* from `com.apple.os_trace_relay` instead, decodes the binary frames in-process (5-byte header, big-endian lengths for plist replies, little-endian for activity records) and pre-filters for `Passes/Cards`, `.pkpass`, `.pkcache`, `passIDs` and friends. See [docs/wallet-card-detection.md](docs/wallet-card-detection.md).

**Extraction.** `/var/mobile/Library/Passes/Cards/<hash>.pkpass` is exported through the AirTraffic link, read over AFC, and the original bytes are written straight back so the pass never loses its Media copy. Vector PDFs are rasterized with `CGPDFDocument`; asset-broker downloads are verified against the sidecar's SHA-1 with `CryptoKit` before being accepted.

**Writing.** WaveCard builds an uncompressed PKZip itself — `META-INF/com.apple.ZipMetadata.plist`, per-path directory entries, a `p0/p1/p2/link` symlink and `payload_N` entries — carrying Apple's `SZ_EXTRA_ID` (`0x5A53`) extra field with the POSIX mode bits, a `zlib` CRC-32 per entry, and a binary `Books.plist` describing the book/asset relocation. That is staged over AFC into `Books/Sync/Books.plist`, synced by `airtraffic_host`, and cleaned up byte-for-byte against a preimage snapshot. Three leaves are written per card:

| Asset | Size |
|---|---|
| `cardBackgroundCombined@3x.png` | 1536 × 969 |
| `cardBackgroundCombined@2x.png` | 1024 × 646 |
| `cardBackgroundCombined.pdf` | vector, 3x box |

**Cache invalidation.** Wallet's `FrontFace`, `PlaceHolder` and `Preview` leaves are removed from `<hash>.cache` and `<hash>.pkcache` after every flash and every restore.

---

## Built With

No third-party dependencies — every layer is an Apple platform API.

| Layer | Technology |
|---|---|
| UI | **SwiftUI** (`NavigationSplitView`, toolbar, inspector, drag & drop) + **AppKit** (`NSOpenPanel` / `NSSavePanel` / `NSWorkspace`) |
| State | `ObservableObject` + **Combine**, serialized device queues |
| Imaging | **CoreGraphics** (`CGContext` aspect-fill scaling, PNG encode) and `CGPDFContext` / `CGPDFDocument` for vector output |
| Integrity | **CryptoKit** (`Insecure.SHA1`) to verify asset-broker artwork, **zlib** `crc32` for PKZip entries |
| File types | `UniformTypeIdentifiers` for image import filtering |
| Device link | **MobileDevice.framework** (private) — pairing, AFC, `os_trace_relay`, `streaming_zip_conduit` |
| Sync engine | **AirTrafficHost.framework** (private) — the `airlift` book sync protocol |
| Packaging | `swiftc` + `lipo` universal binary, ad-hoc `codesign`, `hdiutil` / `create-dmg`, `Makefile` + `build.sh` |
| CI | **GitHub Actions** on `macos-15` — tests, universal build, tagged-release publishing |

---

## Where your data lives

| Path | Contents |
|---|---|
| `~/Documents/WaveCard/Originals/<hash>.png` | Factory artwork pulled off the iPhone — the source of truth for restores and exports |
| `~/Library/Application Support/WaveCard/saved_cards.json` | Card library (`id`, `label`, `customImagePath`) |
| `~/Library/Caches/com.WaveWSBS.wavecard/cards/<hash>/` | Rendered skin cache (`custom.png`) |
| `/var/mobile/Library/Passes/Cards/<hash>.pkpass` *(on iPhone)* | The pass itself |

Originals live in `Documents` on purpose — the system cache can be purged, your factory card art cannot. Nothing is uploaded anywhere; WaveCard talks only to the connected iPhone.

---

## Important notes & risks

> [!WARNING]
> **This tool modifies system pass files on your iPhone. Fetch the originals before you start.**
> - Flashing is a best-effort modification of Apple Wallet internals. It is **not** endorsed by Apple and may conflict with your card issuer's terms.
> - **An iOS update can overwrite or invalidate a skinned card**, and a pass can occasionally stop rendering entirely. Keep your originals, and if a card breaks, **Restore All** or remove and re-add it from Wallet.
> - Cards remain functional payment instruments; only the artwork changes. Do not rely on a freshly skinned card for same-day travel until you have verified it.
> - WaveCard never rewrites `pass.json`, because replacing it invalidates the pass signature on iOS.
> - **Verified** on iPhone 15 Pro (iPhone16,1) / iOS 18.6.2 with macOS 26.6.2. Reported working across iOS 18–26; iPhone 17 / iOS 27 is not verified yet ([issue #28](https://github.com/WaveWSBS/WaveCard/issues/28)).
> - Use it on your own device and your own cards, and respect Apple's terms and your issuer's rules.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Sidebar shows **No Device** | Reconnect the cable, unlock the iPhone, tap **Trust This Computer**. Wi-Fi is intentionally not supported — use USB. |
| `WaveCard scanner: Unlock the iPhone and trust this Mac, then retry.` | Unlock the phone, accept the trust prompt, retry **Scan Cards**. |
| Scan runs but nothing is found | You must open the card in Wallet: double-click Side button → Face ID → **tap the card**. Then paste the hash with **Add Card** if you have it. |
| `Artwork not found on device for [card]` | That pass keeps a vector-only or asset-broker artwork package; fetch it again, or just assign a skin — the canvas stays empty until you do. |
| `Nothing to Fetch` | Every card already has its original stored on this Mac. |
| `No original stored for this card yet. Fetch it first.` | Run **Fetch All Originals** (needs the iPhone connected) before restoring or exporting. |
| Flashed, but Wallet looks unchanged | Force-close Wallet (App Switcher swipe-up) or reboot. The console warns `Cache invalidation warning… reboot may be needed` when it couldn't clear caches. |
| Buttons greyed out during scanning | Scanning blocks fetch, flash and restore on purpose. Press **Stop Scanning** first. |
| `Could not extract card files from device` / `expected assets absent from manifest` | Unlock the phone, keep it connected, and retry — an interrupted AirTraffic sync leaves a stale staging tree. |
| `Scanner failed to launch.` | Relaunch the app; the bundled helper binary is missing from the bundle. |
| Gatekeeper blocks launch | Right-click ➔ **Open**, or `sudo xattr -cr /Applications/WaveCard.app`. |

Still stuck? Open an issue with your **iPhone model, iOS version, macOS version, WaveCard version**, and the **Activity Console error line** — but *never* paste raw device logs or full card hashes.

---

## Building from source

```sh
git clone https://github.com/WaveWSBS/WaveCard.git
cd WaveCard
./build.sh
```

`build.sh` runs six stages and prints the result path:

1. `make clean && make all` — universal `device_helper` + `airtraffic_host` (ad-hoc signed)
2. scaffolds `build/WaveCard.app` (`Info.plist`, bundle id `com.WaveWSBS.wavecard`, min macOS `14.0`)
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
swiftc -O -parse-as-library tests/test_card_exporter.swift Sources/Swift/CardExporter.swift -o /tmp/test_card_exporter && /tmp/test_card_exporter
```

Covers fragmented/coalesced log frames, both length byte orders, disconnects, malformed lengths, truncated records, multiline pass paths, hash validation, and export filename sanitising/deduplication. Fixtures use synthetic identifiers only.

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
│   ├── airlift_target.h         # staging name prefixes + device target gate
│   └── Swift/
│       ├── AirliftBridge.swift  # device I/O, batch writes, cache invalidation
│       ├── AirliftZip.swift     # PKZip + Apple 0x5A53 extras + Books.plist
│       ├── CardAssetManager.swift   # extraction, aspect-fill, PDF render, Originals/ store
│       ├── CardExporter.swift       # PNG export naming/writing
│       ├── CardRestoreManager.swift # rebuild factory artwork from a stored original
│       ├── CardHashScanner.swift    # pass-hash extraction & validation
│       ├── AppViewModel.swift       # app state, fetch / flash / restore pipelines
│       ├── MainContentView.swift    # NavigationSplitView shell, sheets, alerts
│       ├── AppSidebarView.swift     # device status + navigation
│       ├── CardsWorkspaceView.swift # card grid + toolbar
│       ├── CardItemView.swift       # Apple Wallet canvas, drag & drop
│       ├── CardInspectorView.swift  # per-card actions
│       └── LogsView.swift           # Activity Console
├── tests/                       # os_trace decoder, hash scanner, exporter
├── docs/wallet-card-detection.md
└── dmg_assets/                  # DMG background, icon, shipped README
```

---

## Documentation

- [How card detection works](docs/wallet-card-detection.md) — the unified-log bug, the fix, and the verified test environment.

---

## Credits

Developed by [@WaveWSBS](https://github.com/WaveWSBS) & [@Lumid-Off](https://github.com/Lumid-Off).

*WaveCard 1.x was released as AirCard.*

---

## License

MIT © 2026 Johnny Franks — see [LICENSE](LICENSE).

*WaveCard is an independent project and is not affiliated with or endorsed by Apple Inc. "Apple", "Wallet" and "Apple Pay" are trademarks of Apple Inc.*
