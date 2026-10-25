#import <UIKit/UIKit.h>
#import "AxsDockFloatConfig.h"
#import "AxsDockFloatAnimator.h"
#import "AxsDockFloatPrivate.h"

// This tweak targets SpringBoard only (see AxsDockFloat.plist filter).
%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    [[AxsDockFloatConfig axs_dockfloat_shared] axs_dockfloat_reload];
    [[AxsDockFloatAnimator axs_dockfloat_shared] axs_dockfloat_applyFromConfig];
}

%end

%ctor {
    @autoreleasepool {
        // Readers load a snapshot; they never write default preferences.
        [AxsDockFloatConfig axs_dockfloat_shared];
        // After resuming from background the dock view may have been rebuilt,
        // so re-apply (the animator re-searches with throttling).
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            [[AxsDockFloatAnimator axs_dockfloat_shared] axs_dockfloat_applyFromConfig];
        }];
    }
}
