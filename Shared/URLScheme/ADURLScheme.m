#import "ADURLScheme.h"

NSString *const ADURLSchemeName = @"appdrawer";
NSString *const ADOpenRequestNotification = @"com.voring.appdrawer.openrequest";
NSString *const ADPreferencesDomain = @"com.voring.appdrawer";

NSString *ADRequestDirectoryPath(void) {
    return @"/var/mobile/Library/Preferences/com.voring.appdrawer";
}

static NSString *ADRequestFilePath(void) {
    return [ADRequestDirectoryPath() stringByAppendingPathComponent:@"pending.url"];
}

BOOL ADURLIsAppDrawerURL(NSURL *URL) {
    if (![URL isKindOfClass:[NSURL class]]) {
        return NO;
    }
    return [[[URL scheme] lowercaseString] isEqualToString:ADURLSchemeName];
}

BOOL ADSubmitOpenRequest(NSURL *URL) {
    if (!ADURLIsAppDrawerURL(URL)) {
        return NO;
    }

    NSString *directory = ADRequestDirectoryPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];

    NSString *payload = [NSString stringWithFormat:@"%.0f\n%@\n",
                                                   [[NSDate date] timeIntervalSince1970],
                                                   [URL absoluteString]];
    BOOL written = [payload writeToFile:ADRequestFilePath()
                                atomically:YES
                                  encoding:NSUTF8StringEncoding
                                     error:NULL];

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)ADOpenRequestNotification,
                                         NULL,
                                         NULL,
                                         true);
    return written;
}

NSURL *ADConsumeOpenRequest(void) {
    NSString *path = ADRequestFilePath();
    NSString *body = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];

    NSArray<NSString *> *lines = [body componentsSeparatedByString:@"\n"];
    if (lines.count < 2) {
        return nil;
    }

    NSString *urlString = lines[1];
    if (urlString.length == 0) {
        return nil;
    }
    return [NSURL URLWithString:urlString];
}
