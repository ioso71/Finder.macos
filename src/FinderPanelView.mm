#import "FinderPanelView.h"
#import "FinderFileOperations.h"
#import "FinderPreferences.h"
#import "FinderLocalization.h"

/// Shared with -rootPopUpChanged: so the "choose a folder" sentinel item's
/// title always matches the current language, both when it's created and
/// when it's compared against on selection.
static NSString *ChooseFolderTitle(void) {
    return FDLoc(@"Ordner wählen…", @"Choose Folder…");
}

// ─────────────────────────────────────────────────────────────────────────
// Small helpers
// ─────────────────────────────────────────────────────────────────────────

static BOOL FinderIsHiddenName(NSString *name) {
    return name.length > 0 && [name characterAtIndex:0] == '.';
}

/// Folders directly inside `dir`, hidden entries excluded unless `showHidden`, sorted
/// case-insensitively by name. Synchronous — callers keep scope to one
/// directory at a time so this stays fast.
static NSArray<NSString *> *FinderSubdirectories(NSString *dir, BOOL showHidden) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:dir error:nil];
    if (!names) return @[];

    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (NSString *name in names) {
        if (!showHidden && FinderIsHiddenName(name)) continue;
        NSString *full = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir) {
            [result addObject:full];
        }
    }
    [result sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a.lastPathComponent caseInsensitiveCompare:b.lastPathComponent];
    }];
    return result;
}

/// All entries (files + folders) directly inside `dir`, folders first, then
/// files, both alphabetical; hidden entries excluded unless `showHidden`.
static NSArray<NSString *> *FinderListEntries(NSString *dir, BOOL showHidden) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:dir error:nil];
    if (!names) return @[];

    NSMutableArray<NSString *> *folders = [NSMutableArray array];
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (NSString *name in names) {
        if (!showHidden && FinderIsHiddenName(name)) continue;
        NSString *full = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
        if (isDir) [folders addObject:full]; else [files addObject:full];
    }
    NSComparator cmp = ^NSComparisonResult(NSString *a, NSString *b) {
        return [a.lastPathComponent caseInsensitiveCompare:b.lastPathComponent];
    };
    [folders sortUsingComparator:cmp];
    [files sortUsingComparator:cmp];

    NSMutableArray<NSString *> *all = [NSMutableArray arrayWithArray:folders];
    [all addObjectsFromArray:files];
    return all;
}

// ─────────────────────────────────────────────────────────────────────────

@interface FinderPanelView () <NSOutlineViewDataSource, NSOutlineViewDelegate,
                                NSTableViewDataSource, NSTableViewDelegate,
                                NSSearchFieldDelegate, NSMenuDelegate>
@end

@implementation FinderPanelView {
    NSPopUpButton *_rootPopUp;
    NSButton *_upButton;
    NSButton *_homeButton;
    NSButton *_locateButton;
    NSButton *_hiddenButton;
    NSButton *_newFolderButton;
    NSButton *_newFileButton;
    NSSearchField *_searchField;

    NSOutlineView *_outlineView;
    NSTableView *_fileTable;

    NSString *_rootPath;          // top-level context (Home / Computer / a volume / a favorite / custom)
    NSString *_currentListPath;   // directory currently shown in the file list
    NSArray<NSString *> *_currentListEntries; // unfiltered
    NSArray<NSString *> *_filteredListEntries; // after search filter

    NSMutableDictionary<NSString *, NSArray<NSString *> *> *_childCache;
}

#pragma mark - Init / layout

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _childCache = [NSMutableDictionary dictionary];
        _rootPath = [FinderPreferences shared].lastRootPath ?: NSHomeDirectory();
        _currentListPath = _rootPath;
        [self buildUI];
        [self reloadOutline];
        [self reloadListForPath:_currentListPath];

        // Same limitation as the plugin's menu items (see FinderPlugin.mm):
        // no working ABI hook for language changes, so we listen for the
        // host's own notification directly and relabel everything live.
        __weak FinderPanelView *weakSelf = self;
        [FinderLocalization observeLanguageChangesWithBlock:^{
            [weakSelf relocalizeUI];
        }];
    }
    return self;
}

