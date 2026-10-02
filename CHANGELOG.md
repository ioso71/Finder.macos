# Changelog

All notable changes to the Finder plugin are documented here.

Version scheme: `XX.Y.ZZ` (Major.Minor.Patch)
- **ZZ** (Patch): Bugfixes / small changes
- **Y** (Minor): medium updates / new features
- **XX** (Major): large breaking changes

## [1.4.0] — 2026-10-02

### Added
- "Show/Hide Hidden Files" toggle button in the panel toolbar (eye icon).
  When enabled, dot-prefixed files and folders are listed in both the
  folder tree and the file list. The setting is persisted between sessions
  (`showHiddenFiles` in `finder-plugin-prefs.json`) and defaults to off.
  Fixes nextpad-plus-plus-macos issue #364.

### Changed
- "Locate Current File in Finder Panel" now turns on "Show Hidden Files"
  automatically when the active file lives inside a hidden folder; before,
  the tree stopped at the last visible parent and never showed the file.
- Main toolbar icon (`resources/toolbar.png` / `toolbar_dark.png`) replaced
  with a closed-folder glyph: charcoal outline with a pale blue fill in the
  light variant, light-grey outline with a muted blue fill in the dark
  variant. 512×512 RGBA, transparent background.

## [1.3.1] — 2026-08-07

### Reverted
- The 5 panel toolbar icons (Parent Folder, Home, Locate File, New Folder,
  New File) are back to using SF Symbols
  (`toolbarButtonWithSymbol:tooltip:action:`) instead of the custom PNG
  assets introduced in 1.3.0 (`resources/panel-icons/`, now removed again).
  Reason: even after two rounds of fixes (cropping to the bounding box,
  then height-normalization instead of width-normalization), the icons
  still looked inconsistent/too small in the panel according to user
  feedback — worse than the original SF Symbol state. The main Finder
  toolbar icon (`resources/toolbar.png`/`toolbar_dark.png`, the folder
  glyph) is not affected by this revert and stays as set in 1.3.0.

## [1.3.0] — 2026-08-07

### Changed
- The panel's internal toolbar buttons (Parent Folder, Home, Locate File,
  New Folder, New File) now use custom icon assets
  (`resources/panel-icons/*.png`) instead of SF Symbols, so their look is
  consistent with the rest of the icon set. Loaded as a template image
  (`NSImage.template = YES`) so AppKit still auto-tints them for light/dark
  mode — as with SF Symbols, this means a single image file per icon is
  enough, since only the alpha channel counts as the mask. The plugin's own
  folder is resolved at runtime via `dladdr()` on its own `.dylib` symbol
  (no ABI message returns the plugin's own install path; only the shared
  `plugins/` parent folder is available via `NPPM_GETPLUGINHOMEPATH`).
- Main toolbar/menu-band icon (`resources/toolbar.png` /
  `toolbar_dark.png`) replaced with a new folder glyph in the same drawing
  style as the new panel icons.

### Fixed
- Build failed with `error: expected unqualified-id` at `img.template = YES;`
  in `FinderPanelView.mm`. Cause: `template` is a reserved C++ keyword; in
  an Objective-C++ file (`.mm`, compiled as C++) the dot-property syntax
  doesn't parse for it, even though it would have worked in plain
  Objective-C (`.m`). Fixed by using the explicit setter call
  `[img setTemplate:YES];`.
- The 5 new panel icons (`resources/panel-icons/*.png`) appeared tiny in
  the toolbar button, even though they were generated on the same 512×512
  canvas as the main toolbar icon. Cause: the actual glyph filled only a
  small portion of the canvas depending on the icon (e.g. the chevron
  glyph was only about 200×150px of 512×512) — the wide transparent margin
  shrank along with everything else when downscaled to button size, making
  the visible glyph even smaller than intended. Fixed by cropping all 5
  icons to their actual bounding box plus a uniform margin (~14% of the
  target area) before recentering on a fresh 512×512 canvas, plus
  increasing the target render size in code from 16×16pt to 18×18pt.
