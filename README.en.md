# DockApex

**No matter how many apps you have, one Dock holds them all.**

![DockApex: an open folder panel above the bar](docs/images/hero.png)

[中文](README.md)

The interface is in Chinese; quoted labels below are translations.

DockApex is a bar that replaces the macOS Dock. Its look, sizing and feel are calibrated against the system Dock, and it adds iPhone-style folders: put apps of one kind into a single slot, so one spot holds several apps, one click away.

## Why

The macOS Dock can't group apps into folders. As you install more apps, the Dock either keeps growing and its icons keep shrinking, or you take apps out of it and dig through Launchpad whenever you need them. DockApex lets the Dock hold everything while keeping the look and habits you already have.

## A look at the bar

![The whole bar](docs/images/bar.png)

Pinned apps and folders sit on the left; each folder icon shows thumbnails of its apps. A dot under an icon means the app is running. Minimized windows and the Trash are on the far right. Icon size, spacing and the floating glass backdrop are calibrated against the system Dock.

## Features

### iPhone-style folders

- **Create**: drag an app onto the center of another app. The target grows a folder backdrop and shows “Release to create a group”; release and the folder is made. Dropping near an icon's edge reorders instead.
- **Open**: click a folder and a panel unfolds above it, with a small arrow pointing at the folder, three apps per row. Click an app to open or switch to it; an app that isn't running yet bounces in the panel, and the panel closes once it launches.
- **Close**: press Esc, click outside the panel, or click the folder again.
- **Organize**: drag to reorder inside the panel; drag an app out of the panel back onto the bar; right-click a folder to open, rename or ungroup it.
- **Manage folders**: the “Manage folders” window in settings lets you add or remove apps, reorder, rename and ungroup.
- **No duplicates**: when an app inside a folder is running, the folder shows a running dot instead of adding another icon to the bar.

### Works like the system Dock

- Magnification on hover (follows your system Dock's magnification setting), name labels, running indicators, launch animation, unread badges.
- Icons darken when pressed, just like the native Dock; when an app can't be found, its icon shows the native Dock's gray question mark.
- When an app draws its Dock icon with its own Dock tile plug-in (for example after you change its icon inside the app), the bar shows that icon too.
- **Right-click an app**: Open / Switch, its current windows, the app's own Dock menu items (such as Finder's New Finder Window) and Options, Show in Finder, Keep in bar or Remove, Hide, Quit, Force Quit.
- **Window previews**: rest the pointer on a running app and thumbnails of its windows pop up, minimized windows included with their real contents. Click a thumbnail to switch to that window (a minimized one is restored first), or × to close it. Works on the bar and inside folder panels.
- **Reorder and remove**: drag icons to reorder; drag one off the bar and release when it says “Release to remove from the bar” to remove it.
- **Files and folders**: drop files or folders on an empty part of the bar to add them on the right. Click a folder to list its contents, sorted by date modified or by name. Files dragged from a USB drive or network volume onto a folder are copied by default.
- **Open files with an app**: drop files onto an app icon (including apps inside a folder panel) to open them with that app.
- **Minimized windows** appear on the right; if you've chosen to minimize windows into their application icon in System Settings, they aren't shown separately, same as the system.
- **Trash** shows whether it's empty or full; right-click to open it or empty it (a confirmation dialog appears first).
- An uninstalled app leaves the bar after about 10 seconds; reinstall it within 30 minutes and it returns to its old spot.

### Windows stay clear of the bar

Once the system Dock is hidden, apps that are already running assume there's no Dock at the bottom and stretch their windows all the way down. DockApex shortens filled, tiled or overlapping windows so they end above the bar, and moves small floating bars (such as a voice-input bar) out of the way. Double-clicking a title bar to zoom still toggles between the original size and filled.

### Settings and displays

Right-click an empty part of the bar, or click the four-squares icon in the menu bar, to:

- Manage folders; undo layout changes (⌥⌘Z)
- Position: bottom, left, right
- Display: main display, all displays, follow the pointer, or a specific display
- Auto-hide: move to the screen edge to reveal it
- Show recent apps: turn it off and unpinned apps disappear from the bar when they quit
- Icon size: 28, 37, 48 or 64 points
- Open at login (登录时打开): start DockApex when you log in

## Privacy

- Folders, pinned order and preferences stay on your Mac, and the app doesn't go online (the About panel only has a link that opens the GitHub page).
- In everyday use, Screen Recording is used only for the following, and images stay in memory, never written to disk or uploaded:
  - Window previews: only while you hover, that app's windows are captured one by one as small thumbnails; each is dropped when its window closes or the app quits, and at most 64 are kept in memory.
  - Reading an app's own Dock menu items: on right-click, a live image covers the area where the menu would appear for about a second, so the system menu doesn't flash.
  - The optional shadow Dock: painting the backdrop under the bar.

## Getting started

### 1. Download and install

