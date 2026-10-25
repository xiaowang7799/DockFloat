#import "AxsDockFloatAnimator.h"
#import "AxsDockFloatConfig.h"
#import "AxsDockFloatPreferences.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

// Dock discovery uses a naming-convention rule (class name ends with "IconListView"
// and contains "Dock" or "Tray") instead of hardcoded private classes, so unknown
// iOS layouts simply match nothing and the plugin stays inert. The root home-screen
// icon grid (SBRootIconListView...) is deliberately NOT matched.
static BOOL axs_dockfloat_isDockListView(UIView *view) {
    NSString *className = NSStringFromClass([view class]);
    return [className hasSuffix:@"IconListView"]
        && ([className containsString:@"Dock"] || [className containsString:@"Tray"]);
}

static void axs_dockfloat_collectDockViews(UIView *view, NSMutableArray *out) {
    if (axs_dockfloat_isDockListView(view)) {
        [out addObject:view];
        return;
    }
    for (UIView *child in view.subviews) {
        axs_dockfloat_collectDockViews(child, out);
    }
}

// Diagnostics only: record every *IconListView class actually present so a
// "nothing happens" report can identify the real dock class on new iOS versions.
static void axs_dockfloat_collectIconListViewClasses(UIView *view, NSMutableSet *out) {
    NSString *className = NSStringFromClass([view class]);
    if ([className containsString:@"IconListView"]) {
        [out addObject:className];
        return;
    }
    for (UIView *child in view.subviews) {
        axs_dockfloat_collectIconListViewClasses(child, out);
    }
}

@interface AxsDockFloatAnimator ()
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) NSMutableArray<UIView *> *dockViews;
@property (nonatomic, strong) NSMutableArray<UILabel *> *fishViews;
@property (nonatomic, assign) AxsDockFloatMode mode;
@property (nonatomic, assign) BOOL modeTracked;
@property (nonatomic, assign) CFTimeInterval phase;
@property (nonatomic, assign) CFTimeInterval lastSearchTime;
// Random-jitter state: a new target is drawn every randomInterval seconds.
@property (nonatomic, assign) CGPoint randomOffset;
@property (nonatomic, assign) CGPoint randomTarget;
@property (nonatomic, assign) CFTimeInterval randomNextRetarget;
@property (nonatomic, assign) double randomInterval;
// Per-fish state arrays, index-aligned with fishViews.
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fishX;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fishDirection;
@end

@implementation AxsDockFloatAnimator

+ (instancetype)axs_dockfloat_shared {
    static AxsDockFloatAnimator *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _dockViews = [NSMutableArray array];
        _fishViews = [NSMutableArray array];
        _fishX = [NSMutableArray array];
        _fishDirection = [NSMutableArray array];
        _mode = AxsDockFloatModeFloat;
    }
    return self;
}

- (void)axs_dockfloat_applyFromConfig {
    // Register before the enabled check: toggling the switch on must take effect
    // without a respring, so the animator has to already be listening while off.
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AxsDockFloatPreferencesChanged
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(axs_dockfloat_handlePreferencesChanged:)
                                                 name:AxsDockFloatPreferencesChanged
                                               object:nil];
    if (![[AxsDockFloatConfig axs_dockfloat_shared] axs_dockfloat_isEnabled]) {
        [self axs_dockfloat_stop];
        return;
    }
    [self axs_dockfloat_startLinkIfNeeded];
}

- (void)axs_dockfloat_handlePreferencesChanged:(NSNotification *)note {
    [self axs_dockfloat_applyFromConfig];
}

