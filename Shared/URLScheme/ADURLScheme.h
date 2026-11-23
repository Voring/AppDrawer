//
//  ADURLScheme.h
//  AppDrawer
//
//  AppDrawer 的 scheme 定义。scheme 不注册给 LaunchServices，也没有认领 App：
//  完全靠 SpringBoard 进程内的 URL 分发钩子拦截（与 Kayoko / ShellX 同一套做法）。
//

#import <Foundation/Foundation.h>

extern NSString *const ADURLSchemeName;
extern NSString *const ADPreferencesDomain;

BOOL ADURLIsAppDrawerURL(NSURL *URL);

NSString *ADRequestDirectoryPath(void);
