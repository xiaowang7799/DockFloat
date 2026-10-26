#import "AxsDockFloatConfig.h"
#import "AxsDockFloatPreferences.h"
#include <math.h>

@interface AxsDockFloatConfig ()
@property (atomic, copy) NSDictionary *snapshot;
@property (nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static NSString *axs_dockfloat_modeKey(AxsDockFloatMode mode) {
    switch (mode) {
        case AxsDockFloatModeFloat:  return @"mode_float";
        case AxsDockFloatModeRoll:   return @"mode_roll";
        case AxsDockFloatModeShake:  return @"mode_shake";
        case AxsDockFloatModeRandom: return @"mode_random";
        case AxsDockFloatModeFish:   return @"mode_fish";
        case AxsDockFloatModeFirefly: return @"mode_firefly";
        case AxsDockFloatModeBreath:  return @"mode_breath";
        case AxsDockFloatModeStream:  return @"mode_stream";
    }
    return @"mode_float";
}

static NSString *axs_dockfloat_amplitudeKeyForMode(AxsDockFloatMode mode) {
    switch (mode) {
        case AxsDockFloatModeFloat:  return @"amplitude_float";
        case AxsDockFloatModeRoll:   return @"amplitude_roll";
        case AxsDockFloatModeShake:  return @"amplitude_shake";
        case AxsDockFloatModeRandom: return @"amplitude_random";
        default: return nil; // Fish/Firefly/Breath/Stream use the global keys
    }
}

static NSString *axs_dockfloat_periodKeyForMode(AxsDockFloatMode mode) {
    switch (mode) {
        case AxsDockFloatModeFloat:  return @"period_float";
        case AxsDockFloatModeRoll:   return @"period_roll";
        case AxsDockFloatModeShake:  return @"period_shake";
        case AxsDockFloatModeRandom: return @"period_random";
        default: return nil;
    }
}

static void axs_dockfloat_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef info) {
    AxsDockFloatConfig *config = (__bridge AxsDockFloatConfig *)observer;
    dispatch_async(config.reloadQueue, ^{
        [config axs_dockfloat_reload];
    });
}

// Default 8-species set, used as fallback when fish_species is not configured.
static NSArray<NSString *> *axs_dockfloat_defaultSpecies(void) {
    static NSArray<NSString *> *species;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        species = @[@"🐟", @"🐠", @"🐡", @"🦈", @"🐙", @"🦀", @"🐢", @"🐬"];
    });
    return species;
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

