#import "ADURLScheme.h"

NSString *const ADURLSchemeName = @"appdrawer";
NSString *const ADPreferencesDomain = @"com.voring.appdrawer";

NSString *ADRequestDirectoryPath(void) {
    return @"/var/mobile/Library/Preferences/com.voring.appdrawer";
}

BOOL ADURLIsAppDrawerURL(NSURL *URL) {
    if (![URL isKindOfClass:[NSURL class]]) {
        return NO;
    }
    return [[[URL scheme] lowercaseString] isEqualToString:ADURLSchemeName];
}
