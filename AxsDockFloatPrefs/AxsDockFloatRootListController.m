#import "AxsDockFloatRootListController.h"
#import "AxsDockFloatPreferences.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import "AxsDockFloatSliderCell.h"

@interface AxsDockFloatRootListController () <AxsDockFloatSliderCellHandler>
@end

@implementation AxsDockFloatRootListController

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [[self loadSpecifiersFromPlistName:@"AxsDockFloatRoot"
                                                           target:self] mutableCopy];
        [items addObject:[PSSpecifier preferenceSpecifierNamed:@"关于我们" target:self
                     set:nil get:nil detail:nil cell:PSGroupCell edit:nil]];
        [self axs_dockfloat_addButton:@"Sileo 越狱源" action:@selector(axs_dockfloat_openRepository:) to:items];
        [self axs_dockfloat_addButton:@"TG分享频道" action:@selector(axs_dockfloat_openTelegram:) to:items];
        [self axs_dockfloat_addButton:@"QQ交流群组" action:@selector(axs_dockfloat_openQQ:) to:items];
        _specifiers = items;
    }
    return _specifiers;
}

- (void)axs_dockfloat_addButton:(NSString *)title action:(SEL)action to:(NSMutableArray *)items {
    PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:title target:self
                          set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    item.buttonAction = action;
    [items addObject:item];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) return nil;
    return axs_dockfloat_readPreferences()[key] ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) return;
    NSError *error = nil;
    if (!axs_dockfloat_writePreference(key, value, &error)) {
        [self axs_dockfloat_showSaveError:error];
    }
}

- (void)axs_dockfloat_showSaveError:(NSError *)error {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"设置未保存"
        message:error.localizedDescription ?: @"请检查配置文件路径和写入权限。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    [self reloadSpecifiers];
}

- (void)axs_dockfloat_openURL:(NSURL *)url fallback:(NSURL *)fallback {
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        if (success) return;
        if (fallback) {
            [self axs_dockfloat_openURL:fallback fallback:nil];
        } else {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法打开链接"
                message:@"请确认已安装对应应用。" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }];
}

- (void)axs_dockfloat_openRepository:(id)sender {
    NSString *source = @"https://axs66.github.io/pro";
    // Encode the entire URL as a path component, including its own delimiters.
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                              @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *encoded = [source stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSURL *primary = [NSURL URLWithString:[@"sileo://source/" stringByAppendingString:encoded]];
    [self axs_dockfloat_openURL:primary fallback:[NSURL URLWithString:source]];
}

- (void)axs_dockfloat_openTelegram:(id)sender {
    [self axs_dockfloat_openURL:[NSURL URLWithString:@"tg://resolve?domain=wxfx8"]
                   fallback:[NSURL URLWithString:@"https://t.me/wxfx8"]];
}

- (void)axs_dockfloat_openQQ:(id)sender {
    [self axs_dockfloat_openURL:[NSURL URLWithString:@"mqqapi://card/show_pslcard?src_type=internal&version=1&uin=678055716&card_type=group&source=qrcode"] fallback:nil];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([PSListController instancesRespondToSelector:_cmd]) {
        [super tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath];
    }
    if ([cell isKindOfClass:[AxsDockFloatSliderCell class]]) {
        AxsDockFloatSliderCell *sliderCell = (AxsDockFloatSliderCell *)cell;
        sliderCell.handler = self;
        [sliderCell axs_dockfloat_reloadState];
    }
}

- (double)axs_dockfloat_sliderValueForSpecifier:(PSSpecifier *)specifier {
    id value = [self readPreferenceValue:specifier];
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0.0;
}

- (void)axs_dockfloat_setSliderValue:(double)value specifier:(PSSpecifier *)specifier {
    double minimum = [[specifier propertyForKey:@"min"] doubleValue];
    double maximum = [[specifier propertyForKey:@"max"] doubleValue];
    if (!isfinite(minimum)) minimum = 0.0;
    if (!isfinite(maximum) || maximum <= minimum) maximum = minimum + 1.0;
    if (!isfinite(value)) value = minimum;
    [self setPreferenceValue:@(fmax(minimum, fmin(maximum, value))) specifier:specifier];
}

@end
