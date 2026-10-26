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

// Default aquarium species (fallback when fish_species is not configured).
static NSArray<NSString *> *axs_dockfloat_defaultSpecies(void) {
    static NSArray<NSString *> *species;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        species = @[@"🐟", @"🐠", @"🐡", @"🦈", @"🐙", @"🦀", @"🐢", @"🐬"];
    });
    return species;
}

// Bubble palette, cycled per bubble for a rainbow trail.
static UIColor *axs_dockfloat_bubbleColor(NSUInteger index, AxsDockFloatBubbleColorMode mode) {
    if (mode == AxsDockFloatBubbleColorTransparent) {
        return [UIColor clearColor];
    }
    if (mode == AxsDockFloatBubbleColorSingle) {
        return [UIColor colorWithRed:0.40 green:0.75 blue:1.00 alpha:0.85];
    }
    // Rainbow (default)
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

#pragma mark - Ripple notification

static NSString * const AxsDockFloatIconTappedNotification = @"com.axs.dockfloat.icon-tapped";

@interface AxsDockFloatAnimator ()
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) NSMutableArray<UIView *> *dockViews;
// Aquarium actors
@property (nonatomic, strong) NSMutableArray<UILabel *> *fishViews;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fishX;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fishDirection;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fishSpeed;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fishPhase;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fishLane;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fishNextBubble;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *bubbleCounter;
// Fish bounce state (#2)
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fishBouncingTicks;
// Random-jitter state
@property (nonatomic, assign) CGPoint randomOffset;
@property (nonatomic, assign) CGPoint randomTarget;
@property (nonatomic, assign) CFTimeInterval randomNextRetarget;
@property (nonatomic, assign) double randomInterval;
@property (nonatomic, assign) CFTimeInterval phase;
@property (nonatomic, assign) CFTimeInterval lastSearchTime;
// Spring physics envelope (#1)
@property (nonatomic, assign) CFTimeInterval springTicks;
// Firefly particles (#10)
@property (nonatomic, strong) NSMutableArray<CALayer *> *fireflyLayers;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *fireflyStates;
// RGB stream layers (#12)
@property (nonatomic, strong) NSMutableArray<CAGradientLayer *> *streamLayers;
// Click ripple (#13)
@property (nonatomic, strong) NSMutableArray<CAShapeLayer *> *rippleLayers;
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
        _fishBouncingTicks = [NSMutableArray array];
        _fireflyLayers = [NSMutableArray array];
        _fireflyStates = [NSMutableArray array];
        _streamLayers = [NSMutableArray array];
        _rippleLayers = [NSMutableArray array];
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
    // #13: ripple notification
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AxsDockFloatIconTappedNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(axs_dockfloat_handleIconTapped:)
                                                 name:AxsDockFloatIconTappedNotification
                                               object:nil];

    if (![[AxsDockFloatConfig axs_dockfloat_shared] axs_dockfloat_isEnabled]) {
        [self axs_dockfloat_stop];
        return;
    }
    if (!self.displayLink) {
        self.phase = 0;
        self.lastSearchTime = 0;
        self.springTicks = 0;
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
    self.springTicks = 0;
    [self axs_dockfloat_releaseAll];
}

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
    if (found.count != self.dockViews.count) {
        [self axs_dockfloat_releaseFish];
        [self axs_dockfloat_releaseFirefly];
        [self axs_dockfloat_releaseStream];
    }
    self.dockViews = found;
}

#pragma mark - Tick

