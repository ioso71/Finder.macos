/*
 * FinderPlugin.mm — plugin entry point for the Nextpad++ macOS "Finder"
 * plugin (a folder-tree / file-list sidebar with Finder integration,
 * modeled on the Windows npp-explorer-plugin).
 *
 * This file owns the 5 mandatory C exports (setInfo, getName,
 * getFuncsArray, beNotified, messageProc) and a small ObjC controller
 * singleton that bridges the plugin ABI to FinderPanelView.
 *
 * ─────────────────────────────────────────────────────────────────────────
 * VERSION — single source of truth for this plugin's version number.
 * On every change, bump this AND the version line in README.md, and add
 * an entry to CHANGELOG.md:
 *   - Bugfix / small change   → patch (ZZ):  1.1.0 → 1.1.1
 *   - Feature / medium change → minor (Y):   1.0.10 → 1.1.0
 *   - Breaking change         → major (XX):  1.9.0 → 2.0.0
 * ───────────────────────────────────────────────────────────────────────── */
#define FINDER_PLUGIN_VERSION "1.4.0"

#import <Cocoa/Cocoa.h>
#include <string.h>

#include "NppPluginInterfaceMac.h"
#import "FinderPanelView.h"
#import "FinderPreferences.h"
#import "FinderFileOperations.h"
#import "FinderLocalization.h"

/* ─────────────────────────────────────────────────────────────────────────
 * SCNotification — minimal local mirror.
 *
 * NppPluginInterfaceMac.h only forward-declares `struct SCNotification`
 * (it deliberately doesn't pull in Scintilla.h, and neither do we — this
 * plugin project has no dependency on the host's scintilla/ tree). We only
 * ever read notifyCode->nmhdr.code, so we complete the forward declaration
 * with just that leading member. Its layout matches the real
 * scintilla/include/Scintilla.h SCNotification for this shared prefix,
 * which is all that's read here; nothing past nmhdr is touched.
 * ───────────────────────────────────────────────────────────────────────── */
extern "C" {
struct SCNotification {
    struct {
        void         *hwndFrom;
        uintptr_t     idFrom;
        unsigned int  code;
    } nmhdr;
    /* Remaining SCN_* payload fields intentionally omitted — not read by
       this plugin. Do not add field access here without vendoring the
       full struct layout from Scintilla.h. */
};
}

NppData nppData;

/* ─────────────────────────────────────────────────────────────────────────
 * Menu command table — declared up here (ahead of the controller) so that
 * -relocalizeMenuItems below can read gFuncItems[i]._cmdID without a
 * forward declaration. Populated by setInfo(); see bottom of file for the
 * localized name strings.
 * ───────────────────────────────────────────────────────────────────────── */
#define FINDER_FUNC_COUNT 3
static FuncItem gFuncItems[FINDER_FUNC_COUNT];

/// Localized menu item text, indexed the same way as gFuncItems.
static NSString *LocalizedFuncItemName(int idx) {
    switch (idx) {
        case 0: return FDLoc(@"Finder-Panel ein-/ausblenden", @"Toggle Finder Panel");
        case 1: return FDLoc(@"Aktuelle Datei im Finder-Panel anzeigen", @"Locate Current File in Finder Panel");
        case 2: return FDLoc(@"Aktuelle Datei im macOS Finder zeigen", @"Reveal Current File in macOS Finder");
        default: return @"";
    }
}

/// Recursively searches `menu` for an NSMenuItem with the given tag. The
/// host builds its Plugins menu (and Tahoe's flattened variants) as nested
/// NSMenus, so a single top-level scan isn't enough.
static NSMenuItem *FindMenuItemWithTag(NSMenu *menu, NSInteger tag) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.tag == tag) return item;
        if (item.submenu) {
            NSMenuItem *found = FindMenuItemWithTag(item.submenu, tag);
            if (found) return found;
        }
    }
    return nil;
}

/* ─────────────────────────────────────────────────────────────────────────
 * Controller: owns the panel view, the docking handle, and everything that
 * needs to talk back to the host via nppData._sendMessage.
 * ───────────────────────────────────────────────────────────────────────── */
@interface FinderPluginController : NSObject <FinderPanelViewDelegate>
+ (instancetype)shared;
- (void)handleReady;
- (void)handleBeforeShutdown;
- (void)togglePanel;
- (void)locateCurrentFileAction;
- (void)revealCurrentFileInFinderAction;
- (void)relocalizeMenuItems;
@end

@implementation FinderPluginController {
    FinderPanelView *_panelView;
    uintptr_t _panelHandle;
    BOOL _panelVisible;
}

