#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <math.h>
#import <notify.h>

// ============================================================
// 悬浮URL —— 系统级悬浮窗 tweak（rootless / iOS16 / A14 arm64e）
// 包名：com.yzdmm.floatingurl
//
// v1.2.3 变更：
//  - 穿透 window：悬浮 UI 统一挂到自建的 FUOverlayWindow（高 level、clear、绝不设为 key、
//    hitTest 空白区域返回 nil 穿透），根治「主屏图标被悬浮层吞触摸」。
//  - 多 URL 扇形菜单：设置里可加 ≤6 个 URI，每个带自定义图标(相册选/自动压缩)+1汉字+1字母；
//    点开悬浮球展开扇形，选入口打开对应 URI（网页进面板 / scheme 直接拉 app）。
//  - 网页随面板缩放：面板捏合改尺寸时网页内容(page zoom)按比例同步缩放。
//  - 轻量跨 App 同步：哪个 URI 打开 / 面板开关 / 位置 写入偏好 + Darwin 通知，各进程对齐
//    （内容各自按 URL 重载，同 URL 同页）。
// v1.2.2：支持 URL 跳 app/插件（地址栏与网页内自定义 scheme 直接 openURL）。
// v1.2.1：移除自建 UIWindow 兜底（1.2.0 白屏根因），统一挂宿主 key window 子视图。
// v1.2.0 遗留特性：尺寸钳制、捏合缩放、历史记录、地址栏长按切顶/底、玻璃液态小球。
// ============================================================

#define INCLUDE_SPRINGBOARD 1

static NSString * const kFUSuite        = @"com.yzdmm.floatingurl";
static NSString * const kFUPrefsChanged = @"com.yzdmm.floatingurl/settingsChanged";
static NSString * const kFUSyncChanged  = @"com.yzdmm.floatingurl/syncChanged";

// 多 URL 条目字典键
static NSString * const kFUURLs        = @"urls";      // NSArray<NSDictionary>
static NSString * const kFUEntryURL    = @"url";
static NSString * const kFUEntryChar   = @"char";      // 1 个汉字
static NSString * const kFUEntryLetter = @"letter";    // 1 个字母
static NSString * const kFUEntryIcon   = @"icon";      // NSData(PNG)
static NSString * const kFUSync        = @"sync";      // 跨 App 同步状态字典

static const NSInteger kFUMaxEntries = 6;

static void fuPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo);
static void fuSyncChanged(CFNotificationCenterRef center, void *observer,
                          CFStringRef name, const void *object, CFDictionaryRef userInfo);

#pragma mark - 穿透 window（空白区域把触摸交还给下层窗口）

@interface FUOverlayWindow : UIWindow
@end
@implementation FUOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // 命中自己（空白区域）就返回 nil → 触摸穿透到下层窗口（主屏图标/App 照常可点）
    return (hit == self) ? nil : hit;
}
@end

#pragma mark - 浮动管理器

@interface FUFloatingManager : NSObject <WKNavigationDelegate, UITextFieldDelegate,
                                         UITableViewDataSource, UITableViewDelegate>
+ (instancetype)shared;
- (void)reloadPrefs;
- (void)setupWhenHostReady;
- (void)applyVisibility;
@end