- (void)buildUI {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    // ── Toolbar ──────────────────────────────────────────────────────────
    NSView *toolbar = [[NSView alloc] init];
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:toolbar];

    _rootPopUp = [[NSPopUpButton alloc] init];
    _rootPopUp.translatesAutoresizingMaskIntoConstraints = NO;
    [self rebuildRootPopUp];
    _rootPopUp.target = self;
    _rootPopUp.action = @selector(rootPopUpChanged:);
    [toolbar addSubview:_rootPopUp];

    _upButton = [self toolbarButtonWithSymbol:@"chevron.up" tooltip:FDLoc(@"Übergeordneter Ordner", @"Parent Folder") action:@selector(goUp:)];
    _homeButton = [self toolbarButtonWithSymbol:@"house" tooltip:FDLoc(@"Home-Verzeichnis", @"Home Directory") action:@selector(goHome:)];
    _locateButton = [self toolbarButtonWithSymbol:@"location.circle" tooltip:FDLoc(@"Aktuelle Datei anzeigen", @"Locate Current File") action:@selector(locateCurrentFile:)];
    _hiddenButton = [self toolbarButtonWithSymbol:@"eye.slash" tooltip:@"" action:@selector(toggleShowHidden:)];
    [self updateHiddenButton];
    _newFolderButton = [self toolbarButtonWithSymbol:@"folder.badge.plus" tooltip:FDLoc(@"Neuer Ordner", @"New Folder") action:@selector(createNewFolder:)];
    _newFileButton = [self toolbarButtonWithSymbol:@"doc.badge.plus" tooltip:FDLoc(@"Neue Datei", @"New File") action:@selector(createNewFile:)];

    for (NSButton *b in @[_upButton, _homeButton, _locateButton, _hiddenButton, _newFolderButton, _newFileButton]) {
        [toolbar addSubview:b];
    }

    _searchField = [[NSSearchField alloc] init];
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.placeholderString = FDLoc(@"Filter", @"Filter");
    _searchField.delegate = self;
    _searchField.target = self;
    _searchField.action = @selector(searchChanged:);
    [toolbar addSubview:_searchField];

    NSDictionary *views = NSDictionaryOfVariableBindings(_rootPopUp, _upButton, _homeButton, _locateButton, _hiddenButton, _newFolderButton, _newFileButton, _searchField);
    [toolbar addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:
        @"H:|-4-[_rootPopUp(>=90)]-4-[_upButton(24)]-2-[_homeButton(24)]-2-[_locateButton(24)]-2-[_hiddenButton(24)]-8-[_newFolderButton(28)]-2-[_newFileButton(28)]-8-[_searchField(>=90)]-4-|"
        options:NSLayoutFormatAlignAllCenterY metrics:nil views:views]];
    [toolbar addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-4-[_rootPopUp]-4-|"
        options:0 metrics:nil views:views]];

    // ── Split view: folder tree | file list ────────────────────────────
    NSSplitView *split = [[NSSplitView alloc] init];
    split.translatesAutoresizingMaskIntoConstraints = NO;
    split.vertical = YES;
    split.dividerStyle = NSSplitViewDividerStyleThin;
    [self addSubview:split];

    _outlineView = [[NSOutlineView alloc] init];
    NSTableColumn *treeCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    treeCol.title = FDLoc(@"Ordner", @"Folder");
    [_outlineView addTableColumn:treeCol];
    _outlineView.outlineTableColumn = treeCol;
    _outlineView.headerView = nil;
    _outlineView.dataSource = self;
    _outlineView.delegate = self;
    _outlineView.target = self;
    _outlineView.doubleAction = @selector(outlineDoubleClicked:);
    _outlineView.menu = [self buildContextMenuForTable:NO];
    _outlineView.menu.delegate = self;

    NSScrollView *outlineScroll = [[NSScrollView alloc] init];
    outlineScroll.translatesAutoresizingMaskIntoConstraints = NO;
    outlineScroll.documentView = _outlineView;
    outlineScroll.hasVerticalScroller = YES;
    outlineScroll.autohidesScrollers = YES;

    _fileTable = [[NSTableView alloc] init];
    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameCol.title = FDLoc(@"Name", @"Name");
    nameCol.width = 180;
    NSTableColumn *sizeCol = [[NSTableColumn alloc] initWithIdentifier:@"size"];
    sizeCol.title = FDLoc(@"Größe", @"Size");
    sizeCol.width = 70;
    NSTableColumn *dateCol = [[NSTableColumn alloc] initWithIdentifier:@"date"];
    dateCol.title = FDLoc(@"Geändert", @"Modified");
    dateCol.width = 120;
    [_fileTable addTableColumn:nameCol];
    [_fileTable addTableColumn:sizeCol];
    [_fileTable addTableColumn:dateCol];
    _fileTable.dataSource = self;
    _fileTable.delegate = self;
    _fileTable.target = self;
    _fileTable.doubleAction = @selector(fileTableDoubleClicked:);
    _fileTable.usesAlternatingRowBackgroundColors = YES;
    _fileTable.menu = [self buildContextMenuForTable:YES];
    _fileTable.menu.delegate = self;

    NSScrollView *tableScroll = [[NSScrollView alloc] init];
    tableScroll.translatesAutoresizingMaskIntoConstraints = NO;
    tableScroll.documentView = _fileTable;
    tableScroll.hasVerticalScroller = YES;
    tableScroll.autohidesScrollers = YES;

    [split addSubview:outlineScroll];
    [split addSubview:tableScroll];
    [split setHoldingPriority:NSLayoutPriorityDefaultLow forSubviewAtIndex:0];

    // Guarantee both panes stay visible even if the one-shot initial divider
    // placement below ends up running before the panel has a real width (it
    // reads self.bounds, which can still be 0×0 the first time this fires —
    // e.g. NPPN_READY racing the window's layout pass). Without a floor,
    // that produces a divider position of 0, which silently collapses the
    // outline (or, depending on host clamping, the file list) to zero width
    // — outwardly indistinguishable from "the file list doesn't work".
    outlineScroll.translatesAutoresizingMaskIntoConstraints = NO;
    tableScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [outlineScroll addConstraint:[NSLayoutConstraint constraintWithItem:outlineScroll
        attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationGreaterThanOrEqual
        toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:70]];
    [tableScroll addConstraint:[NSLayoutConstraint constraintWithItem:tableScroll
        attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationGreaterThanOrEqual
        toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:120]];

    NSDictionary *rootViews = NSDictionaryOfVariableBindings(toolbar, split);
    [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[toolbar]|" options:0 metrics:nil views:rootViews]];
    [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[split]|" options:0 metrics:nil views:rootViews]];
    [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[toolbar(32)][split]|" options:0 metrics:nil views:rootViews]];

    // Give the tree a sensible initial share of the split. Best-effort only
    // (see min-width constraints above for the actual visibility guarantee);
    // retry once more shortly after in case the panel still had no real
    // width on the first pass.
    __weak NSSplitView *weakSplit = split;
    __weak FinderPanelView *weakSelf = self;
    void (^placeDivider)(void) = ^{
        NSSplitView *s = weakSplit;
        FinderPanelView *strongSelf = weakSelf;
        if (!s || !strongSelf || strongSelf.bounds.size.width < 1) return;
        [s setPosition:strongSelf.bounds.size.width * 0.4 ofDividerAtIndex:0];
    };
    dispatch_async(dispatch_get_main_queue(), placeDivider);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), placeDivider);
}

