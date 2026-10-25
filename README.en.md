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

The bar has three sections separated by dividers: on the left, pinned apps and folders, each folder icon showing thumbnails of its apps; in the middle, running apps that aren't pinned and recent apps; on the right, minimized windows, file and folder items, and the Trash. A dot under an icon means the app is running. Icon size, spacing and the floating glass backdrop are calibrated against the system Dock, and icons shrink automatically when there are many of them.

## Features

### iPhone-style folders

- **Create**: drag an app onto the center of another app and slow down (a fast pass doesn't count). The target grows a folder backdrop and shows “Release to create a group”; release and the folder is made and opens right away. New folders are named “New group” (新分组). Dropping near an icon's edge reorders instead.
- **Add**: drag an app onto the center of a folder (“Release to add to the group”). While a folder panel is open, you can also drag an app from the bar straight into the panel and drop it where you want. Dragging an .app from Finder works the same way. Drag one folder onto another and they merge, keeping the target's name. An app can be in only one folder.
- **Open**: click a folder and a panel unfolds beside it (above it when the bar is at the bottom), with a small arrow pointing at the folder, three apps per row, scrolling when it doesn't fit. Clicking a running app switches to it and closes the panel; an app that isn't running bounces in the panel, and the panel closes once it launches (or after three bounces).
- **Close**: press Esc, click outside the panel, click the folder again, or switch to another app.
- **Organize**: drag to reorder inside the panel. Drag an app out of the panel: onto a gap in the bar to take it out of the folder and pin it there; onto the center of another app to make a new folder with it; anywhere off the bar and it springs back. “Remove group” (移除分组) in a member's right-click menu takes that app out of the folder and back onto the bar.
- **Right-click a folder**: Open; “Edit / Rename group…”, which opens the management window; “Ungroup”, which puts the members back where the folder was, in order.
- **Remove a folder**: drag the folder icon off the bar and confirm; the folder and its apps leave the bar (the apps aren't uninstalled, and “Undo layout change” brings them back).
- **Manage folders**: the “Manage folders” window in settings lets you add apps (with “Add app…” or by dragging an .app from Finder into the list), remove apps, reorder, rename and ungroup (with a confirmation). Apps that can't be found are marked as moved or missing. New folders are made by dragging on the bar.
- **No duplicates**: when an app inside a folder is running, the folder shows a running dot instead of adding another icon to the bar. A folder's badge is the sum of its apps' unread counts.

### Look and feedback

- Magnification on hover, name labels, running indicators, launch bounce and unread badges, just like the system Dock.
- Icons darken when pressed, as in the native Dock; when an app can't be found, its icon shows the native Dock's gray question mark.
- When an app draws its Dock icon with its own Dock tile plug-in (for example after you change its icon inside the app), the bar shows that icon too.
- Magnification (and its size), running indicators, launch animation and whether windows minimize into the application icon follow the options in System Settings › Desktop & Dock: change them there and the bar follows (except with the shadow Dock). DockApex's menu has no separate switches for them.

### Clicks and menus

- **Click an app**: opens it if it isn't running, switches to it if it is; if all its windows are minimized, one of them is restored.
- **Modifier clicks**: ⌘-click shows the item in Finder (file and folder items too); ⌥-click the current app to hide it, or another app to switch to it and hide the previous one; ⌘⌥-click switches to the app and hides all others.
- **Open a menu**: right-click, Control-click, or press and hold for about half a second. Keep holding, drag onto a menu item and release to choose it.
- **An app's right-click menu**: Open / Switch, its current windows (◆ marks minimized ones, ✓ the current one), the app's own Dock menu items (such as Finder's New Finder Window), Options, Show All Windows, Show in Finder, Keep in bar or Remove from bar, Hide, Quit, Force Quit (with a confirmation). Finder stays first and can't be removed or quit.

### Window previews

![Window previews popping up over Tabbit; both windows are minimized](docs/images/preview.png)

Rest the pointer on a running app and thumbnails of its windows pop up, minimized windows included with their real contents. Click a thumbnail to switch to that window (a minimized one is restored first), or × to close it. Works on the bar and inside folder panels.

### Drag and drop

- **Reorder and remove**: drag icons to reorder; drag one off the bar and release when it says “Release to remove from the bar” to remove it. Press Esc while dragging to cancel.
- **Apps from Finder**: drop an .app on a gap in the bar to pin it there, or on the center of an icon to make or join a folder.
- **File and folder items**: drop files or folders on an empty part of the bar to add them to the right section.
- **Open files with an app**: drop files onto an app icon (including apps inside a folder panel) to open them with that app.
- **Into a folder**: files dropped on a folder item are moved when they're on the same disk and copied across disks (USB drives, network volumes and so on); hold ⌥ to always copy or ⌘ to always move.
- **Into the Trash**: drop files on the Trash to move them there.

### Files, folders, minimized windows and the Trash

- **Folder items**: click to list the contents, sorted by date modified by default or by name, up to 500 items. Click an item to open it; right-click to open it, show it in Finder, copy it or move it to the Trash; drag an item out; “Open in Finder” at the bottom opens the folder. Click a file item to open it.
- **Minimized windows**: each minimized window gets a slot in the right section, shown as a window frame holding the app's icon. Click to restore and switch to it; right-click for Show Window and Open / Switch App. If System Settings is set to minimize windows into the application icon, they aren't shown separately, same as the system.
- **Trash**: shows whether it's empty or full; click to open it; right-click to empty it. When Finder's “Show warning before emptying the Trash” is on, you're asked to confirm first.

### Apps that are uninstalled, moved or reinstalled

- An uninstalled app leaves the bar and its folder after about 10 seconds; reinstall it within 30 minutes and it returns to its old spot or folder.
- A moved or reinstalled app is switched to its new location after about 5 seconds. If the disk it lives on isn't connected (an external drive, say), it isn't removed.

### Windows stay clear of the bar

Once the system Dock is hidden, apps that are already running assume there's no Dock at the bottom and stretch their windows all the way down. DockApex shortens filled, tiled or overlapping windows so they end outside the bar (or narrows them when the bar is on the left or right); a large window that reaches under the bar is moved instead when there's room on the other side. Small floating bars from third-party apps (such as a voice-input bar) that reach into the bar are moved out of the way. Double-clicking a title bar to zoom still toggles between the original size and filled.

None of this happens when auto-hide is on or when an app is full screen on that display. When you quit DockApex, shortened windows go back to their original size; floating bars that were moved stay where they are.

### Settings and displays

Right-click an empty part of the bar, or click the four-squares icon in the menu bar, to:

- Manage folders; undo layout changes (one step only; changing settings such as position or icon size also counts as a step)
- Position: bottom, left, right
- Display: main display; all displays (one bar per display); follow the pointer (push the pointer against the edge of another display for about 0.35 seconds and the bar moves there); or a specific display (if it's disconnected, the bar falls back to the main display and returns when it's reconnected)
- Auto-hide: move the pointer to the screen edge to reveal it. The bar on a display also hides automatically while an app is full screen there
- Show recent apps: up to 3; turn it off and unpinned apps disappear from the bar when they quit
- Icon size: 28, 37, 48 or 64 points
- Open at login (登录时打开): start DockApex when you log in

### Keyboard and accessibility

- **Folder panels**: ← → move one item, ↑ ↓ move a row, Home / End jump to the ends; Return or Space opens; type the start of a name to jump to it; Control-Return opens the menu; Esc closes.
- **Folder item lists**: ↑ ↓ and Home / End move, Return opens, Esc closes.
- VoiceOver: icons on the bar and in panels are buttons that read out their names and badge counts, and on the bar whether the app is running.

## Privacy

- Folders, pinned order and preferences stay on your Mac, and the app doesn't go online (the About panel only has a link that opens the GitHub page).
- The data folder also holds an activity log (recording things like the names of apps you opened or switched to and folder names; it rolls over at about 5 MB and keeps 3 files) and a daily layout backup (7 kept), all local.
- In everyday use, Screen Recording is used only for the following, and images stay in memory, never written to disk or uploaded:
  - Window previews: only while you hover, that app's windows are captured one by one as small thumbnails; each is dropped when its window closes or the app quits, and everything is cleared once there are more than 64.
  - Reading an app's own Dock menu items: on right-click, a live image covers the area where the menu would appear for about a second, so the system menu doesn't flash; it also covers it briefly when you run one of those items.
  - The optional shadow Dock: painting the backdrop under the bar.
- An app's own Dock tile plug-in runs in a separate helper process that doesn't get DockApex's Accessibility or Screen Recording permissions.

## Getting started

### 1. Download and install

Requires Apple Silicon and macOS 14 or later.

Download the latest `DockApex-<version>.dmg` from [Releases](https://github.com/DaliangPro/DockApex/releases), open it, and drag “DockApex” into the Applications folder next to it.

### 2. First launch

The app isn't notarized by Apple, so macOS says it can't verify the developer the first time you open it:

1. Double-click “DockApex” in Applications and click Done in the alert.
2. Open System Settings › Privacy & Security, find the note about “DockApex” near the bottom, click Open Anyway, and confirm.

After that it opens normally. The system Dock hides itself and the bar appears on the side where the system Dock was; your pinned apps, the files and folders on the Dock's right side, the icon size and the magnification setting come along, with Finder pinned first. On first launch it adds itself to your login items so it starts when you log in.

After launch, wake or connecting a display, if the hidden system Dock isn't on the display with the bar, DockApex borrows the pointer for about 1.2 seconds to push it there.

Opening DockApex again while it's running brings up the “Manage folders” window. Only one copy can run at a time: another copy (such as a build from source) opened while it's running quits right away.

### 3. Grant permissions

Turn these on in System Settings › Privacy & Security. DockApex doesn't remind you about them; without them, the related features simply don't work:

| Permission | Used for |
| --- | --- |
| Accessibility | Keeping windows clear of the bar, moving floating bars, listing and switching windows, unread badges, detecting full screen, menus |
| Screen Recording | Window previews; reading apps' own Dock menu items (Accessibility is needed too); the optional shadow Dock |
| Automation › Finder | Emptying the Trash; asked the first time you use it |

### 4. Quit, update and uninstall

- **Quit**: click the four-squares icon in the menu bar, or right-click an empty part of the bar, and choose Quit (退出); the “Restore system Dock” button in the “Manage folders” window quits too. The system Dock is restored on quit.
- **Update**: download the new DMG, quit DockApex, then drag the new version into Applications to replace the old one. Your folders, settings and granted permissions are kept.
- **Uninstall**: quit it, then drag “DockApex” from Applications to the Trash. Folders and settings live in `~/Library/Application Support/DockApex` and preferences in `~/Library/Preferences/io.daliang.dockfolders.plist`; delete those too if you no longer need them. Remove the login item in System Settings › General › Login Items.

### Build from source

Requires Apple Silicon, macOS 14 or later, Xcode command line tools (Swift 6) and Python 3.

```bash
git clone https://github.com/DaliangPro/DockApex.git
cd DockApex
bash build.sh
open build/DockFolders.app
```

A build from source keeps folders and settings in `Data/` inside the project folder, and the app bundle records where the project folder is. Don't move or rename the project folder; if you do, run `bash build.sh` again.

To run the tests first:

```bash
swift test -c release --scratch-path build/tests --cache-path build/package-cache
```

To make an installer yourself, run `bash package.sh`; it writes `build/release/DockApex-<version>.dmg`.

## FAQ

**Where did the system Dock go?**
It's set to auto-hide (with a 1-second delay) and moved to the display the bar is on, so minimized windows still shrink toward that display. DockApex intercepts pointer movement at the screen edge so it can't be pulled out. All of this is restored when you quit DockApex.

**The app hung or crashed. How do I get my Dock back?**
When DockApex quits unexpectedly (including a crash), the recovery helper running alongside it restores the system Dock. If it hangs without quitting, force quit DockApex in Activity Monitor first, and the recovery helper takes over. If it still isn't back, open DockApex again: on launch it first restores whatever the last session left unfinished, then quit it normally. With a build from source you can also double-click `RestoreDock.command` in the project folder; it quits a running DockApex first and doesn't need the app's UI or Accessibility permission.

**Why do all my minimized windows come back when I quit or restart DockApex?**
The system Dock has to be reloaded when DockApex starts and when it quits, and reloading the system Dock restores every minimized window.

**Why did my window get shorter on its own?**
That's DockApex keeping windows clear of the bar: a window that reaches under the bar is pulled back outside it (made narrower when the bar is on the left or right). A newly opened app may fill the screen first and then get shortened. Once you resize the window yourself, DockApex stops adjusting it for reaching under the bar; shortened windows go back to their original size when you quit DockApex.

**An unpinned app stays on the bar after quitting.**
That's “recent apps”. Right-click an empty part of the bar and untick “Show recent apps” (显示最近使用的 App), or right-click that icon and choose Remove from bar.

**Where are my folders and settings stored?**
The installed app keeps them in `~/Library/Application Support/DockApex/`; a build from source keeps them in `Data/` inside the project folder. That covers folders, pinned order, preferences and a daily layout backup (7 kept). Nothing is uploaded. The shadow Dock switch and the login item flag are stored in `~/Library/Preferences/io.daliang.dockfolders.plist`.

**Is there another mode?**
Yes, the “shadow Dock”: the system Dock stays visible, reserving screen space and receiving minimized windows, with the bar drawn on top of it. It needs Screen Recording and Accessibility permission (to paint the backdrop under the bar), and it isn't used while the bar's auto-hide is on. In this mode the system Dock's pinned items are cleared down to Finder and running apps, its right side is emptied, and recent apps and magnification are turned off; the original values are written back on quit.

Turn it on:

```bash
defaults write io.daliang.dockfolders useShadowDock -bool true
```

Turn it off:

```bash
defaults delete io.daliang.dockfolders useShadowDock
```

Restart the app for the change to take effect.

## Caveats

- By default the app only changes the system Dock's auto-hide, its delay and its icon size (so minimized windows land at the bar), and leaves its pinned items alone; the shadow Dock also changes pinned items, the right side, recent apps, magnification and position. Original values are recorded first and restored on quit, so please quit it normally.
- Two recovery helpers run alongside the app and quit with it. On first launch it adds itself to your login items (turn this off with “Open at login” in the menu bar menu or in System Settings); no background services are installed.
- Private interfaces it uses include the Dock's reserved screen area (SkyLight), CoreDock, and Accessibility window numbers. A macOS update may break them.

## Known limitations

- Only one display can have a system-reserved area; in “all displays” mode the others rely on window adjustment.
- Apps that are already running can't see the bar's reserved space, so their windows are corrected after the fact and may briefly overlap the bar.
- The first time you right-click an app, reading its own Dock menu items takes about a second; after that a cache is used for 10 minutes.
- Window previews and right-click menus without submenus use the system popover (menus with submenus use a regular system menu). Measured on a 5K display, each time the popover appears at a new position or size the system briefly takes about 250 MB of graphics memory, released after about a second.
- Some custom Dock tiles and full-screen / Spaces combinations aren't fully covered yet.

## License

[MIT](LICENSE)
