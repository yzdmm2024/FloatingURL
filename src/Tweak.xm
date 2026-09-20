#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

// ============================================================
// 悬浮URL —— 系统级悬浮窗 tweak（rootless / iOS16 / A14 arm64e）
// 作者：yzdmm   包名：com.yzdmm.floatingurl
// 功能：屏幕边缘常驻可拖动小球，点开加载设置里填的网址，
//      全 App 可用。URL / 总开关 / 窗口大小均在「设置」里调。
//
// ★ 关键修复（参考「我的语音」插件验证过的悬浮按钮做法）：
//   不创建独立的 UIWindow（windowLevel 调高那套在 iOS 上经常不显示，
//   容易整窗丢失/层级盖不住）。改为直接把悬浮球 / 网页面板
//   addSubview 到宿主已有的 key window 上（fuAnyWindow 多层兜底取窗），
//   显示网页时 bringSubviewToFront，保证永远在最上层。
// ============================================================

// 设 1 可让悬浮球也出现在主屏幕（SpringBoard）。
// 注意：你自己的「方法说明」文档把注入 SpringBoard 列为红线
// （键盘类 tweak 曾因此卡死 + 注销重启）。悬浮球本身很轻量，
// 但为安全默认关闭；要主屏幕也显示，把这里改成 1 并接受极小风险。
#define INCLUDE_SPRINGBOARD 0

static NSString * const kFUSuite        = @"com.yzdmm.floatingurl";
static NSString * const kFUPrefsChanged = @"com.yzdmm.floatingurl/settingsChanged";

// ---- 取一个可用窗口（综合 MyVoice 的 anyWindow + FloatGlass 的 fg_keyWindow）----
// 优先取「前台激活 windowScene」的 keyWindow（iOS13+ 多 scene 下 keyWindow 经常是 nil，
// 且非激活 scene 的窗拿来做挂载会不可见），逐层兜底。只能主线程调用。
static UIWindow *fuAnyWindow() {
    UIApplication *app = UIApplication.sharedApplication;
    if (!app) return nil;
    for (UIScene *s in app.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            ((UIWindowScene *)s).activationState == UISceneActivationStateForegroundActive) {
            UIWindowScene *ws = (UIWindowScene *)s;
            for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
            for (UIWindow *w in ws.windows) if (w.rootViewController) return w;
            if (ws.windows.count) return ws.windows.firstObject;
        }
    }
    UIWindow *kw = app.keyWindow;
    if (kw) return kw;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) return w;
    }
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindow *w = ((UIWindowScene *)scene).windows.firstObject;
        if (w) return w;
    }
    return app.windows.firstObject;
}

@interface FUFloatingManager : NSObject <WKNavigationDelegate>
+ (instancetype)shared;
- (void)reloadPrefs;
- (void)setupWhenHostReady;
- (void)applyVisibility;
@end

@implementation FUFloatingManager {
    UIButton              *_ball;
    UIView                *_panel;
    WKWebView             *_webView;
    UIActivityIndicatorView *_spinner;
    UILabel               *_titleLabel;
    BOOL                  _expanded;
    BOOL                  _didSetup;
    BOOL                  _enabled;
    NSString              *_url;
    CGFloat               _winW;
    CGFloat               _winH;
    CGPoint               _ballDragOrigin;
}

+ (instancetype)shared {
    static FUFloatingManager *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[FUFloatingManager alloc] init]; });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _enabled  = YES;
        _url      = @"https://www.apple.com";
        _winW     = 340;
        _winH     = 480;
        _expanded = NO;
        _didSetup = NO;
        [self reloadPrefs];
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)(self),
            &fuPrefsChanged,
            (__bridge CFStringRef)kFUPrefsChanged,
            NULL,
            CFNotificationSuspensionBehaviorCoalesce);
    }
    return self;
}

static void fuPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    FUFloatingManager *mgr = (__bridge FUFloatingManager *)observer;
    // Darwin 通知可能在任意线程到达，一律回主线程处理 UI。
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ fuPrefsChanged(center, observer, name, object, userInfo); });
        return;
    }
    [mgr reloadPrefs];
    if (mgr->_expanded) {
        [mgr->_titleLabel setText:mgr->_url];
        [mgr loadURL];
    }
    [mgr applyVisibility];
}

