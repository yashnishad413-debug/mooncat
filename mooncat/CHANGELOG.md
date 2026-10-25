# MoonCat changelog

## Moon Veil
- New `MoonVeil.swift`: drag a rectangle anywhere on screen and cover it with a frosted or black veil. Menu: "Moon Veil…" and "Lift the veil".

## File converters
- New "Convert Files…" window (cat menu) and 244 conversions across pictures, PDF, documents, tables, sound and movies. Files: `ConvertFormats` (the matrix), `ConvertImage`, `ConvertDocs`, `ConvertData`, `ConvertOffice` (PPTX/XLSX writers and readers), `ConvertMedia`, `ConvertEngine`, `ConverterWindow`.
- Chat: two new Treasure Box tools, `conversion_options` and `convert_items`, so you can ask Moon to convert files in the box. Results are added to the box; originals stay.
- `Converter.selfCheck()` logs the pair count at launch.

## MoonCat password (replaces the Keychain)
- New `Vault.swift`: you create a password the first time you lock a file or save a chat key. A random master key encrypts locked files and chat keys; it is wrapped with a key made from your password (PBKDF2, 200k rounds) and stored in `vault.json`. Changing the password re-wraps the key, so no file is re-encrypted.
- Existing locked files keep working: the old Keychain key is read once and carried into the vault, then the old Keychain entries are deleted. Saved chat keys are not carried over; paste them again.
- "Change MoonCat Password…" in the cat's menu (needs the current password). No recovery by design.
- `KeychainStore` now stores keys in the vault; `KeychainCooldown` and the Keychain code in `Crypto.swift` are gone.
- Also in this build: list/icon/column views with sorting, AI storage tools with a confirm sheet, and Clean Up (duplicates and old files).

## Keychain prompt fix
- `build.sh` signs with a stable "MoonCat Dev" identity when one exists (create it once with `tools/setup_signing.sh`), so Keychain "Always Allow" survives rebuilds. Falls back to ad-hoc with a warning.
- A denied or cancelled Keychain prompt is remembered for two minutes (`KeychainCooldown`) instead of re-prompting for every item, and key loading is serialized so two prompts can't stack.
- Clearer error when Keychain access is denied.

## Phase A — Settings and Preferences
- Split the single `main.swift` into one file per concern (Helpers, Sprites, PetWindow, PetController, Stash, StashWindow, main). Code moved unchanged.
- New `Settings` model (UserDefaults). Every distance, delay and speed that used to be a literal in `PetController` now lives there, with the same default values. Existing saved size, follow toggle and position carry over.
- New Preferences window (⌘,): size, follow distance, stop distance, sleep delay, play frequency, which screen she lives on, follow toggle, sounds on/off, launch at login, reset to defaults. Changes apply live.
- Launch at login via `SMAppService.mainApp`, in Preferences and in the cat's menu.
- A real main menu (App, Edit, Window) so ⌘, ⌘W ⌘Q and copy/paste work in her windows even though there is no Dock icon.
- `build.sh` now compiles every `Sources/*.swift` and links ServiceManagement. Xcode project lists all files.

## Phase B — Global shortcut, Quick Search, tags and notes, auto-forget
- New `HotKey.swift`: global shortcut through Carbon `RegisterEventHotKey` (no Accessibility permission, no event tap). Default ⌥⌘Space. The key code and modifiers are stored in `Settings` and the shortcut is re-registered whenever they change. Binding a combination that is already taken keeps the previous shortcut and reports it.
- New `QuickSearchPanel.swift`: borderless floating panel, centred on the screen with the cursor, searching Treasure Box items by name, tags and note. ↑/↓ choose, Return opens, ⌘Return reveals in Finder, Esc or a click outside closes. Activates MoonCat on show; Esc restores the previous app.
- Preferences: new **Shortcut** row (click-to-record, needs ⌘/⌥/⌃, Esc cancels, Reset button, clear message when the combination is taken) and a **Treasure Box** section for auto-forget.
- `StashItem` gains `tags: [String]` and `note: String`. They are decoded with `decodeIfPresent`, so index.json files from Phase A still load. If an index ever cannot be read, a copy is kept as `index.unreadable-<time>.json` instead of being overwritten.
- Treasure Box window: edit tags (comma separated) and note for the selected item; search matches name, tags and note; thumbnail column (QLThumbnailGenerator, async, cached, file-icon fallback); Space toggles a Quick Look panel. Dragging out of the table still always copies. The window is taller (560 pt) to fit the editor.
- Auto-forget: `autoForgetEnabled` (default off) and `autoForgetDays` (default 90) in Settings. When on, at launch and then once a day, an alert says how many items are older than N days and deletes them only if you confirm.
- `Settings`: new keys `hotKeyCode`, `hotKeyModifiers`, `autoForgetEnabled`, `autoForgetDays` (plus a bookkeeping value for the daily check).
- `Helpers`: `activateApp()` and `reactivate(_:)`, which use the macOS 14 activation API when available.
- `build.sh` and the Xcode project link Carbon, QuickLookUI and QuickLookThumbnailing. `build.sh` now compiles with `-target <arch>-apple-macos13.0`, matching the Xcode project. `Info.plist` is unchanged.
- README updated (also corrected the Files and Tweaking sections, which still described the single-file layout).

