# AirCard 2.0 💳

> **Apple Wallet Card Skinner for iOS 18+ (No Jailbreak Required)**  
> **Tested on iOS 18 through iOS 26+ release.**  
> Powered by native Swift CoreGraphics and the `airlift` AirTraffic sync engine.

---

## What's New in v2.0 (Pure Swift & Native HIG Redesign)

- 🎨 **Modern macOS Architecture (`NavigationSplitView`):**
  - **Sidebar:** Connected iPhone status, library navigation, and active system console.
  - **Main Shelf:** Realistic Apple Wallet card canvas with metallic sheen, EMV chip, and contactless NFC cues.
  - **Inspector Panel:** Inline card naming, hash copying, original vs custom artwork comparison, and granular actions.
- 📱 **Native Card Artwork Extraction:** Directly reads the real factory card background (`cardBackgroundCombined@3x.png` / `@2x.png` / `.pdf`) from your iPhone and displays the actual card face on the canvas.
- 💾 **1-Click Backup & Restore:**
  - Safely backs up original card assets to `~/Documents/AirCard/Backups/` with metadata and thumbnails.
  - One-click **Restore to iPhone** flashes factory assets back to the device whenever you want to revert.
- ⚡ **100% Pure Swift (Zero Python):**
  - All image scaling, Aspect Fill, and vector PDF generation run natively via CoreGraphics (`CGContext`, `CGPDFContext`).
  - Binary PKZip packaging with Apple `0x5A53` extra attributes and binary `Books.plist` generation in pure Swift.
  - Ultra lightweight (~2 MB universal DMG for Apple Silicon & Intel).
- 🧹 **Focused Experience:** Passcode lockscreen themer completely removed to focus 100% on Apple Wallet card skinning perfection.

---

## Installation

### macOS (Universal DMG)
1. Download **`AirCard.dmg`** from [Releases](https://github.com/mak5er/AirCard/releases).
2. Open `AirCard.dmg` and drag **`AirCard.app`** into your **Applications** folder.
3. Fully compatible with both **Apple Silicon** and **Intel (x86)** Macs.

> [!NOTE]
> **First Launch on macOS (Gatekeeper):**
> If macOS displays an unidentified developer prompt on first launch:
> - **Method 1 (UI):** Right-click `AirCard.app` in Applications ➔ click **Open** ➔ click **Open**.
> - **Method 2 (Terminal):**
>   ```sh
>   sudo xattr -cr /Applications/AirCard.app
>   ```

---

## How to Customize Apple Wallet Cards

1. Connect your iPhone to your Mac via USB cable and unlock it.
2. In AirCard, click **Scan Cards** in the toolbar.
3. On your iPhone:
   - **Double-click the Side button** to open Apple Pay.
   - Authenticate with **Face ID** or **Touch ID**.
   - **Tap your card** to trigger instant real-time detection!
4. AirCard will detect the pass hash and automatically extract its real background artwork.
5. Drag and drop any custom image onto the card (or click **Set Skin**).
6. *(Optional)* Click **Backup** to store a factory copy of your card's artwork on your Mac.
7. Click **Flash to iPhone** (or select multiple cards to batch flash).
8. Force-close the **Wallet** app on your iPhone from the App Switcher (or lock and unlock) to enjoy your new custom card design!

---

## Restoring to Original Factory Card

If you ever want to revert back to your card's original appearance:
1. Navigate to **Card Backups** in the sidebar (or open the right Inspector for the card).
2. Click **Restore to iPhone**.
3. AirCard will write the factory files back to `/var/mobile/Library/Passes/Cards/<hash>.pkpass` and invalidate render caches.
4. Force-close Apple Wallet on your iPhone to verify.

---

## Building from Source

```bash
git clone https://github.com/mak5er/AirCard.git
cd AirCard
./build.sh
```

Outputs universal binaries for `arm64` and `x86_64` and builds `build/AirCard.dmg`.
