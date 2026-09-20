#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

// ============================================================
// 悬浮URL —— 系统级悬浮窗 tweak（rootless / iOS16 / A14 arm64e）
// 作者：yzdmm   包名：com.yzdmm.floatingurl
// 功能：屏幕边缘常驻可拖动小球，点开加载设置里填的网址，
//      全 App 可用。URL / 总开关 / 窗口大小均在「设置」里调。
// ============================================================

// 设 1 可让悬浮球也出现在主屏幕（SpringBoard）。
// 注意：你自己的「方法说明」文档把注入 SpringBoard 列为红线
// （键盘类 tweak 曾因此卡死 + 注销重启）。悬浮球本身很轻量，
// 但为安全默认关闭；要主屏幕也显示，把这里改成 1 并接受极小风险。
#define INCLUDE_SPRINGBOARD 0

static NSString * const kFUSuite         = @"com.yzdmm.floatingurl";
static NSString * const kFUPrefsChanged  = @"com.yzdmm.floatingurl/settingsChanged";

@interface FUFloatingManager : NSObject <WKNavigationDelegate>
+ (instancetype)shared;
- (void)reloadPrefs;
- (void)setupIfNeeded;
- (void)applyVisibility;
@end

@implementation FUFloatingManager {
    UIWindow *_ballWindow;
    UIButton *_ball;
    UIWindow *_webWindow;
    WKWebView *_webView;
    UIActivityIndicatorView *_spinner;
    UILabel  *_titleLabel;
    BOOL _expanded;
    BOOL _didSetup;
    CGPoint _ballDragOrigin;
    BOOL _enabled;
    NSString *_url;
    CGFloat _winW;
    CGFloat _winH;
}

+ (instancetype)shared {
    static FUFloatingManager *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[FUFloatingManager alloc] init]; });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _enabled = YES;
        _url     = @"https://www.apple.com";
        _winW    = 340;
        _winH    = 480;
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

    CFStringRef urlRef = CFPreferencesCopyAppValue(CFSTR("url"),
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

- (UIWindowScene *)activeScene {
    UIWindow *kw = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { kw = w; break; }
    }
    if (!kw) kw = [[UIApplication sharedApplication].windows firstObject];
    return kw.windowScene;
}

- (void)setupIfNeeded {
    if (_didSetup) return;
    UIWindowScene *scene = [self activeScene];
    if (!scene) {
        // 个别 App 启动瞬间 keyWindow 还没就位，0.5s 后重试
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self setupIfNeeded]; });
        return;
    }
    _didSetup = YES;

    // ---- 小球窗口 ----
    _ballWindow = [[UIWindow alloc] initWithFrame:CGRectZero];
    _ballWindow.windowLevel = 1500.0;
    _ballWindow.backgroundColor = [UIColor clearColor];
    _ballWindow.windowScene = scene;
    _ballWindow.hidden = YES;

    UIViewController *ballVC = [[UIViewController alloc] init];
    ballVC.view.backgroundColor = [UIColor clearColor];
    _ballWindow.rootViewController = ballVC;

    _ball = [UIButton buttonWithType:UIButtonTypeCustom];
    _ball.frame = CGRectMake(0, 0, 56, 56);
    _ball.layer.cornerRadius = 28;
    _ball.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.92];
    [_ball setTitle:@"URL" forState:UIControlStateNormal];
    _ball.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [_ball setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _ball.layer.shadowColor = [UIColor blackColor].CGColor;
    _ball.layer.shadowOpacity = 0.4f;
    _ball.layer.shadowRadius = 4.0f;
    _ball.layer.shadowOffset = CGSizeZero;
    [_ball addTarget:self action:@selector(ballTapped)
            forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(panBall:)];
    [_ball addGestureRecognizer:pan];
    [ballVC.view addSubview:_ball];
    _ballWindow.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - 70,
                                   [UIScreen mainScreen].bounds.size.height / 2.0 - 28,
                                   56, 56);

    // ---- 网页窗口 ----
    _webWindow = [[UIWindow alloc] initWithFrame:CGRectZero];
    _webWindow.windowLevel = 1600.0;
    _webWindow.backgroundColor = [UIColor systemBackgroundColor];
    _webWindow.layer.cornerRadius = 12.0f;
    _webWindow.clipsToBounds = YES;
    _webWindow.windowScene = scene;
    _webWindow.hidden = YES;

    UIViewController *webVC = [[UIViewController alloc] init];
    webVC.view.backgroundColor = [UIColor systemBackgroundColor];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _winW, 44)];
    bar.backgroundColor = [UIColor secondarySystemBackgroundColor];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

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
    [webVC.view addSubview:bar];

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    _webView = [[WKWebView alloc] initWithFrame:CGRectMake(0, 44, _winW, _winH - 44)
                                   configuration:cfg];
    _webView.navigationDelegate = self;
    _webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [webVC.view addSubview:_webView];

    _spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.center = CGPointMake(_winW / 2.0, _winH / 2.0);
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                UIViewAutoresizingFlexibleRightMargin |
                                UIViewAutoresizingFlexibleTopMargin |
                                UIViewAutoresizingFlexibleBottomMargin;
    [webVC.view addSubview:_spinner];

    _webWindow.rootViewController = webVC;

    [self applyVisibility];
}

#pragma mark - 交互

- (void)ballTapped { _expanded ? [self collapse] : [self expand]; }

- (void)panBall:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        _ballDragOrigin = _ballWindow.center;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:_ball.superview];
        CGPoint c = CGPointMake(_ballDragOrigin.x + t.x, _ballDragOrigin.y + t.y);
        CGRect s = [UIScreen mainScreen].bounds;
        c.x = MAX(28, MIN(s.size.width  - 28, c.x));
        c.y = MAX(28, MIN(s.size.height - 28, c.y));
        _ballWindow.center = c;
    }
}

- (void)expand {
    [self setupIfNeeded];
    _webWindow.windowScene = [self activeScene];
    CGFloat w = _winW, h = _winH;
    CGRect screen = [UIScreen mainScreen].bounds;
    _webWindow.frame = CGRectMake((screen.size.width - w) / 2.0,
                                  (screen.size.height - h) / 2.0, w, h);
    _webView.frame = CGRectMake(0, 44, w, h - 44);
    _spinner.center = CGPointMake(w / 2.0, h / 2.0);
    [_titleLabel setText:_url];
    [self loadURL];
    _webWindow.hidden = NO;
    _ballWindow.hidden = YES;
    _expanded = YES;
}

- (void)collapse {
    _webWindow.hidden = YES;
    _ballWindow.hidden = !_enabled;
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
    if (!_enabled) {
        _ballWindow.hidden = YES;
        _webWindow.hidden = YES;
        return;
    }
    if (!_expanded) _ballWindow.hidden = NO;
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

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note){
                        [[FUFloatingManager shared] setupIfNeeded];
                    }];
    }
}
