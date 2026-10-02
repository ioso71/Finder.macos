#import "FinderPreferences.h"

static NSString *const kPrefsFileName = @"finder-plugin-prefs.json";
static NSString *const kKeyLastRootPath = @"lastRootPath";
static NSString *const kKeyFavoritePaths = @"favoritePaths";
static NSString *const kKeyDidShowPanelOnFirstRun = @"didShowPanelOnFirstRun";
static NSString *const kKeyShowHiddenFiles = @"showHiddenFiles";

@implementation FinderPreferences {
    NSString *_configDir;
    NSString *_lastRootPath;
    NSArray<NSString *> *_favoritePaths;
    BOOL _showHiddenFiles;
    BOOL _configured;
}

@synthesize didShowPanelOnFirstRun = _didShowPanelOnFirstRun;

+ (instancetype)shared {
    static FinderPreferences *sInstance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sInstance = [[FinderPreferences alloc] init];
    });
    return sInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastRootPath = NSHomeDirectory();
        _favoritePaths = @[];
        _configured = NO;
    }
    return self;
}

- (NSString *)prefsFilePath {
    if (!_configDir) return nil;
    return [_configDir stringByAppendingPathComponent:kPrefsFileName];
}

- (void)configureWithConfigDirectory:(NSString *)configDir {
    if (configDir.length == 0) return;
    _configDir = [configDir copy];

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:_configDir isDirectory:&isDir] || !isDir) {
        [fm createDirectoryAtPath:_configDir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    [self load];
    _configured = YES;
}

- (void)load {
    NSString *path = [self prefsFilePath];
    if (!path) return;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return;

    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[Finder] Failed to parse prefs at %@: %@", path, error);
        return;
    }

    NSDictionary *dict = (NSDictionary *)obj;

    NSString *root = dict[kKeyLastRootPath];
    if ([root isKindOfClass:[NSString class]] &&
        [[NSFileManager defaultManager] fileExistsAtPath:root]) {
        _lastRootPath = [root copy];
    }

    id showHidden = dict[kKeyShowHiddenFiles];
    if ([showHidden isKindOfClass:[NSNumber class]]) {
        _showHiddenFiles = [showHidden boolValue];
    }

    NSArray *favs = dict[kKeyFavoritePaths];
    if ([favs isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *cleaned = [NSMutableArray array];
        for (id item in favs) {
            if ([item isKindOfClass:[NSString class]]) {
                [cleaned addObject:item];
            }
        }
        _favoritePaths = [cleaned copy];
    }

    NSNumber *shown = dict[kKeyDidShowPanelOnFirstRun];
    if ([shown isKindOfClass:[NSNumber class]]) {
        _didShowPanelOnFirstRun = shown.boolValue;
    }
}

- (void)save {
    NSString *path = [self prefsFilePath];
    if (!path) return; // not configured yet; nothing to persist to

    NSDictionary *dict = @{
        kKeyLastRootPath: _lastRootPath ?: NSHomeDirectory(),
        kKeyFavoritePaths: _favoritePaths ?: @[],
        kKeyDidShowPanelOnFirstRun: @(_didShowPanelOnFirstRun),
        kKeyShowHiddenFiles: @(_showHiddenFiles),
    };

    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                     options:NSJSONWritingPrettyPrinted
                                                       error:&error];
    if (!data) {
        NSLog(@"[Finder] Failed to serialize prefs: %@", error);
        return;
    }

    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        NSLog(@"[Finder] Failed to write prefs to %@: %@", path, error);
    }
}

- (NSString *)lastRootPath {
    return _lastRootPath;
}

- (void)setLastRootPath:(NSString *)lastRootPath {
    if (lastRootPath.length == 0) return;
    _lastRootPath = [lastRootPath copy];
}

- (BOOL)showHiddenFiles {
    return _showHiddenFiles;
}

- (void)setShowHiddenFiles:(BOOL)showHiddenFiles {
    _showHiddenFiles = showHiddenFiles;
}

- (NSArray<NSString *> *)favoritePaths {
    return _favoritePaths;
}

- (void)setFavoritePaths:(NSArray<NSString *> *)favoritePaths {
    _favoritePaths = [favoritePaths copy] ?: @[];
}

- (void)addFavoritePath:(NSString *)path {
    if (path.length == 0) return;
    if ([_favoritePaths containsObject:path]) return;
    _favoritePaths = [_favoritePaths arrayByAddingObject:path];
    [self save];
}

- (void)removeFavoritePath:(NSString *)path {
    if (![_favoritePaths containsObject:path]) return;
    NSMutableArray<NSString *> *mut = [_favoritePaths mutableCopy];
    [mut removeObject:path];
    _favoritePaths = [mut copy];
    [self save];
}

@end