/// Builds a flat, borderless toolbar button using an SF Symbol. SF Symbol
/// images returned by +imageWithSystemSymbolName: are template images by
/// default, so AppKit tints them to match the current appearance (dark/light)
/// automatically — no separate asset pair needed, unlike the main toolbar
/// icon shipped in resources/.
///
/// (This plugin briefly shipped a custom-PNG version of these 5 buttons —
/// see CHANGELOG 1.3.0 — but the hand-drawn glyphs didn't reach a consistent
/// height across icons and looked worse than the SF Symbols they replaced,
/// even after two rounds of trying to fix the sizing. Reverted back to SF
/// Symbols on user feedback; keep this as the panel-icon approach going
/// forward unless there's a real design reason to revisit it.)
- (NSButton *)toolbarButtonWithSymbol:(NSString *)symbolName tooltip:(NSString *)tooltip action:(SEL)action {
    NSButton *b = [[NSButton alloc] init];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    NSImage *img = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:tooltip];
    if (img) {
        NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:13
                                                                                          weight:NSFontWeightRegular];
        img = [img imageWithSymbolConfiguration:cfg];
    }
    b.image = img;
    b.imagePosition = NSImageOnly;
    b.imageScaling = NSImageScaleProportionallyDown;
    b.bezelStyle = NSBezelStyleTexturedRounded;
    b.bordered = NO;
    b.toolTip = tooltip;
    b.target = self;
    b.action = action;
    return b;
}

#pragma mark - Localization