- Follow-up fix: despite the above, the 5 panel icons still didn't reach
  the full available toolbar height, and the new-folder icon looked
  noticeably shorter/more squashed than the others. Cause: all icons were
  scaled onto a uniform square 512×512 canvas (scaling by the *larger*
  dimension) — for the wide folder glyph this left vertical whitespace,
  which then shrank along with everything else when downscaled to a fixed
  square button image size. Fixed with two changes: (1) all 5 icons are
  now cropped/scaled to a uniform measure based on their *height* (width
  follows from each icon's own aspect ratio), (2)
  `-toolbarButtonWithIcon:tooltip:action:` reads each icon's real aspect
  ratio from `NSImage.size` and sets the button width/height individually
  to match, instead of using one fixed width for all 5 buttons in the
  toolbar visual-format line.

## [1.2.3] — 2026-08-07

### Known limitation (documented, not fixable plugin-side)
- The main toolbar icon's hover tooltip doesn't switch live on a runtime
  language change (menu items, panel UI, and the context menu do switch
  correctly). Cause: the host caches the tooltip text once at
  `NPPM_ADDTOOLBARICON_FORDARKMODE` and offers no refresh message; a
  repeated registration call with the same `cmdID` is a confirmed
  host-side no-op (dedup check in `MainWindowController.mm`). Documented
  in the README under "Known limitations"; only fixable host-side.

## [1.2.2] — 2026-08-07

### Fixed
- Build warning `unused parameter 'note'` in `FinderLocalization.mm`
  (`observeLanguageChangesWithBlock:`) removed. Now builds clean on macOS
  (confirmed via `cmake --build build`).

## [1.2.1] — 2026-08-07

### Fixed
- Build failed with `error: expected ']'` in `FinderPlugin.mm` at every
  `FDLoc(...)` call site. Cause: the `FDLoc` macro (`FinderLocalization.h`)
  had a parameter named `en`, which was textually identical to the literal
  selector part `en:` inside the macro body — the C preprocessor replaces
  plain tokens without any awareness of Objective-C selector syntax, and so
  also replaced the `en:` inside the selector with the second macro
  argument, breaking the expansion. Fixed by renaming the macro parameters
  to `deText`/`enText`.

## [1.2.0] — 2026-08-07

### Added
- Multilingual support (German/English): new `FinderLocalization` helper
  class (`src/FinderLocalization.h/.mm`) reads the host's own
  `NSUserDefaults` key `"language"` (the same source used by `NppLocalizer`
  in the host) and switches menu items (`FinderPlugin.mm`), toolbar
  tooltips, column titles, the root popup, context menu, and dialogs
  (`FinderPanelView.mm`) live — without a restart — as soon as the user
  changes the language in the host. Reason: the official plugin ABI hooks
  for this (`NPPN_NATIVELANGCHANGED`/`NPPM_GETNATIVELANGFILENAME`) are
  declared in `NppPluginInterfaceMac.h` but not implemented anywhere on
  macOS (same limitation as `FuncItem._pShKey`); instead the plugin listens
  for the host's already-posted `"NPPLocalizationChanged"` notification,
  and menu items are renamed directly by `tag` lookup in `NSApp.mainMenu`.

### Fixed
- Toolbar icon (`resources/toolbar.png` / `toolbar_dark.png`) always
  looked grayish instead of solid black/light-gray at toolbar size,
  regardless of light/dark mode or colorization settings. Cause: the icon
  glyph's stroke was too thin (10pt) — at the small toolbar render size a
  thin stroke is perceived as gray due to anti-aliasing, not a rendering or
  theme bug. Fixed with new icon files using an 18pt stroke width.

## [1.1.1] — 2026-08-07

### Added
- `LICENSE` (MIT, Copyright (c) 2026 Maik Wendelken) and a license
  reference in the README.

## [1.1.0] — 2026-08-07

### Added
- Toolbar/menu-band icon for the Finder panel toggle (`resources/toolbar.png`
  + `resources/toolbar_dark.png`, registered via
  `NPPM_ADDTOOLBARICON_FORDARKMODE`), including automatic copying to
  `resources/` in the install target in `CMakeLists.txt`.
- `CHANGELOG.md` and a fixed version number (`FINDER_PLUGIN_VERSION` in
  `FinderPlugin.mm`) as the binding version source for future releases.

### Changed
- The panel's internal toolbar buttons (Parent Folder, Home, Locate File,
  New Folder, New File) now use native SF Symbols instead of emoji
  characters as icons — automatically light/dark-mode aware, with no
  custom image assets needed.

### Fixed
- The folder tree (left panel) stopped showing folder names — icons only,
  no labels — after a root change (Home/Computer dropdown, "Parent
  Folder" button) **and** after "New Folder", "New File", "Rename", or
  "Move to Trash", until the user manually dragged the divider between
  the tree and file list. Cause: `-reloadItem:nil reloadChildren:YES`
  fetches new data but doesn't force `NSOutlineView` to fully re-tile its
  row/column geometry. All affected call sites now use a shared
  `-reloadOutline` method with a full `-reloadData` plus an explicit
  layout kick; the tree's expansion state is preserved (tree items are
  path strings, and `NSOutlineView` tracks expansion via `-isEqual:`).

## [1.0.0] — 2026-08-06

First working version.

### Added
- Vendored header `NppPluginInterfaceMac.h` for the macOS plugin ABI.
- CMake build (`CMakeLists.txt`) including an `install_plugin` target.
- Plugin entry point (`FinderPlugin.mm`): 5 mandatory C exports, docking
  panel control, menu commands (show/hide panel, locate current file in
  panel, show current file in macOS Finder).
- `FinderPanelView`: folder tree + file list, live filter, context menu
  (Open, Reveal in Finder, Open in Terminal, New Folder/File, Rename,
  Duplicate, Move to Trash, Copy Path/Name, Add to Favorites).
- `FinderFileOperations` / `FinderPreferences`: filesystem actions and
  persistent settings (last root path), respectively.
- README with build/install instructions.

### Fixed
- Panel toggle required a second click to become visible (race between
  `NPPN_READY` and the main window's final layout pass — fixed by
  deferring the first `SHOWPANEL` call and correctly evaluating its return
  value).
- File list (right column in the panel) showed only folders, no files, or
  collapsed to width 0 — fixed with minimum-width constraints on both
  split-view panes plus repeated divider placement.
