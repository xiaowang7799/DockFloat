#import "AxsDockFloatRootListController.h"
#import "AxsDockFloatPreferences.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import "AxsDockFloatSliderCell.h"
#import "AxsDockFloatPreviewView.h"

@interface AxsDockFloatRootListController () <AxsDockFloatSliderCellHandler, AxsDockFloatPreviewDelegate>
@property (nonatomic, strong) AxsDockFloatPreviewView *previewView;
@end

@implementation AxsDockFloatRootListController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    // #16: title bar icon
    NSString *iconPath = [[self axs_dockfloat_prefsBundle] pathForResource:@"icon_title" ofType:@"png"];
    if (iconPath) {
        UIImageView *titleView = [[UIImageView alloc] initWithImage:[UIImage imageWithContentsOfFile:iconPath]];
        titleView.contentMode = UIViewContentModeScaleAspectFit;
        titleView.frame = CGRectMake(0, 0, 28, 28);
        self.navigationItem.titleView = titleView;
    }

    // #5: real-time preview as table header
    if (!self.previewView) {
        self.previewView = [[AxsDockFloatPreviewView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 64.0)];
        self.previewView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        self.previewView.delegate = self;
        self.tableView.tableHeaderView = self.previewView;
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    // #17: first-launch guide
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults boolForKey:@"com.axs.dockfloat.hasLaunchedBefore"]) {
        [defaults setBool:YES forKey:@"com.axs.dockfloat.hasLaunchedBefore"];
        [defaults synchronize];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"欢迎使用 Dock浮动"
            message:@"为 Dock 注入灵魂：浮动、翻滚、抖动、鱼缸游鱼、萤火虫粒子、呼吸脉冲、RGB流光……多种动效可叠加混搭，即时生效无需重启桌面。\n\n试试先开启「浮动」模式看看效果吧！"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"开始体验" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }

    // #5: start preview
    [self.previewView axs_dockfloat_startAnimating];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.previewView axs_dockfloat_stopAnimating];
}

#pragma mark - Preview delegate (#5)

- (double)axs_dockfloat_previewAmplitude {
    id value = axs_dockfloat_readPreferences()[@"amplitude"];
    if (![value isKindOfClass:[NSNumber class]]) {
        value = axs_dockfloat_readPreferences()[@"amplitude_float"];
    }
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 1.0;
}

- (double)axs_dockfloat_previewPeriod {
    id value = axs_dockfloat_readPreferences()[@"period"];
    if (![value isKindOfClass:[NSNumber class]]) {
        value = axs_dockfloat_readPreferences()[@"period_float"];
    }
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 2.0;
}

#pragma mark - Specifiers

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [[self loadSpecifiersFromPlistName:@"AxsDockFloatRoot"
                                                           target:self] mutableCopy];

        // #6: inject fish species selector after the fish count slider
        NSUInteger speciesInsert = NSNotFound;
        for (NSUInteger i = 0; i < items.count; i++) {
            PSSpecifier *s = items[i];
            if ([[s propertyForKey:@"key"] isEqualToString:@"fish_count"]) {
                speciesInsert = i + 1;
                break;
            }
        }
        if (speciesInsert != NSNotFound) {
            PSSpecifier *speciesCell = [PSSpecifier preferenceSpecifierNamed:@"选择鱼种"
                target:self set:nil get:nil detail:nil cell:PSTitleValueCell edit:nil];
            [speciesCell setProperty:@"AxsDockFloatSpeciesCell" forKey:@"cellClass"];
            [items insertObject:speciesCell atIndex:speciesInsert];
        }

        // #9: preset group
        [items addObject:[PSSpecifier preferenceSpecifierNamed:@"预设组合" target:self
                     set:nil get:nil detail:nil cell:PSGroupCell edit:nil]];
        [self axs_dockfloat_addPresetButton:@"禅意 — 轻微浮动" action:@selector(axs_dockfloat_loadPresetZen:) to:items];
        [self axs_dockfloat_addPresetButton:@"派对 — 全开大幅" action:@selector(axs_dockfloat_loadPresetParty:) to:items];
        [self axs_dockfloat_addPresetButton:@"水族馆 — 仅鱼缸" action:@selector(axs_dockfloat_loadPresetAquarium:) to:items];
        [self axs_dockfloat_addPresetButton:@"赛博 — 流光+萤火虫" action:@selector(axs_dockfloat_loadPresetCyber:) to:items];
        [self axs_dockfloat_addPresetButton:@"默认 — 恢复出厂" action:@selector(axs_dockfloat_loadPresetDefault:) to:items];

        // About group (existing)
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

- (void)axs_dockfloat_addPresetButton:(NSString *)title action:(SEL)action to:(NSMutableArray *)items {
    PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:title target:self
                          set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    [item setProperty:@(YES) forKey:@"axs_dockfloat_preset"];
    item.buttonAction = action;
    [items addObject:item];
}

#pragma mark - Preset handlers (#9)

static NSDictionary *axs_dockfloat_presetZen(void) {
    return @{
        @"enabled": @YES,
        @"mode_float": @YES, @"amplitude_float": @(0.5), @"period_float": @(4.0),
        @"mode_roll": @NO, @"mode_shake": @NO, @"mode_random": @NO,
        @"mode_fish": @NO, @"mode_firefly": @NO, @"mode_breath": @YES,
        @"use_spring": @YES, @"mode_stream": @NO,
    };
}

