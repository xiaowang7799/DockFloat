#import "AxsDockFloatPreviewView.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

@interface AxsDockFloatPreviewView ()
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval phase;
@property (nonatomic, strong) NSMutableArray<UIView *> *iconViews;
@end

@implementation AxsDockFloatPreviewView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        _iconViews = [NSMutableArray array];
        // 4 simulated dock icons in a row
        NSArray<UIColor *> *colors = @[
            [UIColor colorWithRed:0.40 green:0.75 blue:1.00 alpha:1.0],
            [UIColor colorWithRed:1.00 green:0.55 blue:0.70 alpha:1.0],
            [UIColor colorWithRed:0.65 green:0.90 blue:0.55 alpha:1.0],
            [UIColor colorWithRed:1.00 green:0.82 blue:0.40 alpha:1.0],
        ];
        CGFloat iconSize = 34.0;
        CGFloat spacing = 18.0;
        CGFloat totalWidth = iconSize * 4 + spacing * 3;
        CGFloat startX = (frame.size.width > 0 ? (frame.size.width - totalWidth) / 2.0 : 0);
        for (NSUInteger i = 0; i < 4; i++) {
            CGFloat x = startX + (iconSize + spacing) * i;
            UIView *icon = [[UIView alloc] initWithFrame:CGRectMake(x, 0, iconSize, iconSize)];
            icon.backgroundColor = colors[i];
            icon.layer.cornerRadius = 8.0;
            icon.layer.masksToBounds = YES;
            [self addSubview:icon];
            [_iconViews addObject:icon];
        }
    }
    return self;
}

- (void)axs_dockfloat_startAnimating {
    if (self.displayLink) return;
    self.phase = 0;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(axs_dockfloat_tick:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)axs_dockfloat_stopAnimating {
    [self.displayLink invalidate];
    self.displayLink = nil;
    self.phase = 0;
    for (UIView *icon in self.iconViews) {
        icon.layer.transform = CATransform3DIdentity;
    }
}

- (void)dealloc {
    [self axs_dockfloat_stopAnimating];
}

- (void)axs_dockfloat_tick:(CADisplayLink *)link {
    double amplitude = 1.0;
    double period = 2.0;
    if ([self.delegate respondsToSelector:@selector(axs_dockfloat_previewAmplitude)]) {
        amplitude = [self.delegate axs_dockfloat_previewAmplitude];
        if (!isfinite(amplitude) || amplitude <= 0) amplitude = 1.0;
    }
    if ([self.delegate respondsToSelector:@selector(axs_dockfloat_previewPeriod)]) {
        period = [self.delegate axs_dockfloat_previewPeriod];
        if (!isfinite(period) || period <= 0) period = 2.0;
    }
    self.phase += link.duration / period;
    double angle = self.phase * M_PI * 2.0;
    CGFloat midY = self.bounds.size.height / 2.0;
    for (NSUInteger i = 0; i < self.iconViews.count; i++) {
        UIView *icon = self.iconViews[i];
        CGFloat bob = (CGFloat)(-6.0 * amplitude * sin(angle + (double)i * 0.9));
        icon.center = CGPointMake(icon.center.x, midY + bob);
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        [self axs_dockfloat_startAnimating];
    } else {
        [self axs_dockfloat_stopAnimating];
    }
}

@end