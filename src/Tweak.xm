#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

// ============================================================
// 悬浮URL —— 系统级悬浮窗 tweak（rootless / iOS16 / A14 arm64e）
// 包名：com.yzdmm.floatingurl
//
// v1.2.0 变更：
//  - 面板尺寸一律钳制到屏幕内（修复超屏设置导致"只看见一角"）
//  - 面板支持捏合自由缩放 + 工具条拖动，位置记忆
//  - 地址栏可编辑输入，支持历史记录（去重、可滑动删除）
//  - 地址栏长按可切换 顶部/底部 位置（记忆）
//  - 悬浮球缩小(56→40) + 玻璃液态质感（系统材质模糊 + 高光描边）
//  - 主屏幕（SpringBoard）兜底：无 UIApplication 时自建 UIWindow
// ============================================================

#define INCLUDE_SPRINGBOARD 1

static NSString * const kFUSuite        = @"com.yzdmm.floatingurl";
static NSString * const kFUPrefsChanged = @"com.yzdmm.floatingurl/settingsChanged";

static void fuPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo);

// ---- 取一个可用窗口（普通 App 路径；SpringBoard 无 UIApplication 会返回 nil）----
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

@interface FUFloatingManager : NSObject <WKNavigationDelegate, UITextFieldDelegate,
                                         UITableViewDataSource, UITableViewDelegate>
+ (instancetype)shared;
- (void)reloadPrefs;
- (void)setupWhenHostReady;
- (void)applyVisibility;
@end

@implementation FUFloatingManager {
    UIButton                *_ball;          // 玻璃液态小球（含模糊层）
    UIVisualEffectView      *_ballBlur;
    UILabel                 *_ballLabel;
    UIView                  *_panel;
    UIView                  *_bar;
    UITextField             *_urlField;
    UIButton                *_reloadBtn;
    UITableView             *_historyTable;
    WKWebView               *_webView;
    UIActivityIndicatorView *_spinner;
    BOOL                    _expanded;
    BOOL                    _didSetup;
    BOOL                    _enabled;
    BOOL                    _barAtBottom;
    NSString                *_url;
    CGFloat                 _winW;
    CGFloat                 _winH;
    CGPoint                 _ballDragOrigin;
    CGSize                  _pinchBaseSize;
    CGPoint                 _pinchBaseCenter;
    NSMutableArray          *_history;
    CGRect                  _lastPanelFrame;
    BOOL                    _hasLastFrame;
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
        _history  = [NSMutableArray array];
        [self reloadPrefs];
        [self loadHistory];
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
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ fuPrefsChanged(center, observer, name, object, userInfo); });
        return;
    }
    [mgr reloadPrefs];
    [mgr loadHistory];
    if (mgr->_historyTable) [mgr->_historyTable reloadData];
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

    CFPropertyListRef barRef = CFPreferencesCopyAppValue(CFSTR("barAtBottom"),
                                  (__bridge CFStringRef)kFUSuite);
    if (barRef) {
        _barAtBottom = [(__bridge NSNumber *)barRef boolValue];
        CFRelease(barRef);
    }
}

#pragma mark - 历史记录

- (void)loadHistory {
    CFPropertyListRef hRef = CFPreferencesCopyAppValue(CFSTR("history"),
                                 (__bridge CFStringRef)kFUSuite);
    if (hRef) {
        NSArray *arr = (__bridge_transfer NSArray *)hRef;
        if ([arr isKindOfClass:[NSArray class]]) _history = [arr mutableCopy];
    }
    if (!_history) _history = [NSMutableArray array];
}

- (void)saveHistory {
    CFPreferencesSetAppValue(CFSTR("history"), (__bridge CFPropertyListRef)(_history),
        (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
}

- (void)pushHistory:(NSString *)raw {
    NSString *u = [self normalizeURL:raw];
    if (!u.length) return;
    [_history removeObject:u];
    [_history insertObject:u atIndex:0];
    while (_history.count > 30) [_history removeLastObject];
    [self saveHistory];
}

- (NSString *)normalizeURL:(NSString *)raw {
    NSString *s = [raw stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) return nil;
    if (![s.lowercaseString hasPrefix:@"http://"] &&
        ![s.lowercaseString hasPrefix:@"https://"]) {
        s = [@"https://" stringByAppendingString:s];
    }
    return s;
}

#pragma mark - 窗口挂载

- (void)attachToWindow:(UIWindow *)w {
    if (!w) return;
    if (_ball && _ball.superview != w) {
        [_ball removeFromSuperview];
        [w addSubview:_ball];
        [self placeBallInWindow:w];
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

    // 所有进程（含 SpringBoard，它本身就是 UIApplication）统一挂到宿主 key window 子视图。
    // 绝不自建 UIWindow —— 自建高 level window 会变成 key window 抢走全部触摸，
    // 且空 window 在某些进程里渲染成全屏遮罩，导致「白屏点不了」。这是 1.2.0 的坑，已移除。
    UIWindow *w = fuAnyWindow();
    if (!w) {
        static int tries = 0;
        if (tries++ < 12) {   // 启动早期窗口未就绪，最多重试 ~5s
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self setupWhenHostReady]; });
        }
        return;
    }
    done = YES;
    [self buildUI:w];
    [self applyVisibility];
}