- (void)axs_dockfloat_tick:(CADisplayLink *)link {
    // #3: Low-power degrade
    BOOL lowPower = [AxsDockFloatConfig axs_dockfloat_isLowPowerMode];
    if (lowPower && self.displayLink.preferredFramesPerSecond != 30) {
        self.displayLink.preferredFramesPerSecond = 30;
    } else if (!lowPower && self.displayLink.preferredFramesPerSecond != 0) {
        self.displayLink.preferredFramesPerSecond = 0;
    }

    // #4: Reduce-motion degrade
    BOOL reduceMotion = [AxsDockFloatConfig axs_dockfloat_isReduceMotion];

    AxsDockFloatConfig *config = [AxsDockFloatConfig axs_dockfloat_shared];
    BOOL floatOn = [config axs_dockfloat_isModeActive:AxsDockFloatModeFloat];
    BOOL rollOn = [config axs_dockfloat_isModeActive:AxsDockFloatModeRoll];
    BOOL shakeOn = [config axs_dockfloat_isModeActive:AxsDockFloatModeShake];
    BOOL randomOn = [config axs_dockfloat_isModeActive:AxsDockFloatModeRandom];
    BOOL fishOn = [config axs_dockfloat_isModeActive:AxsDockFloatModeFish];
    BOOL fireflyOn = [config axs_dockfloat_isModeActive:AxsDockFloatModeFirefly];
    BOOL breathOn = [config axs_dockfloat_isModeActive:AxsDockFloatModeBreath];
    BOOL streamOn = [config axs_dockfloat_isModeActive:AxsDockFloatModeStream];

    if (!floatOn && !rollOn && !shakeOn && !randomOn && !fishOn && !fireflyOn && !breathOn && !streamOn) {
        [self axs_dockfloat_releaseAll];
        return;
    }
    [self axs_dockfloat_refreshDocksIfNeededAt:link.timestamp];
    if (self.dockViews.count == 0) {
        return;
    }

    // #1: Spring physics envelope — reset when tick starts fresh or config changes
    self.springTicks += link.duration;
    BOOL useSpring = [config axs_dockfloat_useSpringPhysics];
    double springDamping = useSpring ? (reduceMotion ? 0.3 : 0.05) : 0.0;

    // Per-mode amplitude/period with reduce-motion scaling
    double ampFloat   = reduceMotion ? [config axs_dockfloat_amplitudeForMode:AxsDockFloatModeFloat] * 0.2
                                     : [config axs_dockfloat_amplitudeForMode:AxsDockFloatModeFloat];
    double perFloat   = [config axs_dockfloat_periodForMode:AxsDockFloatModeFloat];
    double ampRoll    = reduceMotion ? [config axs_dockfloat_amplitudeForMode:AxsDockFloatModeRoll] * 0.2
                                     : [config axs_dockfloat_amplitudeForMode:AxsDockFloatModeRoll];
    double perRoll    = [config axs_dockfloat_periodForMode:AxsDockFloatModeRoll];
    double ampShake   = reduceMotion ? [config axs_dockfloat_amplitudeForMode:AxsDockFloatModeShake] * 0.2
                                     : [config axs_dockfloat_amplitudeForMode:AxsDockFloatModeShake];
    double perShake   = [config axs_dockfloat_periodForMode:AxsDockFloatModeShake];
    double ampRandom  = reduceMotion ? [config axs_dockfloat_amplitudeForMode:AxsDockFloatModeRandom] * 0.2
                                     : [config axs_dockfloat_amplitudeForMode:AxsDockFloatModeRandom];
    double perRandom  = [config axs_dockfloat_periodForMode:AxsDockFloatModeRandom];
    // Fish/Firefly/Breath/Stream use global amplitude/period
    double globalAmp   = reduceMotion ? [config axs_dockfloat_amplitude] * 0.2 : [config axs_dockfloat_amplitude];
    double globalPer   = [config axs_dockfloat_period];

    self.phase += link.duration;
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
        [self axs_dockfloat_stepRandomWithDuration:link.duration period:perRandom amplitude:ampRandom];
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
        // #4: reduce-motion opacity fallback instead of transform
        if (reduceMotion && (floatOn || rollOn || shakeOn || randomOn)) {
            for (UIView *dock in self.dockViews) {
                for (UIView *icon in dock.subviews) {
                    CGFloat opacity = (CGFloat)(0.7 + 0.3 * sin(angle * 3.0));
                    icon.alpha = opacity;
                }
            }
        } else {
            // Whole-dock layer: shake + random jitter compose here.
            for (UIView *dock in self.dockViews) {
                CGAffineTransform transform = CGAffineTransformIdentity;
                if (shakeOn) {
                    CGFloat x = (CGFloat)(4.0 * ampShake * sin(angle * 6.0));
                    CGFloat y = (CGFloat)(2.0 * ampShake * sin(angle * 7.0 + 1.7));
                    CGFloat rotation = (CGFloat)(0.02 * ampShake * sin(angle * 5.0));
                    if (springDamping > 0) {
                        double env = exp(-springDamping * self.springTicks);
                        x *= env; y *= env; rotation *= env;
                    }
                    transform = CGAffineTransformTranslate(transform, x, y);
                    transform = CGAffineTransformRotate(transform, rotation);
                }
                if (randomOn) {
                    transform = CGAffineTransformTranslate(transform, jitter.x, jitter.y);
                }
                dock.transform = transform;
            }
            // Icon layer: float (uneven, per-icon phase) and roll (staggered 3D).
            NSUInteger dockIndex = 0;
            for (UIView *dock in self.dockViews) {
                NSArray<UIView *> *icons = dock.subviews;
                NSUInteger count = icons.count;
                for (NSUInteger index = 0; index < count; index++) {
                    UIView *icon = icons[index];
                    // Skip fish labels and other non-icon subviews
                    if (!floatOn && !rollOn && !breathOn) {
                        if (!CATransform3DIsIdentity(icon.layer.transform)) {
                            icon.layer.transform = CATransform3DIdentity;
                        }
                        continue;
                    }
                    CATransform3D layer = CATransform3DIdentity;
                    if (floatOn) {
                        // Uneven bob: each icon gets its own phase offset so the row
                        // waves instead of moving as a rigid slab.
                        CGFloat bob = (CGFloat)(-8.0 * ampFloat
                            * sin(angle + (double)index * 0.9 + (double)dockIndex * 0.45));
                        if (springDamping > 0) {
                            bob *= (CGFloat)exp(-springDamping * (self.springTicks + (double)index * 0.15));
                        }
                        layer = CATransform3DTranslate(layer, 0, bob, 0);
                    }
                    if (rollOn) {
                        CATransform3D roll = CATransform3DIdentity;
                        roll.m34 = (CGFloat)(-1.0 / (600.0 / fmax(0.3, ampRoll)));
                        double staggered = self.phase / perRoll - (double)index / MAX((NSUInteger)1, count);
                        roll = CATransform3DRotate(roll, staggered * M_PI * 2.0, 0.0, 1.0, 0.0);
                        if (springDamping > 0) {
                            double env = exp(-springDamping * (self.springTicks * 0.5 + (double)index * 0.1));
                            roll = CATransform3DScale(roll, (CGFloat)(1.0 - 0.3 * (1.0 - env)),
                                                          (CGFloat)(1.0 - 0.3 * (1.0 - env)),
                                                          (CGFloat)(1.0 - 0.3 * (1.0 - env)));
                        }
                        layer = CATransform3DConcat(layer, roll);
                    }
                    // #11: Breathing pulse — scale addition
                    if (breathOn) {
                        CGFloat breathScale = (CGFloat)(1.0 + 0.05 * globalAmp * sin(self.phase * 2.0 * M_PI / 3.7));
                        CATransform3D breath = CATransform3DMakeScale(breathScale, breathScale, 1.0);
                        layer = CATransform3DConcat(layer, breath);
                    }
                    icon.layer.transform = layer;
                }
                dockIndex++;
            }
        }
    }

    // Fish mode
    if (fishOn && !reduceMotion) {
        double fishCount = lowPower
            ? MAX(1, (NSInteger)round((double)[config axs_dockfloat_fishCount] / 2.0))
            : [config axs_dockfloat_fishCount];
        [self axs_dockfloat_syncFishWithCount:(NSUInteger)fishCount species:[config axs_dockfloat_fishSpecies]];
        [self axs_dockfloat_stepFishWithConfig:config globalAmp:globalAmp globalPer:globalPer duration:link.duration lowPower:lowPower];
    } else {
        [self axs_dockfloat_releaseFish];
    }

    // #10: Firefly mode
    if (fireflyOn && !reduceMotion) {
        [self axs_dockfloat_stepFireflyWithDuration:link.duration];
    } else {
        [self axs_dockfloat_releaseFirefly];
    }

    // #12: RGB stream mode
    if (streamOn && !reduceMotion) {
        [self axs_dockfloat_stepStream];
    } else {
        [self axs_dockfloat_releaseStream];
    }

    // #13: clean up finished ripples
    [self axs_dockfloat_pruneRipples];
}