Requires Apple Silicon and macOS 14 or later.

Download the latest `DockApex-<version>.dmg` from [Releases](https://github.com/DaliangPro/DockApex/releases), open it, and drag “DockApex” into the Applications folder next to it.

### 2. First launch

The app isn't notarized by Apple, so macOS says it can't verify the developer the first time you open it:

1. Double-click “DockApex” in Applications and click Done in the alert.
2. Open System Settings › Privacy & Security, find the note about “DockApex” near the bottom, click Open Anyway, and confirm.

After that it opens normally. The system Dock hides itself, the bar appears at the bottom of the screen, and the apps pinned in your Dock come along. On first launch it adds itself to your login items so it starts when you log in.

### 3. Grant permissions

In System Settings › Privacy & Security:

| Permission | Used for |
| --- | --- |
| Accessibility | Keeping windows clear of the bar, moving floating bars, listing and switching windows, menus |
| Screen Recording | Window previews and reading apps' own Dock menu items; the optional shadow Dock also needs it |
| Automation › Finder | Emptying the Trash; asked the first time you use it |

### 4. Quit, update and uninstall

- **Quit**: click the four-squares icon in the menu bar, or right-click an empty part of the bar, and choose Quit (退出). The system Dock is restored on quit.
- **Update**: download the new DMG, quit DockApex, then drag the new version into Applications to replace the old one. Your folders, settings and granted permissions are kept.
- **Uninstall**: quit it, then drag “DockApex” from Applications to the Trash. Folders and settings live in `~/Library/Application Support/DockApex`; delete that too if you no longer need them. Remove the login item in System Settings › General › Login Items.

### Build from source

Requires Apple Silicon, macOS 14 or later, Xcode command line tools (Swift 6) and Python 3.

```bash
git clone https://github.com/DaliangPro/DockApex.git
cd DockApex
bash build.sh
open build/DockFolders.app
```

A build from source keeps folders and settings in `Data/` inside the project folder, so keep the project folder and don't move the app bundle out of it.

To run the tests first:

```bash
swift test -c release --scratch-path build/tests --cache-path build/package-cache
```

To make an installer yourself, run `bash package.sh`; it writes `build/release/DockApex-<version>.dmg`.

## FAQ

**Where did the system Dock go?**
It's set to auto-hide and moved to the display the bar is on, so minimized windows still shrink toward the bottom of the screen. It's restored when you quit DockApex.

**The app hung or crashed. How do I get my Dock back?**
If the app quits unexpectedly, the recovery helper running alongside it restores the system Dock. If it still isn't back, open DockApex again: on launch it first restores whatever the last session left unfinished, then quit it normally. With a build from source you can also double-click `RestoreDock.command` in the project folder; it doesn't need the app's UI or Accessibility permission.

**Why do all my minimized windows come back when I quit or restart DockApex?**
The system Dock has to be reloaded when DockApex starts and when it quits, and reloading the system Dock restores every minimized window.

**Why did my window get shorter on its own?**
That's DockApex keeping windows clear of the bar: a window that reaches under the bar has its bottom edge moved above it. A newly opened app may fill the screen first and then get shortened.

**An unpinned app stays on the bar after quitting.**
That's “recent apps”. Right-click an empty part of the bar and untick “Show recent apps” (显示最近使用的 App).

**Where are my folders and settings stored?**
The installed app keeps them in `~/Library/Application Support/DockApex/`; a build from source keeps them in `Data/` inside the project folder. That covers folders, pinned order and preferences. Nothing is uploaded.

**Is there another mode?**
Yes, the “shadow Dock”: the system Dock stays visible, reserving screen space and receiving minimized windows, with the bar drawn on top of it. It needs Screen Recording permission to paint the backdrop under the bar.

```bash
defaults write io.daliang.dockfolders useShadowDock -bool true
```

Restart the app for it to take effect.

## Caveats

- The app changes system Dock settings (auto-hide, icon size, pinned items and so on). It records the original values first and restores them on quit, so please quit it normally.
- Two recovery helpers run alongside the app and quit with it. On first launch it adds itself to your login items (turn this off with “Open at login” in the menu bar menu or in System Settings); no background services are installed.
- Private interfaces it uses include the Dock's reserved screen area (SkyLight), CoreDock, and Accessibility window numbers. A macOS update may break them.

## Known limitations

- Only one display can have a system-reserved area; in “all displays” mode the others rely on window adjustment.
- Apps that are already running can't see the bar's reserved space, so their windows are corrected after the fact and may briefly overlap the bar.
- The first time you right-click an app, reading its own Dock menu items takes about a second; after that a cache is used for 10 minutes.
- Window previews and right-click menus use the system popover. Measured on a 5K display, each time it pops up at a new position or size the system briefly takes about 250 MB of graphics memory, released after about a second.
- Some custom Dock tiles and full-screen / Spaces combinations aren't fully covered yet.

## License

[MIT](LICENSE)
