# FastText ⚡

**Tired of bloated, slow-loading text editors on macOS?** Same. You just wanted to look at a file. Instead you got a splash screen, a "restoring your session" spinner, and a plugin update.

FastText opens in about **90 ms**. That's from process start to the first window drawn on an M-series Mac. Blink and you've already missed it.

## How is it so fast?

By doing nothing it doesn't have to.

- One Objective-C file, AppKit only. No Swift runtime, no SwiftUI, no nibs, no `NSDocument`, no state restoration.
- No tabs, no plugins, no cloud, no telemetry, no "what's new".
- The Settings window, font list and line-number gutter don't exist until you ask for them.

It's a plain-text editor that edits plain text. Revolutionary, I know.

## What you do get

- Windows, Open Recent, drag and drop. Drop a file on the window or the Dock icon.
- "Open With" for text, JSON, JSONL, source code and whatever else you throw at it. It never steals your default app.
- Color presets (Dracula, Nord, Solarized, Monokai, Gruvbox, Amber and more), custom colors, your font, your size.
- Wrap lines, line numbers, current-line highlight, show whitespace, tab width.
- Multi-million-line files. Jumping to the end of 2M lines takes about 150 ms.

## Install

Grab the zip from [Releases](https://github.com/j0uni/fastText/releases), unzip, and drag `FastText.app` into `/Applications`.

It's ad-hoc signed, not notarized (I'm not paying Apple to tell you it's fine). So the first time, right-click ▸ Open, or:

```sh
xattr -dr com.apple.quarantine /Applications/FastText.app
```

Needs macOS 14+. The release build is Apple Silicon. For Intel, build it yourself with `make ARCH=x86_64`.

## Build it yourself

You need the Xcode command line tools. That's all.

```sh
make            # build/FastText.app
make bench      # prints ms from exec to first window
make deploy     # build and copy to /Applications
```

## Notes

Design decisions and timing breakdown are in [NOTES.md](NOTES.md). Most of the 90 ms is AppKit waking up, and the app's own code is the small part.

MIT licensed. Do whatever you like.