#pragma mark - Random jitter

- (void)axs_dockfloat_stepRandomWithDuration:(CFTimeInterval)duration period:(double)period amplitude:(double)amplitude {
    if (self.phase >= self.randomNextRetarget || self.randomInterval <= 0) {
        double span = 0.12 + (double)(arc4random_uniform(240)) / 1000.0;
        self.randomInterval = span;
        self.randomNextRetarget = self.phase + span * (period / 2.0);
        double reach = 14.0 * fmin(5.0, amplitude);
        double dx = ((double)arc4random() / (double)UINT32_MAX - 0.5) * 2.0 * reach;
        double dy = ((double)arc4random() / (double)UINT32_MAX - 0.5) * 2.0 * reach * 0.6;
        self.randomTarget = CGPointMake(dx, dy);
    }
    CGFloat k = MIN(1.0, (CGFloat)duration * 12.0);
    CGPoint offset = self.randomOffset;
    CGPoint target = self.randomTarget;
    offset.x += (target.x - offset.x) * k;
    offset.y += (target.y - offset.y) * k;
    self.randomOffset = offset;
}

#pragma mark - Fish (#2, #7)

- (void)axs_dockfloat_syncFishWithCount:(NSUInteger)desired species:(NSArray<NSString *> *)species {
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
        [self.fishBouncingTicks removeLastObject];
    }
    NSUInteger speciesCount = MAX((NSUInteger)1, species.count);
    while (self.fishViews.count < desired) {
        NSUInteger index = self.fishViews.count;
        UILabel *fish = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
        fish.text = species[index % speciesCount];
        fish.textAlignment = NSTextAlignmentCenter;
        // #6: slight random size variation
        CGFloat fontSize = (CGFloat)(22.0 + ((double)arc4random() / UINT32_MAX) * 8.0);
        fish.font = [UIFont systemFontOfSize:fontSize];
        fish.userInteractionEnabled = NO;
        fish.isAccessibilityElement = NO;
        UIView *dock = self.dockViews[index % MAX((NSUInteger)1, self.dockViews.count)];
        [dock addSubview:fish];
        [self.fishViews addObject:fish];
        [self.fishX addObject:@(10.0)];
        [self.fishDirection addObject:@(((double)arc4random() / UINT32_MAX < 0.5) ? -1.0 : 1.0)];
        [self.fishSpeed addObject:@(0.7 + ((double)arc4random() / UINT32_MAX) * 0.6)];
        [self.fishPhase addObject:@(((double)arc4random() / UINT32_MAX) * M_PI * 2.0)];
        [self.fishLane addObject:@(0.2 + 0.6 * (((double)((index * 41) % 97)) / 97.0))];
        [self.fishNextBubble addObject:@(0.2 + ((double)arc4random() / UINT32_MAX) * 1.2)];
        [self.bubbleCounter addObject:@(index)];
        [self.fishBouncingTicks addObject:@(0)];
    }
    for (NSUInteger index = 0; index < self.fishViews.count; index++) {
        UILabel *fish = self.fishViews[index];
        UIView *dock = self.dockViews[index % MAX((NSUInteger)1, self.dockViews.count)];
        if (fish.superview != dock) {
            [dock addSubview:fish];
        }
        // Update species text in case holiday changed
        fish.text = species[index % speciesCount];
    }
}

