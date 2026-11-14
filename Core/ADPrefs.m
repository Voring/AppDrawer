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

CGFloat ADPrefPanelHeightPercent(void) {
    id value = ADPreferences()[@"PanelHeightPercent"];
    double percent = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.55;
    if (percent > 1.0) {
        percent /= 100.0;
    }
    return MAX(0.35, MIN(0.85, percent));
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

BOOL ADPrefForceScreenCoreFloating(void) {
    id value = ADPreferences()[@"ForceScreenCoreFloating"];
    if (![value respondsToSelector:@selector(boolValue)]) {
        return NO;
    }
    return [value boolValue];
}

UIBlurEffectStyle ADPrefBlurStyle(void) {
    id value = ADPreferences()[@"BlurStyle"];
    NSInteger style = [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
    switch (style) {
        case 1:
            return UIBlurEffectStyleSystemMaterialLight;
        case 2:
            return UIBlurEffectStyleSystemMaterialDark;
        case 3:
            return UIBlurEffectStyleSystemChromeMaterial;
        case 4:
            return UIBlurEffectStyleSystemChromeMaterialDark;
        default:
            return UIBlurEffectStyleSystemMaterial;
    }
}
