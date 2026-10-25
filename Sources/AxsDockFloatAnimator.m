#import "AxsDockFloatAnimator.h"
#import "AxsDockFloatConfig.h"
#import "AxsDockFloatPreferences.h"

// Dock discovery uses a naming-convention rule (class name ends with "IconListView"
// and contains "Dock") instead of hardcoded private classes, so unknown iOS layouts
// simply match nothing and the plugin stays inert. The root home-screen icon grid
// (SBRootIconListView...) is deliberately NOT matched: this plugin only animates
// the dock.
static BOOL axs_dockfloat_isDockListView(UIView *view) {
    NSString *className = NSStringFromClass([view class]);
    return [className hasSuffix:@"IconListView"] && [className containsString:@"Dock"];
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

@interface AxsDockFloatAnimator ()
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) NSMutableArray<UIView *> *dockViews;
@property (nonatomic, assign) AxsDockFloatMode mode;
@property (nonatomic, assign) BOOL modeTracked;
@property (nonatomic, assign) CFTimeInterval phase;
@property (nonatomic, assign) CFTimeInterval lastSearchTime;
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
        _mode = AxsDockFloatModeFloat;
    }
    return self;
}

- (void)axs_dockfloat_applyFromConfig {
    if (![[AxsDockFloatConfig axs_dockfloat_shared] axs_dockfloat_isEnabled]) {
        [self axs_dockfloat_stop];
        return;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(axs_dockfloat_handlePreferencesChanged:)
                                                 name:AxsDockFloatPreferencesChanged
                                               object:nil];
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
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        axs_dockfloat_collectDockViews(window, found);
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
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_displayLink invalidate];
}

@end