+ (instancetype)shared {
    static FinderPluginController *sInstance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sInstance = [[FinderPluginController alloc] init]; });
    return sInstance;
}

/// Reads the active buffer's full path via NPPM_GETFULLCURRENTPATH.
/// Returns nil if there is no active/unsaved-untitled buffer.
- (nullable NSString *)currentFilePath {
    char buf[1024] = {0};
    nppData._sendMessage(nppData._nppHandle, NPPM_GETFULLCURRENTPATH, 0, (intptr_t)buf);
    if (buf[0] == '\0') return nil;
    return [NSString stringWithUTF8String:buf];
}

- (void)ensurePanelCreated {
    if (_panelView) return;

    char configBuf[1024] = {0};
    nppData._sendMessage(nppData._nppHandle, NPPM_GETPLUGINSCONFIGDIR, 1024, (intptr_t)configBuf);
    if (configBuf[0] != '\0') {
        [[FinderPreferences shared] configureWithConfigDirectory:[NSString stringWithUTF8String:configBuf]];
    }

    _panelView = [[FinderPanelView alloc] initWithFrame:NSMakeRect(0, 0, 260, 400)];
    _panelView.delegate = self;

    uintptr_t handle = (uintptr_t)nppData._sendMessage(
        nppData._nppHandle, NPPM_DMM_REGISTERPANEL,
        (uintptr_t)(__bridge void *)_panelView, (intptr_t)"Finder");
    _panelHandle = handle;

    // TEMP DIAGNOSTIC LOGGING — remove once panel visibility is confirmed
    // working end-to-end. Logs unconditionally (not just on failure) so we
    // can see in Console.app / stdout exactly what handle we got back.
    NSLog(@"[Finder] ensurePanelCreated: REGISTERPANEL returned handle=%lu", (unsigned long)_panelHandle);

    if (_panelHandle == 0) {
        NSLog(@"[Finder] NPPM_DMM_REGISTERPANEL failed — host may predate panel docking support (< 1.0.3). Panel will not be available.");
    }
}

- (void)handleReady {
    [self ensurePanelCreated];

    // Live menu relabeling: the plugin-ABI's NPPN_NATIVELANGCHANGED /
    // NPPM_GETNATIVELANGFILENAME hooks are declared but never wired up on
    // macOS (same limitation as FuncItem._pShKey — see project memory), so
    // instead we piggy-back on the host's own "NPPLocalizationChanged"
    // notification and relabel our NSMenuItems by tag directly. Registered
    // once here; the block re-reads the language each time it fires.
    [FinderLocalization observeLanguageChangesWithBlock:^{
        [[FinderPluginController shared] relocalizeMenuItems];
    }];

    if (!_panelHandle) return;

    // Deferred by one runloop tick: NPPN_READY can fire before the main
    // window's split-view geometry has settled (first launch), which made
    // NPPM_DMM_SHOWPANEL "succeed" (return 1) while the panel ended up at
    // effectively zero width — outwardly indistinguishable from "not shown",
    // and only fixed itself once the user's own toggle click forced a fresh
    // layout pass. Waiting a tick avoids relying on that side effect.
    dispatch_async(dispatch_get_main_queue(), ^{
        // Show by default so the plugin is immediately useful after
        // install, matching the Windows Explorer plugin's default-on
        // behavior. Users can hide it via the toggle menu command.
        intptr_t result = nppData._sendMessage(nppData._nppHandle, NPPM_DMM_SHOWPANEL, self->_panelHandle, 0);
        NSLog(@"[Finder] handleReady: SHOWPANEL returned %ld", (long)result);
        self->_panelVisible = (result != 0);
    });
}

- (void)relocalizeMenuItems {
    for (int i = 0; i < FINDER_FUNC_COUNT; i++) {
        NSString *title = LocalizedFuncItemName(i);
        // Keep the ABI-side buffer in sync too, in case the host ever reads
        // _itemName again after startup (e.g. rebuilding a menu/toolbar).
        strlcpy(gFuncItems[i]._itemName, title.UTF8String, NPP_MENU_ITEM_SIZE);

        NSMenuItem *item = FindMenuItemWithTag(NSApp.mainMenu, (NSInteger)gFuncItems[i]._cmdID);
        if (item) item.title = title;
    }
}

- (void)handleBeforeShutdown {
    if (_panelHandle) {
        nppData._sendMessage(nppData._nppHandle, NPPM_DMM_UNREGISTERPANEL, _panelHandle, 0);
        _panelHandle = 0;
    }
    [[FinderPreferences shared] save];
}