- (BOOL)axs_dockfloat_isModeActive:(AxsDockFloatMode)mode {
    id value = [self axs_dockfloat_valueForKey:axs_dockfloat_modeKey(mode) defaultValue:@(NO)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

// Panels clamp this key; readers still guard against corrupt files.
- (NSInteger)axs_dockfloat_fishCount {
    id value = [self axs_dockfloat_valueForKey:@"fish_count" defaultValue:@(3)];
    if (![value isKindOfClass:[NSNumber class]]) return 3;
    double count = [value doubleValue];
    if (!isfinite(count)) return 3;
    return (NSInteger)fmax(1.0, fmin(8.0, round(count)));
}

- (double)axs_dockfloat_amplitude {
    id value = [self axs_dockfloat_valueForKey:@"amplitude" defaultValue:@(1.0)];
    if (![value isKindOfClass:[NSNumber class]]) return 1.0;
    double amplitude = [value doubleValue];
    if (!isfinite(amplitude)) return 1.0;
    return fmax(0.2, fmin(10.0, amplitude));
}

- (double)axs_dockfloat_period {
    id value = [self axs_dockfloat_valueForKey:@"period" defaultValue:@(2.0)];
    if (![value isKindOfClass:[NSNumber class]]) return 2.0;
    double period = [value doubleValue];
    if (!isfinite(period)) return 2.0;
    return fmax(0.5, fmin(20.0, period));
}

#pragma mark - Per-mode amplitude / period (#8)

static double axs_dockfloat_readClampedDouble(id value, double defaultValue, double minimum, double maximum) {
    if (![value isKindOfClass:[NSNumber class]]) return defaultValue;
    double result = [value doubleValue];
    if (!isfinite(result)) return defaultValue;
    return fmax(minimum, fmin(maximum, result));
}

- (double)axs_dockfloat_amplitudeForMode:(AxsDockFloatMode)mode {
    NSString *key = axs_dockfloat_amplitudeKeyForMode(mode);
    if (key) {
        id perModeValue = [self axs_dockfloat_valueForKey:key defaultValue:nil];
        if (perModeValue) return axs_dockfloat_readClampedDouble(perModeValue, 1.0, 0.2, 10.0);
    }
    return [self axs_dockfloat_amplitude];
}

- (double)axs_dockfloat_periodForMode:(AxsDockFloatMode)mode {
    NSString *key = axs_dockfloat_periodKeyForMode(mode);
    if (key) {
        id perModeValue = [self axs_dockfloat_valueForKey:key defaultValue:nil];
        if (perModeValue) return axs_dockfloat_readClampedDouble(perModeValue, 2.0, 0.5, 20.0);
    }
    return [self axs_dockfloat_period];
}

#pragma mark - Spring physics (#1)

- (BOOL)axs_dockfloat_useSpringPhysics {
    id value = [self axs_dockfloat_valueForKey:@"use_spring" defaultValue:@(NO)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

#pragma mark - Bubble customization (#7)

- (BOOL)axs_dockfloat_bubbleEnabled {
    id value = [self axs_dockfloat_valueForKey:@"bubble_enabled" defaultValue:@(YES)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

- (AxsDockFloatBubbleColorMode)axs_dockfloat_bubbleColorMode {
    id value = [self axs_dockfloat_valueForKey:@"bubble_color_mode" defaultValue:@(0)];
    if (![value isKindOfClass:[NSNumber class]]) return AxsDockFloatBubbleColorRainbow;
    NSInteger mode = [value integerValue];
    if (mode < AxsDockFloatBubbleColorRainbow || mode > AxsDockFloatBubbleColorTransparent)
        return AxsDockFloatBubbleColorRainbow;
    return (AxsDockFloatBubbleColorMode)mode;
}

- (double)axs_dockfloat_bubbleSizeMin {
    id value = [self axs_dockfloat_valueForKey:@"bubble_size_min" defaultValue:@(6.0)];
    return axs_dockfloat_readClampedDouble(value, 6.0, 4.0, 16.0);
}

- (double)axs_dockfloat_bubbleSizeMax {
    id value = [self axs_dockfloat_valueForKey:@"bubble_size_max" defaultValue:@(12.0)];
    return axs_dockfloat_readClampedDouble(value, 12.0, 8.0, 24.0);
}

- (double)axs_dockfloat_bubbleDensity {
    id value = [self axs_dockfloat_valueForKey:@"bubble_density" defaultValue:@(1.0)];
    return axs_dockfloat_readClampedDouble(value, 1.0, 0.3, 3.0);
}

#pragma mark - Fish species (#6)

- (NSArray<NSString *> *)axs_dockfloat_fishSpecies {
    id value = [self axs_dockfloat_valueForKey:@"fish_species" defaultValue:nil];
    // fish_species stored as JSON string array, e.g. '["🐟","🐠","🐡"]'
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        NSData *data = [(NSString *)value dataUsingEncoding:NSUTF8StringEncoding];
        if (data) {
            NSError *error = nil;
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            if ([parsed isKindOfClass:[NSArray class]] && [(NSArray *)parsed count] > 0) {
                return parsed;
            }
        }
    }
    // Holiday override: inject holiday-specific species first.
    NSDictionary *holiday = [self axs_dockfloat_holidayOverride];
    NSArray *holidaySpecies = holiday[@"species"];
    if ([holidaySpecies isKindOfClass:[NSArray class]] && holidaySpecies.count > 0) {
        return holidaySpecies;
    }
    return axs_dockfloat_defaultSpecies();
}

#pragma mark - Holiday easter egg (#14)

- (AxsDockFloatHolidayMode)axs_dockfloat_holidayMode {
    id value = [self axs_dockfloat_valueForKey:@"holiday_mode" defaultValue:@(0)];
    if (![value isKindOfClass:[NSNumber class]]) return AxsDockFloatHolidayAuto;
    NSInteger mode = [value integerValue];
    if (mode < AxsDockFloatHolidayAuto || mode > AxsDockFloatHolidayOff)
        return AxsDockFloatHolidayAuto;
    return (AxsDockFloatHolidayMode)mode;
}

- (NSDictionary *)axs_dockfloat_holidayOverride {
    AxsDockFloatHolidayMode mode = [self axs_dockfloat_holidayMode];
    if (mode == AxsDockFloatHolidayOff) return nil;

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *comps = [calendar components:NSCalendarUnitMonth | NSCalendarUnitDay fromDate:[NSDate date]];
    NSInteger month = comps.month;
    NSInteger day = comps.day;

    BOOL forced = (mode == AxsDockFloatHolidayOn);

    // Lunar New Year: ~Jan 21 – Feb 20 (Gregorian window approximation)
    if (forced || (month == 1 && day >= 21) || (month == 2 && day <= 20)) {
        return @{
            @"species": @[@"🐟", @"🐠", @"🐡", @"🐉", @"🧧", @"🏮", @"🐲", @"✨"],
            @"bubbleColor": @"gold",
            @"overlay": [NSNull null],
            @"particleHue": @(0.12), // gold hue
        };
    }
    // Halloween: Oct 25 – Nov 2
    if (forced || (month == 10 && day >= 25) || (month == 11 && day <= 2)) {
        return @{
            @"species": @[@"🦇", @"🕷️", @"👻", @"🎃", @"🕸️", @"💀", @"🦉", @"🐈‍⬛"],
            @"bubbleColor": @"orange",
            @"overlay": [NSNull null],
            @"particleHue": @(0.09), // orange hue
        };
    }
    // Christmas: Dec 20 – Dec 28
    if (forced || (month == 12 && day >= 20 && day <= 28)) {
        return @{
            @"species": @[@"❄️", @"⭐", @"🎄", @"🦌", @"🎅", @"⛄", @"🔔", @"🎁"],
            @"bubbleColor": @"white",
            @"overlay": @"❄️",
            @"particleHue": @(0.58), // icy blue hue
        };
    }
    return nil;
}

#pragma mark - System state (#3, #4)

+ (BOOL)axs_dockfloat_isLowPowerMode {
    return [[NSProcessInfo processInfo] isLowPowerModeEnabled];
}

+ (BOOL)axs_dockfloat_isReduceMotion {
    return UIAccessibilityIsReduceMotionEnabled();
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end