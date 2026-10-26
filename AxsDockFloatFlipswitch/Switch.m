#import <Foundation/Foundation.h>
#import <Flipswitch/Flipswitch.h>
#import <notify.h>

static NSString *const kDomain = @"com.axs.dockfloat";
static NSString *const kEnabledKey = @"enabled";
static NSString *const kChangedNotification = @"com.axs.dockfloat.preferences-changed";

@interface AxsDockFloatFlipswitch : NSObject <FSSwitchDataSource>
@end

@implementation AxsDockFloatFlipswitch

- (FSSwitchState)stateForSwitchIdentifier:(NSString *)switchIdentifier {
    NSDictionary *prefs = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    [prefs synchronize];
    id enabled = [prefs persistentDomainForName:kDomain][kEnabledKey];
    if ([enabled isKindOfClass:[NSNumber class]]) {
        return [enabled boolValue] ? FSSwitchStateOn : FSSwitchStateOff;
    }
    // Also try the binary plist path, same as tweak's read path.
    NSString *path = @"/var/mobile/Library/Preferences/com.axs.dockfloat.plist";
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
    id plistEnabled = plist[kEnabledKey];
    if ([plistEnabled isKindOfClass:[NSNumber class]]) {
        return [plistEnabled boolValue] ? FSSwitchStateOn : FSSwitchStateOff;
    }
    return FSSwitchStateOff;
}

- (void)applyState:(FSSwitchState)state forSwitchIdentifier:(NSString *)switchIdentifier {
    BOOL enable = (state == FSSwitchStateOn);
    NSString *path = @"/var/mobile/Library/Preferences/com.axs.dockfloat.plist";
    NSMutableDictionary *values;
    NSFileManager *manager = [NSFileManager defaultManager];
    if ([manager fileExistsAtPath:path]) {
        NSData *data = [NSData dataWithContentsOfFile:path options:0 error:nil];
        id decoded = data ? [NSPropertyListSerialization propertyListWithData:data
                              options:NSPropertyListMutableContainers format:NULL error:nil] : nil;
        if ([decoded isKindOfClass:[NSDictionary class]]) {
            values = [decoded mutableCopy];
        }
    }
    if (!values) {
        values = [NSMutableDictionary dictionary];
    }
    values[kEnabledKey] = @(enable);
    if (![manager createDirectoryAtPath:[path stringByDeletingLastPathComponent]
            withIntermediateDirectories:YES attributes:nil error:nil]) {
        return;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:values
                         format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (data) {
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
    }
    // Mirror to NSUserDefaults and notify.
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    [defaults setPersistentDomain:values forName:kDomain];
    [defaults synchronize];
    notify_post([kChangedNotification UTF8String]);
}

- (NSString *)titleForSwitchIdentifier:(NSString *)switchIdentifier {
    return @"Dock浮动";
}

@end