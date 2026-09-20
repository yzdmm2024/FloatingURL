#import <Preferences/Preferences.h>
#import <notify.h>

@interface FUSettingsController : PSListController
@end

@implementation FUSettingsController

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // 退出面板时通知悬浮窗重新读取设置（URL / 开关 / 窗口大小）
    notify_post("com.yzdmm.floatingurl/settingsChanged");
}

@end