## Phase C — Private items, drops, reminders, focus timer, reactions, mood, sounds, laser
- **Private Treasure Box items** (`Crypto.swift`, `Stash.swift`, `StashWindow.swift`): Lock/Unlock button encrypts a file with AES-GCM; the 256-bit key lives in the Keychain (service `com.yash.mooncat`, account `stash-key`). Private names show 🔒, thumbnails are a lock icon, Quick Look skips them, opening/dragging out/saving decrypts to a temp folder (0700) that is cleaned up. Folders cannot be locked. If the key is lost, locked items cannot be recovered.
- **Drops** (`StashDrop.swift`): dropping text, links or images on her (or "Paste from clipboard" in the Treasure Box menu) saves a .txt/.md, .webloc or .png.
- **Finder service** (`StashService.swift`, Info.plist `NSServices`): right-click a file in Finder, Services, "Send to Moon Cat".
- **Reminders** (`ReminderParser.swift`, `Reminders.swift`, `Notifier.swift`): "Remind me…" in her menu accepts "20m", "1h30m", "in 2 hours", "3pm", "15:30", "tomorrow 9am". Saved to disk, re-armed at launch, fires a notification and she reacts. "Reminders…" lists and deletes them.
- **Focus timer** (`Pomodoro.swift`): work/short break/long break (25/5/15 by default, 4 rounds). While working she naps and ignores the cursor. Countdown appears in the menu bar. Lengths in Preferences.
- **System reactions** (`SystemWatchers.swift`): she notices finished downloads in ~/Downloads (files already there at launch are ignored) and low battery.
- **Moods** (`Mood.swift`): time of day and battery nudge how soon she naps, how often she pounces and how fast she walks. Toggle in Preferences.
- **Sounds** (`Sounds.swift`): optional meow/purr/chime wav files (see `sounds/README.txt`); missing files are silently skipped. Volume slider in Preferences.
- **Laser game** (`LaserGame.swift`): 30-second game; a red dot follows the cursor, she pounces, score shows in the menu bar. Stop it from her menu.
- **Yawn pose**: if `sprites/yawn.png` exists she yawns before sleeping.
- `build.sh` and the Xcode project link Security, CryptoKit, UserNotifications, IOKit, AVFoundation.

## Phase D — Chat, cosmetics, perching, polish, release tooling
- **Chat** (`ChatSettings.swift`, `ChatProvider.swift`, `ChatWindow.swift`, `ChatPrefsView.swift`, `KeychainStore.swift`): "Chat with Moon…" window. Providers: Google Gemini (free key), any OpenAI-style server (Groq, OpenRouter with a `:free` model…), or Ollama on your own Mac (no key). Chat is OFF by default and makes no network calls until you turn it on and press Send. API keys are kept in the Keychain (one entry per provider), sent in a header, never logged. The conversation is kept in memory only. "Chat settings…" (inside the chat window) has a Test button and an editable personality.
- **Cosmetics** (`Cosmetics.swift`): fur colour (recolours the sprite, cached) and five hats drawn in code. Hats unlock by use: party hat and bow free, beanie after 3 days, top hat after 50 pets, crown after 15 Treasure Box items and 7 days. Menu: "Dress up…". If a hat sits too high or low on a pose, the numbers are in `Cosmetics.heads`.
- **Perching** (`Perch.swift`): menu "Sit on my windows" (off by default). Reads only window positions, no titles or contents, so there is no permission prompt. She sits on a window top when idle or asleep, follows it when it moves and drops to the floor when it goes away.
- **Log** (`Log.swift`): `~/Library/Logs/MoonCat/mooncat.log`, rotated at 1 MB, with key/token redaction. "About & help ▸ Show log file".
- **About** and **Welcome** windows (first launch once; "About & help ▸ Welcome guide…").
- **Menu bar icon**: a template crescent-with-ears image instead of the emoji (the timer and laser score still show next to it).
- **App icon**: `tools/make_icon.sh` makes `Resources/AppIcon.icns`; `build.sh` copies it in when present.
- **Release tooling**: `release/release.sh` (sign, notarize, staple, zip, checksum, `--dry-run`), `release/MoonCat.entitlements`, `release/README_RELEASE.md`. `Updater.swift` is a Sparkle wrapper that compiles to nothing unless Sparkle is added.
- `Info.plist` / `build.sh`: `CFBundleIconFile`, and `NSAllowsLocalNetworking` so the app may talk to a local Ollama server.
- Chat: if Gemini says the saved model name doesn't exist, MoonCat now asks Google for the current list, switches to a suitable "flash" model and retries once. Chat settings also has a "Find models" button for every provider.

- Moon Veil rebuilt: frosted by default, opt-in adaptive mode, per-veil styles and colours, all-edge resize, panic key, above full-screen apps.
- UI refresh: shared Theme (Helpers.swift): graphite canvas, teal accent, rounded type, cards; applied to Converter, Welcome, About, Dress up, Chat, Preferences, Treasure Box.