- (void)axs_dockfloat_stepFishWithConfig:(AxsDockFloatConfig *)config
                               globalAmp:(double)globalAmp
                               globalPer:(double)globalPer
                                duration:(CFTimeInterval)duration
                               lowPower:(BOOL)lowPower {
    NSUInteger count = self.fishViews.count;
    AxsDockFloatBubbleColorMode bubbleColorMode = [config axs_dockfloat_bubbleColorMode];
    BOOL bubbleOn = [config axs_dockfloat_bubbleEnabled] && !lowPower;
    double bubbleSizeMin = [config axs_dockfloat_bubbleSizeMin];
    double bubbleSizeMax = [config axs_dockfloat_bubbleSizeMax];
    double bubbleDensity = [config axs_dockfloat_bubbleDensity];

    for (NSUInteger index = 0; index < count; index++) {
        UIView *dock = self.dockViews[index % self.dockViews.count];
        UILabel *fish = self.fishViews[index];
        CGSize bounds = dock.bounds.size;
        if (bounds.width <= 40.0 || bounds.height <= 30.0) {
            continue;
        }

        // #2: wall bounce cushion
        NSInteger bounceTicks = [self.fishBouncingTicks[index] integerValue];
        if (bounceTicks > 0) {
            self.fishBouncingTicks[index] = @(bounceTicks - 1);
            double progress = 1.0 - (double)bounceTicks / 10.0;
            CGFloat scale = (CGFloat)(1.0 + 0.15 * sin(progress * M_PI));
            fish.transform = CGAffineTransformMakeScale(
                [self.fishDirection[index] doubleValue] > 0 ? -scale : scale, scale);
            // Don't move horizontally while bouncing
            continue;
        }

        double direction = [self.fishDirection[index] doubleValue];
        double speedBias = [self.fishSpeed[index] doubleValue];
        double margin = 8.0;
        double maxX = bounds.width - fish.bounds.size.width - margin;
        double speed = (bounds.width - 2.0 * margin) / MAX(0.5, globalPer) * speedBias;
        double x = [self.fishX[index] doubleValue] + direction * speed * duration;
        BOOL hitWall = NO;
        if (x < margin) {
            x = margin;
            direction = 1.0;
            hitWall = YES;
        } else if (x > maxX) {
            x = maxX;
            direction = -1.0;
            hitWall = YES;
        }
        self.fishX[index] = @(x);
        self.fishDirection[index] = @(direction);

        if (hitWall) {
            self.fishBouncingTicks[index] = @(10); // 10-tick cushion (~0.16s at 60fps)
            // Flip direction immediately so the final scale faces the new direction
            fish.transform = CGAffineTransformMakeScale(
                direction > 0 ? -1.0 : 1.0, 1.0);
            continue;
        }

        double perFishPhase = [self.fishPhase[index] doubleValue];
        double bob = (CGFloat)(sin(self.phase * M_PI * 2.0 * 1.5 + perFishPhase)
            * 4.0 * fmin(3.0, globalAmp));
        CGFloat lane = (CGFloat)([self.fishLane[index] doubleValue]
            * (bounds.height - fish.bounds.size.height - 2.0 * margin) + margin);
        CGFloat y = (CGFloat)fmax(margin, fmin(bounds.height - fish.bounds.size.height - margin,
            lane + bob));
        fish.frame = CGRectMake((CGFloat)x, y, fish.bounds.size.width, fish.bounds.size.height);
        fish.transform = direction > 0 ? CGAffineTransformMakeScale(-1.0, 1.0) : CGAffineTransformIdentity;

        if (bubbleOn && bubbleColorMode != AxsDockFloatBubbleColorTransparent) {
            [self axs_dockfloat_emitBubblesForIndex:index inDock:dock
                                         globalAmp:globalAmp duration:duration
                                   bubbleColorMode:bubbleColorMode
                                       sizeMin:bubbleSizeMin sizeMax:bubbleSizeMax
                                       density:bubbleDensity];
        }
    }
}

