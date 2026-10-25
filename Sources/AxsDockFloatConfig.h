#pragma once

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, AxsDockFloatMode) {
    AxsDockFloatModeFloat = 0,
    AxsDockFloatModeRoll = 1,
    AxsDockFloatModeShake = 2,
};

@interface AxsDockFloatConfig : NSObject
+ (instancetype)axs_dockfloat_shared;
- (BOOL)axs_dockfloat_isEnabled;
- (AxsDockFloatMode)axs_dockfloat_mode;
- (double)axs_dockfloat_amplitude;
- (double)axs_dockfloat_period;
- (id)axs_dockfloat_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)axs_dockfloat_reload;
@end
