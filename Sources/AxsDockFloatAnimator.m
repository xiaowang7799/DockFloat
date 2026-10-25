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

// Aquarium species. Glyphs render from the system emoji font on every iOS 14+,
// no bundled image assets required.
static NSString * const kAxsDockFloatSpecies[] = {
    @"🐟", @"🐠", @"🐡", @"🦈", @"🐙", @"🦀", @"🐢", @"🐬",
};
static const NSUInteger kAxsDockFloatSpeciesCount =
    sizeof(kAxsDockFloatSpecies) / sizeof(kAxsDockFloatSpecies[0]);

// Bubble palette, cycled per bubble for a rainbow trail.
static UIColor *axs_dockfloat_bubbleColor(NSUInteger index) {
    UIColor *colors[] = {
        [UIColor colorWithRed:0.40 green:0.75 blue:1.00 alpha:0.85],
        [UIColor colorWithRed:1.00 green:0.55 blue:0.70 alpha:0.85],
        [UIColor colorWithRed:0.65 green:0.90 blue:0.55 alpha:0.85],
        [UIColor colorWithRed:1.00 green:0.82 blue:0.40 alpha:0.85],
        [UIColor colorWithRed:0.80 green:0.60 blue:1.00 alpha:0.85],
        [UIColor colorWithRed:0.45 green:0.95 blue:0.90 alpha:0.85],
    };
    const NSUInteger count = sizeof(colors) / sizeof(colors[0]);
    return colors[index % count];
}

@interface AxsDockFloatAnimator ()
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) NSMutableArray<UIView *> *dockViews;
// Aquarium actors: each fish label plus its own swim/bubble state.
@property (nonatomic, strong) NSMutableArray<UILabel *> *fishViews;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fishX;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fishDirection;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fishSpeed;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fishPhase;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fishLane;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fishNextBubble;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *bubbleCounter;
// Random-jitter state: a new target is drawn every randomInterval seconds.
@property (nonatomic, assign) CGPoint randomOffset;
@property (nonatomic, assign) CGPoint randomTarget;
@property (nonatomic, assign) CFTimeInterval randomNextRetarget;
@property (nonatomic, assign) double randomInterval;
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
        _fishViews = [NSMutableArray array];
        _fishX = [NSMutableArray array];
        _fishDirection = [NSMutableArray array];
        _fishSpeed = [NSMutableArray array];
        _fishPhase = [NSMutableArray array];
        _fishLane = [NSMutableArray array];
        _fishNextBubble = [NSMutableArray array];
        _bubbleCounter = [NSMutableArray array];
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
    if (!self.displayLink) {
        self.phase = 0;
        self.lastSearchTime = 0;
        self.displayLink = [CADisplayLink displayLinkWithTarget:self
                                                       selector:@selector(axs_dockfloat_tick:)];
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
}

- (void)axs_dockfloat_handlePreferencesChanged:(NSNotification *)note {
    [self axs_dockfloat_applyFromConfig];
}

- (void)axs_dockfloat_stop {
    [self.displayLink invalidate];
    self.displayLink = nil;
    self.phase = 0;
    [self axs_dockfloat_releaseAll];
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
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                axs_dockfloat_collectIconListViewClasses(w, classes);
            }
        }
        NSLog(@"[DockFloat] no dock matched; icon list classes present: %@", classes);
    }
    // Docks were rebuilt: old views are dead, drop fish parented to them.
    if (found.count != self.dockViews.count) {
        [self axs_dockfloat_releaseFish];
    }
    self.dockViews = found;
}