- (void)axs_dockfloat_emitBubblesForIndex:(NSUInteger)index inDock:(UIView *)dock
                                globalAmp:(double)globalAmp duration:(CFTimeInterval)duration
                          bubbleColorMode:(AxsDockFloatBubbleColorMode)bubbleColorMode
                                  sizeMin:(double)sizeMin sizeMax:(double)sizeMax
                                  density:(double)density {
    self.fishNextBubble[index] = @([self.fishNextBubble[index] doubleValue] - duration);
    if ([self.fishNextBubble[index] doubleValue] > 0) {
        return;
    }
    UILabel *fish = self.fishViews[index];
    // #7: density controls emission interval
    self.fishNextBubble[index] = @((0.6 + ((double)arc4random() / UINT32_MAX) * 1.4) / density);

    // #7: random bubble size
    CGFloat bSize = (CGFloat)(sizeMin + ((double)arc4random() / UINT32_MAX) * (sizeMax - sizeMin));
    UIView *bubble = [[UIView alloc] initWithFrame:CGRectMake(0, 0, bSize, bSize)];
    double direction = [self.fishDirection[index] doubleValue];
    CGFloat mouthX = direction > 0 ? CGRectGetMaxX(fish.frame) - 6.0
                                  : CGRectGetMinX(fish.frame) + 6.0;
    bubble.center = CGPointMake(mouthX, fish.frame.origin.y + 2.0);
    bubble.layer.cornerRadius = bSize / 2.0;
    bubble.layer.borderWidth = 1.0;
    NSUInteger colorIndex = [self.bubbleCounter[index] integerValue];
    self.bubbleCounter[index] = @(colorIndex + 1);
    UIColor *color = axs_dockfloat_bubbleColor(colorIndex, bubbleColorMode);
    bubble.layer.borderColor = color.CGColor;
    bubble.layer.backgroundColor = [color colorWithAlphaComponent:0.30].CGColor;
    bubble.userInteractionEnabled = NO;
    bubble.isAccessibilityElement = NO;
    [dock addSubview:bubble];

    CGFloat rise = (CGFloat)(16.0 + 5.0 * fmin(4.0, globalAmp));
    CGFloat drift = (CGFloat)(((double)arc4random() / UINT32_MAX - 0.5) * 16.0);
    NSTimeInterval life = 1.1 + ((double)arc4random() / UINT32_MAX) * 0.5;
    NSTimeInterval delay = ((double)arc4random() / UINT32_MAX) * 0.35;
    CGPoint start = bubble.center;
    [UIView animateWithDuration:life delay:delay options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        // Horizontal wobble for more natural look
        bubble.center = CGPointMake((CGFloat)(start.x + drift + 3.0 * sin(self.phase * 4.0 + (double)colorIndex)),
                                    start.y - rise);
        bubble.transform = CGAffineTransformMakeScale(1.6, 1.6);
        bubble.alpha = 0.0;
    } completion:^(BOOL flagFinish) {
        [bubble removeFromSuperview];
    }];
}

