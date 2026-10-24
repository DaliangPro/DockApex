# DockApex

**No matter how many apps you have, one Dock holds them all.**

![DockApex: an open folder panel above the bar](docs/images/hero.png)

[中文](README.md)

The interface is in Chinese; quoted labels below are translations.

## Why

The macOS Dock can't group apps into folders. As you install more apps, the Dock either keeps growing and its icons keep shrinking, or you take apps out of it and dig through Launchpad whenever you need them.

DockApex replaces the Dock with a bar that looks and feels as close to the system Dock as possible, and adds iPhone-style folders: put apps of one kind into a single slot, so one spot holds several apps, one click away.

## A look at the bar

![The whole bar](docs/images/bar.png)

Pinned apps and folders sit on the left; each folder icon shows thumbnails of its apps. A dot under an icon means the app is running. The Trash is on the far right. Icon size, spacing and the floating glass backdrop are calibrated against the system Dock.

## Features

### iPhone-style folders

- **Create**: drag an app onto the center of another app. The target grows a folder backdrop and shows “Release to create a group”; release and the folder is made. Dropping near an icon's edge reorders instead.
- **Open**: click a folder and a panel unfolds above it, three apps per row. Click an app to open or switch to it; an app that isn't running yet bounces in the panel, and the panel closes once it launches.
- **Close**: press Esc, click outside the panel, or click the folder again.
- **Organize**: drag to reorder inside the panel; drag an app out of the panel back onto the bar; right-click a folder to rename or ungroup it.
- **No duplicates**: when an app inside a folder is running, the folder shows a running dot instead of adding another icon to the bar.

### Works like the system Dock

- Magnification on hover (follows your system Dock's magnification setting), running indicators, launch bounce, unread badges.
- Right-click an app: Open / Switch, the app's own Dock menu items (such as Finder's New Finder Window), Show in Finder, Keep in bar or Remove, Hide, Quit, Force Quit.
- Hover over a running app to preview its windows (minimized ones included); click a thumbnail to switch to that window, or × to close it.
- Drag icons to reorder; drag one off the bar and release when it says “Release to remove from the bar” to remove it.
- Drop files or folders on an empty part of the bar to add them on the right; click a folder to expand it.
- Minimized windows appear on the right.
- The Trash shows whether it's empty or full; right-click to open it or empty it (a confirmation dialog appears first).

### Windows stay clear of the bar

Once the system Dock is hidden, apps that are already running assume there's no Dock at the bottom and stretch their windows all the way down. DockApex shortens filled, tiled or overlapping windows so they end above the bar, and moves small floating bars (such as a voice-input bar) out of the way. Double-clicking a title bar to zoom still toggles between the original size and filled.

### Displays and settings

Right-click an empty part of the bar, or click the four-squares icon in the menu bar, to:

- Manage folders, undo layout changes
- Position: bottom, left, right
- Display: main display, a specific display, all displays, or follow the pointer
- Auto-hide, icon size
- Show recent apps: turn it off and unpinned apps disappear from the bar when they quit
- Open at login (登录时打开): start DockApex when you log in

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
| Accessibility | Keeping windows clear of the bar, moving floating bars, menus |
| Screen Recording | Window previews on hover and reading apps' own Dock menu items; the optional shadow Dock also needs it |
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
It's set to auto-hide and moved to the display the bar is on, so minimized windows still shrink toward the bottom of the screen. It's restored when you quit DockFolders.

**The app hung or crashed. How do I get my Dock back?**
If the app quits unexpectedly, the recovery helper running alongside it restores the system Dock. If it still isn't back, open DockApex again: on launch it first restores whatever the last session left unfinished, then quit it normally. With a build from source you can also double-click `RestoreDock.command` in the project folder; it doesn't need the app's UI or Accessibility permission.

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
- The first time you right-click an app, reading its own Dock menu items takes about a second; some custom Dock tiles and full-screen / Spaces combinations aren't fully covered.

## License

[MIT](LICENSE)