/// Re-applies FDLoc(...) text everywhere the language can be baked into a
/// created-once object (tooltips, column titles, popup/menu item titles,
/// search field placeholder). Invoked live via
/// +[FinderLocalization observeLanguageChangesWithBlock:] — see
/// -initWithFrame:. Dialog/alert strings need no such refresh since they're
/// built fresh (via FDLoc) each time they're shown.
- (void)relocalizeUI {
    _upButton.toolTip = FDLoc(@"Übergeordneter Ordner", @"Parent Folder");
    _homeButton.toolTip = FDLoc(@"Home-Verzeichnis", @"Home Directory");
    _locateButton.toolTip = FDLoc(@"Aktuelle Datei anzeigen", @"Locate Current File");
    [self updateHiddenButton];
    _newFolderButton.toolTip = FDLoc(@"Neuer Ordner", @"New Folder");
    _newFileButton.toolTip = FDLoc(@"Neue Datei", @"New File");
    _searchField.placeholderString = FDLoc(@"Filter", @"Filter");

    for (NSTableColumn *col in _outlineView.tableColumns) {
        if ([col.identifier isEqualToString:@"name"]) col.title = FDLoc(@"Ordner", @"Folder");
    }
    for (NSTableColumn *col in _fileTable.tableColumns) {
        if ([col.identifier isEqualToString:@"name"]) col.title = FDLoc(@"Name", @"Name");
        else if ([col.identifier isEqualToString:@"size"]) col.title = FDLoc(@"Größe", @"Size");
        else if ([col.identifier isEqualToString:@"date"]) col.title = FDLoc(@"Geändert", @"Modified");
    }

    [self rebuildRootPopUp]; // re-adds items with the current-language "choose a folder" sentinel; preserves selection

    _outlineView.menu = [self buildContextMenuForTable:NO];
    _outlineView.menu.delegate = self;
    _fileTable.menu = [self buildContextMenuForTable:YES];
    _fileTable.menu.delegate = self;
}

#pragma mark - Hidden files

/// Syncs the toggle button's icon and tooltip with the persisted state. The
/// icon shows the current state (eye = hidden files visible); the tooltip
/// names the action a click performs.
- (void)updateHiddenButton {
    BOOL show = [FinderPreferences shared].showHiddenFiles;
    NSString *tooltip = show ? FDLoc(@"Versteckte Dateien ausblenden", @"Hide Hidden Files")
                             : FDLoc(@"Versteckte Dateien anzeigen", @"Show Hidden Files");
    NSImage *img = [NSImage imageWithSystemSymbolName:(show ? @"eye" : @"eye.slash")
                             accessibilityDescription:tooltip];
    if (img) {
        img = [img imageWithSymbolConfiguration:
            [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular]];
    }
    _hiddenButton.image = img;
    _hiddenButton.toolTip = tooltip;
}

- (void)toggleShowHidden:(id)sender {
    FinderPreferences *prefs = [FinderPreferences shared];
    prefs.showHiddenFiles = !prefs.showHiddenFiles;
    [prefs save];
    [self updateHiddenButton];

    [_childCache removeAllObjects];
    [self reloadOutline];
    [self reloadListForPath:_currentListPath];
    [self expandTreeToDirectory:_currentListPath];
}

#pragma mark - Outline reload helper

/// Re-queries the outline's data (top level, plus every currently-expanded
/// descendant, since NSOutlineView tracks expansion by item -isEqual:, which
/// -reloadData preserves for our path-string items — same effect as
/// -reloadItem:reloadChildren: without its downside below) and forces a full
/// re-tile of row/column geometry. Call after invalidating _childCache
/// entries: new root (Home/Computer/goUp) *and* in-place changes (new file/
/// folder, rename, trash) alike.
///
/// Originally this used -reloadItem:nil reloadChildren:YES, which re-queries
/// data but doesn't force NSOutlineView to re-tile its cached row/column
/// widths. That left stale, effectively-zero-width cell views on screen —
/// outwardly indistinguishable from "the folder names are just gone" — for
/// *any* data change, not just a root swap (confirmed via "New Folder" too).
/// Something else (e.g. manually dragging the split divider) forcing an
/// unrelated layout pass was the only thing that papered over it.
- (void)reloadOutline {
    [_outlineView reloadData];
    [_outlineView setNeedsLayout:YES];
    [_outlineView.enclosingScrollView setNeedsLayout:YES];
    [self setNeedsLayout:YES];
}

#pragma mark - Root selection

- (void)rebuildRootPopUp {
    [_rootPopUp removeAllItems];
    [_rootPopUp addItemWithTitle:@"🏠 Home"];
    [_rootPopUp addItemWithTitle:@"💻 Computer"];

    for (NSString *fav in [FinderPreferences shared].favoritePaths) {
        [_rootPopUp addItemWithTitle:[NSString stringWithFormat:@"★ %@", fav.lastPathComponent]];
        ((NSMenuItem *)_rootPopUp.itemArray.lastObject).representedObject = fav;
    }

    NSArray<NSURL *> *volumes = [[NSFileManager defaultManager]
        mountedVolumeURLsIncludingResourceValuesForKeys:nil
        options:NSVolumeEnumerationSkipHiddenVolumes];
    for (NSURL *vol in volumes) {
        NSString *path = vol.path;
        if ([path isEqualToString:@"/"]) continue; // already covered by "Computer"
        [_rootPopUp addItemWithTitle:[NSString stringWithFormat:@"💾 %@" , path.lastPathComponent]];
        ((NSMenuItem *)_rootPopUp.itemArray.lastObject).representedObject = path;
    }

    [_rootPopUp addItemWithTitle:ChooseFolderTitle()];

    [_rootPopUp itemWithTitle:@"🏠 Home"].representedObject = NSHomeDirectory();
    [_rootPopUp itemWithTitle:@"💻 Computer"].representedObject = @"/";
    [self syncRootPopUpSelection];
}