#pragma mark - Firefly (#10)

- (void)axs_dockfloat_stepFireflyWithDuration:(CFTimeInterval)duration {
    NSUInteger desiredCountPerDock = 25;
    NSUInteger totalDesired = desiredCountPerDock * self.dockViews.count;

    // Trim excess
    while (self.fireflyLayers.count > totalDesired) {
        CALayer *extra = self.fireflyLayers.lastObject;
        [extra removeFromSuperlayer];
        [self.fireflyLayers removeLastObject];
        [self.fireflyStates removeLastObject];
    }

    // Spawn new ones
    while (self.fireflyLayers.count < totalDesired) {
        NSUInteger index = self.fireflyLayers.count;
        NSUInteger dockIndex = index % self.dockViews.count;
        UIView *dock = self.dockViews[dockIndex];
        CGSize bounds = dock.bounds.size;

        CALayer *dot = [CALayer layer];
        dot.frame = CGRectMake(0, 0, 3, 3);
        dot.cornerRadius = 1.5;
        dot.backgroundColor = [UIColor colorWithHue:(CGFloat)((double)arc4random() / UINT32_MAX)
                                         saturation:0.8 brightness:1.0 alpha:1.0].CGColor;
        dot.opacity = 0.0;
        [dock.layer addSublayer:dot];
        [self.fireflyLayers addObject:dot];

        CGFloat startX = (CGFloat)(arc4random_uniform((uint32_t)MAX(1, (int)bounds.width - 8)) + 4);
        CGFloat startY = (CGFloat)(arc4random_uniform((uint32_t)MAX(1, (int)bounds.height - 8)) + 4);
        CGFloat vx = (CGFloat)(((double)arc4random() / UINT32_MAX - 0.5) * 30.0);
        CGFloat vy = (CGFloat)(((double)arc4random() / UINT32_MAX - 0.5) * 30.0);
        CGFloat phase = (CGFloat)(((double)arc4random() / UINT32_MAX) * M_PI * 2.0);
        CGFloat hueShift = (CGFloat)(((double)arc4random() / UINT32_MAX) * 0.15);

        [self.fireflyStates addObject:@{
            @"x": @(startX), @"y": @(startY),
            @"vx": @(vx), @"vy": @(vy),
            @"phase": @(phase), @"hueShift": @(hueShift),
            @"dockIndex": @(dockIndex),
        }];
    }

    for (NSUInteger i = 0; i < self.fireflyLayers.count; i++) {
        CALayer *dot = self.fireflyLayers[i];
        NSMutableDictionary *state = [self.fireflyStates[i] mutableCopy];
        UIView *dock = self.dockViews[[state[@"dockIndex"] unsignedIntegerValue] % MAX((NSUInteger)1, self.dockViews.count)];
        if (dot.superlayer != dock.layer) {
            [dock.layer addSublayer:dot];
        }

        CGFloat x = [state[@"x"] floatValue];
        CGFloat y = [state[@"y"] floatValue];
        CGFloat vx = [state[@"vx"] floatValue];
        CGFloat vy = [state[@"vy"] floatValue];
        CGFloat phase = [state[@"phase"] floatValue];
        CGFloat hueShift = [state[@"hueShift"] floatValue];
        CGSize bounds = dock.bounds.size;

        // Drift
        x += vx * (CGFloat)duration;
        y += vy * (CGFloat)duration;

        // Wrap at edges
        if (x < 2 || x > bounds.width - 5) { vx = -vx; x = (CGFloat)MAX(2, MIN(bounds.width - 5, x)); }
        if (y < 2 || y > bounds.height - 5) { vy = -vy; y = (CGFloat)MAX(2, MIN(bounds.height - 5, y)); }

        // Opacity pulse
        CGFloat fade = (CGFloat)(0.3 + 0.7 * fabs(sin(self.phase * 3.0 + phase)));
        dot.opacity = fade;

        // Color cycle with hue shift
        CGFloat hue = (CGFloat)(fmod(self.phase * 0.1 + phase * 0.3 + hueShift, 1.0));
        dot.backgroundColor = [UIColor colorWithHue:hue saturation:0.8 brightness:1.0 alpha:1.0].CGColor;
        dot.position = CGPointMake(x, y);

        state[@"x"] = @(x); state[@"y"] = @(y);
        state[@"vx"] = @(vx); state[@"vy"] = @(vy);
        self.fireflyStates[i] = state;
    }
}