- (void)axs_dockfloat_startLinkIfNeeded {
    if (self.displayLink) {
        return;
    }
    self.phase = 0;
    self.lastSearchTime = 0;
    self.modeTracked = NO;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self
                                                   selector:@selector(axs_dockfloat_tick:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)axs_dockfloat_stop {
    [self.displayLink invalidate];
    self.displayLink = nil;
    [self axs_dockfloat_resetTransforms];
    self.phase = 0;
    self.modeTracked = NO;
}

// Search is throttled: rotating the phone or entering the home screen can rebuild
// the dock view, so re-locate it when the cache has no live window.
- (void)axs_dockfloat_refreshDocksIfNeededAt:(CFTimeInterval)now {
    BOOL allDetached = self.dockViews.count == 0;
    for (UIView *view in self.dockViews) {
        if (view.window) {
            allDetached = NO;
            break;
        }
    }
    if (!allDetached || now - self.lastSearchTime < 0.5) {
        return;
    }
    self.lastSearchTime = now;
    NSMutableArray *found = [NSMutableArray array];
    // UIWindowScene.windows (iOS 13+) instead of the deprecated UIApplication.windows,
    // which -Werror rejects on the iOS 15+ SDK used by the build.
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            axs_dockfloat_collectDockViews(window, found);
        }
    }
    if (found.count == 0) {
        NSMutableSet *classes = [NSMutableSet set];
        for (UIWindow *window in [UIApplication sharedApplication].connectedScenes) {
            if (![window isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            for (UIWindow *w in ((UIWindowScene *)window).windows) {
                axs_dockfloat_collectIconListViewClasses(w, classes);
            }
        }
        NSLog(@"[DockFloat] no dock matched; icon list classes present: %@", classes);
    }
    self.dockViews = found;
}

- (void)axs_dockfloat_tick:(CADisplayLink *)link {
    AxsDockFloatConfig *config = [AxsDockFloatConfig axs_dockfloat_shared];
    AxsDockFloatMode mode = [config axs_dockfloat_mode];
    if (!self.modeTracked || mode != self.mode) {
        [self axs_dockfloat_resetTransforms];
        self.mode = mode;
        self.modeTracked = YES;
        self.phase = 0;
    }
    [self axs_dockfloat_refreshDocksIfNeededAt:link.timestamp];
    if (self.dockViews.count == 0) {
        return;
    }
    double period = [config axs_dockfloat_period];
    double amplitude = [config axs_dockfloat_amplitude];
    self.phase += link.duration / period;
    double angle = self.phase * M_PI * 2.0;
    // While SpringBoard is animating the dock itself (open/close, page switch),
    // its transform wins: touching it here would fight the system animation.
    BOOL dockBusy = NO;
    for (UIView *dock in self.dockViews) {
        if (dock.layer.animationKeys.count > 0) {
            dockBusy = YES;
            break;
        }
    }
    if (dockBusy) {
        return;
    }
    switch (mode) {
        case AxsDockFloatModeFloat: {
            CGFloat offset = (CGFloat)(-8.0 * amplitude * sin(angle));
            for (UIView *dock in self.dockViews) {
                dock.transform = CGAffineTransformMakeTranslation(0, offset);
            }
            break;
        }
        case AxsDockFloatModeShake: {
            CGFloat x = (CGFloat)(4.0 * amplitude * sin(angle * 6.0));
            CGFloat y = (CGFloat)(2.0 * amplitude * sin(angle * 7.0 + 1.7));
            CGFloat rotation = (CGFloat)(0.02 * amplitude * sin(angle * 5.0));
            CGAffineTransform transform = CGAffineTransformMakeTranslation(x, y);
            transform = CGAffineTransformRotate(transform, rotation);
            for (UIView *dock in self.dockViews) {
                dock.transform = transform;
            }
            break;
        }
        case AxsDockFloatModeRoll: {
            for (UIView *dock in self.dockViews) {
                dock.transform = CGAffineTransformIdentity;
                NSArray<UIView *> *icons = dock.subviews;
                NSUInteger count = icons.count;
                for (NSUInteger index = 0; index < count; index++) {
                    CATransform3D transform = CATransform3DIdentity;
                    transform.m34 = -1.0 / 600.0;
                    double staggered = self.phase - (double)index / MAX((NSUInteger)1, count);
                    transform = CATransform3DRotate(transform, staggered * M_PI * 2.0, 0.0, 1.0, 0.0);
                    icons[index].layer.transform = transform;
                }
            }
            break;
        }
        case AxsDockFloatModeRandom: {
            [self axs_dockfloat_stepRandomWithDuration:link.duration];
            for (UIView *dock in self.dockViews) {
                dock.transform = CGAffineTransformMakeTranslation(self.randomOffset.x, self.randomOffset.y);
            }
            break;
        }
        case AxsDockFloatModeFish: {
            [self axs_dockfloat_syncFishCountWithDocks];
            [self axs_dockfloat_stepFishWithPeriod:period amplitude:amplitude duration:link.duration];
            break;
        }
    }
}

// Random jitter: pick a fresh offset every randomInterval, then ease toward it.
// Non-uniform intervals and per-axis ranges keep it from reading as a fixed loop.
- (void)axs_dockfloat_stepRandomWithDuration:(CFTimeInterval)duration {
    if (self.phase >= self.randomNextRetarget || self.randomInterval <= 0) {
        double span = 0.12 + (double)(arc4random_uniform(240)) / 1000.0;
        self.randomInterval = span;
        self.randomNextRetarget = self.phase + span;
        double reach = 14.0;
        double dx = ((double)arc4random() / (double)UINT32_MAX - 0.5) * 2.0 * reach;
        double dy = ((double)arc4random() / (double)UINT32_MAX - 0.5) * 2.0 * reach * 0.6;
        self.randomTarget = CGPointMake(dx, dy);
    }
    CGFloat dt = (CGFloat)duration;
    self.randomOffset.x += (self.randomTarget.x - self.randomOffset.x) * MIN(1.0, dt * 12.0);
    self.randomOffset.y += (self.randomTarget.y - self.randomOffset.y) * MIN(1.0, dt * 12.0);
}

// One fish per dock; views are plain subviews so taps still reach the icons below.
- (void)axs_dockfloat_syncFishCountWithDocks {
    while (self.fishViews.count > self.dockViews.count) {
        UILabel *extra = self.fishViews.lastObject;
        [extra removeFromSuperview];
        [self.fishViews removeLastObject];
        [self.fishX removeLastObject];
        [self.fishDirection removeLastObject];
    }
    while (self.fishViews.count < self.dockViews.count) {
        UILabel *fish = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 28, 28)];
        fish.text = @"🐟";
        fish.textAlignment = NSTextAlignmentCenter;
        fish.font = [UIFont systemFontOfSize:24];
        fish.userInteractionEnabled = NO;
        fish.isAccessibilityElement = NO;
        [self.dockViews[self.fishViews.count] addSubview:fish];
        [self.fishViews addObject:fish];
        [self.fishX addObject:@(0.0)];
        [self.fishDirection addObject:@(1.0)];
    }
    // The dock can be rebuilt (rotation, home re-layout); re-parent stale fish.
    NSUInteger count = MIN(self.fishViews.count, self.dockViews.count);
    for (NSUInteger index = 0; index < count; index++) {
        UILabel *fish = self.fishViews[index];
        UIView *dock = self.dockViews[index];
        if (fish.superview != dock) {
            [fish removeFromSuperview];
            [dock addSubview:fish];
        }
    }
}