- (void)syncRootPopUpSelection {
    for (NSMenuItem *item in _rootPopUp.itemArray) {
        if ([item.representedObject isEqual:_rootPath]) {
            [_rootPopUp selectItem:item];
            return;
        }
    }
}

- (void)rootPopUpChanged:(id)sender {
    NSMenuItem *item = _rootPopUp.selectedItem;
    if ([item.title isEqualToString:ChooseFolderTitle()]) {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseDirectories = YES;
        panel.canChooseFiles = NO;
        panel.allowsMultipleSelection = NO;
        [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
            if (result == NSModalResponseOK && panel.URL) {
                [self setRootPath:panel.URL.path];
            } else {
                [self syncRootPopUpSelection];
            }
        }];
        return;
    }
    NSString *path = item.representedObject;
    if (path) [self setRootPath:path];
}

- (void)setRootPath:(NSString *)path {
    _rootPath = path;
    [FinderPreferences shared].lastRootPath = path;
    [[FinderPreferences shared] save];
    [_childCache removeAllObjects];
    [self reloadOutline];
    [self reloadListForPath:path];
    [self syncRootPopUpSelection];
}

#pragma mark - Public API

- (NSString *)currentRootPath {
    return _rootPath;
}

- (void)navigateToPath:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    BOOL exists = [fm fileExistsAtPath:path isDirectory:&isDir];
    if (!exists) return;

    NSString *dirToShow = isDir ? path : [path stringByDeletingLastPathComponent];

    // The target lives inside a hidden folder (e.g. ~/.config/...) but hidden
    // entries are filtered out, so the tree could never reach it. Switch the
    // option on (and persist it, like a manual toggle) rather than silently
    // stopping at the last visible ancestor.
    if (![FinderPreferences shared].showHiddenFiles) {
        NSString *relativeToRoot = [dirToShow hasPrefix:_rootPath] ? [dirToShow substringFromIndex:_rootPath.length] : dirToShow;
        for (NSString *comp in relativeToRoot.pathComponents) {
            if (FinderIsHiddenName(comp)) {
                [FinderPreferences shared].showHiddenFiles = YES;
                [[FinderPreferences shared] save];
                [self updateHiddenButton];
                [_childCache removeAllObjects];
                [self reloadOutline];
                break;
            }
        }
    }

    if (![dirToShow hasPrefix:_rootPath]) {
        // Target isn't reachable from the current root — fall back to
        // "Computer" (filesystem root) so the tree can always reach it.
        [self setRootPath:@"/"];
    }

    [self expandTreeToDirectory:dirToShow];
    [self reloadListForPath:dirToShow];

    if (!isDir) {
        [self selectAndScrollToEntryNamed:path.lastPathComponent inTable:_fileTable];
    }
}

- (void)revealAndSelectPath:(NSString *)path {
    [self navigateToPath:path];
    [self.window makeKeyAndOrderFront:nil];
}

#pragma mark - Tree expand-to-path