#pragma mark - RGB Stream (#12)

- (void)axs_dockfloat_stepStream {
    while (self.streamLayers.count < self.dockViews.count) {
        NSUInteger index = self.streamLayers.count;
        UIView *dock = self.dockViews[index];
        CAGradientLayer *gradient = [CAGradientLayer layer];
        gradient.frame = CGRectMake(0, dock.bounds.size.height - 2, dock.bounds.size.width, 2);
        gradient.colors = @[
            (id)[UIColor colorWithHue:0.0 saturation:1.0 brightness:1.0 alpha:1.0].CGColor,
            (id)[UIColor colorWithHue:0.16 saturation:1.0 brightness:1.0 alpha:1.0].CGColor,
            (id)[UIColor colorWithHue:0.33 saturation:1.0 brightness:1.0 alpha:1.0].CGColor,
            (id)[UIColor colorWithHue:0.50 saturation:1.0 brightness:1.0 alpha:1.0].CGColor,
            (id)[UIColor colorWithHue:0.66 saturation:1.0 brightness:1.0 alpha:1.0].CGColor,
            (id)[UIColor colorWithHue:0.83 saturation:1.0 brightness:1.0 alpha:1.0].CGColor,
        ];
        gradient.startPoint = CGPointMake(0, 0.5);
        gradient.endPoint = CGPointMake(1, 0.5);
        [dock.layer addSublayer:gradient];
        [self.streamLayers addObject:gradient];

        // Animate locations for flowing effect
        CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"locations"];
        anim.fromValue = @[@(0.0), @(0.1), @(0.2), @(0.3), @(0.4), @(0.5)];
        anim.toValue = @[@(0.5), @(0.6), @(0.7), @(0.8), @(0.9), @(1.0)];
        anim.duration = 2.5;
        anim.repeatCount = HUGE_VALF;
        anim.autoreverses = YES;
        [gradient addAnimation:anim forKey:@"axs_stream_locations"];
    }

    // Keep frames in sync
    for (NSUInteger i = 0; i < self.streamLayers.count && i < self.dockViews.count; i++) {
        UIView *dock = self.dockViews[i];
        CAGradientLayer *gradient = self.streamLayers[i];
        if (gradient.superlayer != dock.layer) {
            [dock.layer addSublayer:gradient];
        }
        gradient.frame = CGRectMake(0, dock.bounds.size.height - 2, dock.bounds.size.width, 2);
    }
}

