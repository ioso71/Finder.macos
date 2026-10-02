#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Tiny JSON-file-backed preferences store for the Finder plugin.
///
/// Deliberately minimal: no third-party JSON/plist libraries are used —
/// NSJSONSerialization (Foundation) is sufficient for the handful of values
/// this plugin needs to remember between sessions.
@interface FinderPreferences : NSObject

+ (instancetype)shared;

/// Must be called once, early (from setInfo/NPPN_READY), with the directory
/// returned by NPPM_GETPLUGINSCONFIGDIR. Preferences are loaded immediately.
- (void)configureWithConfigDirectory:(NSString *)configDir;

/// Root folder the tree/list should show on next launch. Defaults to the
/// user's home directory if never set or if the stored path no longer exists.
@property (nonatomic, copy) NSString *lastRootPath;

/// User-pinned favorite folders (absolute paths), shown above the volume list.
@property (nonatomic, copy) NSArray<NSString *> *favoritePaths;

/// Whether dot-prefixed ("hidden") files and folders are shown in the tree
/// and file list. Defaults to NO.
@property (nonatomic, assign) BOOL showHiddenFiles;

- (void)addFavoritePath:(NSString *)path;
- (void)removeFavoritePath:(NSString *)path;

/// One-shot flag: the panel is force-shown exactly once, on the first launch
/// after install (the "immediately useful" default-on). Every later launch
/// defers to the host's own panel restore (NPPM_DMM_SETPANELINFO), which
/// reopens the panel only if it was visible at quit.
@property (nonatomic) BOOL didShowPanelOnFirstRun;

/// Persists current values to disk immediately. Safe to call often; writes
/// are cheap (small JSON file) and this plugin has no high-frequency callers.
- (void)save;

@end

NS_ASSUME_NONNULL_END