- (void)axs_dockfloat_tick:(CADisplayLink *)link {
    AxsDockFloatConfig *config = [AxsDockFloatConfig axs_dockfloat_shared];
    BOOL floatOn = [config axs_dockfloat_isModeActive:AxsDockFloatModeFloat];
    BOOL rollOn = [config axs_dockfloat_isModeActive:AxsDockFloatModeRoll];
    BOOL shakeOn = [config axs_dockfloat_isModeActive:AxsDockFloatModeShake];
    BOOL randomOn = [config axs_dockfloat_isModeActive:AxsDockFloatModeRandom];
    BOOL fishOn = [config axs_dockfloat_isModeActive:AxsDockFloatModeFish];

    if (!floatOn && !rollOn && !shakeOn && !randomOn && !fishOn) {
        [self axs_dockfloat_releaseAll];
        return;
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
    // its transform wins: touching it this frame would fight the system animation.
    BOOL dockBusy = NO;
    for (UIView *dock in self.dockViews) {
        if (dock.layer.animationKeys.count > 0) {
            dockBusy = YES;
            break;
        }
    }

    CGPoint jitter = CGPointZero;
    if (randomOn) {
        [self axs_dockfloat_stepRandomWithDuration:link.duration];
        jitter = self.randomOffset;
    } else {
        self.randomOffset = CGPointZero;
        self.randomTarget = CGPointZero;
        self.randomInterval = 0;
        self.randomNextRetarget = 0;
    }

    if (dockBusy) {
        [self axs_dockfloat_releaseTransforms];
    } else {
        // Whole-dock layer: shake + random jitter compose here.
        for (UIView *dock in self.dockViews) {
            CGAffineTransform transform = CGAffineTransformIdentity;
            if (shakeOn) {
                CGFloat x = (CGFloat)(4.0 * amplitude * sin(angle * 6.0));
                CGFloat y = (CGFloat)(2.0 * amplitude * sin(angle * 7.0 + 1.7));
                CGFloat rotation = (CGFloat)(0.02 * amplitude * sin(angle * 5.0));
                transform = CGAffineTransformTranslate(transform, x, y);
                transform = CGAffineTransformRotate(transform, rotation);
            }
            if (randomOn) {
                transform = CGAffineTransformTranslate(transform, jitter.x, jitter.y);
            }
            dock.transform = transform;
        }
        // Icon layer: float (uneven, per-icon phase) and roll (staggered 3D) compose.
        NSUInteger dockIndex = 0;
        for (UIView *dock in self.dockViews) {
            NSArray<UIView *> *icons = dock.subviews;
            NSUInteger count = icons.count;
            for (NSUInteger index = 0; index < count; index++) {
                UIView *icon = icons[index];
                if (!floatOn && !rollOn) {
                    if (!CATransform3DIsIdentity(icon.layer.transform)) {
                        icon.layer.transform = CATransform3DIdentity;
                    }
                    continue;
                }
                CATransform3D layer = CATransform3DIdentity;
                if (floatOn) {
                    // Uneven bob: each icon gets its own phase offset so the row
                    // waves instead of moving as a rigid slab.
                    CGFloat bob = (CGFloat)(-8.0 * amplitude
                        * sin(angle + (double)index * 0.9 + (double)dockIndex * 0.45));
                    layer = CATransform3DTranslate(layer, 0, bob, 0);
                }
                if (rollOn) {
                    CATransform3D roll = CATransform3DIdentity;
                    roll.m34 = -1.0 / 600.0;
                    double staggered = self.phase - (double)index / MAX((NSUInteger)1, count);
                    roll = CATransform3DRotate(roll, staggered * M_PI * 2.0, 0.0, 1.0, 0.0);
                    layer = CATransform3DConcat(layer, roll);
                }
                icon.layer.transform = layer;
            }
            dockIndex++;
        }
    }

    if (fishOn) {
        [self axs_dockfloat_syncFishWithConfig:config];
        [self axs_dockfloat_stepFishWithPeriod:period amplitude:amplitude duration:link.duration];
    } else {
        [self axs_dockfloat_releaseFish];
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
    // CGPoint members returned by a property getter are rvalues: mutate a local
    // copy and write the whole struct back.
    CGFloat k = MIN(1.0, (CGFloat)duration * 12.0);
    CGPoint offset = self.randomOffset;
    CGPoint target = self.randomTarget;
    offset.x += (target.x - offset.x) * k;
    offset.y += (target.y - offset.y) * k;
    self.randomOffset = offset;
}

// The fish-count key applies per dock: N fish swim inside each matched dock view.
- (void)axs_dockfloat_syncFishWithConfig:(AxsDockFloatConfig *)config {
    NSUInteger desired = (NSUInteger)[config axs_dockfloat_fishCount] * self.dockViews.count;
    while (self.fishViews.count > desired) {
        UILabel *extra = self.fishViews.lastObject;
        [extra removeFromSuperview];
        [self.fishViews removeLastObject];
        [self.fishX removeLastObject];
        [self.fishDirection removeLastObject];
        [self.fishSpeed removeLastObject];
        [self.fishPhase removeLastObject];
        [self.fishLane removeLastObject];
        [self.fishNextBubble removeLastObject];
        [self.bubbleCounter removeLastObject];
    }
    while (self.fishViews.count < desired) {
        NSUInteger index = self.fishViews.count;
        UILabel *fish = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
        fish.text = kAxsDockFloatSpecies[index % kAxsDockFloatSpeciesCount];
        fish.textAlignment = NSTextAlignmentCenter;
        fish.font = [UIFont systemFontOfSize:24];
        fish.userInteractionEnabled = NO;
        fish.isAccessibilityElement = NO;
        UIView *dock = self.dockViews[index % MAX((NSUInteger)1, self.dockViews.count)];
        [dock addSubview:fish];
        [self.fishViews addObject:fish];
        [self.fishX addObject:@(10.0)];
        [self.fishDirection addObject:@(((double)arc4random() / UINT32_MAX < 0.5) ? -1.0 : 1.0)];
        [self.fishSpeed addObject:@(0.7 + ((double)arc4random() / UINT32_MAX) * 0.6)];
        [self.fishPhase addObject:@(((double)arc4random() / UINT32_MAX) * M_PI * 2.0)];
        // Fixed vertical lane per fish (0..1), spread deterministically.
        [self.fishLane addObject:@(0.2 + 0.6 * (((double)((index * 41) % 97)) / 97.0))];
        [self.fishNextBubble addObject:@(0.2 + ((double)arc4random() / UINT32_MAX) * 1.2)];
        [self.bubbleCounter addObject:@(index)];
    }
    // Dock rebuilt (rotation, re-layout): re-parent fish onto the live docks.
    for (NSUInteger index = 0; index < self.fishViews.count; index++) {
        UILabel *fish = self.fishViews[index];
        UIView *dock = self.dockViews[index % MAX((NSUInteger)1, self.dockViews.count)];
        if (fish.superview != dock) {
            [dock addSubview:fish];
        }
    }
}

- (void)axs_dockfloat_stepFishWithPeriod:(double)period amplitude:(double)amplitude
                                 duration:(CFTimeInterval)duration {
    NSUInteger count = self.fishViews.count;
    for (NSUInteger index = 0; index < count; index++) {
        UIView *dock = self.dockViews[index % self.dockViews.count];
        UILabel *fish = self.fishViews[index];
        CGSize bounds = dock.bounds.size;
        if (bounds.width <= 40.0 || bounds.height <= 30.0) {
            continue;
        }
        double direction = [self.fishDirection[index] doubleValue];
        double speedBias = [self.fishSpeed[index] doubleValue];
        double margin = 8.0;
        double maxX = bounds.width - fish.bounds.size.width - margin;
        double speed = (bounds.width - 2.0 * margin) / MAX(0.5, period) * speedBias;
        double x = [self.fishX[index] doubleValue] + direction * speed * duration;
        if (x < margin) {
            x = margin;
            direction = 1.0;
        } else if (x > maxX) {
            x = maxX;
            direction = -1.0;
        }
        self.fishX[index] = @(x);
        self.fishDirection[index] = @(direction);

        double perFishPhase = [self.fishPhase[index] doubleValue];
        double bob = (CGFloat)(sin(self.phase * M_PI * 2.0 * 1.5 + perFishPhase)
            * 4.0 * fmin(3.0, amplitude));
        CGFloat lane = (CGFloat)([self.fishLane[index] doubleValue]
            * (bounds.height - fish.bounds.size.height - 2.0 * margin) + margin);
        CGFloat y = (CGFloat)fmax(margin, fmin(bounds.height - fish.bounds.size.height - margin,
            lane + bob));
        fish.frame = CGRectMake((CGFloat)x, y, fish.bounds.size.width, fish.bounds.size.height);
        // Most glyphs face left; mirror when swimming right.
        fish.transform = direction > 0 ? CGAffineTransformMakeScale(-1.0, 1.0) : CGAffineTransformIdentity;

        [self axs_dockfloat_emitBubblesForIndex:index inDock:dock amplitude:amplitude duration:duration];
    }
}

// Rising colored bubbles spawn from the fish mouth every few seconds and are
// removed by their own animation completion, keeping the dock layer bounded.
- (void)axs_dockfloat_emitBubblesForIndex:(NSUInteger)index inDock:(UIView *)dock
                                amplitude:(double)amplitude duration:(CFTimeInterval)duration {
    self.fishNextBubble[index] = @([self.fishNextBubble[index] doubleValue] - duration);
    if ([self.fishNextBubble[index] doubleValue] > 0) {
        return;
    }
    UILabel *fish = self.fishViews[index];
    self.fishNextBubble[index] = @(0.6 + ((double)arc4random() / UINT32_MAX) * 1.4);

    UIView *bubble = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 8)];
    // Mouth side follows swim direction.
    double direction = [self.fishDirection[index] doubleValue];
    CGFloat mouthX = direction > 0 ? CGRectGetMaxX(fish.frame) - 6.0
                                  : CGRectGetMinX(fish.frame) + 6.0;
    bubble.center = CGPointMake(mouthX, fish.frame.origin.y + 2.0);
    bubble.layer.cornerRadius = 4.0;
    bubble.layer.borderWidth = 1.0;
    NSUInteger colorIndex = [self.bubbleCounter[index] integerValue];
    self.bubbleCounter[index] = @(colorIndex + 1);
    UIColor *color = axs_dockfloat_bubbleColor(colorIndex);
    bubble.layer.borderColor = color.CGColor;
    bubble.layer.backgroundColor = [color colorWithAlphaComponent:0.30].CGColor;
    bubble.userInteractionEnabled = NO;
    bubble.isAccessibilityElement = NO;
    [dock addSubview:bubble];

    CGFloat rise = (CGFloat)(16.0 + 5.0 * fmin(4.0, amplitude));
    CGFloat drift = (CGFloat)(((double)arc4random() / UINT32_MAX - 0.5) * 16.0);
    NSTimeInterval life = 1.1 + ((double)arc4random() / UINT32_MAX) * 0.5;
    NSTimeInterval delay = ((double)arc4random() / UINT32_MAX) * 0.35;
    CGPoint start = bubble.center;
    [UIView animateWithDuration:life delay:delay options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        bubble.center = CGPointMake(start.x + drift, start.y - rise);
        bubble.transform = CGAffineTransformMakeScale(1.6, 1.6);
        bubble.alpha = 0.0;
    } completion:^(BOOL removeFromSuperviewDidFinish) {
        [bubble removeFromSuperview];
    }];
}

- (void)axs_dockfloat_releaseFish {
    for (UILabel *fish in self.fishViews) {
        [fish removeFromSuperview];
    }
    [self.fishViews removeAllObjects];
    [self.fishX removeAllObjects];
    [self.fishDirection removeAllObjects];
    [self.fishSpeed removeAllObjects];
    [self.fishPhase removeAllObjects];
    [self.fishLane removeAllObjects];
    [self.fishNextBubble removeAllObjects];
    [self.bubbleCounter removeAllObjects];
}

- (void)axs_dockfloat_releaseTransforms {
    for (UIView *dock in self.dockViews) {
        dock.transform = CGAffineTransformIdentity;
        for (UIView *icon in dock.subviews) {
            icon.layer.transform = CATransform3DIdentity;
        }
    }
}

- (void)axs_dockfloat_releaseAll {
    [self axs_dockfloat_releaseTransforms];
    [self.dockViews removeAllObjects];
    [self axs_dockfloat_releaseFish];
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