@implementation FUFloatingManager {
    FUOverlayWindow        *_overlay;       // 穿透 window（球/面板/扇形都挂这里）
    UIButton              *_ball;
    UIVisualEffectView    *_ballBlur;
    UILabel               *_ballLabel;
    UIView                *_panel;
    UIView                *_bar;
    UITextField           *_urlField;
    UIButton              *_reloadBtn;
    UITableView           *_historyTable;
    WKWebView             *_webView;
    UIActivityIndicatorView *_spinner;

    BOOL                  _expanded;
    BOOL                  _didSetup;
    BOOL                  _enabled;
    BOOL                  _barAtBottom;
    BOOL                  _fanOpen;
    BOOL                  _applyingRemote;  // 应用远端同步时，避免写回造成回环

    NSString              *_url;
    CGFloat               _winW;
    CGFloat               _winH;
    CGPoint               _ballDragOrigin;
    CGSize                _pinchBaseSize;
    CGPoint               _pinchBaseCenter;
    NSMutableArray        *_history;
    CGRect                _lastPanelFrame;
    BOOL                  _hasLastFrame;

    NSArray               *_entries;       // 多 URL 条目（dict 数组）
    NSMutableArray        *_fanItems;      // 扇形按钮（UIButton）
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
        _fanOpen  = NO;
        _history  = [NSMutableArray array];
        _fanItems = [NSMutableArray array];
        [self reloadPrefs];
        [self loadHistory];
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)(self),
            &fuPrefsChanged, (__bridge CFStringRef)kFUPrefsChanged, NULL,
            CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)(self),
            &fuSyncChanged, (__bridge CFStringRef)kFUSyncChanged, NULL,
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

static void fuSyncChanged(CFNotificationCenterRef center, void *observer,
                          CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    FUFloatingManager *mgr = (__bridge FUFloatingManager *)observer;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ fuSyncChanged(center, observer, name, object, userInfo); });
        return;
    }
    [mgr applySync];
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
        _winW = [(__bridge NSNumber *)wRef floatValue]; CFRelease(wRef);
    }
    CFPropertyListRef hRef = CFPreferencesCopyAppValue(CFSTR("winHeight"),
                                (__bridge CFStringRef)kFUSuite);
    if (hRef && CFGetTypeID(hRef) == CFNumberGetTypeID()) {
        _winH = [(__bridge NSNumber *)hRef floatValue]; CFRelease(hRef);
    }
    if (_winW < 200) _winW = 200;
    if (_winW > 600) _winW = 600;
    if (_winH < 280) _winH = 280;
    if (_winH > 900) _winH = 900;

    CFPropertyListRef barRef = CFPreferencesCopyAppValue(CFSTR("barAtBottom"),
                                  (__bridge CFStringRef)kFUSuite);
    if (barRef) { _barAtBottom = [(__bridge NSNumber *)barRef boolValue]; CFRelease(barRef); }

    [self loadEntries];
}

// 读取多 URL 条目；为空则用单条 _url 兜底（保证老用户行为不变）
- (void)loadEntries {
    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUURLs,
                                (__bridge CFStringRef)kFUSuite);
    NSArray *arr = nil;
    if (r) { arr = (__bridge_transfer NSArray *)r; if (![arr isKindOfClass:[NSArray class]]) arr = nil; }
    if (arr.count) {
        _entries = arr;
    } else {
        _entries = @[ @{ kFUEntryURL: (_url ?: @"https://www.apple.com") } ];
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
    // 已带合法 scheme（http/https 或自定义 scheme：weixin://、tel:、cydia://、sileo:// ...）
    // 原样放行；只有裸域名（无 scheme）才补 https://，避免把 app/插件 scheme 改坏。
    NSURLComponents *c = [NSURLComponents componentsWithString:s];
    if (c && c.scheme.length && [c.scheme rangeOfString:@"."].location == NSNotFound) {
        return s;
    }
    return [@"https://" stringByAppendingString:s];
}

- (BOOL)isWebScheme:(NSString *)u {
    NSURLComponents *c = [NSURLComponents componentsWithString:u];
    NSString *sch = c.scheme.lowercaseString;
    if (!sch.length) return YES;
    return [@[@"http",@"https"] containsObject:sch];
}

#pragma mark - 穿透 window 挂载

