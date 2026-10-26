#import "AxsDockFloatSpeciesCell.h"
#import <UIKit/UIKit.h>

static NSArray<NSString *> *axs_dockfloat_allSpecies(void) {
    static NSArray<NSString *> *species;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        species = @[@"🐟", @"🐠", @"🐡", @"🦈", @"🐙", @"🦀", @"🐢", @"🐬"];
    });
    return species;
}

@interface AxsDockFloatSpeciesCell ()
@property (nonatomic, strong) NSMutableArray<UIButton *> *buttons;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedSet;
@end

@implementation AxsDockFloatSpeciesCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier specifier:specifier];
    if (self) {
        self.textLabel.text = @"选择鱼种";
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _buttons = [NSMutableArray array];
        _selectedSet = [NSMutableSet set];
        [self axs_dockfloat_loadSelection];
        [self axs_dockfloat_buildButtons];
    }
    return self;
}

- (void)axs_dockfloat_loadSelection {
    NSArray *all = axs_dockfloat_allSpecies();
    // Read the user's saved selection.
    NSString *path = @"/var/mobile/Library/Preferences/com.axs.dockfloat.plist";
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
    id savedString = prefs[@"fish_species"];
    if ([savedString isKindOfClass:[NSString class]] && [(NSString *)savedString length] > 0) {
        NSData *data = [(NSString *)savedString dataUsingEncoding:NSUTF8StringEncoding];
        if (data) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([parsed isKindOfClass:[NSArray class]]) {
                for (NSString *s in parsed) {
                    if ([s isKindOfClass:[NSString class]] && [all containsObject:s]) {
                        [self.selectedSet addObject:s];
                    }
                }
            }
        }
    }
    // Default: select all if nothing is saved.
    if (self.selectedSet.count == 0) {
        [self.selectedSet addObjectsFromArray:all];
    }
}

- (void)axs_dockfloat_buildButtons {
    for (UIButton *btn in self.buttons) {
        [btn removeFromSuperview];
    }
    [self.buttons removeAllObjects];

    NSArray *all = axs_dockfloat_allSpecies();
    for (NSUInteger i = 0; i < all.count; i++) {
        NSString *species = all[i];
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.tag = i;
        [btn setTitle:species forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:28];
        btn.layer.cornerRadius = 10.0;
        btn.layer.masksToBounds = YES;
        [btn addTarget:self action:@selector(axs_dockfloat_toggleSpecies:) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:btn];
        [self.buttons addObject:btn];
        [self axs_dockfloat_updateButton:btn species:species];
    }
    [self setNeedsLayout];
}

- (void)axs_dockfloat_updateButton:(UIButton *)btn species:(NSString *)species {
    BOOL selected = [self.selectedSet containsObject:species];
    btn.backgroundColor = selected
        ? [UIColor colorWithRed:0.20 green:0.60 blue:1.00 alpha:0.30]
        : [UIColor colorWithRed:0.85 green:0.85 blue:0.85 alpha:0.25];
    btn.layer.borderWidth = selected ? 2.0 : 0.5;
    btn.layer.borderColor = selected
        ? [UIColor colorWithRed:0.20 green:0.60 blue:1.00 alpha:1.0].CGColor
        : [UIColor colorWithRed:0.70 green:0.70 blue:0.70 alpha:1.0].CGColor;
}

- (void)axs_dockfloat_toggleSpecies:(UIButton *)sender {
    NSString *species = axs_dockfloat_allSpecies()[sender.tag];
    if ([self.selectedSet containsObject:species]) {
        if (self.selectedSet.count > 1) { // keep at least 1 selected
            [self.selectedSet removeObject:species];
        }
    } else {
        [self.selectedSet addObject:species];
    }
    [self axs_dockfloat_updateButton:sender species:species];
    [self axs_dockfloat_saveSelection];
}

- (void)axs_dockfloat_saveSelection {
    NSError *error = nil;
    NSArray *sorted = [[self.selectedSet allObjects] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger ia = [axs_dockfloat_allSpecies() indexOfObject:a];
        NSInteger ib = [axs_dockfloat_allSpecies() indexOfObject:b];
        return [@(ia) compare:@(ib)];
    }];
    NSData *data = [NSJSONSerialization dataWithJSONObject:sorted options:0 error:&error];
    if (!data) return;
    NSString *jsonString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!jsonString) return;

    NSString *path = @"/var/mobile/Library/Preferences/com.axs.dockfloat.plist";
    NSFileManager *manager = [NSFileManager defaultManager];
    NSMutableDictionary *values;
    if ([manager fileExistsAtPath:path]) {
        NSData *existing = [NSData dataWithContentsOfFile:path options:0 error:nil];
        id decoded = existing ? [NSPropertyListSerialization propertyListWithData:existing
                              options:NSPropertyListMutableContainers format:NULL error:nil] : nil;
        values = [decoded isKindOfClass:[NSDictionary class]] ? [decoded mutableCopy] : [NSMutableDictionary dictionary];
    } else {
        values = [NSMutableDictionary dictionary];
    }
    values[@"fish_species"] = jsonString;
    [manager createDirectoryAtPath:[path stringByDeletingLastPathComponent]
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:values
                         format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    [plist writeToFile:path options:NSDataWritingAtomic error:nil];
    // Also notify the tweak.
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)@"com.axs.dockfloat.preferences-changed", NULL, NULL, true);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat margin = 16.0;
    CGFloat btnSize = 42.0;
    CGFloat gap = 6.0;
    CGFloat availableWidth = self.contentView.bounds.size.width - margin * 2;
    // 8 buttons in 2 rows of 4.
    for (NSUInteger i = 0; i < self.buttons.count; i++) {
        NSUInteger row = i / 4;
        NSUInteger col = i % 4;
        CGFloat cx = (availableWidth - (btnSize * 4 + gap * 3)) / 2.0;
        CGFloat x = margin + cx + (btnSize + gap) * col;
        CGFloat y = 34.0 + (btnSize + gap) * row;
        self.buttons[i].frame = CGRectMake(x, y, btnSize, btnSize);
    }
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self axs_dockfloat_loadSelection];
    for (NSUInteger i = 0; i < self.buttons.count && i < axs_dockfloat_allSpecies().count; i++) {
        [self axs_dockfloat_updateButton:self.buttons[i] species:axs_dockfloat_allSpecies()[i]];
    }
}

@end