static NSDictionary *axs_dockfloat_presetParty(void) {
    return @{
        @"enabled": @YES,
        @"mode_float": @YES, @"amplitude_float": @(6.0), @"period_float": @(1.0),
        @"mode_roll": @YES, @"amplitude_roll": @(8.0), @"period_roll": @(0.8),
        @"mode_shake": @YES, @"amplitude_shake": @(5.0), @"period_shake": @(0.5),
        @"mode_random": @YES, @"amplitude_random": @(8.0), @"period_random": @(1.0),
        @"mode_fish": @YES, @"fish_count": @(6),
        @"mode_firefly": @YES, @"mode_breath": @YES, @"mode_stream": @YES,
        @"use_spring": @NO,
    };
}

static NSDictionary *axs_dockfloat_presetAquarium(void) {
    return @{
        @"enabled": @YES,
        @"mode_float": @NO, @"mode_roll": @NO, @"mode_shake": @NO,
        @"mode_random": @NO, @"mode_fish": @YES, @"fish_count": @(5),
        @"mode_firefly": @NO, @"mode_breath": @NO, @"mode_stream": @NO,
        @"bubble_enabled": @YES, @"bubble_color_mode": @(0), @"bubble_density": @(1.5),
    };
}

static NSDictionary *axs_dockfloat_presetCyber(void) {
    return @{
        @"enabled": @YES,
        @"mode_float": @NO, @"mode_roll": @NO, @"mode_shake": @NO,
        @"mode_random": @YES, @"amplitude_random": @(3.0),
        @"mode_fish": @NO, @"mode_firefly": @YES, @"mode_stream": @YES,
        @"mode_breath": @YES, @"use_spring": @NO,
    };
}

static NSDictionary *axs_dockfloat_presetDefault(void) {
    return @{
        @"enabled": @NO,
        @"mode_float": @NO, @"mode_roll": @NO, @"mode_shake": @NO,
        @"mode_random": @NO, @"mode_fish": @NO, @"mode_firefly": @NO,
        @"mode_breath": @NO, @"mode_stream": @NO,
        @"amplitude": @(1.0), @"period": @(2.0), @"fish_count": @(3),
        @"use_spring": @NO, @"bubble_enabled": @YES,
        @"bubble_color_mode": @(0), @"bubble_size_min": @(6.0),
        @"bubble_size_max": @(12.0), @"bubble_density": @(1.0),
        @"holiday_mode": @(0),
        // Remove per-mode keys so global fallback applies
        @"amplitude_float": [NSNull null],
        @"period_float": [NSNull null],
        @"amplitude_roll": [NSNull null],
        @"period_roll": [NSNull null],
        @"amplitude_shake": [NSNull null],
        @"period_shake": [NSNull null],
        @"amplitude_random": [NSNull null],
        @"period_random": [NSNull null],
    };
}

- (void)axs_dockfloat_applyPreset:(NSDictionary *)preset name:(NSString *)name {
    NSError *error = nil;
    for (NSString *key in preset) {
        id value = preset[key];
        if ([value isEqual:[NSNull null]]) {
            // Remove the key
            NSString *path = axs_dockfloat_preferencesPath();
            NSFileManager *manager = [NSFileManager defaultManager];
            if ([manager fileExistsAtPath:path]) {
                NSMutableDictionary *values = [[axs_dockfloat_readPreferences() mutableCopy] ?: [NSMutableDictionary dictionary] mutableCopy];
                [values removeObjectForKey:key];
                NSData *data = [NSPropertyListSerialization dataWithPropertyList:values
                                             format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
                if (data) [data writeToFile:path options:NSDataWritingAtomic error:nil];
            }
        } else {
            axs_dockfloat_writePreference(key, value, &error);
        }
    }
    if (error) {
        [self axs_dockfloat_showSaveError:error];
    } else {
        [self reloadSpecifiers];
        // Also trigger a config reload in the tweak
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)AxsDockFloatPreferencesChanged, NULL, NULL, true);
    }
}

- (void)axs_dockfloat_loadPresetZen:(id)sender {
    [self axs_dockfloat_confirmPreset:@"禅意" dict:axs_dockfloat_presetZen()];
}

- (void)axs_dockfloat_loadPresetParty:(id)sender {
    [self axs_dockfloat_confirmPreset:@"派对" dict:axs_dockfloat_presetParty()];
}

- (void)axs_dockfloat_loadPresetAquarium:(id)sender {
    [self axs_dockfloat_confirmPreset:@"水族馆" dict:axs_dockfloat_presetAquarium()];
}

- (void)axs_dockfloat_loadPresetCyber:(id)sender {
    [self axs_dockfloat_confirmPreset:@"赛博" dict:axs_dockfloat_presetCyber()];
}

- (void)axs_dockfloat_loadPresetDefault:(id)sender {
    [self axs_dockfloat_confirmPreset:@"默认" dict:axs_dockfloat_presetDefault()];
}

- (void)axs_dockfloat_confirmPreset:(NSString *)name dict:(NSDictionary *)preset {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:name
        message:[NSString stringWithFormat:@"将应用「%@」预设，当前设置将被覆盖。", name]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        [self axs_dockfloat_applyPreset:preset name:name];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Preference read/write

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

#pragma mark - URLs

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

#pragma mark - Slider cell (#8 per-mode support)

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

#pragma mark - Helpers

- (NSBundle *)axs_dockfloat_prefsBundle {
    return [NSBundle bundleForClass:[self class]];
}

@end