- (void)togglePanel {
    [self ensurePanelCreated];
    NSLog(@"[Finder] togglePanel: _panelHandle=%lu _panelVisible=%d", (unsigned long)_panelHandle, _panelVisible);
    if (!_panelHandle) return;

    intptr_t result;
    if (_panelVisible) {
        result = nppData._sendMessage(nppData._nppHandle, NPPM_DMM_HIDEPANEL, _panelHandle, 0);
        NSLog(@"[Finder] togglePanel: HIDEPANEL returned %ld", (long)result);
    } else {
        result = nppData._sendMessage(nppData._nppHandle, NPPM_DMM_SHOWPANEL, _panelHandle, 0);
        NSLog(@"[Finder] togglePanel: SHOWPANEL returned %ld", (long)result);
    }
    _panelVisible = !_panelVisible;
}

- (void)locateCurrentFileAction {
    [self ensurePanelCreated];
    NSString *path = [self currentFilePath];
    if (!path) return;

    if (!_panelVisible && _panelHandle) {
        nppData._sendMessage(nppData._nppHandle, NPPM_DMM_SHOWPANEL, _panelHandle, 0);
        _panelVisible = YES;
    }
    [_panelView revealAndSelectPath:path];
}

- (void)revealCurrentFileInFinderAction {
    NSString *path = [self currentFilePath];
    if (!path) return;
    [FinderFileOperations revealInFinder:path];
}

#pragma mark - FinderPanelViewDelegate

- (void)finderPanelView:(FinderPanelView *)view openFileAtPath:(NSString *)path {
    (void)view;
    nppData._sendMessage(nppData._nppHandle, NPPM_DOOPEN, 0, (intptr_t)path.UTF8String);
}

- (void)finderPanelViewDidRequestLocateCurrentFile:(FinderPanelView *)view {
    (void)view;
    [self locateCurrentFileAction];
}

@end

/* ─────────────────────────────────────────────────────────────────────────
 * Plugin command callbacks (must be plain C function pointers — no
 * captured context — hence routing straight into the singleton).
 * ───────────────────────────────────────────────────────────────────────── */

static void Cmd_TogglePanel(void) {
    [[FinderPluginController shared] togglePanel];
}

static void Cmd_LocateCurrentFile(void) {
    [[FinderPluginController shared] locateCurrentFileAction];
}

static void Cmd_RevealCurrentFileInFinder(void) {
    [[FinderPluginController shared] revealCurrentFileInFinderAction];
}

extern "C" {

NPP_EXPORT void setInfo(struct NppData data) {
    nppData = data;

    memset(gFuncItems, 0, sizeof(gFuncItems));

    strlcpy(gFuncItems[0]._itemName, LocalizedFuncItemName(0).UTF8String, NPP_MENU_ITEM_SIZE);
    gFuncItems[0]._pFunc = Cmd_TogglePanel;
    gFuncItems[0]._init2Check = false;

    strlcpy(gFuncItems[1]._itemName, LocalizedFuncItemName(1).UTF8String, NPP_MENU_ITEM_SIZE);
    gFuncItems[1]._pFunc = Cmd_LocateCurrentFile;
    gFuncItems[1]._init2Check = false;

    strlcpy(gFuncItems[2]._itemName, LocalizedFuncItemName(2).UTF8String, NPP_MENU_ITEM_SIZE);
    gFuncItems[2]._pFunc = Cmd_RevealCurrentFileInFinder;
    gFuncItems[2]._init2Check = false;
}

NPP_EXPORT const char *getName(void) {
    return "Finder";
}

NPP_EXPORT struct FuncItem *getFuncsArray(int *nbF) {
    *nbF = FINDER_FUNC_COUNT;
    return gFuncItems;
}

NPP_EXPORT void beNotified(struct SCNotification *notifyCode) {
    if (!notifyCode) return;
    switch (notifyCode->nmhdr.code) {
        case NPPN_READY:
            [[FinderPluginController shared] handleReady];
            // Registers the toolbar/menu-bar icon for the "toggle panel" command.
            // lParam=NULL → host falls back to its default lookup convention
            // (toolbar.png / toolbar_dark.png in the plugin dir or resources/).
            nppData._sendMessage(nppData._nppHandle, NPPM_ADDTOOLBARICON_FORDARKMODE,
                                  (uintptr_t)gFuncItems[0]._cmdID, (intptr_t)NULL);
            break;
        case NPPN_BEFORESHUTDOWN:
            [[FinderPluginController shared] handleBeforeShutdown];
            break;
        default:
            break;
    }
}

NPP_EXPORT intptr_t messageProc(uint32_t Message, uintptr_t wParam, intptr_t lParam) {
    (void)Message;
    (void)wParam;
    (void)lParam;
    return 0;
}

} /* extern "C" */