- (void)setupWhenHostReady {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self setupWhenHostReady]; }); return; }
    static BOOL done = NO;
    if (done) return;

    UIApplication *app = UIApplication.sharedApplication;
    if (!app) {                 // 启动早期窗口未就绪，最多重试 ~5s
        static int tries = 0;
        if (tries++ < 12) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4*NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ [self setupWhenHostReady]; });
        return;
    }
    // 自建穿透 window（高 level、clear、绝不设为 key、空白穿透），所有悬浮 UI 都挂这里。
    if (!_overlay) {
        _overlay = [[FUOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        _overlay.windowLevel = 1000;
        _overlay.backgroundColor = [UIColor clearColor];
        _overlay.rootViewController = [UIViewController new];
        _overlay.hidden = NO;     // 仅设为可见，绝不 makeKeyAndVisible（不当 key，不抢触摸）
        _overlay.userInteractionEnabled = YES;
    }
    done = YES;
    [self buildUI];
    [self applyVisibility];
}

- (void)buildUI {
    _didSetup = YES;

    // ---- 悬浮球：玻璃液态（系统材质模糊 + 高光描边），40pt ----
    _ball = [UIButton buttonWithType:UIButtonTypeCustom];
    _ball.frame = CGRectMake(0, 0, 40, 40);
    _ball.layer.cornerRadius = 20;
    _ball.layer.shadowColor  = [UIColor blackColor].CGColor;
    _ball.layer.shadowOpacity = 0.25f;
    _ball.layer.shadowRadius  = 6.0f;
    _ball.layer.shadowOffset  = CGSizeMake(0, 2);
    _ball.backgroundColor = [UIColor clearColor];

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

    [_ball addTarget:self action:@selector(ballTapped) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(panBall:)];
    [_ball addGestureRecognizer:pan];
    [_overlay addSubview:_ball];
    [self placeBallInWindow:_overlay];

    // ---- 网页面板 ----
    _panel = [[UIView alloc] initWithFrame:CGRectZero];
    _panel.backgroundColor = [UIColor systemBackgroundColor];
    _panel.layer.cornerRadius = 14.0f;
    _panel.clipsToBounds = YES;
    _panel.hidden = YES;
    _panel.layer.borderColor = [UIColor separatorColor].CGColor;
    _panel.layer.borderWidth = 0.5f;

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
    [close addTarget:self action:@selector(collapse) forControlEvents:UIControlEventTouchUpInside];
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
    [_urlField addTarget:self action:@selector(urlGo) forControlEvents:UIControlEventEditingDidEndOnExit];
    [_urlField addTarget:self action:@selector(urlEditingBegan) forControlEvents:UIControlEventEditingDidBegin];
    [_bar addSubview:_urlField];

    UIButton *reload = [UIButton buttonWithType:UIButtonTypeSystem];
    _reloadBtn = reload;
    reload.frame = CGRectMake(0, 0, 44, 40);
    [reload setTitle:@"↻" forState:UIControlStateNormal];
    reload.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [reload addTarget:self action:@selector(reload) forControlEvents:UIControlEventTouchUpInside];
    reload.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [_bar addSubview:reload];
    [_panel addSubview:_bar];

    _historyTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
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
    _webView.scrollView.bounces = YES;
    [_panel addSubview:_webView];

    _spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                UIViewAutoresizingFlexibleRightMargin |
                                UIViewAutoresizingFlexibleTopMargin |
                                UIViewAutoresizingFlexibleBottomMargin;
    [_webView addSubview:_spinner];

    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc]
            initWithTarget:self action:@selector(pinchPanel:)];
    [_panel addGestureRecognizer:pinch];

    [_overlay addSubview:_panel];
    [self layoutPanel];
}

- (void)placeBallInWindow:(UIWindow *)w {
    if (!_ball || !w) return;
    _ball.frame = CGRectMake(w.bounds.size.width - 40 - 4,
                             w.bounds.size.height * 0.45, 40, 40);
}

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
    [self applyWebZoom];
}