- (void)buildUI:(UIWindow *)w {
    _didSetup = YES;

    // ---- 悬浮球：玻璃液态（系统材质模糊 + 高光描边），40pt ----
    _ball = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
    _ball.layer.cornerRadius = 20;
    _ball.layer.shadowColor  = [UIColor blackColor].CGColor;
    _ball.layer.shadowOpacity = 0.25f;
    _ball.layer.shadowRadius  = 6.0f;
    _ball.layer.shadowOffset  = CGSizeMake(0, 2);

    _ballBlur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    _ballBlur.frame = _ball.bounds;
    _ballBlur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _ballBlur.layer.cornerRadius = 20;
    _ballBlur.clipsToBounds = YES;
    _ballBlur.layer.borderWidth = 0.8f;
    _ballBlur.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
    [_ball addSubview:_ballBlur];

    _ballLabel = [[UILabel alloc] initWithFrame:_ball.bounds];
    _ballLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _ballLabel.text = @"URL";
    _ballLabel.font = [UIFont boldSystemFontOfSize:10];
    _ballLabel.textAlignment = NSTextAlignmentCenter;
    _ballLabel.textColor = [UIColor labelColor];
    [_ballBlur.contentView addSubview:_ballLabel];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(ballTapped)];
    [_ball addGestureRecognizer:tap];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(panBall:)];
    [_ball addGestureRecognizer:pan];
    [w addSubview:_ball];
    [self placeBallInWindow:w];

    // ---- 网页面板 ----
    _panel = [[UIView alloc] initWithFrame:CGRectZero];
    _panel.backgroundColor = [UIColor systemBackgroundColor];
    _panel.layer.cornerRadius = 14.0f;
    _panel.clipsToBounds = YES;
    _panel.hidden = YES;
    _panel.layer.borderColor = [UIColor separatorColor].CGColor;
    _panel.layer.borderWidth = 0.5f;

    // 工具条（可拖动整面板；长按切换顶部/底部）
    _bar = [[UIView alloc] initWithFrame:CGRectZero];
    _bar.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIPanGestureRecognizer *panelPan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(panPanel:)];
    [_bar addGestureRecognizer:panelPan];
    UILongPressGestureRecognizer *barLong = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(toggleBarPosition:)];
    barLong.minimumPressDuration = 0.6;
    [_bar addGestureRecognizer:barLong];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(4, 0, 44, 40);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [close addTarget:self action:@selector(collapse)
            forControlEvents:UIControlEventTouchUpInside];
    close.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
    [_bar addSubview:close];

    _urlField = [[UITextField alloc] initWithFrame:CGRectZero];
    _urlField.placeholder = @"输入网址";
    _urlField.text = _url;
    _urlField.font = [UIFont systemFontOfSize:12];
    _urlField.textAlignment = NSTextAlignmentCenter;
    _urlField.borderStyle = UITextBorderStyleRoundedRect;
    _urlField.autocorrectionType = UITextAutocorrectionTypeNo;
    _urlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _urlField.keyboardType = UIKeyboardTypeURL;
    _urlField.returnKeyType = UIReturnKeyGo;
    _urlField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _urlField.delegate = self;
    _urlField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_urlField addTarget:self action:@selector(urlGo)
           forControlEvents:UIControlEventEditingDidEndOnExit];
    [_urlField addTarget:self action:@selector(urlEditingBegan)
           forControlEvents:UIControlEventEditingDidBegin];
    [_bar addSubview:_urlField];

    UIButton *reload = [UIButton buttonWithType:UIButtonTypeSystem];
    _reloadBtn = reload;
    reload.frame = CGRectMake(0, 0, 44, 40);
    [reload setTitle:@"↻" forState:UIControlStateNormal];
    reload.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [reload addTarget:self action:@selector(reload)
             forControlEvents:UIControlEventTouchUpInside];
    reload.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [_bar addSubview:reload];
    [_panel addSubview:_bar];

    // 历史记录列表（编辑地址时浮层显示）
    _historyTable = [[UITableView alloc] initWithFrame:CGRectZero
                                                 style:UITableViewStylePlain];
    _historyTable.dataSource = self;
    _historyTable.delegate = self;
    _historyTable.hidden = YES;
    _historyTable.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _historyTable.layer.cornerRadius = 10;
    _historyTable.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_panel addSubview:_historyTable];

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    _webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    _webView.navigationDelegate = self;
    _webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_panel addSubview:_webView];

    _spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                UIViewAutoresizingFlexibleRightMargin |
                                UIViewAutoresizingFlexibleTopMargin |
                                UIViewAutoresizingFlexibleBottomMargin;
    [_webView addSubview:_spinner];

    // 捏合自由缩放（挂在面板上，双指捏合改尺寸，中心不动）
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc]
            initWithTarget:self action:@selector(pinchPanel:)];
    [_panel addGestureRecognizer:pinch];

    [w addSubview:_panel];
    [self layoutPanel];
}

