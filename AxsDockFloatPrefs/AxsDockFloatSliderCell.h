#pragma once

#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#include <math.h>

@protocol AxsDockFloatSliderCellHandler <NSObject>
- (double)axs_dockfloat_sliderValueForSpecifier:(PSSpecifier *)specifier;
- (void)axs_dockfloat_setSliderValue:(double)value specifier:(PSSpecifier *)specifier;
@end

@interface AxsDockFloatSliderCell : PSTableCell
@property (nonatomic, weak) id<AxsDockFloatSliderCellHandler> handler;
- (void)axs_dockfloat_reloadState;
@end