// 面板尺寸 → 网页内容(page zoom)按比例同步缩放
- (void)applyWebZoom {
    if (!_webView || !_expanded) return;
    CGFloat z = _panel.bounds.size.width / 340.0f;
    z = MAX(0.5f, MIN(3.0f, z));
    UIScrollView *sv = _webView.scrollView;
    if (fabs(sv.zoomScale - z) < 0.02f) return;
    CGSize cs = sv.contentSize;
    if (cs.width < 1) cs = _webView.bounds.size;
    CGPoint c = CGPointMake(cs.width / 2.0, cs.height / 2.0);
    CGFloat w = _webView.bounds.size.width / z;
    CGFloat h = _webView.bounds.size.height / z;
    [sv zoomToRect:CGRectMake(c.x - w/2.0, c.y - h/2.0, w, h) animated:NO];
}

#pragma mark - 交互

- (void)ballTapped {
    if (_expanded) { [self collapse]; return; }
    if (_fanOpen)  { [self closeFan]; return; }
    if (_entries.count <= 1) { [self expand]; return; }   // 仅 1 条：直接打开
    [self openFan];
}

- (void)panBall:(UIPanGestureRecognizer *)g {
    if (!_ball) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        _ballDragOrigin = _ball.frame.origin;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:_overlay];
        CGRect f = _ball.frame;
        f.origin.x = _ballDragOrigin.x + t.x;
        f.origin.y = _ballDragOrigin.y + t.y;
        f.origin.x = MAX(0, MIN(_overlay.bounds.size.width  - f.size.width,  f.origin.x));
        f.origin.y = MAX(0, MIN(_overlay.bounds.size.height - f.size.height, f.origin.y));
        _ball.frame = f;
    }
}

- (void)panPanel:(UIPanGestureRecognizer *)g {
    if (!_panel || !_panel.superview) return;
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:_overlay];
        CGRect f = _panel.frame;
        f.origin.x += t.x; f.origin.y += t.y;
        f.origin.x = MAX(0, MIN(_overlay.bounds.size.width  - f.size.width,  f.origin.x));
        f.origin.y = MAX(0, MIN(_overlay.bounds.size.height - f.size.height, f.origin.y));
        _panel.frame = f;
        _lastPanelFrame = f; _hasLastFrame = YES;
        [g setTranslation:CGPointZero inView:_overlay];
    } else if (g.state == UIGestureRecognizerStateEnded) {
        [self writeSync];
    }
}

- (void)pinchPanel:(UIPinchGestureRecognizer *)g {
    if (!_panel || !_panel.superview) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        _pinchBaseSize   = _panel.frame.size;
        _pinchBaseCenter = CGPointMake(CGRectGetMidX(_panel.frame), CGRectGetMidY(_panel.frame));
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGFloat scale = g.scale;
        if (scale <= 0.01) return;
        CGRect s = _overlay.bounds;
        CGFloat ww = MIN(MAX(_pinchBaseSize.width  * scale, 220), s.size.width  - 16);
        CGFloat hh = MIN(MAX(_pinchBaseSize.height * scale, 300), s.size.height - 24);
        CGRect f = CGRectMake(_pinchBaseCenter.x - ww / 2.0, _pinchBaseCenter.y - hh / 2.0, ww, hh);
        f.origin.x = MAX(0, MIN(s.size.width  - f.size.width,  f.origin.x));
        f.origin.y = MAX(0, MIN(s.size.height - f.size.height, f.origin.y));
        _panel.frame = f;
        _lastPanelFrame = f; _hasLastFrame = YES;
        _winW = ww; _winH = hh;
        [self layoutPanel];
    } else if (g.state == UIGestureRecognizerStateEnded) {
        [self writeSync];
    }
}

