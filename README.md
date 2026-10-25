# FastText

A plain-text editor for macOS built to launch as fast as possible: about 90 ms from process start to first window drawn on Apple Silicon.

Pure AppKit in a single Objective-C file. There is no Swift runtime, SwiftUI, nib, `NSDocument` or state restoration, and no work happens at launch that the first window doesn't need.

## Features

- Multiple windows, New / Open / Open Recent / Save / Save As, drag and drop files onto a window or the app icon
- Registers as an "Open With" candidate for text, JSON, JSONL, source code and other files, without becoming the default handler
- Settings (⌘,): color presets (Dracula, Nord, Solarized, Monokai, Gruvbox, …) or custom colors, fixed-width font and size
- Wrap lines, line numbers, highlight current line, show whitespace, tab width (also in the View menu)
- UTF-8 files, with a Latin-1 fallback that saves back in the same encoding

## Build

Requires macOS 14+ and the Xcode command line tools.

```sh
make            # build/FastText.app
make bench      # exec -> first window drawn, in ms
make deploy     # build and install to /Applications (DEST=... to override)
make icon       # regenerate resources/AppIcon.icns
```

## Install from a release

Download `FastText-<version>-macos-arm64.zip` from the Releases page and move `FastText.app` to `/Applications`. The app is ad-hoc signed, not notarized, so on first launch right-click it and choose Open, or run `xattr -dr com.apple.quarantine /Applications/FastText.app`.

See [NOTES.md](NOTES.md) for design decisions and measurements.

## License

MIT, see [LICENSE](LICENSE).
