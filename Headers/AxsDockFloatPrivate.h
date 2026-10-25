#pragma once

#import <UIKit/UIKit.h>

// Declare only private interfaces confirmed on the target iOS version.
//
// DockFloat deliberately declares none. The dock is located by class name lookup
// (see Sources/AxsDockFloatAnimator.m) and animated through public UIView/CALayer
// APIs, so no unverified private selector is sent to SpringBoard objects.