- (void)toggleBarPosition:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    _barAtBottom = !_barAtBottom;
    CFPreferencesSetAppValue(CFSTR("barAtBottom"),
        (__bridge CFPropertyListRef)[NSNumber numberWithBool:_barAtBottom], (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    [self layoutPanel];
}

#pragma mark - 扇形菜单

- (void)openFan {
    if (_fanOpen || _entries.count <= 1) return;
    _fanOpen = YES;
    [self closeFanItemsAnimated:NO];
    CGPoint c = CGPointMake(CGRectGetMidX(_ball.frame), CGRectGetMidY(_ball.frame));
    BOOL left = (c.x > _overlay.bounds.size.width / 2.0);
    NSInteger n = _entries.count;
    CGFloat base = left ? 180.0f : 0.0f;
    CGFloat span = MIN(140.0f, 40.0f + 30.0f * (n - 1));
    CGFloat R = 96.0f;
    for (NSInteger i = 0; i < n; i++) {
        CGFloat a = (n == 1) ? base : (base - span/2.0f + span * ((CGFloat)i / (CGFloat)(n - 1)));
        CGFloat rad = a * M_PI / 180.0f;
        CGFloat x = c.x + R * cos(rad);
        CGFloat y = c.y + R * sin(rad);
        UIButton *it = [self buildFanItem:_entries[i] index:i];
        CGFloat sz = 52.0f;
        CGRect target = CGRectMake(x - sz/2.0f, y - sz/2.0f, sz, sz);
        target.origin.x = MAX(2, MIN(_overlay.bounds.size.width  - sz - 2, target.origin.x));
        target.origin.y = MAX(2, MIN(_overlay.bounds.size.height - sz - 2, target.origin.y));
        it.frame = CGRectMake(c.x - sz/2.0f, c.y - sz/2.0f, sz, sz);
        it.alpha = 0.0f;
        it.transform = CGAffineTransformMakeScale(0.1f, 0.1f);
        [_overlay addSubview:it];
        [_fanItems addObject:it];
        [UIView animateWithDuration:0.22 delay:0.02*i
             usingSpringWithDamping:0.7 initialSpringVelocity:0.6
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ it.frame = target; it.alpha = 1.0f;
                                       it.transform = CGAffineTransformIdentity; }
                         completion:nil];
    }
}

- (UIButton *)buildFanItem:(NSDictionary *)entry index:(NSInteger)idx {
    UIButton *it = [UIButton buttonWithType:UIButtonTypeCustom];
    it.layer.cornerRadius = 26.0f;
    it.layer.shadowColor = [UIColor blackColor].CGColor;
    it.layer.shadowOpacity = 0.3f;
    it.layer.shadowRadius = 5.0f;
    it.layer.shadowOffset = CGSizeMake(0, 2);
    it.clipsToBounds = YES;
    it.tag = idx;

    NSData *icon = entry[kFUEntryIcon];
    UIImage *img = icon.length ? [UIImage imageWithData:icon] : nil;
    if (img) {
        [it setImage:[img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
            forState:UIControlStateNormal];
        it.backgroundColor = [UIColor secondarySystemBackgroundColor];
        it.imageView.contentMode = UIViewContentModeScaleAspectFill;
        it.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
        it.contentVerticalAlignment   = UIControlContentVerticalAlignmentFill;
    } else {
        it.backgroundColor = [UIColor colorWithHue:((CGFloat)idx / (CGFloat)kFUMaxEntries)
                                         saturation:0.6 brightness:0.95 alpha:1.0];
    }
    UILabel *lab = [[UILabel alloc] initWithFrame:it.bounds];
    lab.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    lab.textAlignment = NSTextAlignmentCenter;
    lab.textColor = [UIColor whiteColor];
    NSString *ch = entry[kFUEntryChar] ?: @"";
    NSString *lt = entry[kFUEntryLetter] ?: @"";
    lab.numberOfLines = 0;
    lab.font = [UIFont boldSystemFontOfSize:img ? 11 : 17];
    lab.text = img ? [NSString stringWithFormat:@"%@\n%@", ch, lt] : ch;
    if (img) lab.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    [it addSubview:lab];

    [it addTarget:self action:@selector(fanItemTapped:) forControlEvents:UIControlEventTouchUpInside];
    return it;
}

- (void)fanItemTapped:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if (idx < 0 || idx >= (NSInteger)_entries.count) { [self closeFan]; return; }
    NSDictionary *entry = _entries[idx];
    [self closeFan];
    NSString *u = entry[kFUEntryURL];
    if (!u.length) return;
    NSString *norm = [self normalizeURL:u];
    if ([self isWebScheme:norm]) {
        _url = norm;
        [self expand];
    } else {
        UIApplication *app = UIApplication.sharedApplication;
        NSURL *nu = [NSURL URLWithString:norm];
        if (app && nu) [app openURL:nu options:@{} completionHandler:nil];
    }
}