- (void)placeBallInWindow:(UIWindow *)w {
    if (!_ball || !w) return;
    _ball.frame = CGRectMake(w.bounds.size.width - 40 - 4,
                             w.bounds.size.height * 0.45,
                             40, 40);
}

// 面板内部布局：工具条在顶或底（长按切换），WebView 填充剩余
- (void)layoutPanel {
    if (!_panel) return;
    CGRect b = _panel.bounds;
    CGFloat barH = 40;
    CGRect barF, webF;
    if (_barAtBottom) {
        barF = CGRectMake(0, b.size.height - barH, b.size.width, barH);
        webF = CGRectMake(0, 0, b.size.width, b.size.height - barH);
    } else {
        barF = CGRectMake(0, 0, b.size.width, barH);
        webF = CGRectMake(0, barH, b.size.width, b.size.height - barH);
    }
    _bar.frame = barF;
    _webView.frame = webF;
    _historyTable.frame = webF;
    CGFloat fieldX = 52, fieldW = b.size.width - 104;
    _urlField.frame = CGRectMake(fieldX, 6, fieldW, 28);
    _reloadBtn.frame = CGRectMake(b.size.width - 48, 0, 44, 40);
    _spinner.center = CGPointMake(webF.size.width / 2.0, webF.size.height / 2.0);
    [_historyTable setNeedsLayout];
}

#pragma mark - 交互

- (void)ballTapped { _expanded ? [self collapse] : [self expand]; }

- (void)panBall:(UIPanGestureRecognizer *)g {
    UIWindow *w = _ball.superview ?: fuAnyWindow();
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
        _lastPanelFrame = f; _hasLastFrame = YES;
        [g setTranslation:CGPointZero inView:w];
    }
}

// 捏合缩放：以捏合起始中心为锚，尺寸 = 基础尺寸 × scale，钳制在屏幕内
- (void)pinchPanel:(UIPinchGestureRecognizer *)g {
    UIWindow *w = _panel.superview;
    if (!w) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        _pinchBaseSize   = _panel.frame.size;
        _pinchBaseCenter = CGPointMake(CGRectGetMidX(_panel.frame), CGRectGetMidY(_panel.frame));
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGFloat scale = g.scale;
        if (scale <= 0.01) return;
        CGRect s = w.bounds;
        CGFloat ww = MIN(MAX(_pinchBaseSize.width  * scale, 220), s.size.width  - 16);
        CGFloat hh = MIN(MAX(_pinchBaseSize.height * scale, 300), s.size.height - 24);
        CGRect f = CGRectMake(_pinchBaseCenter.x - ww / 2.0,
                              _pinchBaseCenter.y - hh / 2.0, ww, hh);
        f.origin.x = MAX(0, MIN(s.size.width  - f.size.width,  f.origin.x));
        f.origin.y = MAX(0, MIN(s.size.height - f.size.height, f.origin.y));
        _panel.frame = f;
        _lastPanelFrame = f; _hasLastFrame = YES;
        _winW = ww; _winH = hh;
    } else if (g.state == UIGestureRecognizerStateEnded) {
        [self layoutPanel];
    }
}

