<p align="center">
  <img src="art/art_welcome_hero.png" alt="MoonCat welcome artwork" height="220">
</p>

<h1 align="center">MoonCat</h1>

<p align="center">A native macOS desktop cat with file management, conversion tools, AI chat, and desktop utilities.</p>

MoonCat is a native macOS menu bar app written in Swift and AppKit. A small animated cat walks on top of your windows across Spaces. Clicks pass through everywhere except on the cat, so she stays out of the way. The app also includes a file manager, file conversion tools, optional AI chat, and desktop utilities.

## Features

- **Animated desktop cat:** Follow or look at the cursor, pounce, nap, react to petting, perch on windows, and customize size, distance, moods, hats, and fur colours.
- **Treasure Box file manager:** Save copies of files and folders, then tag, annotate, search, preview, organize, duplicate, and clean them up.
- **Private items:** Encrypt selected files using the app's password-based vault. Saved chat API keys can also be stored in the vault.
- **Quick Search:** Open a global search panel with a configurable keyboard shortcut.
- **File conversion:** Convert supported image, PDF, document, spreadsheet, audio, and video formats using macOS frameworks. Includes OCR for supported image-to-text workflows.
- **Optional AI chat:** Connect supported Gemini, OpenAI-compatible, NVIDIA NIM, or local Ollama providers. Chat tools can help search, tag, move, and convert Treasure Box items; deletion requires confirmation.
- **Moon Veil:** Cover part of the screen with frosted glass, paper, a solid colour, or an app-adaptive effect.
- **Desktop utilities:** Reminders, a focus timer, a laser-pointer game, sounds, a Finder “Send to Moon Cat” service, and launch-at-login support.

## Tech stack

- **Language:** Swift 5
- **App/UI:** AppKit and native macOS APIs
- **Apple frameworks:** QuartzCore, ServiceManagement, Carbon, QuickLook, Security, CryptoKit, UserNotifications, IOKit, AVFoundation, PDFKit, Vision, ImageIO, and ScreenCaptureKit
- **Project/build:** Xcode project (`MoonCat.xcodeproj`) or the included `build.sh` script using the Swift compiler
- **External dependencies:** No third-party package dependency is required for the core app

## Requirements

- macOS 13 or newer. The “adapt to app” Moon Veil style requires macOS 14 or newer.
- Git, if cloning the repository.
- Xcode or the Xcode Command Line Tools, which provide `swiftc`, `codesign`, and other build utilities.

To install the Command Line Tools if needed, open Terminal and run:

```bash
xcode-select --install
```

## Install and run

### Option A: Build from Terminal

1. Clone the repository and enter the project folder:

   ```bash
   git clone https://github.com/yashnishad413-debug/mooncat.git
   cd mooncat
   ```

2. Build and launch MoonCat:

   ```bash
   ./build.sh
   ```

   The script compiles the Swift sources, copies the artwork and sprites into `MoonCat.app`, signs the app with the local “MoonCat Dev” identity when available (otherwise it attempts an ad-hoc signature), and opens it.

3. Find the crescent-moon icon in the macOS menu bar. MoonCat is designed as a menu bar app and does not show a regular Dock icon.

If the script is not executable after downloading or copying the project, run `chmod +x build.sh` and retry step 2.

### Option B: Run from Xcode

1. Open `MoonCat.xcodeproj` in Xcode.
2. Select the **MoonCat** scheme and **My Mac** as the run destination.
3. If required, choose your own development team under **Signing & Capabilities**.
4. Press **Run** (⌘R).

### Optional setup

- Run `tools/make_icon.sh` to generate an app icon. The generated icon is intentionally ignored by Git; regenerate it locally when needed.
- Run `tools/setup_signing.sh` to create a local “MoonCat Dev” signing identity. Review the script before running it; signing identities and private keys should remain on your Mac and must not be committed.
- Place optional `meow.wav`, `purr.wav`, and `chime.wav` files in `sounds/` for extra sound effects. See `sounds/README.txt`.

## First-time AI chat setup

AI chat is off by default and does not make network calls until it is enabled and a message is sent.

1. Open **Chat with Moon… → Chat settings…**.
2. Choose a provider and enter your own API key, or choose Ollama for a local model.
3. Enable chat and use **Test connection**.
4. If a model name is rejected, use the **Find models** button to check the provider's currently available models.

API keys belong to the person running the app. Do not commit them to source control. Ollama can be used for local inference; cloud providers receive the data described below.

## Permissions and privacy

- The app stores its data locally under `~/Library/Application Support/MoonCat/`. Logs are stored under `~/Library/Logs/MoonCat/`; the app is designed to redact API keys and tokens from its logs.
- When AI chat tools are enabled, the selected provider may receive messages and Treasure Box metadata (such as item names, tags, notes, sizes, and folder paths) used by the model. File contents are not sent by the described file tools. Use a local Ollama setup if you want to avoid sending chat data to a cloud AI provider.
- The MoonCat vault password has no recovery flow. Keep backups of important encrypted files and the vault data, and remember the password.
- The vault uses PBKDF2 and AES-GCM via CryptoKit, but it has not had an independent security review. Do not rely on it as the sole protection for highly sensitive information.
- The app is not sandboxed. See `release/README_RELEASE.md` for release and signing notes.

## Known limitations

- PDF-to-text conversion requires PDFs with selectable text. For scanned documents, use an image-based workflow where supported.
- PowerPoint-to-image export processes only the first slide. Dates read from XLSX may be represented as Excel serial numbers.
- HEIC, JPEG 2000, and WebP support depends on the macOS version and available system capabilities.
- The project currently has no automated test suite. `Converter.selfCheck()` checks the conversion table at launch.

## Project structure

```text
mooncat/
├── MoonCat.xcodeproj/  Xcode project and workspace metadata
├── Sources/            Swift app code, organized by feature
├── art/                Window illustrations and UI artwork
├── sprites/            Cat animation sprites
├── Resources/          Resource placeholder; generated icon is created locally
├── sounds/             Instructions for optional sound effects
├── tools/              Icon-generation and local signing helpers
├── release/            Release script, entitlements, and release notes
├── Info.plist          App bundle and macOS service configuration
├── build.sh            Terminal build-and-launch script
├── .gitignore          Local build, IDE, secret, and large-artifact exclusions
├── CHANGELOG.md        Project change history
└── LICENSE             Project code license
```

Useful source groups include `PetController.swift` and `PetWindow.swift` for the cat, `Stash*.swift` for the Treasure Box, `Convert*.swift` for conversion, `Chat*.swift` for AI chat, `Vault.swift` and `Crypto.swift` for vault functionality, and `MoonVeil.swift` for screen veils.

## Screenshots

Screenshots will be added here. Place images in a `docs/screenshots/` folder and update this section when they are ready.

- Desktop pet: _Coming soon_
- Treasure Box: _Coming soon_
- File converter and AI chat: _Coming soon_

## Development notes

The project was developed with substantial assistance from AI coding tools. Feature verification has primarily been manual; automated tests have not yet been added.

Behaviour settings such as follow distance, nap delay, and the keyboard shortcut are in `Sources/Settings.swift`.

## Releasing

See [`release/README_RELEASE.md`](release/README_RELEASE.md) for release instructions.

## License

The source code is licensed under the MIT License; see [`LICENSE`](LICENSE). The artwork in `art/` and `sprites/` is not covered by the code license and is reserved by the author.

## Author

Yash Nishad