- (void)closeFan {
    _fanOpen = NO;
    [self closeFanItemsAnimated:YES];
}

- (void)closeFanItemsAnimated:(BOOL)animated {
    NSArray *items = [_fanItems copy];
    [_fanItems removeAllObjects];
    CGPoint c = _ball ? CGPointMake(CGRectGetMidX(_ball.frame), CGRectGetMidY(_ball.frame))
                      : CGPointMake(_overlay.bounds.size.width - 20, _overlay.bounds.size.height/2.0);
    for (UIButton *it in items) {
        if (animated) {
            [UIView animateWithDuration:0.18 animations:^{
                it.alpha = 0.0f; it.transform = CGAffineTransformMakeScale(0.1f, 0.1f);
                it.center = c;
            } completion:^(BOOL f){ [it removeFromSuperview]; }];
        } else {
            [it removeFromSuperview];
        }
    }
}

#pragma mark - 展开 / 收起 面板

- (void)expand {
    if (!_didSetup) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self expand]; });
        return;
    }
    [self loadHistory];
    CGRect s = _overlay.bounds;
    CGFloat ww = MIN(_winW, s.size.width  - 16);
    CGFloat hh = MIN(_winH, s.size.height - 24);
    if (_hasLastFrame) {
        CGRect f = _lastPanelFrame;
        f.size.width = ww; f.size.height = hh;
        f.origin.x = MAX(0, MIN(s.size.width  - f.size.width,  f.origin.x));
        f.origin.y = MAX(0, MIN(s.size.height - f.size.height, f.origin.y));
        _panel.frame = f;
    } else {
        _panel.frame = CGRectMake((s.size.width - ww)/2.0, (s.size.height - hh)/2.0, ww, hh);
    }
    _urlField.text = _url;
    [self layoutPanel];
    [self loadURL];
    [_overlay bringSubviewToFront:_panel];
    _panel.hidden = NO;
    _historyTable.hidden = YES;
    _ball.hidden = YES;
    _expanded = YES;
    [self writeSync];
}

- (void)collapse {
    [_urlField resignFirstResponder];
    _historyTable.hidden = YES;
    _panel.hidden = YES;
    _ball.hidden  = !_enabled;
    _expanded = NO;
    [self writeSync];
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
    [self writeSync];
}

- (void)urlEditingBegan {
    [_historyTable reloadData];
    _historyTable.hidden = _history.count == 0;
}

- (void)loadURL {
    NSURL *u = [NSURL URLWithString:_url];
    if (!u || u.scheme == nil) u = [NSURL URLWithString:@"https://www.apple.com"];
    NSString *scheme = u.scheme.lowercaseString;
    NSSet *webSchemes = [NSSet setWithObjects:@"http", @"https", @"about", @"data",
                                                  @"blob", @"file", @"javascript", nil];
    if (scheme.length && ![webSchemes containsObject:scheme]) {
        UIApplication *app = UIApplication.sharedApplication;
        if (app) [app openURL:u options:@{} completionHandler:nil];
        return;
    }
    [_webView loadRequest:[NSURLRequest requestWithURL:u]];
}

