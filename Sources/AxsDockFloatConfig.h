#pragma once

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, AxsDockFloatMode) {
    AxsDockFloatModeFloat = 0,
    AxsDockFloatModeRoll = 1,
    AxsDockFloatModeShake = 2,
    AxsDockFloatModeRandom = 3,
    AxsDockFloatModeFish = 4,
    AxsDockFloatModeFirefly = 5,
    AxsDockFloatModeBreath = 6,
    AxsDockFloatModeStream = 7,
};

typedef NS_ENUM(NSInteger, AxsDockFloatBubbleColorMode) {
    AxsDockFloatBubbleColorRainbow = 0,
    AxsDockFloatBubbleColorSingle = 1,
    AxsDockFloatBubbleColorTransparent = 2,
};

typedef NS_ENUM(NSInteger, AxsDockFloatHolidayMode) {
    AxsDockFloatHolidayAuto = 0,
    AxsDockFloatHolidayOn = 1,
    AxsDockFloatHolidayOff = 2,
};

@interface AxsDockFloatConfig : NSObject
+ (instancetype)axs_dockfloat_shared;
- (BOOL)axs_dockfloat_isEnabled;
// Each mode has its own switch key; several may be active at once and stack.
- (BOOL)axs_dockfloat_isModeActive:(AxsDockFloatMode)mode;
- (NSInteger)axs_dockfloat_fishCount;
- (double)axs_dockfloat_amplitude;
- (double)axs_dockfloat_period;
// Per-mode amplitude/period — falls back to the global keys when not set.
- (double)axs_dockfloat_amplitudeForMode:(AxsDockFloatMode)mode;
- (double)axs_dockfloat_periodForMode:(AxsDockFloatMode)mode;
// Spring physics toggle (#1).
- (BOOL)axs_dockfloat_useSpringPhysics;
// Bubble customization (#7).
- (BOOL)axs_dockfloat_bubbleEnabled;
- (AxsDockFloatBubbleColorMode)axs_dockfloat_bubbleColorMode;
- (double)axs_dockfloat_bubbleSizeMin;
- (double)axs_dockfloat_bubbleSizeMax;
- (double)axs_dockfloat_bubbleDensity;
// Fish species set (#6) — returns the user-selected species strings, or the full default set.
- (NSArray<NSString *> *)axs_dockfloat_fishSpecies;
// Holiday easter egg (#14).
- (AxsDockFloatHolidayMode)axs_dockfloat_holidayMode;
// Returns nil when no holiday is active, otherwise a dict with keys:
//   "species", "bubbleColor", "overlay" (NSString emoji or NSNull), "particleHue" (NSNumber 0-1).
- (NSDictionary *)axs_dockfloat_holidayOverride;
// Low-power / reduce-motion guards (#3, #4) — convenience wrappers.
+ (BOOL)axs_dockfloat_isLowPowerMode;
+ (BOOL)axs_dockfloat_isReduceMotion;
// Generic accessors (already present).
- (id)axs_dockfloat_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)axs_dockfloat_reload;
@end