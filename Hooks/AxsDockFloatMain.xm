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

// #13: Click ripple — hook icon tap in dock to spawn ripple animation.
// We hook touchesEnded on the icon view class used by the dock.
// The class name varies across iOS versions, so we use %c to resolve it at runtime.
%hook SBIconView
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    UITouch *touch = [touches anyObject];
    CGPoint point = [touch locationInView:self.superview];
    // Determine if this icon is inside a dock list view.
    UIView *dockView = nil;
    UIView *parent = self.superview;
    while (parent) {
        NSString *className = NSStringFromClass([parent class]);
        if ([className hasSuffix:@"IconListView"]
            && ([className containsString:@"Dock"] || [className containsString:@"Tray"])) {
            dockView = parent;
            break;
        }
        parent = parent.superview;
    }
    if (dockView) {
        CGPoint tapInDock = [touch locationInView:dockView];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"com.axs.dockfloat.icon-tapped"
            object:nil userInfo:@{
                @"dockView": dockView,
                @"tapPoint": [NSValue valueWithCGPoint:tapInDock],
            }];
    }
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