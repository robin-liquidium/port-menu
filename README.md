# Port Menu

**localhost, organized.**

A tiny macOS menu bar app that tracks your dev servers across projects.

No config. No setup. It just works.

## Personal fork

This fork identifies Raycast and oMLX using their full process titles, instead of
labeling them as `node` or `homebrew`. Both services are hidden from the menu and
count. Filtering uses service identity, so ordinary Node servers and projects
with the same names remain visible. Known services do not inherit Homebrew's Git
branch.

The menu bar item is removed when the filtered list is empty. Scanning continues
in the background; the item returns when a development server is detected,
normally within 5 seconds.

The upstream updater is disabled so it cannot replace these changes.

Build and run the local patch with `./script/build_and_run.sh --verify`.
It uses local ad hoc signing by default. Set `CODE_SIGN_IDENTITY` and
`DEVELOPMENT_TEAM` to use your Developer ID certificate. The output is
`build/DerivedData/Build/Products/Release/Port Menu.app`, version `0.8.10-robin.2`.

---

## What it does

Port Menu sits in your menu bar and automatically detects local development servers running on your machine. One click to see what's running, which project it belongs to, and on which port.

- **Auto-detection** — scans for running dev servers every few seconds
- **Project context** — shows Git repo name, current branch, port, and uptime
- **Kill or open** — stop a server or open it in your browser directly from the menu
- **Copy URL** — right-click to copy the localhost URL

## Download

**[Download for macOS →](https://portmenu.dev)**

Requires macOS 14 (Sonoma) or later.

1. Download and open the DMG
2. Drag `Port Menu.app` into `Applications`
3. Open Port Menu from `Applications`
4. Click the icon in your menu bar to get started

## Build from source

```bash
git clone https://github.com/wieandteduard/port-menu.git
cd Porter
open Porter.xcodeproj
```

Requires Xcode 15+.

## Release

Signed and notarized macOS builds are published on the [GitHub Releases](https://github.com/wieandteduard/port-menu/releases) page.

Maintainers can follow the release process in `docs/releasing.md`.

## Testing

```bash
xcodebuild test -project "Porter.xcodeproj" -scheme "Porter" -destination "platform=macOS"
```

## License

MIT