- (void)applyVisibility {
    if (!_didSetup) return;
    if (!_enabled) {
        _ball.hidden  = YES;
        _panel.hidden = YES;
        if (_fanOpen) [self closeFan];
        return;
    }
    if (!_expanded && !_fanOpen) {
        _ball.hidden = NO;
        [_overlay bringSubviewToFront:_ball];
    }
}

#pragma mark - 跨 App 轻量同步

- (void)writeSync {
    if (_applyingRemote) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"open"] = @(_expanded);
    if (_expanded) {
        d[@"url"]   = _url ?: @"";
        d[@"panel"] = NSStringFromCGRect(_panel.frame);
    }
    CFPreferencesSetAppValue((__bridge CFStringRef)kFUSync,
        (__bridge CFPropertyListRef)d, (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    notify_post("com.yzdmm.floatingurl/syncChanged");
}

- (void)applySync {
    if (_applyingRemote) return;
    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUSync,
                                  (__bridge CFStringRef)kFUSuite);
    if (!r) return;
    NSDictionary *d = (__bridge_transfer NSDictionary *)r;
    BOOL open = [d[@"open"] boolValue];
    NSString *u = d[@"url"];
    if (open == _expanded && (!open || (_url && u && [_url isEqualToString:[self normalizeURL:u]]))) {
        NSString *pf = d[@"panel"];
        if (open && pf && _hasLastFrame) {
            CGRect f = CGRectFromString(pf);
            if (!CGRectIsNull(f) && !CGRectEqualToRect(f, _panel.frame)) {
                _lastPanelFrame = f; _panel.frame = f; [self layoutPanel];
            }
        }
        return;
    }
    _applyingRemote = YES;
    if (open) {
        if (u.length) _url = [self normalizeURL:u];
        NSString *pf = d[@"panel"];
        if (pf) { _lastPanelFrame = CGRectFromString(pf); _hasLastFrame = YES; }
        if (!_expanded) [self expand];
        else { _urlField.text = _url; [self layoutPanel]; [self loadURL]; }
    } else {
        if (_expanded) [self collapse];
    }
    _applyingRemote = NO;
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField { [self urlGo]; return YES; }
- (BOOL)textFieldShouldClear:(UITextField *)textField { _historyTable.hidden = NO; return YES; }

#pragma mark - 历史 UITableView

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return _history.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *id = @"FUHistCell";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:id];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:id];
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
    _url = u; _urlField.text = u;
    [self loadURL]; [self pushHistory:u];
    [tv reloadData]; _historyTable.hidden = YES;
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

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)nav { [_spinner startAnimating]; }
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)nav {
    [_spinner stopAnimating];
    NSString *cur = webView.URL.absoluteString;
    if (cur.length && _expanded) { _url = cur; _urlField.text = cur; [self pushHistory:cur]; }
    [self applyWebZoom];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)nav withError:(NSError *)error { [_spinner stopAnimating]; }
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)nav withError:(NSError *)error { [_spinner stopAnimating]; }

// 网页内点击自定义 scheme 链接 → 交给系统拉起对应 app；web 内部 scheme 照常加载
- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *u = navigationAction.request.URL;
    NSString *scheme = u.scheme.lowercaseString;
    NSSet *webSchemes = [NSSet setWithObjects:@"http", @"https", @"about", @"data",
                                                  @"blob", @"file", @"javascript", nil];
    if (u && scheme.length && ![webSchemes containsObject:scheme]) {
        UIApplication *app = UIApplication.sharedApplication;
        if (app) [app openURL:u options:@{} completionHandler:nil];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

@end

// ============================================================
// 注入入口：Filter 为 Bundles=(com.apple.UIKit)，全 App + 主屏幕（都加载 UIKit）。
// 设置进程跳过（避看门狗）。
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [[FUFloatingManager shared] setupWhenHostReady]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [[FUFloatingManager shared] setupWhenHostReady]; });
    }
}