- (void)reloadPrefs {
    Boolean valid;
    BOOL en = CFPreferencesGetAppBooleanValue(CFSTR("enabled"),
                 (__bridge CFStringRef)kFUSuite, &valid);
    _enabled = valid ? en : YES;

    CFPropertyListRef urlRef = CFPreferencesCopyAppValue(CFSTR("url"),
                       (__bridge CFStringRef)kFUSuite);
    if (urlRef) {
        NSString *u = (__bridge_transfer NSString *)urlRef;
        if (u.length) _url = u;
    }

    CFPropertyListRef wRef = CFPreferencesCopyAppValue(CFSTR("winWidth"),
                                (__bridge CFStringRef)kFUSuite);
    if (wRef && CFGetTypeID(wRef) == CFNumberGetTypeID()) {
        _winW = [(__bridge NSNumber *)wRef floatValue];
        CFRelease(wRef);
    }
    CFPropertyListRef hRef = CFPreferencesCopyAppValue(CFSTR("winHeight"),
                                (__bridge CFStringRef)kFUSuite);
    if (hRef && CFGetTypeID(hRef) == CFNumberGetTypeID()) {
        _winH = [(__bridge NSNumber *)hRef floatValue];
        CFRelease(hRef);
    }
    if (_winW < 200) _winW = 200;
    if (_winW > 600) _winW = 600;
    if (_winH < 280) _winH = 280;
    if (_winH > 900) _winH = 900;
}

// 把视图挂到当前 key window 上（窗口换了就重新挂，避免跑到旧 window 上）。
- (void)attachToWindow:(UIWindow *)w {
    if (!w) return;
    if (_ball && _ball.superview != w) {
        [_ball removeFromSuperview];
        [w addSubview:_ball];
    }
    if (_panel && _panel.superview != w) {
        [_panel removeFromSuperview];
        [w addSubview:_panel];
    }
}

- (void)setupWhenHostReady {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self setupWhenHostReady]; }); return; }
    static BOOL done = NO;
    if (done) return;
    UIWindow *w = fuAnyWindow();
    if (!w) {
        // 启动瞬间窗口还没就位，0.4s 后再试（轮询，最多撑到它出现）。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self setupWhenHostReady]; });
        return;
    }
    done = YES;
    [self buildUI:w];
    [self applyVisibility];
}

- (void)buildUI:(UIWindow *)w {
    _didSetup = YES;

    // ---- 悬浮球（直接挂到 key window）----
    _ball = [UIButton buttonWithType:UIButtonTypeCustom];
    _ball.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.92];
    [_ball setTitle:@"URL" forState:UIControlStateNormal];
    _ball.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [_ball setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _ball.layer.cornerRadius = 28;
    _ball.clipsToBounds = YES;
    _ball.layer.shadowColor = [UIColor blackColor].CGColor;
    _ball.layer.shadowOpacity = 0.4f;
    _ball.layer.shadowRadius = 4.0f;
    _ball.layer.shadowOffset = CGSizeZero;
    [_ball addTarget:self action:@selector(ballTapped)
            forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(panBall:)];
    [_ball addGestureRecognizer:pan];
    [w addSubview:_ball];
    [self placeBallInWindow:w];

    // ---- 网页面板（普通 UIView，挂到同一 window，显示时置顶）----
    _panel = [[UIView alloc] initWithFrame:CGRectZero];
    _panel.backgroundColor = [UIColor systemBackgroundColor];
    _panel.layer.cornerRadius = 12.0f;
    _panel.clipsToBounds = YES;
    _panel.hidden = YES;

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _winW, 44)];
    bar.backgroundColor = [UIColor secondarySystemBackgroundColor];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    // 顶部工具条可拖动整个面板
    UIPanGestureRecognizer *panelPan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(panPanel:)];
    [bar addGestureRecognizer:panelPan];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    close.frame = CGRectMake(8, 0, 56, 44);
    [close addTarget:self action:@selector(collapse)
            forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:close];

    UIButton *reload = [UIButton buttonWithType:UIButtonTypeSystem];
    [reload setTitle:@"刷新" forState:UIControlStateNormal];
    reload.frame = CGRectMake(_winW - 64, 0, 56, 44);
    reload.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [reload addTarget:self action:@selector(reload)
             forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:reload];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(68, 0, _winW - 136, 44)];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.font = [UIFont systemFontOfSize:11];
    _titleLabel.textColor = [UIColor secondaryLabelColor];
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _titleLabel.text = _url;
    _titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [bar addSubview:_titleLabel];
    [_panel addSubview:bar];

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    _webView = [[WKWebView alloc] initWithFrame:CGRectMake(0, 44, _winW, _winH - 44)
                                   configuration:cfg];
    _webView.navigationDelegate = self;
    _webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_panel addSubview:_webView];

    _spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.center = CGPointMake(_winW / 2.0, _winH / 2.0);
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                UIViewAutoresizingFlexibleRightMargin |
                                UIViewAutoresizingFlexibleTopMargin |
                                UIViewAutoresizingFlexibleBottomMargin;
    [_panel addSubview:_spinner];

    [w addSubview:_panel];
}