- (void)axs_dockfloat_stepFishWithPeriod:(double)period amplitude:(double)amplitude
                                 duration:(CFTimeInterval)duration {
    NSUInteger count = self.fishViews.count;
    for (NSUInteger index = 0; index < count; index++) {
        UIView *dock = self.dockViews[index];
        UILabel *fish = self.fishViews[index];
        CGSize bounds = dock.bounds.size;
        if (bounds.width <= 40.0 || bounds.height <= 24.0) {
            continue;
        }
        double direction = [self.fishDirection[index] doubleValue];
        double speed = (bounds.width - 40.0) / MAX(0.5, period) * 0.5;
        double x = [self.fishX[index] doubleValue] + direction * speed * duration;
        double margin = 8.0;
        double maxX = bounds.width - fish.bounds.size.width - margin;
        if (x < margin) {
            x = margin;
            direction = 1.0;
        } else if (x > maxX) {
            x = maxX;
            direction = -1.0;
        }
        self.fishX[index] = @(x);
        self.fishDirection[index] = @(direction);
        double bob = (CGFloat)(sin(self.phase * M_PI * 2.0 * 1.5 + index) * 5.0 * amplitude);
        CGFloat y = (CGFloat)(MAX(margin, (bounds.height - fish.bounds.size.height) / 2.0 + bob));
        fish.frame = CGRectMake((CGFloat)x, y, fish.bounds.size.width, fish.bounds.size.height);
        // The glyph faces left; mirror it when swimming right.
        fish.transform = direction > 0 ? CGAffineTransformMakeScale(-1.0, 1.0) : CGAffineTransformIdentity;
    }
}

- (void)axs_dockfloat_resetTransforms {
    for (UIView *dock in self.dockViews) {
        dock.transform = CGAffineTransformIdentity;
        for (UIView *icon in dock.subviews) {
            icon.layer.transform = CATransform3DIdentity;
        }
    }
    [self.dockViews removeAllObjects];
    for (UILabel *fish in self.fishViews) {
        [fish removeFromSuperview];
    }
    [self.fishViews removeAllObjects];
    [self.fishX removeAllObjects];
    [self.fishDirection removeAllObjects];
    self.randomOffset = CGPointZero;
    self.randomTarget = CGPointZero;
    self.randomInterval = 0;
    self.randomNextRetarget = 0;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_displayLink invalidate];
}

@end
