#pragma once

#import <UIKit/UIKit.h>

@protocol AxsDockFloatPreviewDelegate <NSObject>
- (double)axs_dockfloat_previewAmplitude;
- (double)axs_dockfloat_previewPeriod;
@end

@interface AxsDockFloatPreviewView : UIView
@property (nonatomic, weak) id<AxsDockFloatPreviewDelegate> delegate;
- (void)axs_dockfloat_startAnimating;
- (void)axs_dockfloat_stopAnimating;
@end