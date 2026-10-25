# FastText – project notes

Goal: fastest-launching plain-text editor on macOS (only macOS, arm64 native build).

## Build / run
- `make` → `build/FastText.app` (clang, -O2 + LTO, stripped, ad-hoc signed). No Xcode project.
- `make bench` → exec→first-window-drawn time (ms) via `-DFT_BENCH`; first run is cold (~330 ms), warm ≈ 90 ms (measured 2026-10-25, macOS 15.7, Apple Silicon).

- `make deploy` / `scripts/deploy.sh` → build, quit running copy, install to /Applications (`DEST=` overrides), re-register with Launch Services.
- `make icon` regenerates `resources/AppIcon.icns` from `tools/makeicon.m` (black squircle, white "FT"); the .icns is committed.

## Decisions (and why)
- One Objective-C file, links only AppKit: no Swift runtime, no SwiftUI, no nib/storyboard, minimal dyld work.
- No NSDocument (autosave/versions/restoration machinery is startup + memory cost); own tiny FTDoc controller.
- Window shown from `applicationDidFinishLaunching`; files arriving via `openFiles:` are opened before it, so no stray Untitled window.
- TextKit 1 stack built by hand (non-contiguous layout for large files). Smart quotes/dashes/spellcheck/link detection off – plain raw text, and avoids spell-server startup.
- State restoration, automatic termination off; app quits when last window closes.
- Encoding: UTF-8, else Latin-1 fallback; saved back in the same encoding.
- Measured breakdown (warm): `[NSApplication sharedApplication]` ≈ 45 ms (framework init, unavoidable), finishLaunching ≈ 14 ms, NSWindow ≈ 15 ms, text view ≈ 3 ms. Near the AppKit floor.

- Open Recent: own list in NSUserDefaults (`recentFiles`, max 12), menu built lazily in `menuNeedsUpdate:`. Not NSDocumentController (would add launch cost, and its menu only fills once instantiated).
- Drag & drop: `FTTextView` opens dropped files in new windows (instead of pasting paths). Dock/Finder drops work via document types.
- "Open With": Info.plist declares many text/source UTIs, an extension list (jsonl, ndjson, ...), and a catch-all (`public.data`, ext `*`), all rank Alternate (never steals default handler). Files with NUL bytes in first 8 KB get an "open anyway?" prompt.

- Settings (⌘,): preset / background / text color / font family (fixed-pitch families only) / size, applied live to all windows. Stored in NSUserDefaults (`preset`, `bg`, `fg` hex, `fontName`, `fontSize`); absent = system colors + system monospaced 13 pt. Window built lazily on first open (zero launch cost); the font list is computed then too. Window appearance is set dark/light from background luminance so scrollbars/find bar match. View menu: ⌘+ / ⌘- / ⌘0 change size.
- Presets: System, Light, Paper, Solarized Light, Dark, Midnight, Solarized Dark, Nord, Dracula, Monokai, Gruvbox Dark, Terminal Green, Amber. Editing a color switches the preset to "Custom".

- Editor options (Settings + View menu, ⌥⌘W / ⌥⌘L / ⌥⌘H / ⌥⌘I): `wrap` (default on), `lineNumbers`, `highlightLine`, `showWhitespace` (all default off), `tabWidth` (1–16, default 4). All applied by `FTDoc applyStyle`.
  - Wrap: toggles container width tracking + horizontal scroller.
  - Line numbers: `FTRuler` (NSRulerView), created only when first enabled. Numbers are logical lines (wrapped rows unnumbered). Uses a cached (offset, line) anchor, so scrolling counts newlines only across the scrolled distance (2M-line file: jump to end ≈ 150 ms). Anchor reset on edits before it (`shouldChangeTextInRange`). Gutter width grows with digit count (applied async, never inside draw).
  - Highlight line: `FTTextView drawViewBackgroundInRect:` fills the logical line of an empty selection.
  - Whitespace: `FTLayoutManager drawGlyphsForGlyphRange:` overlays · → ¬ (NBSP °) for the visible range only.
  - Tab width: paragraph style `defaultTabInterval` = N × space width, reapplied on font change.
  - Test-harness gotcha: layout/gutter settle a runloop turn after restyle; snapshot after ~0.5 s, and clear the harness's own defaults domain between runs.

## Open questions / ideas
- No app icon (avoids icon loading; generic icon shown).
- Not universal (x86_64) – `make ARCH=x86_64` works for an Intel build.
- Keeping a resident helper would be faster still but isn't "launch" speed; not done.
