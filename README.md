# Finder — Nextpad++ macOS Plugin

**Version:** 1.4.0 — see [CHANGELOG.md](CHANGELOG.md) for the version history.

A sidebar panel for Nextpad++ (macOS) that shows a folder tree + file list of the real filesystem and offers Finder-style actions (reveal in Finder, open in Terminal, rename, move to Trash, copy path, new file/folder, favorites). 
It's the macOS counterpart to the classic Windows plugin npp-explorer-plugin, built on top of the native Nextpad++ plugin API for macOS (`NppPluginInterfaceMac.h`, see `vendor/README.md`).

## No external dependencies

This plugin uses only Apple system frameworks (**Cocoa/AppKit, Foundation**) plus CMake as the build system — exactly like the Nextpad++ host itself. No third-party packages were installed or added, and none are needed for the current feature set.

## Important: can only be built on macOS

This plugin is Objective-C++ (`.mm`) and links against `Cocoa`/`Foundation`. 
It **cannot** be compiled in this session's Linux sandbox — that requires a Mac with the Command Line Tools (or Xcode) installed. Everything here was carefully checked by hand against the header conventions and existing patterns of the host repo (see "Known limitations / possible next steps" below), but an actual compile run is still required on your end.

## Structure

```
finder/
├── CMakeLists.txt              Build configuration (produces Finder.dylib)
├── vendor/
│   ├── NppPluginInterfaceMac.h Unmodified copy of the plugin ABI from the host repo
│   └── README.md               Provenance/sync note for the vendored file
└── src/
    ├── FinderPlugin.mm         Mandatory exports (setInfo/getName/getFuncsArray/
    │                           beNotified/messageProc), panel registration
    ├── FinderPanelView.h/.mm   NSOutlineView (folder tree) + NSTableView
    │                           (file list), toolbar, context menus
    ├── FinderFileOperations.h/.mm  Reveal in Finder, open Terminal, new
    │                           file/folder, rename, trash, copy
    └── FinderPreferences.h/.mm JSON file with last root path + favorites
```

## Building (on a Mac)

Prerequisite: Nextpad++ has already been built from `nextpad-plus-plus-macos` (or installed) — this plugin builds independently of that, but has to be loaded by a running Nextpad++ instance at runtime.

```sh
cd /path/to/your/repository
cmake -S . -B build
cmake --build build
```

Result: `build/Finder.dylib` (universal binary, arm64 + x86_64, deployment target macOS 11).

## Installing

Nextpad++ loads plugins from `~/Library/Application Support/Nextpad++/plugins/<Name>/<Name>.dylib` (see `NppPluginManager.h` in the host repo). A convenience target handles this:

```sh
cmake --build build --target install_plugin
```

This copies the built library to `~/Library/Application Support/Nextpad++/plugins/Finder/Finder.dylib`.

Then (re)start Nextpad++. On startup the Finder panel is shown automatically (default behavior, matching the Windows Explorer plugin); it can be hidden via the **Plugins → Finder → Toggle Finder Panel** menu item.

## Testing with the host's own plugin test harness

The host repo ships a load test (`test_plugins/`) that checks every plugin in the plugins directory against the 5 mandatory exports, without starting the full app:

```sh
cd /path/to/your/repository/nextpad-plus-plus-macos
cmake -S test_plugins -B test_plugins/build
cmake --build test_plugins/build
./test_plugins/build/test_plugins
```

Expected output: `[PASS] Finder — "Finder" (3 menu items)` with the three menu entries (toggle panel, locate current file in panel, reveal current file in Finder).

## Feature set (v1)

- Folder tree (folders only, lazily loaded) + file list (folders+files) of the selected root — choice between Home, "Computer" (`/`), mounted volumes, favorites, or a freely chosen folder.
- Double-click on a file → opens it in Nextpad++ (`NPPM_DOOPEN`).
- Double-click on a folder → navigates into it.
- "Locate Current File in Finder Panel" (menu + toolbar button) — jumps to the active file in the tree/list.
- "Reveal Current File in macOS Finder" — opens the real Finder directly, without going through the panel.
- Context menu: Open, Reveal in Finder, Open in Terminal, New Folder, New File, Rename, Duplicate, Move to Trash, Copy Path/Name, Add to Favorites.
- Search/filter field for the file list.
- Toolbar toggle to show/hide hidden (dot-prefixed) files and folders in the tree and file list; remembered between sessions. "Locate Current File" enables it automatically when the file is inside a hidden folder.
- Last root path and favorites are persisted between sessions (`NPPM_GETPLUGINSCONFIGDIR`/JSON file, no NSUserDefaults suite conflict
  with other plugins).
- Multilingual (German/English): menu items, toolbar tooltips, column titles, context menu, and dialogs follow the host's language selection (`NSUserDefaults` key `"language"`) and switch live, without a restart — see `src/FinderLocalization.h/.mm`.

## Known limitations / possible next steps

- A root path set freely via "Choose Folder…" doesn't appear as its own entry in the root popup (cosmetic — navigation works fine, but the popup selection "jumps" back to the last matching menu entry the next time it's opened).
- No drag & drop out of the panel (e.g. into other apps) — only open-via-double-click/menu.
- No automatic reload on external filesystem changes (no `FSEvents`watcher); an implicit "reload" happens via re-navigating, but there's no explicit refresh button.
- Renaming goes through an `NSAlert` dialog instead of inline row editing (deliberately kept simpler for v1).
- The main toolbar icon's hover tooltip (registered via `NPPM_ADDTOOLBARICON_FORDARKMODE`) does **not** switch live on a runtime language change — the host caches the tooltip text once at registration time and offers no message/notification to refresh it; a repeated `NPPM_ADDTOOLBARICON_FORDARKMODE` call with the same `cmdID` is a confirmed host-side no-op (dedup check in `MainWindowController.mm`).
  Menu items, panel UI, and the context menu, however, do switch correctly live. Restarting Nextpad++ shows the tooltip in the then-current language. Only fixable host-side — outside this plugin's scope.

## License

MIT — see [LICENSE](LICENSE).
