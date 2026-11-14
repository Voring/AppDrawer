//
//  ADURLScheme.h
//  AppDrawer
//
//  插件本体（SpringBoard 内）与 URL 认领 App 共用的 scheme 定义与请求通道。
//  通道只用真实路径 /var/mobile/Library/Preferences/com.voring.appdrawer，
//  不涉及 jbroot()，因此独立 App 里不需要链接 libroothide。
//

#import <Foundation/Foundation.h>

extern NSString *const ADURLSchemeName;
extern NSString *const ADOpenRequestNotification;
extern NSString *const ADPreferencesDomain;

BOOL ADURLIsAppDrawerURL(NSURL *URL);

NSString *ADRequestDirectoryPath(void);

// App 侧：把 URL 落盘 + 发 Darwin 通知，随后可以立刻退出。
BOOL ADSubmitOpenRequest(NSURL *URL);

// SpringBoard 侧：取出并删除待处理请求。
NSURL *ADConsumeOpenRequest(void);
