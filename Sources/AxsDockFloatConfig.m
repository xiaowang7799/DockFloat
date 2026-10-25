#import "AxsDockFloatConfig.h"
#import "AxsDockFloatPreferences.h"

@interface AxsDockFloatConfig ()
@property (atomic, copy) NSDictionary *snapshot;
@property (nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static void axs_dockfloat_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef info) {
    AxsDockFloatConfig *config = (__bridge AxsDockFloatConfig *)observer;
    dispatch_async(config.reloadQueue, ^{
        [config axs_dockfloat_reload];
    });
}

@implementation AxsDockFloatConfig

+ (instancetype)axs_dockfloat_shared {
    static AxsDockFloatConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _reloadQueue = dispatch_queue_create("com.axs.dockfloat.preferences", DISPATCH_QUEUE_SERIAL);
        [self axs_dockfloat_reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, axs_dockfloat_preferencesDidChange,
            (__bridge CFStringRef)AxsDockFloatPreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // Close the window between the first read and observer registration.
        dispatch_async(_reloadQueue, ^{ [self axs_dockfloat_reload]; });
    }
    return self;
}

- (void)axs_dockfloat_reload {
    self.snapshot = axs_dockfloat_readPreferences();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AxsDockFloatPreferencesChanged object:self];
    });
}

- (id)axs_dockfloat_valueForKey:(NSString *)key defaultValue:(id)defaultValue {
    return self.snapshot[key] ?: defaultValue;
}

- (BOOL)axs_dockfloat_isEnabled {
    id value = [self axs_dockfloat_valueForKey:@"enabled" defaultValue:@(NO)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

// Panels clamp these keys; readers still guard against corrupt files.
- (AxsDockFloatMode)axs_dockfloat_mode {
    id value = [self axs_dockfloat_valueForKey:@"mode" defaultValue:@(AxsDockFloatModeFloat)];
    if (![value isKindOfClass:[NSNumber class]]) {
        return AxsDockFloatModeFloat;
    }
    NSInteger mode = [value integerValue];
    return (mode >= AxsDockFloatModeFloat && mode <= AxsDockFloatModeShake)
        ? (AxsDockFloatMode)mode : AxsDockFloatModeFloat;
}

- (double)axs_dockfloat_amplitude {
    id value = [self axs_dockfloat_valueForKey:@"amplitude" defaultValue:@(1.0)];
    if (![value isKindOfClass:[NSNumber class]]) return 1.0;
    double amplitude = [value doubleValue];
    if (!isfinite(amplitude)) return 1.0;
    return fmax(0.2, fmin(3.0, amplitude));
}

- (double)axs_dockfloat_period {
    id value = [self axs_dockfloat_valueForKey:@"period" defaultValue:@(2.0)];
    if (![value isKindOfClass:[NSNumber class]]) return 2.0;
    double period = [value doubleValue];
    if (!isfinite(period)) return 2.0;
    return fmax(0.5, fmin(6.0, period));
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