- (void)expandTreeToDirectory:(NSString *)dirPath {
    if ([dirPath isEqualToString:_rootPath]) return;

    NSString *relative = [dirPath substringFromIndex:_rootPath.length];
    NSArray<NSString *> *components = [relative pathComponents];
    NSString *runningPath = _rootPath;
    id parentItem = nil;

    for (NSString *comp in components) {
        if ([comp isEqualToString:@"/"] || comp.length == 0) continue;
        runningPath = [runningPath stringByAppendingPathComponent:comp];

        NSArray<NSString *> *siblings = parentItem ? [self childrenOfItem:parentItem]
                                                    : [self childrenOfItem:nil];
        if (![siblings containsObject:runningPath]) return; // e.g. hidden folder while "Show Hidden Files" is off — stop here

        [_outlineView expandItem:parentItem];
        parentItem = runningPath;
        [_outlineView expandItem:parentItem];
    }

    NSInteger row = [_outlineView rowForItem:parentItem];
    if (row >= 0) {
        [_outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        [_outlineView scrollRowToVisible:row];
    }
}

#pragma mark - Outline data source (folders only, rooted at _rootPath)

- (NSArray<NSString *> *)childrenOfItem:(id)item {
    NSString *dir = item ?: _rootPath;
    NSArray<NSString *> *cached = _childCache[dir];
    if (cached) return cached;
    NSArray<NSString *> *children = FinderSubdirectories(dir, [FinderPreferences shared].showHiddenFiles);
    _childCache[dir] = children;
    return children;
}

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
    return [self childrenOfItem:item].count;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
    return [self childrenOfItem:item][index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    return [self childrenOfItem:item].count > 0;
}

- (nullable NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)tableColumn item:(id)item {
    NSString *path = item;
    NSTableCellView *cell = [[NSTableCellView alloc] init];
    NSImageView *iv = [[NSImageView alloc] init];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.image = [[NSWorkspace sharedWorkspace] iconForFile:path];

    NSTextField *tf = [NSTextField new];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.stringValue = path.lastPathComponent;
    tf.editable = NO;
    tf.bordered = NO;
    tf.drawsBackground = NO;

    [cell addSubview:iv];
    [cell addSubview:tf];
    cell.imageView = iv;
    cell.textField = tf;

    NSDictionary *v = NSDictionaryOfVariableBindings(iv, tf);
    [cell addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-2-[iv(16)]-4-[tf]-2-|" options:0 metrics:nil views:v]];
    [cell addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-1-[iv(16)]" options:0 metrics:nil views:v]];
    [cell addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[tf]|" options:0 metrics:nil views:v]];
    return cell;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    id item = [_outlineView itemAtRow:_outlineView.selectedRow];
    NSString *path = item ?: _rootPath;
    [self reloadListForPath:path];
}

- (void)outlineDoubleClicked:(id)sender {
    NSInteger row = _outlineView.clickedRow;
    if (row < 0) return;
    [_outlineView expandItem:[_outlineView itemAtRow:row]];
}

#pragma mark - File list

- (void)reloadListForPath:(NSString *)path {
    _currentListPath = path;
    _currentListEntries = FinderListEntries(path, [FinderPreferences shared].showHiddenFiles);
    [self applySearchFilter];
}

- (void)applySearchFilter {
    NSString *query = _searchField.stringValue;
    if (query.length == 0) {
        _filteredListEntries = _currentListEntries;
    } else {
        NSMutableArray<NSString *> *filtered = [NSMutableArray array];
        for (NSString *p in _currentListEntries) {
            if ([p.lastPathComponent rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [filtered addObject:p];
            }
        }
        _filteredListEntries = filtered;
    }
    [_fileTable reloadData];
}

- (void)searchChanged:(id)sender {
    [self applySearchFilter];
}

/// NSTextFieldDelegate (NSSearchField inherits it) — fires on every
/// keystroke so the file list filters live, not just on Enter/clear like
/// the plain .action would.
- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == _searchField) {
        [self applySearchFilter];
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _filteredListEntries.count;
}

- (nullable NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSString *path = _filteredListEntries[row];
    NSFileManager *fm = [NSFileManager defaultManager];

    if ([tableColumn.identifier isEqualToString:@"name"]) {
        NSTableCellView *cell = [[NSTableCellView alloc] init];
        NSImageView *iv = [[NSImageView alloc] init];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        iv.image = [[NSWorkspace sharedWorkspace] iconForFile:path];
        NSTextField *tf = [NSTextField new];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.stringValue = path.lastPathComponent;
        tf.editable = NO;
        tf.bordered = NO;
        tf.drawsBackground = NO;
        [cell addSubview:iv];
        [cell addSubview:tf];
        cell.imageView = iv;
        cell.textField = tf;
        NSDictionary *v = NSDictionaryOfVariableBindings(iv, tf);
        [cell addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-2-[iv(16)]-4-[tf]-2-|" options:0 metrics:nil views:v]];
        [cell addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-1-[iv(16)]" options:0 metrics:nil views:v]];
        [cell addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[tf]|" options:0 metrics:nil views:v]];
        return cell;
    }

    NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:path error:nil];
    NSTableCellView *cell = [[NSTableCellView alloc] init];
    NSTextField *tf = [NSTextField new];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.editable = NO;
    tf.bordered = NO;
    tf.drawsBackground = NO;
    tf.alignment = NSTextAlignmentRight;

    if ([tableColumn.identifier isEqualToString:@"size"]) {
        BOOL isDir = [attrs[NSFileType] isEqualToString:NSFileTypeDirectory];
        if (isDir) {
            tf.stringValue = @"--";
        } else {
            unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
            tf.stringValue = [NSByteCountFormatter stringFromByteCount:(long long)size
                                                             countStyle:NSByteCountFormatterCountStyleFile];
        }
    } else if ([tableColumn.identifier isEqualToString:@"date"]) {
        NSDate *date = attrs[NSFileModificationDate];
        if (date) {
            static NSDateFormatter *df;
            if (!df) {
                df = [[NSDateFormatter alloc] init];
                df.dateStyle = NSDateFormatterShortStyle;
                df.timeStyle = NSDateFormatterShortStyle;
            }
            tf.stringValue = [df stringFromDate:date];
        }
    }

    [cell addSubview:tf];
    [cell addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-2-[tf]-2-|" options:0 metrics:nil views:@{@"tf": tf}]];
    [cell addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[tf]|" options:0 metrics:nil views:@{@"tf": tf}]];
    return cell;
}

- (void)fileTableDoubleClicked:(id)sender {
    NSInteger row = _fileTable.clickedRow;
    if (row < 0 || row >= (NSInteger)_filteredListEntries.count) return;
    [self openOrNavigateToEntry:_filteredListEntries[row]];
}

- (void)openOrNavigateToEntry:(NSString *)path {
    BOOL isDir = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
    if (isDir) {
        [self navigateToPath:path];
    } else {
        [self.delegate finderPanelView:self openFileAtPath:path];
    }
}

- (void)selectAndScrollToEntryNamed:(NSString *)name inTable:(NSTableView *)table {
    for (NSUInteger i = 0; i < _filteredListEntries.count; i++) {
        if ([_filteredListEntries[i].lastPathComponent isEqualToString:name]) {
            [table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
            [table scrollRowToVisible:i];
            return;
        }
    }
}

#pragma mark - Toolbar actions

- (void)goUp:(id)sender {
    NSString *parent = [_currentListPath stringByDeletingLastPathComponent];
    if (parent.length == 0) return;
    [self navigateToPath:parent];
}

- (void)goHome:(id)sender {
    [self setRootPath:NSHomeDirectory()];
}

- (void)locateCurrentFile:(id)sender {
    // The view has no reference to nppData/the active buffer path by design
    // (keeps it independent of the plugin ABI) — it asks the delegate
    // (FinderPlugin), which knows the current file and calls back into
    // -revealAndSelectPath: with it.
    if ([self.delegate respondsToSelector:@selector(finderPanelViewDidRequestLocateCurrentFile:)]) {
        [self.delegate finderPanelViewDidRequestLocateCurrentFile:self];
    }
}

- (void)createNewFolder:(id)sender {
    NSError *error = nil;
    NSString *newPath = [FinderFileOperations createNewFolderInDirectory:_currentListPath error:&error];
    if (!newPath) {
        [self showAlertForError:error];
        return;
    }
    [self reloadListForPath:_currentListPath];
    [_childCache removeObjectForKey:_currentListPath];
    [self reloadOutline];
    [self selectAndScrollToEntryNamed:newPath.lastPathComponent inTable:_fileTable];
    [self promptRenameForPath:newPath];
}

- (void)createNewFile:(id)sender {
    NSError *error = nil;
    NSString *newPath = [FinderFileOperations createNewFileInDirectory:_currentListPath error:&error];
    if (!newPath) {
        [self showAlertForError:error];
        return;
    }
    [self reloadListForPath:_currentListPath];
    [self selectAndScrollToEntryNamed:newPath.lastPathComponent inTable:_fileTable];
    [self promptRenameForPath:newPath];
}

- (void)showAlertForError:(NSError *)error {
    if (!error) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = FDLoc(@"Aktion fehlgeschlagen", @"Action Failed");
    alert.informativeText = error.localizedDescription;
    [alert runModal];
}

#pragma mark - Context menu

- (NSMenu *)buildContextMenuForTable:(BOOL)isFileTable {
    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:FDLoc(@"Öffnen", @"Open") action:@selector(menuOpen:) keyEquivalent:@""].target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:FDLoc(@"In Finder anzeigen", @"Reveal in Finder") action:@selector(menuRevealInFinder:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:FDLoc(@"Im Terminal öffnen", @"Open in Terminal") action:@selector(menuOpenTerminal:) keyEquivalent:@""].target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:FDLoc(@"Neuer Ordner", @"New Folder") action:@selector(menuNewFolder:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:FDLoc(@"Neue Datei", @"New File") action:@selector(menuNewFile:) keyEquivalent:@""].target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:FDLoc(@"Umbenennen…", @"Rename…") action:@selector(menuRename:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:FDLoc(@"Duplizieren", @"Duplicate") action:@selector(menuDuplicate:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:FDLoc(@"In den Papierkorb legen", @"Move to Trash") action:@selector(menuTrash:) keyEquivalent:@""].target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:FDLoc(@"Pfad kopieren", @"Copy Path") action:@selector(menuCopyPath:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:FDLoc(@"Name kopieren", @"Copy Name") action:@selector(menuCopyName:) keyEquivalent:@""].target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:FDLoc(@"Als Favorit hinzufügen", @"Add to Favorites") action:@selector(menuAddFavorite:) keyEquivalent:@""].target = self;
    return menu;
}

/// Resolves which path the context menu should act on, depending on which
/// view was last clicked (outline row vs. table row).
- (nullable NSString *)contextMenuTargetPath {
    if (_fileTable.clickedRow >= 0 && _fileTable.clickedRow < (NSInteger)_filteredListEntries.count) {
        return _filteredListEntries[_fileTable.clickedRow];
    }
    NSInteger outlineRow = _outlineView.clickedRow;
    if (outlineRow >= 0) {
        return [_outlineView itemAtRow:outlineRow];
    }
    return _currentListPath;
}

- (void)menuOpen:(id)sender {
    NSString *path = [self contextMenuTargetPath];
    if (path) [self openOrNavigateToEntry:path];
}

- (void)menuRevealInFinder:(id)sender {
    NSString *path = [self contextMenuTargetPath] ?: _currentListPath;
    [FinderFileOperations revealInFinder:path];
}

- (void)menuOpenTerminal:(id)sender {
    NSString *path = [self contextMenuTargetPath] ?: _currentListPath;
    [FinderFileOperations openTerminalAtPath:path];
}

- (void)menuNewFolder:(id)sender { [self createNewFolder:sender]; }
- (void)menuNewFile:(id)sender { [self createNewFile:sender]; }

- (void)menuRename:(id)sender {
    NSString *path = [self contextMenuTargetPath];
    if (path) [self promptRenameForPath:path];
}

- (void)promptRenameForPath:(NSString *)path {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = FDLoc(@"Umbenennen", @"Rename");
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    input.stringValue = path.lastPathComponent;
    alert.accessoryView = input;
    [alert addButtonWithTitle:FDLoc(@"OK", @"OK")];
    [alert addButtonWithTitle:FDLoc(@"Abbrechen", @"Cancel")];
    NSModalResponse response = [alert runModal];
    if (response != NSAlertFirstButtonReturn) return;

    NSError *error = nil;
    NSString *newPath = [FinderFileOperations renameItemAtPath:path toName:input.stringValue error:&error];
    if (!newPath) {
        [self showAlertForError:error];
        return;
    }
    [_childCache removeObjectForKey:_currentListPath];
    [self reloadOutline];
    [self reloadListForPath:_currentListPath];
}

- (void)menuDuplicate:(id)sender {
    NSString *path = [self contextMenuTargetPath];
    if (!path) return;
    NSError *error = nil;
    NSString *newPath = [FinderFileOperations duplicateItemAtPath:path error:&error];
    if (!newPath) {
        [self showAlertForError:error];
        return;
    }
    [self reloadListForPath:_currentListPath];
}

- (void)menuTrash:(id)sender {
    NSString *path = [self contextMenuTargetPath];
    if (!path) return;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:FDLoc(@"\"%@\" in den Papierkorb legen?", @"Move \"%@\" to Trash?"),
                          path.lastPathComponent];
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:FDLoc(@"In den Papierkorb legen", @"Move to Trash")];
    [alert addButtonWithTitle:FDLoc(@"Abbrechen", @"Cancel")];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSError *error = nil;
    if (![FinderFileOperations moveItemToTrash:path error:&error]) {
        [self showAlertForError:error];
        return;
    }
    [_childCache removeObjectForKey:_currentListPath];
    [self reloadOutline];
    [self reloadListForPath:_currentListPath];
}

- (void)menuCopyPath:(id)sender {
    NSString *path = [self contextMenuTargetPath];
    if (path) [FinderFileOperations copyPathToPasteboard:path];
}

- (void)menuCopyName:(id)sender {
    NSString *path = [self contextMenuTargetPath];
    if (path) [FinderFileOperations copyNameToPasteboard:path];
}

- (void)menuAddFavorite:(id)sender {
    NSString *path = [self contextMenuTargetPath];
    if (!path) return;
    BOOL isDir = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
    NSString *folder = isDir ? path : [path stringByDeletingLastPathComponent];
    [[FinderPreferences shared] addFavoritePath:folder];
    [self rebuildRootPopUp];
}

@end
