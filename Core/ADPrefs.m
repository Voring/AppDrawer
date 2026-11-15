#import "ADPrefs.h"

#import "../Shared/URLScheme/ADURLScheme.h"

static NSDictionary *ADPreferences(void) {
    NSString *path = [@"/var/mobile/Library/Preferences"
        stringByAppendingPathComponent:[ADPreferencesDomain stringByAppendingPathExtension:@"plist"]];
    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:path];
    return [preferences isKindOfClass:[NSDictionary class]] ? preferences : @{};
}

NSInteger ADPrefColumns(void) {
    id value = ADPreferences()[@"Columns"];
    NSInteger columns = [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 4;
    return MAX(3, MIN(6, columns));
}

CGFloat ADPrefPanelCornerRadius(void) {
    id value = ADPreferences()[@"PanelCornerRadius"];
    double radius = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 28.0;
    return MAX(0.0, MIN(44.0, radius));
}

BOOL ADPrefShowSystemApps(void) {
    id value = ADPreferences()[@"ShowSystemApps"];
    if (![value respondsToSelector:@selector(boolValue)]) {
        return YES;
    }
    return [value boolValue];
}

ADLauncherMode ADPrefLauncherMode(void) {
    id value = ADPreferences()[@"LauncherMode"];
    if (![value respondsToSelector:@selector(integerValue)]) {
        return ADLauncherModeScreenCore;
    }
    return [value integerValue] == ADLauncherModeLaunchServices ? ADLauncherModeLaunchServices
                                                               : ADLauncherModeScreenCore;
}