// 长按工具条：地址栏 顶部 ↔ 底部
- (void)toggleBarPosition:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    _barAtBottom = !_barAtBottom;
    CFPreferencesSetAppValue(CFSTR("barAtBottom"),
        (__bridge CFPropertyListRef)[NSNumber numberWithBool:_barAtBottom], (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    [self layoutPanel];
}

- (void)expand {
    UIWindow *w = _ball.superview ?: fuAnyWindow();
    if (!w || !_didSetup) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self expand]; });
        return;
    }
    [self attachToWindow:w];
    [self loadHistory];

    // 关键：尺寸钳制到屏幕内（修复"只看见一角"），且不超当前窗口
    CGRect s = w.bounds;
    CGFloat ww = MIN(_winW, s.size.width  - 16);
    CGFloat hh = MIN(_winH, s.size.height - 24);

    if (_hasLastFrame) {
        // 记住上次位置，但钳制在屏幕内
        CGRect f = _lastPanelFrame;
        f.size.width  = ww; f.size.height = hh;
        f.origin.x = MAX(0, MIN(s.size.width  - f.size.width,  f.origin.x));
        f.origin.y = MAX(0, MIN(s.size.height - f.size.height, f.origin.y));
        _panel.frame = f;
    } else {
        _panel.frame = CGRectMake((s.size.width - ww) / 2.0,
                                  (s.size.height - hh) / 2.0, ww, hh);
    }
    _urlField.text = _url;
    [self layoutPanel];
    [self loadURL];
    [w bringSubviewToFront:_panel];
    _panel.hidden = NO;
    _historyTable.hidden = YES;
    _ball.hidden = YES;
    _expanded = YES;
}

- (void)collapse {
    [_urlField resignFirstResponder];
    _historyTable.hidden = YES;
    _panel.hidden = YES;
    _ball.hidden  = !_enabled;
    _expanded = NO;
}

- (void)reload { [self loadURL]; }

- (void)urlGo {
    NSString *raw = _urlField.text;
    NSString *u = [self normalizeURL:raw];
    if (!u.length) { _urlField.text = _url; return; }
    _url = u;
    [self pushHistory:u];
    [self loadURL];
    [_urlField resignFirstResponder];
    _historyTable.hidden = YES;
}

- (void)urlEditingBegan {
    [_historyTable reloadData];
    _historyTable.hidden = _history.count == 0;
}

- (void)loadURL {
    NSURL *u = [NSURL URLWithString:_url];
    if (!u || u.scheme == nil) u = [NSURL URLWithString:@"https://www.apple.com"];
    [_webView loadRequest:[NSURLRequest requestWithURL:u]];
}

- (void)applyVisibility {
    if (!_didSetup) return;
    UIWindow *w = _ball.superview ?: fuAnyWindow();
    if (!w) return;            // 窗口未就绪时先不动，等 setup 重试
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

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField { [self urlGo]; return YES; }
- (BOOL)textFieldShouldClear:(UITextField *)textField { _historyTable.hidden = NO; return YES; }

#pragma mark - 历史 UITableView

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return _history.count;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *id = @"FUHistCell";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:id];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                       reuseIdentifier:id];
    c.textLabel.text = _history[ip.row];
    c.textLabel.font = [UIFont systemFontOfSize:12];
    c.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    c.detailTextLabel.text = @"长按地址栏可切换工具条位置";
    c.detailTextLabel.font = [UIFont systemFontOfSize:9];
    c.detailTextLabel.textColor = [UIColor tertiaryLabelColor];
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSString *u = _history[ip.row];
    _url = u;
    _urlField.text = u;
    [self loadURL];
    [self pushHistory:u];
    [tv reloadData];
    _historyTable.hidden = YES;
    [_urlField resignFirstResponder];
}
- (void)tableView:(UITableView *)tv
   commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
   forRowAtIndexPath:(NSIndexPath *)ip {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        [_history removeObjectAtIndex:ip.row];
        [self saveHistory];
        [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationFade];
        if (_history.count == 0) _historyTable.hidden = YES;
    }
}
- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip {
    return @"删除";
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)nav {
    [_spinner startAnimating];
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)nav {
    [_spinner stopAnimating];
    NSString *cur = webView.URL.absoluteString;
    if (cur.length && _expanded) {
        _url = cur;
        _urlField.text = cur;
        [self pushHistory:cur];
    }
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)nav withError:(NSError *)error {
    [_spinner stopAnimating];
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)nav withError:(NSError *)error {
    [_spinner stopAnimating];
}

@end

// ============================================================
// 注入入口：Filter 为 Bundles=(com.apple.UIKit)，
// 全 App + 主屏幕（都加载 UIKit）。设置进程跳过（避看门狗）。
// ============================================================
%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if ([bid isEqualToString:@"com.apple.Preferences"]) return;
        if (!INCLUDE_SPRINGBOARD && [bid isEqualToString:@"com.apple.springboard"]) return;

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note){
                        [[FUFloatingManager shared] setupWhenHostReady];
                    }];
        // 兜底：1.5s / 3.5s 各试一次（SpringBoard 没有
        // UIApplicationDidFinishLaunchingNotification，靠轮询 + 自建窗兜底）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[FUFloatingManager shared] setupWhenHostReady];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[FUFloatingManager shared] setupWhenHostReady];
        });
    }
}