- (void)placeBallInWindow:(UIWindow *)w {
    if (!_ball || !w) return;
    _ball.frame = CGRectMake(w.bounds.size.width - 56 - 6,
                             w.bounds.size.height * 0.45,
                             56, 56);
}

#pragma mark - 交互

- (void)ballTapped { _expanded ? [self collapse] : [self expand]; }

- (void)panBall:(UIPanGestureRecognizer *)g {
    UIWindow *w = fuAnyWindow();
    if (!w) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        _ballDragOrigin = _ball.frame.origin;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:w];
        CGRect f = _ball.frame;
        f.origin.x = _ballDragOrigin.x + t.x;
        f.origin.y = _ballDragOrigin.y + t.y;
        f.origin.x = MAX(0, MIN(w.bounds.size.width  - f.size.width,  f.origin.x));
        f.origin.y = MAX(0, MIN(w.bounds.size.height - f.size.height, f.origin.y));
        _ball.frame = f;
    } else if (g.state == UIGestureRecognizerStateEnded) {
        // 松手吸附到最近屏幕边缘
        CGRect f = _ball.frame;
        CGFloat cx = CGRectGetMidX(f);
        CGFloat targetX = (cx < w.bounds.size.width / 2.0) ? 4 : w.bounds.size.width - f.size.width - 4;
        [UIView animateWithDuration:0.3 delay:0
             usingSpringWithDamping:0.7 initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ _ball.frame = CGRectMake(targetX, f.origin.y, f.size.width, f.size.height); }
                         completion:nil];
    }
}

- (void)panPanel:(UIPanGestureRecognizer *)g {
    UIWindow *w = _panel.superview;
    if (!w) return;
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:w];
        CGRect f = _panel.frame;
        f.origin.x += t.x; f.origin.y += t.y;
        f.origin.x = MAX(0, MIN(w.bounds.size.width  - f.size.width,  f.origin.x));
        f.origin.y = MAX(0, MIN(w.bounds.size.height - f.size.height, f.origin.y));
        _panel.frame = f;
        [g setTranslation:CGPointZero inView:w];
    }
}

- (void)expand {
    UIWindow *w = fuAnyWindow();
    if (!w || !_didSetup) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self expand]; });
        return;
    }
    [self attachToWindow:w];
    CGFloat ww = _winW, hh = _winH;
    CGRect s = w.bounds;
    _panel.frame = CGRectMake((s.size.width - ww) / 2.0,
                             (s.size.height - hh) / 2.0, ww, hh);
    [_titleLabel setText:_url];
    [self loadURL];
    [w bringSubviewToFront:_panel];
    _panel.hidden = NO;
    _ball.hidden  = YES;
    _expanded = YES;
}

- (void)collapse {
    _panel.hidden = YES;
    _ball.hidden  = !_enabled;
    _expanded = NO;
}

- (void)reload { [self loadURL]; }

- (void)loadURL {
    NSURL *u = [NSURL URLWithString:_url];
    if (!u || u.scheme == nil) u = [NSURL URLWithString:@"https://www.apple.com"];
    [_webView loadRequest:[NSURLRequest requestWithURL:u]];
}

- (void)applyVisibility {
    if (!_didSetup) return;
    UIWindow *w = fuAnyWindow();
    [self attachToWindow:w];
    if (!_enabled) {
        _ball.hidden  = YES;
        _panel.hidden = YES;
        return;
    }
    if (!_expanded) {
        _ball.hidden = NO;
        [w bringSubviewToFront:_ball];
    }
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)nav {
    [_spinner startAnimating];
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)nav {
    [_spinner stopAnimating];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)nav withError:(NSError *)error {
    [_spinner stopAnimating];
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)nav withError:(NSError *)error {
    [_spinner stopAnimating];
}

@end

// ============================================================
// 注入入口：所有 App 都注入（Filter: AnyApplication），
// 但设置进程（避开看门狗）和默认的主屏幕进程里不初始化。
// ============================================================
%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if ([bid isEqualToString:@"com.apple.Preferences"]) return;       // 避开设置进程看门狗
        if (!INCLUDE_SPRINGBOARD && [bid isEqualToString:@"com.apple.springboard"]) return;

        // 启动完成后（UIApplicationDidFinishLaunching）再建 UI；
        // 同时兜底 1.5s 强制检查一次（防止错过该通知的非标准启动路径）。
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note){
                        [[FUFloatingManager shared] setupWhenHostReady];
                    }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[FUFloatingManager shared] setupWhenHostReady];
        });
    }
}