#pragma mark - Click ripple (#13)

- (void)axs_dockfloat_handleIconTapped:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    UIView *dockView = info[@"dockView"];
    NSValue *pointValue = info[@"tapPoint"];
    if (!dockView || !pointValue) return;

    CGPoint tapPoint = [pointValue CGPointValue];
    for (NSUInteger i = 0; i < 3; i++) {
        CAShapeLayer *ring = [CAShapeLayer layer];
        ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-10, -10, 20, 20)].CGPath;
        ring.position = tapPoint;
        ring.fillColor = [UIColor clearColor].CGColor;
        ring.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.6].CGColor;
        ring.lineWidth = 2.0;
        ring.opacity = 0.6;
        [dockView.layer addSublayer:ring];
        [self.rippleLayers addObject:ring];

        CGFloat delay = (CGFloat)i * 0.08;
        [UIView animateWithDuration:0.6 delay:delay options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            ring.transform = CATransform3DMakeScale(4.0, 4.0, 1.0);
            ring.opacity = 0.0;
        } completion:nil];
    }
}

- (void)axs_dockfloat_pruneRipples {
    NSMutableArray *toRemove = [NSMutableArray array];
    for (CAShapeLayer *ring in self.rippleLayers) {
        if (ring.presentationLayer.opacity < 0.01 || ring.superlayer == nil) {
            [ring removeFromSuperlayer];
            [toRemove addObject:ring];
        }
    }
    [self.rippleLayers removeObjectsInArray:toRemove];
}

#pragma mark - Release helpers

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
    [self.fishBouncingTicks removeAllObjects];
}

- (void)axs_dockfloat_releaseTransforms {
    for (UIView *dock in self.dockViews) {
        dock.transform = CGAffineTransformIdentity;
        for (UIView *icon in dock.subviews) {
            icon.layer.transform = CATransform3DIdentity;
            icon.alpha = 1.0;
        }
    }
}

- (void)axs_dockfloat_releaseFirefly {
    for (CALayer *dot in self.fireflyLayers) {
        [dot removeFromSuperlayer];
    }
    [self.fireflyLayers removeAllObjects];
    [self.fireflyStates removeAllObjects];
}

- (void)axs_dockfloat_releaseStream {
    for (CAGradientLayer *gradient in self.streamLayers) {
        [gradient removeAllAnimations];
        [gradient removeFromSuperlayer];
    }
    [self.streamLayers removeAllObjects];
}

- (void)axs_dockfloat_releaseAll {
    [self axs_dockfloat_releaseTransforms];
    [self.dockViews removeAllObjects];
    [self axs_dockfloat_releaseFish];
    [self axs_dockfloat_releaseFirefly];
    [self axs_dockfloat_releaseStream];
    self.randomOffset = CGPointZero;
    self.randomTarget = CGPointZero;
    self.randomInterval = 0;
    self.randomNextRetarget = 0;
    self.springTicks = 0;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_displayLink invalidate];
}

@end