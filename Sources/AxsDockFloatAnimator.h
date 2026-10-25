#pragma once

#import <UIKit/UIKit.h>

@interface AxsDockFloatAnimator : NSObject
+ (instancetype)axs_dockfloat_shared;
// Reads one config snapshot and starts, restyles or stops the dock animation.
- (void)axs_dockfloat_applyFromConfig;
- (void)axs_dockfloat_stop;
@end
