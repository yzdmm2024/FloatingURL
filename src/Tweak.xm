#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <notify.h>
#import <dlfcn.h>

// PhotosUI 在 SDK14.5 下无法以模块方式编译（simd/cmath 缺失），tweak 里不 import 头文件，
// 改用运行时 NSClassFromString 调用 PHPicker，避免模块构建失败。
@class PHPickerConfiguration, PHPickerViewController, PHPickerResult, PHPickerFilter;
@protocol PHPickerViewControllerDelegate;

// ============================================================
// 悬浮URL —— 系统级悬浮窗 tweak（rootless / iOS16 / A14 arm64e）
// 包名：com.yzdmm.floatingurl
//
// v1.3.5 变更（6 条修复）：
//  01 自动吸附改为「以屏幕中心线为界」：球在左半屏→吸左边，右半屏→吸右边（不再四边乱吸）。
//  02 新增「自动吸附 / 全屏固定」两种模式（设置→布局调节 里滑动选择）。
//  03 扇形朝向按球的实际位置自动识别左右：球在左→扇形朝右展开，球在右→扇形朝左展开。
//  04 网页改回「系统浏览器打开」为默认（SpringBoard 内置 WKWebView 打不开），
//     并保留「内置面板」开关给需要的用户。
//  05 新增悬浮球自定义：名称（默认 URL）、图标（相册选取+方形裁剪）、底色（无图标时生效）。
//  06 修「删光快捷 URL 后点球还弹网页」：删空即视为无入口，点球不再弹任何面板。
// v1.2.5 变更（关键修复 + 新功能）：
//  - 【冻结修复】悬浮窗 FUOverlayWindow 永远不抢 key：平时非 key + hitTest 空白穿透，
//    App 照常可点；只在面板/扇形/编辑器中打开时临时 makeKeyWindow，关闭立即还给 App。
//    去掉 1.2.4 的 windowScene 绑定（它会把悬浮窗提升为 key → 吞掉空白触摸 → App 卡死）。
//  - 扇形图标尺寸 = 悬浮球尺寸（40pt），视觉统一。
//  - 长按扇形图标 → 就地弹出编辑器（URL/汉字/字母/图标，含方形裁剪），改完写回并全局同步。
//  - 新增「作用 App」限制：设置里勾选后，仅指定 App 显示（桌面始终显示）。
// v1.2.4 遗留：图标方形裁剪、说明书/玩法、App 列表（见 FUSettingsController）。
// ============================================================

#define INCLUDE_SPRINGBOARD 1

static NSString * const kFUSuite        = @"com.yzdmm.floatingurl";
static NSString * const kFUPrefsChanged = @"com.yzdmm.floatingurl/settingsChanged";
static NSString * const kFUSyncChanged  = @"com.yzdmm.floatingurl/syncChanged";
static NSString * const kFUAlivePrefix  = @"com.yzdmm.floatingurl/alive/";  // v1.3.2：+App bundle id（前台心跳）
static NSString * const kFUGonePrefix   = @"com.yzdmm.floatingurl/gone/";   // v1.3.2：+App bundle id（退到后台）
// v1.3.12：桌面 → App 进程的「内置浏览器」请求。球归桌面（读得到设置），但桌面渲染不了网页，
//  所以桌面把 URL 写进目标 App 容器 + 发这个通知，由 App 进程用 SFSafariViewController 显示。
static NSString * const kFUInAppWebName = @"com.yzdmm.floatingurl/inAppWeb";
static NSString * const kFUInAppWebFile = @"fu_inapp_web.txt";
// v1.3.13：App 真正弹出内置浏览器后的「回执」。桌面据此判断要不要兜底系统浏览器 ——
// 修 1.3.12 的漏洞：App 只删了交接文件却没弹出浏览器时，桌面以为已接住 → 结果什么都不开。
static NSString * const kFUInAppWebAck  = @"com.yzdmm.floatingurl/inAppWebAck";
// v1.3.13：备用信箱。桌面写目标 App 容器常被沙盒拒绝，写不进去就改投这里；
// App 端两处都看，读不到就静默跳过（无副作用）。
static NSString * const kFUWebMailboxMedia = @"/var/mobile/Media/FloatingURL_incoming.txt";

static NSString * const kFUURLs        = @"urls";
static NSString * const kFUEntryURL    = @"url";
static NSString * const kFUEntryChar   = @"char";       // v1.3.3：名称/标签（自由文本，显示在图标上）
static NSString * const kFUEntryLetter = @"letter";
static NSString * const kFUEntryIcon   = @"icon";
static NSString * const kFUEntryColor  = @"color";      // v1.3.3：自定义图标底色（hex，无图标时生效）
static NSString * const kFUSync        = @"sync";
static NSString * const kFUEnabledApps = @"enabledApps";
static NSString * const kFUSide        = @"side";       // 球停靠边：0=右(默认) 1=左
static NSString * const kFUIconSize    = @"iconSize";   // 快捷图标尺寸 pt
static NSString * const kFUIconGap     = @"iconGap";    // 图标/圈层间隔 pt
static NSString * const kFUFanSpan     = @"fanSpan";    // v1.3.2 扇形角度（60~180°，默认 180）
static NSString * const kFUFanScale    = @"fanScale";   // v1.3.2 整体距离（%，默认 100）
static NSString * const kFULayer1Count = @"layer1";     // v1.3.3：第一层入口数（0=自动）
static NSString * const kFULayer2Count = @"layer2";     // v1.3.3：第二层入口数（0=自动）
static NSString * const kFULayer3Count = @"layer3";     // v1.3.3：第三层入口数（0=自动）
static NSString * const kFUSilent      = @"silent";     // v1.3.3：静默模式（1=不注入 App 进程、零打扰）
static NSString * const kFUSnapMode    = @"snapMode";   // v1.3.5：0=自动吸附 1=全屏固定
static NSString * const kFUBallX       = @"ballX";      // v1.3.5：球中心 X（归一化 0~1）
static NSString * const kFUBallY       = @"ballY";      // v1.3.5：球中心 Y（归一化 0~1）
static NSString * const kFUBallTitle   = @"ballTitle";  // v1.3.5：球的文字（默认 URL）
static NSString * const kFUBallIcon    = @"ballIcon";   // v1.3.5：球的图标（PNG data）
static NSString * const kFUBallColor   = @"ballColor";  // v1.3.5：球的底色 hex（无图标时生效）
static NSString * const kFUWebMode     = @"webMode";    // v1.3.5：YES=内置面板打开网页（v1.3.13 起桌面不再用它，见 triggerEntry）
static NSString * const kFUSnapDelay   = @"snapDelay";  // v1.3.13：松手后「完整悬浮图标」停留几秒再自动吸附（默认 3，0=立即）

static const NSInteger kFUMaxEntries = 48;   // v1.3.6：上限 48（三层 8 + 16 + 24）
static const NSInteger kFULayer1Max  = 4;    // 第一层（内环）最多 4 个
static const NSInteger kFULayer2Max  = 6;    // 第二层（外环）最多 6 个
static const CGFloat   kFUButtonSize = 40.0f;   // 悬浮球尺寸
static const CGFloat   kFUSnapThreshold = 48.0f; // 松手时距边 ≤48pt 才自动吸附（修「不靠近也吸走」）

static void fuPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo);
static void fuSyncChanged(CFNotificationCenterRef center, void *observer,
                          CFStringRef name, const void *object, CFDictionaryRef userInfo);

// ---- v1.3.2 核心修复：球只由 SpringBoard 持有 ----
// 真机 frida 实测（Notes / 闲鱼 等沙盒 App 进程内）：
//   · NSUserDefaults(suite) → null；CFPreferences 各种变体 → 全 nil；
//   · 连 /var/mobile/Library/Preferences 都无法读、无法写（沙盒直接拒绝，报 ENOENT）。
//   → 沙盒 App 进程**根本读不到本 tweak 的偏好**：json/URL/布局全回退成默认值，
//     黑名单也拿不到。这正是用户反馈「每个 App 里只有 1 个快捷 URL、黑名单不生效」的根因。
//   而 SpringBoard 进程读设置完全正常（实测 6 条 URL + 黑名单都在）。
// 方案：UI（球/扇形/面板）只在 SpringBoard 进程创建（设置可读、层级最高、全 App 可见）；
//      各 App 进程只做一件事——用 Darwin 通知上报「我现在在前台」，
//      SpringBoard 据此在黑名单 App 里隐藏悬浮球（跨进程通知不受沙盒限制）。
static BOOL fuIsSpringBoard(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"];
}
static NSString *fuAliveName(NSString *bid) { return [kFUAlivePrefix stringByAppendingString:bid]; }
static NSString *fuGoneName(NSString *bid)  { return [kFUGonePrefix  stringByAppendingString:bid]; }

// ---- v1.3.12：App 进程内的「内置浏览器」----
// 为什么必须由 App 进程来显示网页：SpringBoard 进程里 WKWebView 白屏（WebKit2 内容进程拿不到
// 桌面沙盒豁免）、UIWebView 会挂死桌面主线程（watchdog 杀 SpringBoard → 无限注销），都是真机实锤；
// 而 App 进程有网络权限 —— 这正是 1.2.1 能打开网页的原因（那时球在每个 App 进程里）。
static NSString *fuAppWebFilePath(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (!dirs.count) return nil;
    return [(NSString *)dirs.firstObject stringByAppendingPathComponent:kFUInAppWebFile];
}
// v1.3.13：App 端要看的「信箱」列表（桌面写哪处能成功，就走哪处）。
static NSArray *fuAppWebMailboxPaths(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSString *own = fuAppWebFilePath();
    if (own.length) [out addObject:own];
    [out addObject:kFUWebMailboxMedia];
    return out;
}
static UIViewController *fuTopViewController(void) {
    UIApplication *a = UIApplication.sharedApplication;
    if (!a) return nil;
    UIWindow *key = nil;
    for (UIWindow *w in a.windows) { if (w.isKeyWindow) { key = w; break; } }
    if (!key) { for (UIWindow *w in a.windows) { if (w.windowLevel == UIWindowLevelNormal) { key = w; break; } } }
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) { vc = vc.presentedViewController; }
    return vc;
}
static double fuLastWebSeq = 0;   // v1.3.13：已处理过的请求序号（防陈旧文件被重复打开）
static void fuHandleInAppWebRequest(void) {
    @try {
        for (NSString *p in fuAppWebMailboxPaths()) {
            NSString *raw = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
            if (!raw.length) continue;                     // 没有交接文件 = 不是给我的
            [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];   // 先清掉，避免下次误触发
            // 文件格式：第一行是序号（时间戳），第二行是 URL
            NSString *seqS = raw, *urlS = @"";
            NSRange nl = [raw rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]];
            if (nl.location != NSNotFound) {
                seqS = [raw substringToIndex:nl.location];
                urlS = [raw substringFromIndex:nl.location + 1];
            }
            double seq = seqS.doubleValue;
            if (seq <= fuLastWebSeq) continue;              // 陈旧请求（上次没删干净的）→ 忽略
            fuLastWebSeq = seq;
            NSString *s = [urlS stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!s.length) return;
            if (![s.lowercaseString hasPrefix:@"http"]) s = [@"https://" stringByAppendingString:s];
            NSURL *u = [NSURL URLWithString:s];
            UIApplication *a = UIApplication.sharedApplication;
            // 不在前台就不打扰，也**不发回执** —— 桌面 1.5s 收不到回执会自动改用系统浏览器，
            // 所以绝不会出现「点了没反应」。
            if (!u || !a || a.applicationState != UIApplicationStateActive) return;
            NSString *myBid = [[NSBundle mainBundle] bundleIdentifier];
            if ([myBid isEqualToString:@"com.apple.mobilesafari"]) {   // 自己就是浏览器：直接跳转
                [a openURL:u options:@{} completionHandler:nil];
                notify_post(kFUInAppWebAck.UTF8String);
                return;
            }
            Class sfCls = NSClassFromString(@"SFSafariViewController");
            if (!sfCls) {   // SafariServices 一般没被 App 加载 → 现场按需加载（只在真要开网页时，非启动路径）
                dlopen("/System/Library/Frameworks/SafariServices.framework/SafariServices", RTLD_LAZY);
                sfCls = NSClassFromString(@"SFSafariViewController");
            }
            UIViewController *top = fuTopViewController();
            if (sfCls && top) {                 // 内置浏览器：不离开当前 App，附带刷新/分享/完成按钮
                id svc = ((id (*)(id, SEL, id))objc_msgSend)([sfCls alloc], NSSelectorFromString(@"initWithURL:"), u);
                if (svc) {
                    [top presentViewController:svc animated:YES completion:nil];
                    notify_post(kFUInAppWebAck.UTF8String);   // 真弹出来了才回执
                    return;
                }
            }
            NSLog(@"[FloatingURL] 内置浏览器不可用（sf=%@ top=%@）→ 交给桌面走系统浏览器", sfCls, top);
            return;
        }
    } @catch (NSException *e) {
        NSLog(@"[FloatingURL] inAppWeb 异常（已忽略）: %@", e);
    }
}

// 非 SpringBoard 进程：只广播前台状态，不建任何 UI、不加载设置。
static void fuStartAppHeartbeat(NSString *bid) {
    static BOOL started = NO; if (started) return; started = YES;
    if (!bid.length) return;
    // v1.3.3 静默模式：SpringBoard 写好标记文件后，App 进程完全不注入心跳（零打扰、最省电）。
    // 读取失败（沙盒等）则回退到正常心跳，不影响黑名单功能。
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Media/FloatingURL_silent"]) return;
    NSString *alive = fuAliveName(bid), *gone = fuGoneName(bid);
    void (^beat)(void) = ^{
        // 关键：只有「真前台」才上报。后台 App 的定时器可能仍在校跑，
        // 若无条件上报，桌面球会被永久顶掉（用户实测「常驻桌面的悬浮球没了」）。
        UIApplication *a = UIApplication.sharedApplication;
        if (a && a.applicationState == UIApplicationStateActive) notify_post(alive.UTF8String);
    };
    // v1.3.3：低频保活（4s），仅在真前台才发通知；App 进后台即被系统挂起，定时器不再触发 → 低能耗。
    NSTimer *t = [NSTimer timerWithTimeInterval:4.0 repeats:YES block:^(NSTimer *tt){ beat(); }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                     queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){ beat(); }];
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
                     queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){ notify_post(gone.UTF8String); }];
    [nc addObserverForName:UIApplicationWillTerminateNotification object:nil
                     queue:nil usingBlock:^(NSNotification *n){ notify_post(gone.UTF8String); }];
    // v1.3.12：接收桌面发来的「用内置浏览器打开网页」请求（纯 C 注册，重活在回调里，不碰启动路径的 UI）。
    static int fuWebToken = 0;
    notify_register_dispatch(kFUInAppWebName.UTF8String, &fuWebToken,
                             dispatch_get_main_queue(), ^(int t){ fuHandleInAppWebRequest(); });
}

#pragma mark - 穿透 window（空白区域把触摸交还给下层窗口）
// 关键：本 window 永远不 makeKey（不当 key → 不吞 App 触摸）；空白命中 window 自身 → 返回 nil 穿透。
@interface FUOverlayWindow : UIWindow
@end
@implementation FUOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // 命中 window 自身（空白区域）→ 返回 nil，触摸穿透到下层窗口。
    // 命中球/面板/扇形/编辑器 → 正常返回。
    return (hit == self) ? nil : hit;
}
@end

#pragma mark - 方形裁剪控制器（选图后让用户调整裁剪框）
@interface FUCropViewController : UIViewController <UIScrollViewDelegate>
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, copy)   void (^onCropped)(NSData *png);
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIImageView  *imgView;
@end
@implementation FUCropViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.title = @"调整裁剪";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"确定" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(done)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(cancel)];

    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.delegate = self;
    _scroll.showsHorizontalScrollIndicator = NO;
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.bounces = NO;
    _scroll.backgroundColor = [UIColor blackColor];
    [self.view addSubview:_scroll];

    _imgView = [[UIImageView alloc] initWithImage:_image];
    _imgView.contentMode = UIViewContentModeScaleAspectFit;
    [_scroll addSubview:_imgView];

    CGFloat side = MIN(self.view.bounds.size.width, self.view.bounds.size.height) - 40;
    // 居中正方形裁剪框：暗化外部、框内清晰，白色框线明显，让用户看清要裁的正方形。
    UIView *dim = [[UIView alloc] initWithFrame:self.view.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    dim.userInteractionEnabled = NO;
    CGRect vb = self.view.bounds;
    CAShapeLayer *mask = [CAShapeLayer layer];
    UIBezierPath *outer = [UIBezierPath bezierPathWithRect:vb];
    CGRect sq = CGRectMake((vb.size.width - side)/2.0, (vb.size.height - side)/2.0, side, side);
    [outer appendPath:[[UIBezierPath bezierPathWithRect:sq] bezierPathByReversingPath]];
    mask.path = outer.CGPath; mask.fillRule = kCAFillRuleEvenOdd;
    dim.layer.mask = mask;
    [self.view addSubview:dim];
    UIView *frame = [[UIView alloc] initWithFrame:sq];
    frame.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                            UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    frame.layer.borderColor = [UIColor whiteColor].CGColor; frame.layer.borderWidth = 2.0;
    frame.userInteractionEnabled = NO;
    [self.view addSubview:frame];
    // 初始缩放：让图片至少覆盖裁剪框
    CGFloat z = side / MIN(_image.size.width, _image.size.height);
    _scroll.minimumZoomScale = z * 0.5;
    _scroll.maximumZoomScale = z * 4.0;
    _scroll.zoomScale = z;
    [self layoutContent];
    [self centerContent];
}
- (void)layoutContent {
    CGFloat z = _scroll.zoomScale;
    CGSize s = CGSizeMake(_image.size.width * z, _image.size.height * z);
    _imgView.frame = CGRectMake(0, 0, s.width, s.height);
    _scroll.contentSize = s;
}
- (void)centerContent {
    CGFloat side = MIN(self.view.bounds.size.width, self.view.bounds.size.height) - 40;
    CGFloat ox = MAX(0, (_scroll.contentSize.width  - side) / 2.0);
    CGFloat oy = MAX(0, (_scroll.contentSize.height - side) / 2.0);
    _scroll.contentOffset = CGPointMake(ox, oy);
}
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)sv { return _imgView; }
- (void)scrollViewDidZoom:(UIScrollView *)sv { [self centerContent]; }

- (void)done {
    CGFloat side = MIN(self.view.bounds.size.width, self.view.bounds.size.height) - 40;
    CGFloat z = _scroll.zoomScale;
    // 取可视区域正中央的 side×side 正方形（与界面上的正方形框线对齐）。
    CGRect visible = CGRectMake(_scroll.contentOffset.x + (_scroll.bounds.size.width  - side)/2.0,
                                _scroll.contentOffset.y + (_scroll.bounds.size.height - side)/2.0,
                                side, side);
    CGRect imgRect = CGRectMake(visible.origin.x / z, visible.origin.y / z,
                                visible.size.width / z, visible.size.height / z);
    CGImageRef cg = CGImageCreateWithImageInRect(_image.CGImage, imgRect);
    UIImage *sq = cg ? [UIImage imageWithCGImage:cg] : nil;
    if (cg) CGImageRelease(cg);
    NSData *out = nil;
    if (sq) {
        CGFloat max = 120.0;
        CGFloat s = MIN(1.0, max / MAX(sq.size.width, sq.size.height));
        CGSize ts = CGSizeMake(sq.size.width * s, sq.size.height * s);
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:ts];
        UIImage *small = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx){
            [sq drawInRect:CGRectMake(0, 0, ts.width, ts.height)];
        }];
        out = UIImagePNGRepresentation(small);
    }
    if (_onCropped) _onCropped(out);
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

#pragma mark - 条目编辑器（设置/长按扇形共用：URL+汉字+字母+图标）
@interface FUEntryEditorViewController : UIViewController <UITextFieldDelegate, PHPickerViewControllerDelegate>
@property (nonatomic, assign) NSInteger index;        // -1 = 新增
@property (nonatomic, copy)   void (^onSaved)(void);
@property (nonatomic, strong) UITextField *urlField, *labelField;
@property (nonatomic, strong) UIButton    *iconButton;
@property (nonatomic, strong) NSData      *iconData;
@property (nonatomic, copy)   NSString    *colorHex;     // v1.3.3 自定义图标底色（hex）
@property (nonatomic, strong) NSMutableArray *colorButtons;
@property (nonatomic, strong) NSArray     *colorPresets;
@property (nonatomic, copy)   void (^onDismiss)(void);   // 关闭后把 key 还给 App
@end
@implementation FUEntryEditorViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = (_index >= 0) ? @"编辑入口" : @"新增入口";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(save)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(cancel)];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:scroll];

    __block CGFloat y = 20;
    CGFloat pad = 16, w = self.view.bounds.size.width - pad*2, h = 40;
    UIView * (^mkField)(NSString *, NSString *, UIKeyboardType) =
        ^UIView *(NSString *ph, NSString *val, UIKeyboardType kt){
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(pad, y, w, h)];
        tf.placeholder = ph; tf.text = val; tf.borderStyle = UITextBorderStyleRoundedRect;
        tf.keyboardType = kt; tf.font = [UIFont systemFontOfSize:14];
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.delegate = self;
        y += h + 12; [scroll addSubview:tf]; return tf;
    };
    _urlField    = (UITextField *)mkField(@"网址 / scheme（如 https://a.com 或 weixin://）", nil, UIKeyboardTypeURL);

    // 文字（汉字或字母，1 个字符）—— 合并为单框
    _labelField = [[UITextField alloc] initWithFrame:CGRectMake(pad, y, w, 40)];
    _labelField.placeholder = @"名称（最多 8 字，如 百度 / 地图 / W）";
    _labelField.borderStyle = UITextBorderStyleRoundedRect;
    _labelField.font = [UIFont systemFontOfSize:14];
    _labelField.textAlignment = NSTextAlignmentCenter;
    _labelField.autocorrectionType = UITextAutocorrectionTypeNo;
    _labelField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _labelField.delegate = self;
    y += 40 + 16; [scroll addSubview:_labelField];

    // 图标：大正方形预览
    CGFloat sq = 160;
    _iconButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _iconButton.frame = CGRectMake((w - sq)/2.0 + pad, y, sq, sq);
    _iconButton.layer.cornerRadius = 14; _iconButton.layer.borderWidth = 1.5;
    _iconButton.layer.borderColor = [UIColor separatorColor].CGColor;
    _iconButton.clipsToBounds = YES;
    _iconButton.titleLabel.textAlignment = NSTextAlignmentCenter;
    _iconButton.titleLabel.numberOfLines = 0; _iconButton.titleLabel.font = [UIFont systemFontOfSize:13];
    [_iconButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    [_iconButton setTitle:@"选择图标\n（从相册，方形裁剪）" forState:UIControlStateNormal];
    [_iconButton addTarget:self action:@selector(pickIcon) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:_iconButton]; y += sq + 8;

    // 提示
    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w, 44)];
    tip.numberOfLines = 0; tip.font = [UIFont systemFontOfSize:12]; tip.textColor = [UIColor tertiaryLabelColor];
    tip.text = @"提示：图标自动压缩成 120×120 正方形；名称最多 8 字（汉字/字母/数字均可）；还可选图标底色（不填图标时生效）。图标与文字二选一。";
    [scroll addSubview:tip]; y += 44 + 12;

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.frame = CGRectMake(pad, y, w, 40);
    [clear setTitle:@"清除图标（用文字显示）" forState:UIControlStateNormal];
    [clear addTarget:self action:@selector(clearIcon) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:clear]; y += 40 + 20;

    // v1.3.3：图标底色选择（不填图标时生效）
    UILabel *colLab = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w, 18)];
    colLab.font = [UIFont systemFontOfSize:12]; colLab.textColor = [UIColor secondaryLabelColor];
    colLab.text = @"图标底色（不填图标时生效，留空=默认蓝）";
    [scroll addSubview:colLab]; y += 22;
    _colorPresets = @[@"#3385E6",@"#E63946",@"#2EA44F",@"#F4801A",@"#8E44AD",@"#16A2B8",@"#E84393",@"#6C757D",@""];
    _colorButtons = [NSMutableArray array];
    CGFloat sw = 36, csp = 8; CGFloat cx = pad;
    for (NSString *hex in _colorPresets) {
        if (cx + sw > pad + w) { cx = pad; y += sw + csp; }
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(cx, y, sw, sw);
        b.layer.cornerRadius = sw/2.0f; b.layer.borderWidth = 2.0f;
        b.layer.borderColor = [UIColor separatorColor].CGColor; b.clipsToBounds = YES;
        if (hex.length) b.backgroundColor = [self colorFromHex:hex];
        else { b.backgroundColor = [UIColor secondarySystemBackgroundColor];
               [b setTitle:@"无" forState:UIControlStateNormal]; b.titleLabel.font = [UIFont systemFontOfSize:11];
               [b setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal]; }
        b.tag = 900 + [_colorPresets indexOfObject:hex];
        [b addTarget:self action:@selector(colorTapped:) forControlEvents:UIControlEventTouchUpInside];
        [scroll addSubview:b]; [_colorButtons addObject:b]; cx += sw + csp;
    }
    y += sw + 20;
    [self refreshColor];
    scroll.contentSize = CGSizeMake(self.view.bounds.size.width, y);

    if (_index >= 0) [self prefill];
}
- (void)prefill {
    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUURLs,
                                    (__bridge CFStringRef)kFUSuite);
    if (!r) return;
    NSArray *arr = (__bridge_transfer NSArray *)r;
    if ([arr isKindOfClass:[NSArray class]] && _index < (NSInteger)arr.count) {
        NSDictionary *e = arr[_index];
        _urlField.text    = e[kFUEntryURL] ?: @"";
        NSString *ch = e[kFUEntryChar] ?: @""; NSString *lt = e[kFUEntryLetter] ?: @"";
        _labelField.text  = ch.length ? ch : lt;
        _iconData        = e[kFUEntryIcon];
        _colorHex        = e[kFUEntryColor];
        [self refreshIcon:_iconData];
        [self refreshColor];
    }
}
- (BOOL)textField:(UITextField *)tf shouldChangeCharactersInRange:(NSRange)r
                                              replacementString:(NSString *)s {
    if (tf == _labelField) {
        NSString *next = [tf.text stringByReplacingCharactersInRange:r withString:s];
        if (next.length > 8) return NO;   // v1.3.3：名称最多 8 个字符（汉字/字母/数字均可）
    }
    return YES;
}
- (void)refreshIcon:(NSData *)d {
    UIImage *img = d.length ? [UIImage imageWithData:d] : nil;
    if (img) {
        [_iconButton setImage:[img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
                     forState:UIControlStateNormal];
        _iconButton.imageView.contentMode = UIViewContentModeScaleAspectFill;
        [_iconButton setTitle:nil forState:UIControlStateNormal];
    } else {
        [_iconButton setImage:nil forState:UIControlStateNormal];
        [_iconButton setTitle:@"选择图标\n（从相册，方形裁剪）" forState:UIControlStateNormal];
    }
}
- (void)pickIcon {
    // v1.3.16：恢复桌面长按直接选照片。PHPickerViewController 是系统独立进程、且不需要相册权限
    // （与 UIImagePickerController 不同），从 overlay 这个 key 窗口/scene 弹出不会崩 SpringBoard。
    // 任何异常都 @try 兜住并退回「去设置里选」提示，绝不带崩 SpringBoard。
    @try {
        if (@available(iOS 14.0, *)) {
            Class pvClass = NSClassFromString(@"PHPickerViewController");
            Class cfgClass = NSClassFromString(@"PHPickerConfiguration");
            Class fltClass = NSClassFromString(@"PHPickerFilter");
            if (pvClass && cfgClass && fltClass) {
                PHPickerConfiguration *cfg = [[cfgClass alloc] init];
                if ([cfg respondsToSelector:@selector(setSelectionLimit:)]) cfg.selectionLimit = 1;
                if ([cfg respondsToSelector:@selector(setFilter:)]) cfg.filter = [fltClass imagesFilter];
                PHPickerViewController *pv = [[pvClass alloc] initWithConfiguration:cfg];
                pv.delegate = (id)self;
                [self presentViewController:pv animated:YES completion:nil];
                return;
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[FloatingURL] pickIcon 异常（已忽略）: %@", e);
    }
    // 兜底：任何失败 → 退回「去设置里选」提示
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"换图标请到「设置」里"
        message:@"桌面暂时无法打开相册选择器。打开「设置 → 悬浮URL → 快捷URI」，点对应入口的「选择图标」即可。"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"知道啦" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)picker:(id)picker didFinishPicking:(NSArray *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;
    id provider = [results.firstObject valueForKey:@"itemProvider"]; if (!provider) return;
    [provider loadObjectOfClass:[UIImage class]
                 completionHandler:^(__kindof id obj, NSError *err){
        if ([obj isKindOfClass:[UIImage class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                FUCropViewController *crop = [[FUCropViewController alloc] init];
                crop.image = obj;
                crop.onCropped = ^(NSData *png){ self.iconData = png; [self refreshIcon:png]; };
                UINavigationController *nc = [[UINavigationController alloc] initWithRootViewController:crop];
                [self presentViewController:nc animated:YES completion:nil];
            });
        }
    }];
}
- (void)clearIcon { _iconData = nil; [self refreshIcon:nil]; }
- (void)colorTapped:(UIButton *)b {
    NSInteger idx = b.tag - 900;
    if (idx < 0 || idx >= (NSInteger)_colorPresets.count) return;
    NSString *hex = _colorPresets[idx];
    _colorHex = hex.length ? hex : nil;
    [self refreshColor];
}
- (void)refreshColor {
    NSString *cur = _colorHex ?: @"";
    for (UIButton *b in _colorButtons) {
        NSInteger idx = b.tag - 900; if (idx < 0) continue;
        NSString *hex = _colorPresets[idx];
        BOOL sel = (hex.length == 0 && cur.length == 0) ||
                  (hex.length && [cur caseInsensitiveCompare:hex] == NSOrderedSame);
        b.layer.borderColor = (sel ? [UIColor systemBlueColor] : [UIColor separatorColor]).CGColor;
        b.layer.borderWidth = sel ? 3.0f : 2.0f;
    }
}
- (UIColor *)colorFromHex:(NSString *)hex {
    if (![hex isKindOfClass:[NSString class]] || hex.length < 6) return nil;
    NSString *h = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (h.length == 3) h = [NSString stringWithFormat:@"%c%c%c%c%c%c",
        [h characterAtIndex:0],[h characterAtIndex:0],[h characterAtIndex:1],
        [h characterAtIndex:1],[h characterAtIndex:2],[h characterAtIndex:2]];
    if (h.length != 6) return nil;
    unsigned int v = 0; NSScanner *s = [NSScanner scannerWithString:h]; [s scanHexInt:&v];
    return [UIColor colorWithRed:((v>>16)&0xFF)/255.0f green:((v>>8)&0xFF)/255.0f
                             blue:(v&0xFF)/255.0f alpha:1.0f];
}
- (void)save {
    NSMutableDictionary *e = [NSMutableDictionary dictionary];
    e[kFUEntryURL] = (_urlField.text.length ? _urlField.text : @"");
    NSString *lab = _labelField.text ?: @"";
    if (lab.length) e[kFUEntryChar] = lab;   // v1.3.1：存完整标签（2 汉字 / 3 字母）
    if (_iconData) e[kFUEntryIcon] = _iconData;
    if (_colorHex.length) e[kFUEntryColor] = _colorHex;

    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUURLs,
                                    (__bridge CFStringRef)kFUSuite);
    NSMutableArray *arr = nil;
    if (r) { NSArray *a = (__bridge_transfer NSArray *)r; arr = [a mutableCopy]; }
    if (!arr) arr = [NSMutableArray array];
    if (_index >= 0 && _index < (NSInteger)arr.count) arr[_index] = e;
    else { if (arr.count >= kFUMaxEntries) { [self cancel]; return; } [arr addObject:e]; }
    CFPreferencesSetAppValue((__bridge CFStringRef)kFUURLs,
        (__bridge CFPropertyListRef)arr, (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    notify_post("com.yzdmm.floatingurl/settingsChanged");
    if (_onSaved) _onSaved();
    [self dismissViewControllerAnimated:YES completion:nil];
    if (_onDismiss) _onDismiss();
}
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; if (_onDismiss) _onDismiss(); }
@end

#pragma mark - 浮动管理器
@interface FUFloatingManager : NSObject <WKNavigationDelegate, UITextFieldDelegate,
                                         UITableViewDataSource, UITableViewDelegate>
+ (instancetype)shared;
- (void)reloadPrefs;
- (void)setupWhenHostReady;
- (void)applyVisibility;
- (void)setInteractive:(BOOL)on;   // 面板/扇形/编辑器打开时临时当 key
// v1.3.2：前台 App 上报（Darwin 心跳）→ 黑名单判断；以及跨进程打开 URL
- (void)markFrontBid:(NSString *)bid;
- (void)clearFrontBid:(NSString *)bid;
- (NSArray *)fuBlacklist;
- (void)fuSyncFrontWatches;
- (void)fuOpenExternally:(NSString *)s;
- (BOOL)fuHandoffWebToFrontApp:(NSURL *)u;   // v1.3.12：把网页交给前台 App 的内置浏览器
- (void)fuOpenViaSystem:(NSURL *)u;          // v1.3.13：系统打开链路（openURL → FBSSystemService → workspace）
- (void)fuOpenViaFBS:(NSURL *)u;             // v1.3.13：FrontBoard 异步接口（失败回调里继续往下兜底）
- (void)fuOpenViaWorkspace:(NSURL *)u;       // v1.3.13：LSApplicationWorkspace 最后兜底
- (NSArray *)fuWebMailboxPathsForBid:(NSString *)bid;   // v1.3.13：可写的投递信箱列表
- (NSArray *)fuFanPointArray;                           // v1.3.13：扇形点位（openFan 与拖动重排共用同一套算法）
- (void)fuRelayoutFanInstant;                           // v1.3.13：拖动球时围绕球实时重排扇形
- (void)cancelPendingSnap;                              // v1.3.13：取消「待吸附」
- (void)scheduleSnapAfterDrop;                          // v1.3.13：松手后按「吸附延时」归位
- (void)triggerEntry:(NSDictionary *)entry;          // v1.3.8：触发一条入口（扇形点击 / 单入口点球共用）
- (CGFloat)fuAngleToScreenCenter:(CGPoint)c;         // v1.3.8：球心 -> 屏幕中心 的方向角
@property (nonatomic, strong) UIView      *schemeBox;     // 非网页入口的简单输入框容器
@property (nonatomic, strong) UITextField *schemeField;
@property (nonatomic, strong) UIButton    *schemeOpenBtn;
@end

// v1.3.2：前台 App 心跳回调（SpringBoard 侧）。通知名 = 前缀 + bundle id，从通知名反解出 App。
static void fuFrontAliveCb(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    FUFloatingManager *mgr = (__bridge FUFloatingManager *)observer; if (!mgr) return;
    NSString *n = (__bridge NSString *)name;
    if (![n hasPrefix:kFUAlivePrefix]) return;
    NSString *bid = [n substringFromIndex:kFUAlivePrefix.length];
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [mgr markFrontBid:bid]; });
        return;
    }
    [mgr markFrontBid:bid];
}
static void fuFrontGoneCb(CFNotificationCenterRef center, void *observer,
                          CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    FUFloatingManager *mgr = (__bridge FUFloatingManager *)observer; if (!mgr) return;
    NSString *n = (__bridge NSString *)name;
    if (![n hasPrefix:kFUGonePrefix]) return;
    NSString *bid = [n substringFromIndex:kFUGonePrefix.length];
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [mgr clearFrontBid:bid]; });
        return;
    }
    [mgr clearFrontBid:bid];
}

@implementation FUFloatingManager {
    FUOverlayWindow        *_overlay;
    UIViewController      *_overlayRoot;   // disabled 透明 vc，用于承载编辑器 + 安全穿透
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
    UILabel               *_webErrorLabel;   // 网页加载失败时显示原因（否则白屏无提示）

    BOOL                  _expanded;
    BOOL                  _didSetup;
    BOOL                  _enabled;
    BOOL                  _barAtBottom;
    BOOL                  _fanOpen;
    BOOL                  _tapConfirm;  // YES=点扇形图标先弹确认框(输入框+打开按钮)，NO=一点就直接触发
    BOOL                  _applyingRemote;

    NSString              *_url;
    CGFloat               _winW;
    CGFloat               _winH;
    CGPoint               _ballDragOrigin;
    CGSize                _pinchBaseSize;
    CGPoint               _pinchBaseCenter;
    NSMutableArray        *_history;
    CGRect                _lastPanelFrame;
    BOOL                  _hasLastFrame;

    NSArray               *_entries;
    NSMutableArray        *_fanItems;
    NSMutableArray        *_fanOffsets;  // 每个扇形相对球的中心偏移(CGPoint)，拖动球时跟随用
    NSString              *_hostBid;     // 当前宿主 App 的 bundle id（用于「作用 App」网关）
    BOOL                  _interactive;  // 是否已临时当 key（避免重复 rekey）
    NSInteger             _side;             // 球停靠边 0=右 1=左
    CGFloat               _iconSize;         // 快捷图标尺寸
    CGFloat               _iconGap;          // 图标/圈层间隔
    NSTimer               *_pollTimer;       // 每秒兜底重判黑名单/开关（修黑名单不生效）
    CGFloat               _fanSpan;          // v1.3.2 扇形角度 60~180°
    CGFloat               _fanScale;         // v1.3.2 整体距离 %
    NSInteger             _layer1;           // v1.3.3 第一层入口数（0=自动）
    NSInteger             _layer2;           // v1.3.3 第二层入口数（0=自动）
    NSInteger             _layer3;           // v1.3.3 第三层入口数（0=自动）
    BOOL                  _silent;           // v1.3.3 静默模式（旗标文件存在即为开）
    NSInteger             _snapMode;         // v1.3.5 0=自动吸附 1=全屏固定
    NSString             *_ballTitle;        // v1.3.5 球上的文字
    NSData               *_ballIcon;         // v1.3.5 球的图标
    NSString             *_ballColor;        // v1.3.5 球的底色 hex
    NSInteger             _webMode;          // v1.3.5 0=系统浏览器 1=内置面板
    UIImageView          *_ballImageView;    // v1.3.5 球图标显示
    BOOL                  _draggingBall;     // v1.3.5 拖动中（避免 1s 轮询把 alpha 抢回去）
    NSString             *_frontBid;         // v1.3.2 当前前台 App 的 bundle id（来自 Darwin 心跳）
    CFAbsoluteTime        _frontBidTs;       // 心跳时间戳（>3s 视为过期）
    NSMutableSet         *_frontWatched;     // 已注册通知监听的黑名单 bundle id
    // ---- v1.3.13 ----
    NSInteger             _snapGen;          // 吸附延时：代号（每次重排 +1，让排队中的旧延时块失效）
    BOOL                  _snapPending;      // 有待吸附（扇形/面板开着时先挂起）
    NSTimeInterval        _snapDelay;        // 松手后「完整悬浮图标」停留秒数（默认 3，0=立即吸附）
    BOOL                  _webAckPending;    // 正在等 App 的内置浏览器回执（没有就兜底系统浏览器）
    NSData               *_ballIconShown;    // 球外观缓存（避免每秒轮询重复解码图片）
    NSString             *_ballShownTitle;
    NSString             *_ballShownColor;
}

+ (instancetype)shared {
    static FUFloatingManager *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[FUFloatingManager alloc] init]; });
    return s;
}
- (instancetype)init {
    if (self = [super init]) {
        _enabled  = YES; _url = @"https://www.apple.com";
        _winW = 340; _winH = 480; _expanded = NO; _didSetup = NO; _fanOpen = NO;
        _side = 0; _iconSize = 40.0f; _iconGap = 56.0f;   // v1.3.1：球默认停靠右侧
        _fanSpan = 180.0f; _fanScale = 100.0f;            // v1.3.2 扇形角度 / 整体距离
        _snapMode = 0; _webMode = 0; _ballTitle = @"URL";  // v1.3.5 默认：自动吸附 + 系统浏览器
        _snapDelay = 3.0;                                  // v1.3.13：默认吸附延时 3 秒（松手后先给完整图标）
        _layer1 = 8; _layer2 = 16; _layer3 = 24;           // v1.3.6：三层默认数量 8/16/24（合计 48）
        _frontWatched = [NSMutableSet set];
        _history = [NSMutableArray array]; _fanItems = [NSMutableArray array]; _fanOffsets = [NSMutableArray array];
        [self reloadPrefs]; [self loadHistory];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)(self), &fuPrefsChanged,
            (__bridge CFStringRef)kFUPrefsChanged, NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)(self), &fuSyncChanged,
            (__bridge CFStringRef)kFUSyncChanged, NULL, CFNotificationSuspensionBehaviorCoalesce);
        // v1.3.13：App 弹出内置浏览器后的回执（纯 C 通知注册，与上面两条同一套路，不碰启动路径 UI）
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)(self), &fuInAppWebAckCb,
            (__bridge CFStringRef)kFUInAppWebAck, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
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
    [mgr reloadPrefs]; [mgr loadHistory];
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
// v1.3.13：前台 App 的内置浏览器真的弹出来了 → 撤销系统浏览器兜底
static void fuInAppWebAckCb(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    FUFloatingManager *mgr = (__bridge FUFloatingManager *)observer; if (!mgr) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ fuInAppWebAckCb(center, observer, name, object, userInfo); });
        return;
    }
    mgr->_webAckPending = NO;
    NSLog(@"[FloatingURL] App 已弹出内置浏览器（回执收到）");
}

- (void)reloadPrefs {
    // 关键：读之前强制把本进程对偏好域的缓存与磁盘同步，否则读到的仍是进程启动时的旧缓存值，
    // 导致「关开关没用 / 设了条目扇形不弹 / 作用 App 限制不生效」等一堆症状。
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    Boolean valid;
    BOOL en = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), (__bridge CFStringRef)kFUSuite, &valid);
    _enabled = valid ? en : YES;
    CFPropertyListRef urlRef = CFPreferencesCopyAppValue(CFSTR("url"), (__bridge CFStringRef)kFUSuite);
    if (urlRef) { NSString *u = (__bridge_transfer NSString *)urlRef; if (u.length) _url = u; }
    CFPropertyListRef wRef = CFPreferencesCopyAppValue(CFSTR("winWidth"), (__bridge CFStringRef)kFUSuite);
    if (wRef && CFGetTypeID(wRef) == CFNumberGetTypeID()) { _winW = [(__bridge NSNumber *)wRef floatValue]; CFRelease(wRef); }
    CFPropertyListRef hRef = CFPreferencesCopyAppValue(CFSTR("winHeight"), (__bridge CFStringRef)kFUSuite);
    if (hRef && CFGetTypeID(hRef) == CFNumberGetTypeID()) { _winH = [(__bridge NSNumber *)hRef floatValue]; CFRelease(hRef); }
    if (_winW < 200) _winW = 200; if (_winW > 600) _winW = 600;
    if (_winH < 280) _winH = 280; if (_winH > 900) _winH = 900;
    CFPropertyListRef barRef = CFPreferencesCopyAppValue(CFSTR("barAtBottom"), (__bridge CFStringRef)kFUSuite);
    if (barRef) { _barAtBottom = [(__bridge NSNumber *)barRef boolValue]; CFRelease(barRef); }
    // v1.3.1 布局：停靠边(side) + 图标大小 + 图标间隔（位置不再用 X/Y 滑杆，球固定在左/右边）
    CFPropertyListRef sdRef = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUSide, (__bridge CFStringRef)kFUSuite);
    if (sdRef && CFGetTypeID(sdRef) == CFNumberGetTypeID()) { _side = [(__bridge NSNumber *)sdRef integerValue]; CFRelease(sdRef); }
    CFPropertyListRef isRef = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUIconSize, (__bridge CFStringRef)kFUSuite);
    if (isRef && CFGetTypeID(isRef) == CFNumberGetTypeID()) { _iconSize = [(__bridge NSNumber *)isRef floatValue]; CFRelease(isRef); }
    CFPropertyListRef igRef = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUIconGap, (__bridge CFStringRef)kFUSuite);
    if (igRef && CFGetTypeID(igRef) == CFNumberGetTypeID()) { _iconGap = [(__bridge NSNumber *)igRef floatValue]; CFRelease(igRef); }
    if (_side != 0) _side = 1;
    if (_iconSize < 24) _iconSize = 24; if (_iconSize > 64) _iconSize = 64;
    if (_iconGap  < 12) _iconGap  = 12; if (_iconGap  > 120) _iconGap = 120;
    // v1.3.2：扇形角度 / 整体距离
    CFPropertyListRef fspRef = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUFanSpan, (__bridge CFStringRef)kFUSuite);
    if (fspRef && CFGetTypeID(fspRef) == CFNumberGetTypeID()) { _fanSpan = [(__bridge NSNumber *)fspRef floatValue]; CFRelease(fspRef); }
    CFPropertyListRef fscRef = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUFanScale, (__bridge CFStringRef)kFUSuite);
    if (fscRef && CFGetTypeID(fscRef) == CFNumberGetTypeID()) { _fanScale = [(__bridge NSNumber *)fscRef floatValue]; CFRelease(fscRef); }
    if (_fanSpan  < 60.0f) _fanSpan = 60.0f;  if (_fanSpan  > 180.0f) _fanSpan = 180.0f;
    if (_fanScale < 60.0f) _fanScale = 60.0f; if (_fanScale > 160.0f) _fanScale = 160.0f;
    // v1.3.3：每层数量（0=自动）
    CFPropertyListRef l1 = CFPreferencesCopyAppValue((__bridge CFStringRef)kFULayer1Count, (__bridge CFStringRef)kFUSuite);
    if (l1 && CFGetTypeID(l1) == CFNumberGetTypeID()) { _layer1 = [(__bridge NSNumber *)l1 integerValue]; CFRelease(l1); }
    CFPropertyListRef l2 = CFPreferencesCopyAppValue((__bridge CFStringRef)kFULayer2Count, (__bridge CFStringRef)kFUSuite);
    if (l2 && CFGetTypeID(l2) == CFNumberGetTypeID()) { _layer2 = [(__bridge NSNumber *)l2 integerValue]; CFRelease(l2); }
    CFPropertyListRef l3 = CFPreferencesCopyAppValue((__bridge CFStringRef)kFULayer3Count, (__bridge CFStringRef)kFUSuite);
    if (l3 && CFGetTypeID(l3) == CFNumberGetTypeID()) { _layer3 = [(__bridge NSNumber *)l3 integerValue]; CFRelease(l3); }
    // v1.3.6：三层上限 8 / 16 / 24（0 = 该层自动按弧长排）
    if (_layer1 < 0) _layer1 = 0; if (_layer1 > 8)  _layer1 = 8;
    if (_layer2 < 0) _layer2 = 0; if (_layer2 > 16) _layer2 = 16;
    if (_layer3 < 0) _layer3 = 0; if (_layer3 > 24) _layer3 = 24;
    // v1.3.3：静默模式（旗标文件存在 = 开；App 心跳与桌面球都据此休眠）
    _silent = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Media/FloatingURL_silent"];
    // ---- v1.3.5：吸附模式 / 网页打开方式 / 悬浮球外观 ----
    CFPropertyListRef smRef = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUSnapMode, (__bridge CFStringRef)kFUSuite);
    if (smRef && CFGetTypeID(smRef) == CFNumberGetTypeID()) { _snapMode = [(__bridge NSNumber *)smRef integerValue]; CFRelease(smRef); }
    if (_snapMode != 1) _snapMode = 0;
    Boolean wv = NO; CFPreferencesGetAppBooleanValue((__bridge CFStringRef)kFUWebMode, (__bridge CFStringRef)kFUSuite, &wv);
    _webMode = wv ? 1 : 0;
    // v1.3.13：吸附延时（秒）。松手后球先以「完整悬浮图标」停在落点，这么久之后才自动吸附（0=立即）。
    CFPropertyListRef sdlyRef = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUSnapDelay, (__bridge CFStringRef)kFUSuite);
    if (sdlyRef && CFGetTypeID(sdlyRef) == CFNumberGetTypeID()) {
        _snapDelay = [(__bridge NSNumber *)sdlyRef doubleValue];
        CFRelease(sdlyRef);
    } else if (sdlyRef) { CFRelease(sdlyRef); }
    if (_snapDelay < 0) _snapDelay = 0; if (_snapDelay > 15) _snapDelay = 15;
    // v1.3.9 修 05（真机实测确认的根因）：键被删掉时 CFPreferencesCopyAppValue 返回 NULL，
    // 而旧代码两个分支都不走 → _ballIcon / _ballColor / _ballTitle **保持上一次的旧值**，
    // 于是「设置里删了照片，球上照片还在」。这里必须在读到 NULL 时明确清空。
    CFPropertyListRef btRef = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUBallTitle, (__bridge CFStringRef)kFUSuite);
    if (btRef && CFGetTypeID(btRef) == CFStringGetTypeID()) { _ballTitle = (__bridge_transfer NSString *)btRef; }
    else { if (btRef) CFRelease(btRef); _ballTitle = nil; }
    if (!_ballTitle.length) _ballTitle = @"URL";
    CFPropertyListRef biRef = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUBallIcon, (__bridge CFStringRef)kFUSuite);
    if (biRef && CFGetTypeID(biRef) == CFDataGetTypeID()) { _ballIcon = (__bridge_transfer NSData *)biRef; }
    else { if (biRef) CFRelease(biRef); _ballIcon = nil; }
    CFPropertyListRef bcRef = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUBallColor, (__bridge CFStringRef)kFUSuite);
    if (bcRef && CFGetTypeID(bcRef) == CFStringGetTypeID()) { _ballColor = (__bridge_transfer NSString *)bcRef; }
    else { if (bcRef) CFRelease(bcRef); _ballColor = nil; }
    NSInteger oldEntryCount = (NSInteger)_entries.count;
    [self loadEntries];
    if (_didSetup) {
        [self applyBallAppearance];   // 设置里改了外观 → 立即生效
        // v1.3.13：扇形正开着时新增/删除了入口 → 立刻重排，修「添加了快捷 URL 但扇形里不显示」
        if (_fanOpen && (NSInteger)_entries.count != oldEntryCount) [self fuRelayoutFanInstant];
    }
}
#pragma mark - v1.3.2 黑名单（前台 App 心跳驱动）
- (NSArray *)fuBlacklist {
    CFPropertyListRef arr = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUEnabledApps, (__bridge CFStringRef)kFUSuite);
    NSArray *list = nil;
    if (arr) { list = (__bridge_transfer NSArray *)arr; if (![list isKindOfClass:[NSArray class]]) list = nil; }
    return list ?: @[];
}
// 黑名单里的每个 bundle id 注册「来前台 / 退后台」两条 Darwin 通知（通知名带 bundle id，可精确匹配）
- (void)fuSyncFrontWatches {
    if (!fuIsSpringBoard()) return;
    if (!_frontWatched) _frontWatched = [NSMutableSet set];
    for (id b in [self fuBlacklist]) {
        if (![b isKindOfClass:[NSString class]] || ![(NSString *)b length]) continue;
        NSString *bid = (NSString *)b;
        if ([_frontWatched containsObject:bid]) continue;
        [_frontWatched addObject:bid];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)(self), &fuFrontAliveCb,
            (__bridge CFStringRef)fuAliveName(bid), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)(self), &fuFrontGoneCb,
            (__bridge CFStringRef)fuGoneName(bid), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
- (void)markFrontBid:(NSString *)bid {
    if (!bid.length) return;
    _frontBid = bid; _frontBidTs = CFAbsoluteTimeGetCurrent();
    NSLog(@"[FloatingURL] frontApp -> %@", bid);
    [self applyVisibility];
}
- (void)clearFrontBid:(NSString *)bid {
    if (![_frontBid isEqualToString:bid]) return;
    _frontBid = nil; _frontBidTs = 0;
    NSLog(@"[FloatingURL] frontApp left -> %@", bid);
    [self applyVisibility];
}
// v1.3.3：直接读取 SpringBoard 当前前台 App（最可靠，不依赖各 App 心跳上报）。
// 之前只靠各 App 发 Darwin 心跳，部分 App（如奥维地图）因注入/时机问题不上报 → 黑名单漏判。
- (NSString *)fuFrontmostBid {
    // v1.3.4 热修：全程 respondsToSelector 守卫 + @try/@catch 兜底。
    // 任何私有 API 缺失 / KVC 异常都只返回 nil，绝不抛异常——否则会带崩 SpringBoard → 安全模式。
    @try {
        NSString *bid = nil;
        // v1.3.11：回滚 1.3.10 的 dlopen/dlsym 实验 —— 虽然它大概率无害，但它在桌面启动路径上，
        // 且无法用 @try 兜底（C 函数段错误拦截不了）。回到 1.3.9 守卫式 ObjC 路径（真机长期稳定）。
        // 首选：SBApplicationController（iOS 13+ 稳定存在），取前台 App 的 bundle id。
        Class ctrl = NSClassFromString(@"SBApplicationController");
        SEL sharedSel = NSSelectorFromString(@"sharedInstance");
        if (ctrl && [ctrl respondsToSelector:sharedSel]) {
            id shared = [ctrl performSelector:sharedSel];
            SEL fsel = NSSelectorFromString(@"frontmostApplication");
            if (shared && [shared respondsToSelector:fsel]) {
                id front = [shared performSelector:fsel];
                if (front && [front respondsToSelector:@selector(bundleIdentifier)]) {
                    bid = [front bundleIdentifier];
                }
            }
        }
        // 兜底：UIApplication 私有 API（部分环境 SBApplicationController 取不到时再试它）。
        if (!bid.length) {
            UIApplication *app = UIApplication.sharedApplication;
            SEL sel = NSSelectorFromString(@"_frontmostApplication");
            if (app && [app respondsToSelector:sel]) {
                id front = [app performSelector:sel];
                if (front && [front respondsToSelector:@selector(bundleIdentifier)]) {
                    bid = [front bundleIdentifier];
                }
            }
        }
        if (bid && [bid isEqualToString:@"com.apple.springboard"]) bid = nil;   // 桌面自身不算“前台 App”
        return bid;
    } @catch (NSException *e) {
        NSLog(@"[FloatingURL] fuFrontmostBid 异常（已忽略，避免崩溃）: %@", e);
        return nil;
    }
}
- (void)loadEntries {
    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUURLs, (__bridge CFStringRef)kFUSuite);
    NSArray *arr = nil;
    if (r) { arr = (__bridge_transfer NSArray *)r; if (![arr isKindOfClass:[NSArray class]]) arr = nil; }
    // v1.3.5 修 06：用户把快捷 URL 全删了（urls 存在但为空数组）→ 就是「没有入口」，
    // 绝不能再用默认网址兜底（那正是「删完还弹出一个打不开的网页」的根因）。
    if (arr) { _entries = arr; return; }
    // 兼容老版本：只设了主 URL、没有 urls 数组 → 当成唯一一条入口。
    CFPropertyListRef ur = CFPreferencesCopyAppValue(CFSTR("url"), (__bridge CFStringRef)kFUSuite);
    NSString *u = nil;
    if (ur) { u = (__bridge_transfer NSString *)ur; if (![u isKindOfClass:[NSString class]]) u = nil; }
    _entries = u.length ? @[ @{ kFUEntryURL: u } ] : @[];
}

#pragma mark - 历史
- (void)loadHistory {
    CFPropertyListRef hRef = CFPreferencesCopyAppValue(CFSTR("history"), (__bridge CFStringRef)kFUSuite);
    if (hRef) { NSArray *arr = (__bridge_transfer NSArray *)hRef;
        if ([arr isKindOfClass:[NSArray class]]) _history = [arr mutableCopy]; }
    if (!_history) _history = [NSMutableArray array];
}
- (void)saveHistory {
    CFPreferencesSetAppValue(CFSTR("history"), (__bridge CFPropertyListRef)(_history), (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
}
- (void)pushHistory:(NSString *)raw {
    NSString *u = [self normalizeURL:raw]; if (!u.length) return;
    [_history removeObject:u]; [_history insertObject:u atIndex:0];
    while (_history.count > 30) [_history removeLastObject];
    [self saveHistory];
}
- (NSString *)normalizeURL:(NSString *)raw {
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) return nil;
    NSURLComponents *c = [NSURLComponents componentsWithString:s];
    if (c && c.scheme.length && [c.scheme rangeOfString:@"."].location == NSNotFound) return s;
    return [@"https://" stringByAppendingString:s];
}
- (BOOL)isWebScheme:(NSString *)u {
    NSURLComponents *c = [NSURLComponents componentsWithString:u];
    NSString *sch = c.scheme.lowercaseString; if (!sch.length) return YES;
    return [@[@"http",@"https"] containsObject:sch];
}

#pragma mark - 穿透 window 挂载（永远不抢 key）
- (void)setupWhenHostReady {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self setupWhenHostReady]; }); return; }
    static BOOL done = NO; if (done) return;
    _hostBid = [[NSBundle mainBundle] bundleIdentifier];

    UIApplication *app = UIApplication.sharedApplication;
    if (!app) {
        static int tries = 0;
        if (tries++ < 25) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4*NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ [self setupWhenHostReady]; });
        return;
    }
    // iOS13+ 必须绑定 windowScene，否则 UIWindow 不渲染（球/扇形/编辑器全都不显示）。
    // 平时非 key + hitTest 空白穿透（不吞 App 触摸，巨魔 app 不卡死）；
    // 仅网页面板/编辑器需键盘时临时 makeKeyWindow，关闭立即还给 App。
    if (!_overlay) {
        __block UIWindowScene *scene = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in app.connectedScenes) {
                if (s.activationState == UISceneActivationStateForegroundActive &&
                    [s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
            }
        }
        if (scene) _overlay = [[FUOverlayWindow alloc] initWithWindowScene:scene];
        else       _overlay = [[FUOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        // v1.3.0：层级提到 1e9（远高于状态栏 1000 / 弹窗 2000），下拉控制中心时球不再被盖住。
        _overlay.windowLevel = 1000000000.0f;
        _overlay.backgroundColor = [UIColor clearColor];
        _overlay.hidden = NO;            // 仅可见，绝不 makeKeyAndVisible
        _overlay.userInteractionEnabled = YES;
        // disabled 透明 rootVC：用于承载编辑器 VC，且其 view 不参与 hitTest（安全穿透）
        _overlayRoot = [UIViewController new];
        _overlayRoot.view.backgroundColor = [UIColor clearColor];
        _overlayRoot.view.userInteractionEnabled = NO;
        _overlay.rootViewController = _overlayRoot;
        [self rekeyApp];                 // 确保 App 仍是 key，悬浮窗不抢
    }
    done = YES;
    [self buildUI];
    [self applyBallAppearance];   // v1.3.5：应用自定义球名称/图标/颜色
    // 进入前台时实时重判「作用 App」网关，免去重启 App 才生效。
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(onBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    // v1.3.0 兜底：每秒重读偏好并重判黑名单/开关。Darwin 通知在某些 App（如 QQ）里会被
    // 延迟或吞掉，导致「设置里加了黑名单、球还在」——轮询保证 1 秒内必生效。
    if (!_pollTimer) {
        _pollTimer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(onBecomeActive)
                                           userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:_pollTimer forMode:NSRunLoopCommonModes];
    }
    // v1.3.2：SpringBoard 监听「黑名单 App 来前台/退后台」心跳，命中即隐藏悬浮球。
    [self fuSyncFrontWatches];
    [self onBecomeActive];
}
- (void)onBecomeActive {
    if (!_didSetup) return;
    @try {
        // v1.3.3：静默模式 → 桌面球彻底休眠，跳过前台检测与偏好重读（最省电）
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Media/FloatingURL_silent"]) {
            [self applyVisibility]; return;
        }
        [self reloadPrefs];
        if (fuIsSpringBoard()) {
            // v1.3.3：用 SpringBoard 直读前台 App 作为权威来源（修复奥维地图等漏判）。
            NSString *fb = [self fuFrontmostBid];
            if (fb.length) { _frontBid = fb; _frontBidTs = CFAbsoluteTimeGetCurrent(); }
            else if (_frontBid && (CFAbsoluteTimeGetCurrent() - _frontBidTs) > 1.0) {
                _frontBid = nil; _frontBidTs = 0;
            }
        } else {
            [self fuSyncFrontWatches];   // 非桌面进程：保留心跳兜底
            if (_frontBid && (CFAbsoluteTimeGetCurrent() - _frontBidTs) > 3.0) { _frontBid = nil; _frontBidTs = 0; }
        }
        [self applyVisibility];
    } @catch (NSException *e) {
        // v1.3.4：任何意外都不该带崩 SpringBoard（否则循环进安全模式）。记日志后静默退出本次重判。
        NSLog(@"[FloatingURL] onBecomeActive 异常（已忽略）: %@", e);
    }
}
// 把 key 还给 App 的主窗口（level Normal）
- (void)rekeyApp {
    UIApplication *app = UIApplication.sharedApplication;
    for (UIWindow *w in app.windows) {
        if (w != _overlay && w.windowLevel == UIWindowLevelNormal) { [w makeKeyWindow]; break; }
    }
}
// 交互态（面板/编辑器需键盘）临时当 key；关闭时还给 App。扇形无需键盘，保持非 key。
- (void)setInteractive:(BOOL)on {
    if (on == _interactive) return;
    _interactive = on;
    if (on) [_overlay makeKeyWindow];
    else [self rekeyApp];
}

- (void)buildUI {
    _didSetup = YES;
    // ---- 悬浮球：玻璃液态，kFUButtonSize ----
    _ball = [UIButton buttonWithType:UIButtonTypeCustom];
    _ball.frame = CGRectMake(0, 0, kFUButtonSize, kFUButtonSize);
    _ball.layer.cornerRadius = kFUButtonSize/2.0;
    _ball.layer.shadowColor  = [UIColor blackColor].CGColor;
    _ball.layer.shadowOpacity = 0.25f; _ball.layer.shadowRadius = 6.0f; _ball.layer.shadowOffset = CGSizeMake(0, 2);
    _ball.backgroundColor = [UIColor clearColor];

    _ballBlur = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    _ballBlur.frame = _ball.bounds;
    _ballBlur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _ballBlur.layer.cornerRadius = kFUButtonSize/2.0; _ballBlur.clipsToBounds = YES;
    _ballBlur.layer.borderWidth = 0.8f; _ballBlur.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
    [_ball addSubview:_ballBlur];

    _ballLabel = [[UILabel alloc] initWithFrame:_ball.bounds];
    _ballLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _ballLabel.text = @"URL"; _ballLabel.font = [UIFont boldSystemFontOfSize:10];
    _ballLabel.textAlignment = NSTextAlignmentCenter; _ballLabel.textColor = [UIColor labelColor];
    [_ballBlur.contentView addSubview:_ballLabel];

    // 区分「点击」与「拖动」：用 UITapGestureRecognizer 触发 ballTapped，并要求它等
    // UIPanGestureRecognizer「失败」后才生效——这样纯粹点击（几乎无位移）才会弹扇形，
    // 而拖动（超过位移阈值）只移动小球、不弹扇形，且不会误触发 ballTapped。
    // 关键：绝对不能再给按钮加 UIControlEventTouchUpInside 的 addTarget——否则拖动结束也会触发一次点击，
    // 而且真实点击往往带几像素位移，会先让 pan 开始并吞掉按钮触摸，导致 TouchUpInside 永不触发（点了没反应）。
    UIPanGestureRecognizer *ballPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panBall:)];
    ballPan.cancelsTouchesInView = NO;   // 不吞掉按钮自身触摸，保证上面的 tap 仍能被识别
    [_ball addGestureRecognizer:ballPan];
    UITapGestureRecognizer *ballTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ballTapped)];
    [ballTap requireGestureRecognizerToFail:ballPan];
    [_ball addGestureRecognizer:ballTap];
    [_overlay addSubview:_ball];
    [self placeBallInWindow:_overlay];

    // ---- 网页面板 ----
    _panel = [[UIView alloc] initWithFrame:CGRectZero];
    _panel.backgroundColor = [UIColor systemBackgroundColor];
    _panel.layer.cornerRadius = 14.0f; _panel.clipsToBounds = YES; _panel.hidden = YES;
    _panel.layer.borderColor = [UIColor separatorColor].CGColor; _panel.layer.borderWidth = 0.5f;

    _bar = [[UIView alloc] initWithFrame:CGRectZero];
    _bar.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_bar addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panPanel:)]];
    UILongPressGestureRecognizer *barLong = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(toggleBarPosition:)];
    barLong.minimumPressDuration = 0.6;
    [_bar addGestureRecognizer:barLong];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(4, 0, 44, 40); [close setTitle:@"✕" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [close addTarget:self action:@selector(collapse) forControlEvents:UIControlEventTouchUpInside];
    close.autoresizingMask = UIViewAutoresizingFlexibleRightMargin; [_bar addSubview:close];

    _urlField = [[UITextField alloc] initWithFrame:CGRectZero];
    _urlField.placeholder = @"输入网址"; _urlField.text = _url; _urlField.font = [UIFont systemFontOfSize:12];
    _urlField.textAlignment = NSTextAlignmentCenter; _urlField.borderStyle = UITextBorderStyleRoundedRect;
    _urlField.autocorrectionType = UITextAutocorrectionTypeNo; _urlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _urlField.keyboardType = UIKeyboardTypeURL; _urlField.returnKeyType = UIReturnKeyGo;
    _urlField.clearButtonMode = UITextFieldViewModeWhileEditing; _urlField.delegate = self;
    _urlField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_urlField addTarget:self action:@selector(urlGo) forControlEvents:UIControlEventEditingDidEndOnExit];
    [_urlField addTarget:self action:@selector(urlEditingBegan) forControlEvents:UIControlEventEditingDidBegin];
    [_bar addSubview:_urlField];

    UIButton *reload = [UIButton buttonWithType:UIButtonTypeSystem];
    _reloadBtn = reload; reload.frame = CGRectMake(0, 0, 44, 40); [reload setTitle:@"↻" forState:UIControlStateNormal];
    reload.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [reload addTarget:self action:@selector(reload) forControlEvents:UIControlEventTouchUpInside];
    reload.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin; [_bar addSubview:reload];
    [_panel addSubview:_bar];

    _historyTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _historyTable.dataSource = self; _historyTable.delegate = self; _historyTable.hidden = YES;
    _historyTable.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _historyTable.layer.cornerRadius = 10;
    _historyTable.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_panel addSubview:_historyTable];

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    // ★ 关键：独立悬浮窗里的 WKWebView 白屏，常见根因是 Web 内容进程在「非 App 主窗口」里启停不稳。
    //   复用同一个 WKProcessPool，让 Web 进程持久稳定，杜绝白屏。
    static WKProcessPool *fuPool = nil;
    static dispatch_once_t oncePool;
    dispatch_once(&oncePool, ^{ fuPool = [[WKProcessPool alloc] init]; });
    cfg.processPool = fuPool;
    cfg.allowsAirPlayForMediaPlayback = YES;
    _webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    _webView.navigationDelegate = self;
    _webView.allowsBackForwardNavigationGestures = YES;
    // v1.3.0 修「只有网址没有网页内容(白屏)」：透明 WKWebView 在独立 window 里
    // 合成路径异常 → 改回不透明 + 实底色，内容进程稳定渲染。
    _webView.opaque = YES; _webView.backgroundColor = [UIColor systemBackgroundColor];
    _webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _webView.scrollView.bounces = YES; [_panel addSubview:_webView];
    // v1.3.11 血泪教训：绝对不要在 SpringBoard 里创建 UIWebView(WebKit1) —— 它会拉起 WebThread
    // 挂死桌面主线程，watchdog 每 60~120s 杀一次 SpringBoard → 无限 respring 循环（真机复现）。
    // 桌面内置网页面板暂不可行；webMode 打开时桌面点击仍走系统浏览器。

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [_webView addSubview:_spinner];

    // 网页加载失败时显示原因（白屏无提示太难排查）；叠在 webView 之上、工具条之下。
    _webErrorLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _webErrorLabel.hidden = YES; _webErrorLabel.numberOfLines = 0;
    _webErrorLabel.textAlignment = NSTextAlignmentCenter;
    _webErrorLabel.font = [UIFont systemFontOfSize:12];
    _webErrorLabel.textColor = [UIColor systemRedColor];
    _webErrorLabel.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _webErrorLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_panel addSubview:_webErrorLabel];
    [_panel bringSubviewToFront:_bar];   // 保证关闭/地址条始终在最上层

    // 非网页入口（scheme 类）的简单输入框：仅此模式显示，不显示网页工具条/网页视图。
    _schemeBox = [[UIView alloc] initWithFrame:CGRectZero];
    _schemeBox.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _schemeBox.layer.cornerRadius = 12; _schemeBox.hidden = YES;
    [_panel addSubview:_schemeBox];
    _schemeField = [[UITextField alloc] initWithFrame:CGRectZero];
    _schemeField.borderStyle = UITextBorderStyleRoundedRect; _schemeField.font = [UIFont systemFontOfSize:13];
    _schemeField.textAlignment = NSTextAlignmentCenter; _schemeField.keyboardType = UIKeyboardTypeURL;
    _schemeField.autocorrectionType = UITextAutocorrectionTypeNo; _schemeField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _schemeField.clearButtonMode = UITextFieldViewModeWhileEditing; _schemeField.returnKeyType = UIReturnKeyGo;
    [_schemeBox addSubview:_schemeField];
    _schemeOpenBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _schemeOpenBtn.layer.cornerRadius = 10; _schemeOpenBtn.backgroundColor = [UIColor systemBlueColor];
    [_schemeOpenBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_schemeOpenBtn setTitle:@"打开" forState:UIControlStateNormal];
    [_schemeOpenBtn addTarget:self action:@selector(openScheme) forControlEvents:UIControlEventTouchUpInside];
    [_schemeBox addSubview:_schemeOpenBtn];

    [_panel addGestureRecognizer:[[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinchPanel:)]];
    [_overlay addSubview:_panel];
    [self layoutPanel];
}
- (void)placeBallInWindow:(UIWindow *)w {
    if (!_ball || !w) return;
    // v1.3.5：球位置改成「归一化坐标」持久化（ballX/ballY）——自动吸附模式记吸附边，
    // 全屏固定模式记用户拖到哪就停哪，重启后原位恢复。
    CGRect s = w.bounds;
    CFPropertyListRef bx = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUBallX, (__bridge CFStringRef)kFUSuite);
    CFPropertyListRef by = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUBallY, (__bridge CFStringRef)kFUSuite);
    BOOL hasPos = (bx || by);
    CGFloat nx = 0.92f, ny = 0.45f;
    if (bx && CFGetTypeID(bx) == CFNumberGetTypeID()) nx = [(__bridge NSNumber *)bx floatValue];
    if (by && CFGetTypeID(by) == CFNumberGetTypeID()) ny = [(__bridge NSNumber *)by floatValue];
    if (bx) CFRelease(bx); if (by) CFRelease(by);
    if (!hasPos) { nx = (s.size.width - kFUButtonSize - 8.0f) / MAX(1.0f, s.size.width); ny = 0.45f; }
    if (nx < 0) nx = 0; if (nx > 1) nx = 1;
    if (ny < 0) ny = 0; if (ny > 1) ny = 1;
    CGFloat cx = nx * s.size.width, cy = ny * s.size.height;
    CGFloat x = MAX(-kFUButtonSize/2.0f, MIN(s.size.width  - kFUButtonSize/2.0f, cx - kFUButtonSize/2.0f));
    CGFloat y = MAX(2.0f,             MIN(s.size.height - kFUButtonSize - 2.0f, cy - kFUButtonSize/2.0f));
    _ball.frame = CGRectMake(x, y, kFUButtonSize, kFUButtonSize);
    _ball.alpha = 0.4f;   // 初始即半透明待机（拖动/点击会临时变实心）
}
// v1.3.5 修 05：把自定义的名称/图标/底色应用到悬浮球（图标优先于文字）
- (void)applyBallAppearance {
    if (!_ball) return;
    NSString *titleNow = (_ballTitle.length ? _ballTitle : @"URL");
    // v1.3.13：这个方法每秒都会被轮询调到 —— 外观没变就直接返回，别反复解码球图标（省电、少卡顿）。
    if (_ballImageView) {
        BOOL sameIcon  = (_ballIcon == nil && _ballIconShown == nil) ||
                         (_ballIcon != nil && _ballIconShown != nil && [_ballIcon isEqualToData:_ballIconShown]);
        BOOL sameTitle = [_ballShownTitle isEqualToString:titleNow];
        BOOL sameColor = (_ballColor == nil && _ballShownColor == nil) ||
                         (_ballColor != nil && _ballShownColor != nil && [_ballColor isEqualToString:_ballShownColor]);
        if (sameIcon && sameTitle && sameColor) return;
    }
    _ballIconShown = _ballIcon; _ballShownTitle = titleNow; _ballShownColor = _ballColor;
    if (!_ballImageView) {
        _ballImageView = [[UIImageView alloc] initWithFrame:_ball.bounds];
        _ballImageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _ballImageView.contentMode = UIViewContentModeScaleAspectFill;
        _ballImageView.clipsToBounds = YES;
        _ballImageView.layer.cornerRadius = kFUButtonSize/2.0f;
        [_ballBlur.contentView addSubview:_ballImageView];
    }
    UIImage *img = _ballIcon.length ? [UIImage imageWithData:_ballIcon] : nil;
    if (img) {
        _ballImageView.image = img; _ballImageView.hidden = NO; _ballLabel.hidden = YES;
        _ballBlur.backgroundColor = [UIColor clearColor];
    } else {
        _ballImageView.image = nil; _ballImageView.hidden = YES; _ballLabel.hidden = NO;
        NSString *t = _ballTitle.length ? _ballTitle : @"URL";
        _ballLabel.text = t;
        _ballLabel.font = [UIFont boldSystemFontOfSize:(t.length >= 4 ? 8.0f : (t.length == 3 ? 9.0f : 10.0f))];
        UIColor *bg = [self fuColorFromHex:_ballColor];
        _ballBlur.backgroundColor = bg ?: [UIColor clearColor];   // 不填底色 = 玻璃质感
    }
}
// v1.3.5 修 03：扇形朝向 = 由球的「实际位置」判定左右，而不是设置里手选的边。
// 球在屏幕中心线左边 → 扇形朝右（屏幕内侧）展开；在右边 → 朝左展开。
- (NSInteger)fuBallSide {
    if (!_ball || !_overlay) return 0;
    CGFloat cx = CGRectGetMidX(_ball.frame);
    return (cx < _overlay.bounds.size.width / 2.0f) ? 1 : 0;   // 1=左 0=右
}
// v1.3.5：把球当前位置写成归一化坐标（不动 settingsChanged 通知，避免自触发死循环）
- (void)persistBallPos {
    if (!_ball || !_overlay) return;
    CGRect s = _overlay.bounds;
    if (s.size.width < 1 || s.size.height < 1) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)kFUBallX,
        (__bridge CFPropertyListRef)@(CGRectGetMidX(_ball.frame) / s.size.width), (__bridge CFStringRef)kFUSuite);
    CFPreferencesSetAppValue((__bridge CFStringRef)kFUBallY,
        (__bridge CFPropertyListRef)@(CGRectGetMidY(_ball.frame) / s.size.height), (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
}
- (void)layoutPanel {
    if (!_panel) return;
    CGRect b = _panel.bounds; CGFloat barH = 40; CGRect barF, webF;
    if (_barAtBottom) { barF = CGRectMake(0, b.size.height - barH, b.size.width, barH);
        webF = CGRectMake(0, 0, b.size.width, b.size.height - barH); }
    else { barF = CGRectMake(0, 0, b.size.width, barH); webF = CGRectMake(0, barH, b.size.width, b.size.height - barH); }
    _bar.frame = barF; _webView.frame = webF; _historyTable.frame = webF;
    _urlField.frame = CGRectMake(52, 6, b.size.width - 104, 28);
    _reloadBtn.frame = CGRectMake(b.size.width - 48, 0, 44, 40);
    _spinner.center = CGPointMake(webF.size.width/2.0, webF.size.height/2.0);
    if (_webErrorLabel) _webErrorLabel.frame = webF;   // 覆盖网页区域（不含工具条）
    if (_schemeBox) {
        _schemeBox.frame = CGRectMake(12, 12, b.size.width - 24, b.size.height - 24);
        CGFloat pad = 16; CGRect ib = _schemeBox.bounds;
        _schemeField.frame = CGRectMake(pad, 24, ib.size.width - pad*2, 36);
        _schemeOpenBtn.frame = CGRectMake(pad, 76, ib.size.width - pad*2, 44);
    }
    [_historyTable setNeedsLayout]; [self applyWebZoom];
}
- (void)applyWebZoom {
    if (!_webView || !_expanded) return;
    CGFloat z = _panel.bounds.size.width / 340.0f; z = MAX(0.5f, MIN(3.0f, z));
    UIScrollView *sv = _webView.scrollView;
    if (fabs(sv.zoomScale - z) < 0.02f) return;
    CGSize cs = sv.contentSize; if (cs.width < 1) cs = _webView.bounds.size;
    CGPoint c = CGPointMake(cs.width/2.0, cs.height/2.0);
    CGFloat w = _webView.bounds.size.width / z, h = _webView.bounds.size.height / z;
    [sv zoomToRect:CGRectMake(c.x - w/2.0, c.y - h/2.0, w, h) animated:NO];
}

#pragma mark - 交互
- (void)ballTapped {
    [self cancelPendingSnap];     // v1.3.13：点球 = 取消待吸附（否则扇形刚弹出球就被吸走）
    _ball.alpha = 1.0f;   // 点击唤醒：变实心，方便使用
    [self restoreBallFromSnap];   // 半隐吸附态 → 先拉回完整可见
    if (_expanded) { [self collapse]; return; }
    if (_fanOpen)  { [self closeFan]; return; }
    // v1.3.5 修 06：一个入口都没有（用户把快捷 URL 删光了）→ 什么都不做，
    // 不能再弹出一个默认网页（那既莫名又打不开）。
    if (_entries.count == 0) return;
    // v1.3.8 修 07：只有一个入口 → 展开扇形毫无意义（就一个图标还占满屏），直接触发它。
    if (_entries.count == 1) {
        [self triggerEntry:_entries[0]];
        _ball.alpha = 0.4f;   // 立刻回到待机半透明
        return;
    }
    [self openFan];   // 有入口 → 弹出扇形（几个入口排几个）
}
- (void)panBall:(UIPanGestureRecognizer *)g {
    if (!_ball) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        _ballDragOrigin = _ball.frame.origin; _ball.alpha = 1.0f; _draggingBall = YES;   // 拖动时变实心
        [self cancelPendingSnap];   // v1.3.13：一开始拖就取消待吸附，别拖到一半被吸走
    }
    else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:_overlay];
        CGRect f = _ball.frame;
        f.origin.x = MAX(0, MIN(_overlay.bounds.size.width  - f.size.width,  _ballDragOrigin.x + t.x));
        f.origin.y = MAX(0, MIN(_overlay.bounds.size.height - f.size.height, _ballDragOrigin.y + t.y));
        _ball.frame = f;
        // v1.3.13 修「拖动球时扇形被推着走」：以前只把图标按偏移平移（会被一路推出屏幕、越推越歪），
        // 现在改成用**同一套算法围绕球重新排布**（朝向/圈层/贴边平移全部重算），
        // 球拖到哪，扇形就正对着它重新铺开。
        [self fuRelayoutFanInstant];
    }
    else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        _draggingBall = NO;   // 取消/中断也要复位，否则球的半透明待机态回不来
        if (g.state == UIGestureRecognizerStateEnded) [self scheduleSnapAfterDrop];   // v1.3.13：按延时吸附
    }
}
// v1.3.13：吸附改成「延时吸附」三步走（用户要求：松手后先给完整的悬浮图标，N 秒后再吸附）：
//   ① cancelPendingSnap        —— 用户一动球就取消，绝不「拖到一半被吸走」；
//   ② scheduleSnapAfterDrop    —— 松手：先完整可见地停在落点，N 秒（默认 3，可设 0）后才吸附；
//   ③ doSnapToEdgeWithGen:     —— 真正吸附（按屏幕中心线分左右，只露一半），带代号防串台。
- (void)cancelPendingSnap {
    _snapGen++;          // 代号 +1 → 所有已排队但还没执行的延时块自动失效
    _snapPending = NO;
}
// 把球钳在屏内，保证「完整图标」（不半隐）
- (void)clampBallFullyIntoView {
    if (!_ball || !_overlay) return;
    CGRect s = _overlay.bounds, f = _ball.frame;
    CGFloat x = MAX(0.0f, MIN(s.size.width - f.size.width, f.origin.x));
    CGFloat y = MAX(2.0f, MIN(s.size.height - f.size.height - 2.0f, f.origin.y));
    if (fabs(x - f.origin.x) > 0.5f || fabs(y - f.origin.y) > 0.5f)
        _ball.frame = CGRectMake(x, y, f.size.width, f.size.height);
}
- (void)scheduleSnapAfterDrop {
    if (!_ball || !_overlay) return;
    _snapGen++; NSInteger myGen = _snapGen;
    [self clampBallFullyIntoView];
    [self persistBallPos];       // 先把「完整可见」的落点记下来（重启后原位恢复）
    if (_snapMode == 1) {        // 全屏固定：永不吸附，直接半透明待机
        _snapPending = NO; _ball.alpha = 0.4f; return;
    }
    _ball.alpha = 1.0f;          // ★ 延时期间 = 完整的悬浮图标（用户明确要的效果）
    if (_fanOpen || _expanded) { _snapPending = YES; return; }   // 扇形/面板还开着 → 等关掉再排（见 closeFan）
    _snapPending = NO;
    NSTimeInterval d = MAX(0.0, _snapDelay);
    if (d <= 0.05) { [self doSnapToEdgeWithGen:myGen]; return; }   // 设成 0 = 立即吸附（老行为）
    __weak FUFloatingManager *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FUFloatingManager *ss = ws; if (!ss) return;
        if (myGen != ss->_snapGen) return;      // 已被取消（又拖了/点了球）或重排过
        [ss doSnapToEdgeWithGen:myGen];
    });
}
// 自动吸附：以「屏幕中心线（听筒→充电口）」为界 —— 球心在左半屏吸左边、右半屏吸右边，只露一半。
- (void)doSnapToEdgeWithGen:(NSInteger)gen {
    if (!_ball || !_overlay) return;
    if (gen != _snapGen) return;
    if (_snapMode == 1 || _fanOpen || _expanded) return;
    CGRect b = _ball.frame; CGRect s = _overlay.bounds;
    CGFloat half = b.size.width / 2.0f;
    // 竖向永远停在松手位置（不吸上/下边，避免球跑到状态栏或 Dock 上）
    CGFloat ty = MAX(2.0f, MIN(s.size.height - b.size.height - 2.0f, b.origin.y));
    CGRect f = b; f.origin.y = ty;
    NSInteger side = (CGRectGetMidX(b) < s.size.width / 2.0f) ? 1 : 0;   // 1=左 0=右
    f.origin.x = (side == 1) ? -half : (s.size.width - half);
    __weak FUFloatingManager *ws = self;
    [UIView animateWithDuration:0.3 delay:0.0 usingSpringWithDamping:0.65 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ _ball.frame = f; _ball.alpha = 0.4f; }
                     completion:^(BOOL done){
        FUFloatingManager *ss = ws; if (!ss) return;
        [ss persistBallPos];
    }];
}
// 球处于「半隐吸附态」时，点击先把它完整拉回屏幕内（再弹环/面板）。
- (void)restoreBallFromSnap {
    if (!_ball) return;
    CGRect s = _overlay.bounds; CGRect f = _ball.frame;
    CGRect clamped = CGRectMake(MAX(0, MIN(s.size.width  - f.size.width,  f.origin.x)),
                                MAX(0, MIN(s.size.height - f.size.height, f.origin.y)),
                                f.size.width, f.size.height);
    if (!CGRectEqualToRect(f, clamped))
        [UIView animateWithDuration:0.2 animations:^{ _ball.frame = clamped; }];
}
- (void)panPanel:(UIPanGestureRecognizer *)g {
    if (!_panel || !_panel.superview) return;
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:_overlay]; CGRect f = _panel.frame;
        f.origin.x += t.x; f.origin.y += t.y;
        f.origin.x = MAX(0, MIN(_overlay.bounds.size.width  - f.size.width,  f.origin.x));
        f.origin.y = MAX(0, MIN(_overlay.bounds.size.height - f.size.height, f.origin.y));
        _panel.frame = f; _lastPanelFrame = f; _hasLastFrame = YES; [g setTranslation:CGPointZero inView:_overlay];
    } else if (g.state == UIGestureRecognizerStateEnded) [self writeSync];
}
- (void)pinchPanel:(UIPinchGestureRecognizer *)g {
    if (!_panel || !_panel.superview) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        _pinchBaseSize = _panel.frame.size; _pinchBaseCenter = CGPointMake(CGRectGetMidX(_panel.frame), CGRectGetMidY(_panel.frame));
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGFloat scale = g.scale; if (scale <= 0.01) return;
        CGRect s = _overlay.bounds;
        CGFloat ww = MIN(MAX(_pinchBaseSize.width*scale, 220), s.size.width-16);
        CGFloat hh = MIN(MAX(_pinchBaseSize.height*scale, 300), s.size.height-24);
        CGRect f = CGRectMake(_pinchBaseCenter.x - ww/2.0, _pinchBaseCenter.y - hh/2.0, ww, hh);
        f.origin.x = MAX(0, MIN(s.size.width  - f.size.width,  f.origin.x));
        f.origin.y = MAX(0, MIN(s.size.height - f.size.height, f.origin.y));
        _panel.frame = f; _lastPanelFrame = f; _hasLastFrame = YES; _winW = ww; _winH = hh;
        [self layoutPanel];
    } else if (g.state == UIGestureRecognizerStateEnded) [self writeSync];
}
- (void)toggleBarPosition:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    _barAtBottom = !_barAtBottom;
    CFPreferencesSetAppValue(CFSTR("barAtBottom"), (__bridge CFPropertyListRef)[NSNumber numberWithBool:_barAtBottom],
        (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    [self layoutPanel];
}

#pragma mark - 扇形快捷菜单（v1.3.2：数量决定层数与位置 + 贴边自动变形）
// 布局规则（对齐「悬浮扇形编辑器」的思路）：
//   · 球固定在左/右边，扇形只朝屏幕内展开；
//   · 圈层半径 = 球半径 + 图标/间隔 逐层递推，再乘「整体距离」滑杆；
//   · 每层能放几个 = 该半径下的扇形弧长 ÷ (图标 + 最小净空隙)
//     → **用户加几个入口就排几个**：第 1 层放满自动溢到第 2、3 层；
//   · 球靠近上/下边缘时，扇形角度逐档收缩，直到所有图标都留在屏内（遇到屏幕边自动变形）。
// v1.3.10：朝向回归「屏幕中心线分左右」（球在左→扇形朝右、在右→朝左），永远围绕悬浮球；
// 只有四角/上下边导致展示不全时，才由「角度收缩 + 整体平移」自动变形（fuAngleToScreenCenter 保留备用）。
- (CGFloat)fuAngleToScreenCenter:(CGPoint)c {
    CGRect s = _overlay ? _overlay.bounds : [UIScreen mainScreen].bounds;
    CGFloat dx = s.size.width  / 2.0f - c.x;
    CGFloat dy = s.size.height / 2.0f - c.y;
    if (fabs(dx) < 1.0f && fabs(dy) < 1.0f) return 0.0f;   // 球正好在屏幕中心：默认朝右
    return atan2f(dy, dx) * 180.0f / (CGFloat)M_PI;
}
// v1.3.8 修 02：给定扇形角度是否可用。
//   checkFit=YES 时还检查「所有图标都在屏内」；
//   两种模式都会检查「同层相邻图标的弧距 >= 图标直径」——收缩角度会让弧距变小，一旦会挤到一起就不能再收了。
- (BOOL)fuSpanOK:(CGFloat)sp center:(CGFloat)centerA radii:(const CGFloat *)R
            caps:(const NSInteger *)caps icon:(CGFloat)isz margin:(CGFloat)m
          screen:(CGRect)sc ball:(CGPoint)c checkFit:(BOOL)checkFit {
    for (int layer = 0; layer < 3; layer++) {
        NSInteger cnt = caps[layer]; if (cnt <= 0) continue;
        CGFloat sp2 = (cnt > 1) ? sp / (CGFloat)(cnt - 1) : 0.0f;
        if (cnt > 1) {
            CGFloat arcStep = sp2 * (CGFloat)M_PI / 180.0f * R[layer];
            if (arcStep < isz * 1.02f) return NO;      // 会重叠 → 这个角度不可用
        }
        if (!checkFit) continue;
        CGFloat a0 = centerA - sp / 2.0f;
        for (NSInteger k = 0; k < cnt; k++) {
            CGFloat a = (cnt > 1) ? (a0 + sp2 * (CGFloat)k) : centerA;
            CGFloat rad = a * (CGFloat)M_PI / 180.0f;
            CGFloat x = c.x + R[layer] * cosf(rad), y = c.y + R[layer] * sinf(rad);
            if (x - isz/2.0f < m || x + isz/2.0f > sc.size.width  - m ||
                y - isz/2.0f < m || y + isz/2.0f > sc.size.height - m) return NO;
        }
    }
    return YES;
}
// v1.3.8 修 02：在给定中心角下，求「所有图标都在屏内、且同层不重叠」的最大扇形角度。
// 从用户设定角度起每 5° 收缩一次；一旦再收缩就会让图标挤到一起，就停止收缩（交给整体平移兜底）。
- (CGFloat)fuFittingSpanForCenter:(CGFloat)centerA radii:(const CGFloat *)R caps:(const NSInteger *)caps
                            icon:(CGFloat)isz margin:(CGFloat)m maxSpan:(CGFloat)spanMax {
    CGRect sc = _overlay ? _overlay.bounds : [UIScreen mainScreen].bounds;
    CGPoint c = CGPointMake(CGRectGetMidX(_ball.frame), CGRectGetMidY(_ball.frame));
    CGFloat sp = spanMax;
    while (sp > 45.0f) {
        if ([self fuSpanOK:sp center:centerA radii:R caps:caps icon:isz margin:m screen:sc ball:c checkFit:YES])
            break;
        CGFloat next = sp - 5.0f;
        if (![self fuSpanOK:next center:centerA radii:R caps:caps icon:isz margin:m screen:sc ball:c checkFit:NO])
            break;   // 再收就会重叠 → 保持当前角度
        sp = next;
    }
    return sp;
}
// v1.3.13：把「算扇形点位」抽成独立方法 —— openFan（动画摆放）与拖动球（实时重排）共用同一套算法，
// 保证「扇形永远围绕球、且始终留在屏内」在两种场景下完全一致。
- (NSArray *)fuFanPointArray {
    NSMutableArray *pts = [NSMutableArray array];
    if (!_ball || !_overlay || _entries.count < 1) return pts;
    CGRect sc = _overlay.bounds;
    CGPoint c = CGPointMake(CGRectGetMidX(_ball.frame), CGRectGetMidY(_ball.frame));
    CGFloat isz   = _iconSize;
    CGFloat gap   = MAX(4.0f, _iconGap * 0.5f);   // 图标之间至少要留的净空隙
    CGFloat stepR = isz + _iconGap;               // 相邻圈层的半径差
    CGFloat scale = _fanScale / 100.0f;           // 整体距离
    // 1) 三层半径
    CGFloat R[3];
    R[0] = (kFUButtonSize/2.0f + isz/2.0f + _iconGap) * scale;
    R[1] = R[0] + stepR * scale;
    R[2] = R[1] + stepR * scale;
    // 2) 每圈容量（v1.3.10 重做）：容量 = 弧长 ÷ (图标+净空隙) → 同圈永不挤叠。
    //    用户指定的每层数量只作该圈「上限」（0=自动），放不下的自动溢到下一圈，
    //    第三圈满了继续往外动态加圈 —— 条目再多（到48）扇形也始终围绕悬浮球。
    //    （1.3.6 的「塞满指定层」把 27 条挤进 3 圈，真机实测图标叠成一团。）
    NSInteger n = (NSInteger)_entries.count;
    NSInteger want[3] = { _layer1, _layer2, _layer3 };
    NSInteger caps[3] = { 0, 0, 0 };   // 预估每圈容量（仅供下面「角度收缩」检查用）
    CGFloat spanMax = MAX(60.0f, MIN(180.0f, _fanSpan));
    {
        CGFloat spanRad0 = spanMax * (CGFloat)M_PI / 180.0f;
        NSInteger placed2 = 0;
        for (int i = 0; i < 3 && placed2 < n; i++) {
            NSInteger capArc = MAX(1, (NSInteger)floor(R[i] * spanRad0 / (isz + gap)));
            if (want[i] > 0) capArc = MIN(capArc, want[i]);
            NSInteger add = MIN(capArc, n - placed2);
            caps[i] = add; placed2 += add;
        }
    }
    // v1.3.10：朝向回归「按屏幕中心线分左右」—— 球在左→扇形朝右、在右→朝左，始终围绕悬浮球。
    // （1.3.8 的「球心指向屏幕中心」让球在四角/上下边时扇形乱指，真机反馈：除角落外都应围绕球。）
    CGFloat centerA = [self fuBallSide] ? 0.0f : 180.0f;
    // v1.3.8 修 02：角度自适应——从用户设定角度起逐档收缩，直到所有图标都在屏内；
    // （收缩会让同层弧距变小 → 一旦会挤到一起就停止收缩，改由下方「整体平移」兜底。）
    CGFloat span = [self fuFittingSpanForCenter:centerA radii:R caps:caps icon:isz margin:6.0f maxSpan:spanMax];
    // 3) 摆点（v1.3.10 重做）：用**最终** span 重算每圈容量；第三圈满了继续动态加圈（最多 8 圈）
    {
        CGFloat spanRad = span * (CGFloat)M_PI / 180.0f;
        NSInteger placed2 = 0;
        for (NSInteger ring = 0; ring < 8 && placed2 < n; ring++) {
            CGFloat Rcur = (ring < 3) ? R[ring] : (R[2] + stepR * scale * (CGFloat)(ring - 2));
            NSInteger capArc = MAX(1, (NSInteger)floor(Rcur * spanRad / (isz + gap)));
            if (ring < 3 && want[ring] > 0) capArc = MIN(capArc, want[ring]);
            NSInteger add = MIN(capArc, n - placed2);
            if (add <= 0) break;
            CGFloat a0  = centerA - span/2.0f;
            CGFloat sp2 = (add > 1) ? span / (CGFloat)(add - 1) : 0.0f;
            for (NSInteger k = 0; k < add; k++) {
                CGFloat a = (add > 1) ? (a0 + sp2 * (CGFloat)k) : centerA;
                CGFloat rad = a * (CGFloat)M_PI / 180.0f;
                CGPoint p = CGPointMake(c.x + Rcur * cosf(rad), c.y + Rcur * sinf(rad));
                [pts addObject:[NSValue valueWithCGPoint:p]];
            }
            placed2 += add;
        }
    }
    // 4) v1.3.3 贴边自适应：若整体超出屏幕，则整体平移（保持间距，绝不重叠），直到刚好在屏内。
    if (pts.count) {
        CGFloat minX = CGFLOAT_MAX, minY = CGFLOAT_MAX, maxX = -CGFLOAT_MAX, maxY = -CGFLOAT_MAX;
        for (NSValue *v in pts) {
            CGPoint p = v.CGPointValue;
            minX = MIN(minX, p.x - isz/2.0f); maxX = MAX(maxX, p.x + isz/2.0f);
            minY = MIN(minY, p.y - isz/2.0f); maxY = MAX(maxY, p.y + isz/2.0f);
        }
        CGFloat m = 6.0f; CGFloat dx = 0, dy = 0;
        if (minX < m) dx = m - minX;
        if (minY < m) dy = m - minY;
        if (maxX > sc.size.width  - m) dx = (sc.size.width  - m) - maxX;
        if (maxY > sc.size.height - m) dy = (sc.size.height - m) - maxY;
        if (dx != 0 || dy != 0) {
            NSMutableArray *shifted = [NSMutableArray array];
            for (NSValue *v in pts) {
                CGPoint p = v.CGPointValue;
                [shifted addObject:[NSValue valueWithCGPoint:CGPointMake(p.x + dx, p.y + dy)]];
            }
            pts = shifted;
        }
    }
    return pts;
}
// v1.3.13 修「拖动球时扇形被推着走」：拖动过程中就用上面的算法重新排布（不带动画，跟手）。
- (void)fuRelayoutFanInstant {
    if (!_fanOpen || !_ball || !_overlay) return;
    [self restoreBallFromSnap];
    NSArray *pts = [self fuFanPointArray];
    if (pts.count != _fanItems.count) {     // 条目数变了（刚加/删了入口）→ 整组重开
        [self closeFanItemsAnimated:NO];
        _fanOpen = NO; [self openFan];
        return;
    }
    CGFloat isz = _iconSize;
    CGPoint c = CGPointMake(CGRectGetMidX(_ball.frame), CGRectGetMidY(_ball.frame));
    [_fanOffsets removeAllObjects];
    for (NSUInteger k = 0; k < pts.count; k++) {
        UIButton *it = _fanItems[k];
        if (![it isKindOfClass:[UIButton class]]) continue;
        CGPoint p = [pts[k] CGPointValue];
        CGRect f = CGRectMake(p.x - isz/2.0f, p.y - isz/2.0f, isz, isz);
        it.frame = f;
        [_fanOffsets addObject:[NSValue valueWithCGPoint:
            CGPointMake(CGRectGetMidX(f) - c.x, CGRectGetMidY(f) - c.y)]];
    }
}
- (void)openFan {
    if (_fanOpen || _entries.count < 1) return;   // 0 个入口不弹（loadEntries 至少兜底 1 个）
    _fanOpen = YES; _ball.alpha = 1.0f;           // 展开期间球保持实心可见
    [self cancelPendingSnap];                     // v1.3.13：扇形开着不吸附
    [self closeFanItemsAnimated:NO];
    [self restoreBallFromSnap];                   // 半隐态先拉回，环才不会跟着缩在屏外
    // 环无需键盘，保持非 key（不抢 App 触摸）；触摸经 hitTest 正常命中图标按钮。
    CGRect sc = _overlay.bounds;
    CGPoint c = CGPointMake(CGRectGetMidX(_ball.frame), CGRectGetMidY(_ball.frame));
    CGFloat isz = _iconSize;
    // v1.3.13：点位由 fuFanPointArray 统一计算（拖动重排用的是同一套）
    NSArray *pts = [self fuFanPointArray];
    // 5) 正式摆放（带轻微 clamp 兜底 + 缩放动画）
    [_fanOffsets removeAllObjects];
    NSInteger placed = 0;
    for (NSValue *v in pts) {
        NSInteger idx = placed; placed++;
        CGPoint p = v.CGPointValue;
        UIButton *it = [self buildFanItem:_entries[idx] index:idx size:isz];
        CGRect target = CGRectMake(p.x - isz/2.0f, p.y - isz/2.0f, isz, isz);
        target.origin.x = MAX(2.0f, MIN(sc.size.width  - isz - 2.0f, target.origin.x));
        target.origin.y = MAX(2.0f, MIN(sc.size.height - isz - 2.0f, target.origin.y));
        // 先把最终 frame 定死，再只动画 transform(缩放) + alpha。
        // 严禁在同一动画块里既设 frame 又设 transform（UIKit 未定义行为会放大 10 倍）。
        it.frame = target;
        [_fanOffsets addObject:[NSValue valueWithCGPoint:
            CGPointMake(CGRectGetMidX(target) - c.x, CGRectGetMidY(target) - c.y)]];
        it.alpha = 0.0f; it.transform = CGAffineTransformMakeScale(0.1f, 0.1f);
        [_overlay addSubview:it]; [_fanItems addObject:it];
        [UIView animateWithDuration:0.22 delay:0.02 * (CGFloat)idx
                            usingSpringWithDamping:0.7 initialSpringVelocity:0.6
                                          options:UIViewAnimationOptionCurveEaseOut
                                       animations:^{ it.alpha = 1.0f; it.transform = CGAffineTransformIdentity; }
                                       completion:nil];
    }
}
- (UIButton *)buildFanItem:(NSDictionary *)entry index:(NSInteger)idx size:(CGFloat)isz {
    UIButton *it = [UIButton buttonWithType:UIButtonTypeCustom];
    it.layer.cornerRadius = isz/2.0f; it.layer.shadowColor = [UIColor blackColor].CGColor;
    it.layer.shadowOpacity = 0.3f; it.layer.shadowRadius = 5.0f; it.layer.shadowOffset = CGSizeMake(0, 2);
    it.clipsToBounds = YES; it.tag = idx;
    NSData *icon = entry[kFUEntryIcon]; UIImage *img = icon.length ? [UIImage imageWithData:icon] : nil;
    if (img) {
        [it setImage:[img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal];
        it.backgroundColor = [UIColor secondarySystemBackgroundColor];
        it.imageView.contentMode = UIViewContentModeScaleAspectFill;
        it.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
        it.contentVerticalAlignment   = UIControlContentVerticalAlignmentFill;
    } else {
        // v1.3.3：无图标入口优先用自定义底色（kFUEntryColor hex），否则默认蓝。
        UIColor *bg = [self fuColorFromHex:entry[kFUEntryColor]];
        it.backgroundColor = bg ?: [UIColor colorWithRed:0.20f green:0.52f blue:0.90f alpha:0.92f];
    }
    UILabel *lab = [[UILabel alloc] initWithFrame:it.bounds];
    lab.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    lab.textAlignment = NSTextAlignmentCenter; lab.textColor = [UIColor whiteColor];
    NSString *ch = entry[kFUEntryChar] ?: @"";   // 现可存 2 汉字 / 3 字母
    lab.numberOfLines = 0;
    CGFloat fs = isz * 0.42f;
    if (ch.length >= 3) fs = isz * 0.26f; else if (ch.length == 2) fs = isz * 0.32f;
    lab.font = [UIFont boldSystemFontOfSize:fs];
    lab.text = ch;
    if (img) lab.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    [it addSubview:lab];
    [it addTarget:self action:@selector(fanItemTapped:) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(fanItemLongPressed:)];
    [it addGestureRecognizer:lp];
    return it;
}
// v1.3.3：把 #RRGGBB / #RGB 解析成 UIColor（入口自定义图标底色用）。
- (UIColor *)fuColorFromHex:(NSString *)hex {
    if (![hex isKindOfClass:[NSString class]] || hex.length < 6) return nil;
    NSString *h = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (h.length == 3) {
        h = [NSString stringWithFormat:@"%c%c%c%c%c%c",
             [h characterAtIndex:0], [h characterAtIndex:0],
             [h characterAtIndex:1], [h characterAtIndex:1],
             [h characterAtIndex:2], [h characterAtIndex:2]];
    }
    if (h.length != 6) return nil;
    unsigned int v = 0; NSScanner *s = [NSScanner scannerWithString:h]; [s scanHexInt:&v];
    return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0f
                             green:((v >> 8)  & 0xFF) / 255.0f
                              blue:(v & 0xFF)        / 255.0f alpha:1.0f];
}
- (void)fanItemTapped:(UIButton *)sender {
    NSInteger idx = sender.tag; if (idx < 0 || idx >= (NSInteger)_entries.count) { [self closeFan]; return; }
    NSDictionary *entry = _entries[idx]; [self closeFan];
    [self triggerEntry:entry];
}
// v1.3.8 修 07：把「触发一条入口」抽成独立方法，扇形图标点击与「只有 1 个入口时点球」共用同一套逻辑。
- (void)triggerEntry:(NSDictionary *)entry {
    if (![entry isKindOfClass:[NSDictionary class]]) return;
    NSString *u = entry[kFUEntryURL]; if (![u isKindOfClass:[NSString class]] || !u.length) return;
    NSString *norm = [self normalizeURL:u]; if (!norm.length) return;
    // 确认模式（设置里可开）：不直接触发，先弹输入框+打开按钮，用户点「打开」才执行。
    if (_tapConfirm) { [self showSchemeBox:norm]; return; }
    // v1.3.16：网页类恢复「内置小窗打开」（与最初版本一致）。SpringBoard 里的 WKWebView 面板在
    // 正确 makeKey + 延时加载下可正常渲染（中央球用的就是同一套面板），不再强制跳系统浏览器。
    if ([self isWebScheme:norm]) {
        [self pushHistory:norm];
        _url = norm;
        [self expand];
        return;
    }
    [self fuOpenExternally:norm];
}
- (void)fanItemLongPressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIButton *it = (UIButton *)g.view; NSInteger idx = it.tag;
    if (idx < 0 || idx >= (NSInteger)_entries.count) return;
    [self closeFan];
    [self setInteractive:YES];   // 编辑器需要接收触摸
    FUEntryEditorViewController *ed = [[FUEntryEditorViewController alloc] init];
    ed.index = idx; ed.onSaved = ^{ [self reloadPrefs]; };
    ed.onDismiss = ^{ [self setInteractive:NO]; };
    UINavigationController *nc = [[UINavigationController alloc] initWithRootViewController:ed];
    [_overlayRoot presentViewController:nc animated:YES completion:nil];
}
- (void)closeFan {
    _fanOpen = NO; [self closeFanItemsAnimated:YES];
    [self setInteractive:NO];   // 关闭扇形 → 还给 App
    // v1.3.13：关掉扇形后按「吸附延时」归位 —— 先完整可见地停 N 秒（默认 3），再到点吸附/固定。
    [self scheduleSnapAfterDrop];
}
- (void)closeFanItemsAnimated:(BOOL)animated {
    NSArray *items = [_fanItems copy]; [_fanItems removeAllObjects]; [_fanOffsets removeAllObjects];
    CGPoint c = _ball ? CGPointMake(CGRectGetMidX(_ball.frame), CGRectGetMidY(_ball.frame))
                      : CGPointMake(_overlay.bounds.size.width - 20, _overlay.bounds.size.height/2.0);
    for (UIButton *it in items) {
        if (animated) [UIView animateWithDuration:0.18 animations:^{
            it.alpha = 0.0f; it.transform = CGAffineTransformMakeScale(0.1f, 0.1f); it.center = c;
        } completion:^(BOOL f){ [it removeFromSuperview]; }];
        else [it removeFromSuperview];
    }
}

// v1.3.0 修「历史列表看得见点不动」：_webView 比 _historyTable 后加入 _panel，
// 永远压在历史表上层把触摸吞掉 → 显示历史时必须把表置顶，收起时把 webView 顶回。
- (void)setHistoryVisible:(BOOL)v {
    if (!_historyTable) return;
    if (v) { [_historyTable reloadData]; _historyTable.hidden = (_history.count == 0);
             [_panel bringSubviewToFront:_historyTable]; [_panel bringSubviewToFront:_bar]; }
    else   { _historyTable.hidden = YES; [_panel bringSubviewToFront:_webView]; [_panel bringSubviewToFront:_bar]; }
}

// v1.3.2：跨进程打开 URL。SpringBoard 里 UIApplication.openURL 不稳，优先用 LSApplicationWorkspace。
// v1.3.8 修 01（卡死 bug）：**绝不能在主线程同步调用** —— openSensitiveURL:withOptions: 会一路同步等
// FrontBoard 把目标 App 拉起，Safari/微信冷启动时要好几秒，这几秒里 SpringBoard 主线程被占死，
// 表现就是「点了网页 -> 整机卡住、屏幕动不了」。这里整段丢到后台队列，主线程立刻返回。
// v1.3.13：返回「可以投递的信箱路径」列表（按优先级）。桌面写目标 App 容器常被沙盒拒绝，
// 所以多准备一个 /var/mobile/Media 下的公共信箱 —— 哪个写成功就用哪个，App 端两处都看。
- (NSArray *)fuWebMailboxPathsForBid:(NSString *)bid {
    NSMutableArray *out = [NSMutableArray array];
    if (bid.length) {
        @try {
            Class proxyCls = NSClassFromString(@"LSApplicationProxy");
            SEL fSel = NSSelectorFromString(@"applicationProxyForIdentifier:");
            if (proxyCls && [proxyCls respondsToSelector:fSel]) {
                id proxy = [proxyCls performSelector:fSel withObject:bid];
                SEL dSel = NSSelectorFromString(@"dataContainerURL");
                if (proxy && [proxy respondsToSelector:dSel]) {
                    id dataURL = [proxy performSelector:dSel];
                    if ([dataURL isKindOfClass:[NSURL class]]) {
                        NSString *caches = [[(NSURL *)dataURL path] stringByAppendingPathComponent:@"Library/Caches"];
                        if (caches.length) {
                            [[NSFileManager defaultManager] createDirectoryAtPath:caches
                                withIntermediateDirectories:YES attributes:nil error:NULL];
                            [out addObject:[caches stringByAppendingPathComponent:kFUInAppWebFile]];
                        }
                    }
                }
            }
        } @catch (NSException *e) { }
    }
    [out addObject:kFUWebMailboxMedia];   // 公共备用信箱
    return out;
}

- (BOOL)fuHandoffWebToFrontApp:(NSURL *)u {
    @try {
        NSString *bid = [self fuFrontmostBid];
        if (!bid.length) return NO;                       // 在桌面 → 没有 App 能接手，直接走系统浏览器
        if ([bid isEqualToString:@"com.apple.mobilesafari"]) return NO;   // Safari 自己就是浏览器，别套一层
        // 载荷 = 第一行时间戳（序号，防陈旧文件被重复打开）+ 第二行 URL
        NSString *payload = [NSString stringWithFormat:@"%.3f\n%@",
                             CFAbsoluteTimeGetCurrent(), u.absoluteString];
        if (!payload.length) return NO;
        for (NSString *p in [self fuWebMailboxPathsForBid:bid]) {
            if ([payload writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
                NSLog(@"[FloatingURL] 网页已投递给 %@（信箱 %@）", bid, p);
                _webAckPending = YES;                     // 先立旗，再喊人（App 回执可能瞬间到）
                notify_post(kFUInAppWebName.UTF8String);
                return YES;
            }
        }
        NSLog(@"[FloatingURL] 投递信箱全部写失败（沙盒）→ 走系统浏览器");
        return NO;                                        // 写不进去 → 兜底系统浏览器，绝不「点了没反应」
    } @catch (NSException *e) { return NO; }
}

- (void)fuOpenViaWorkspace:(NSURL *)u {
    @try {
        Class wsc = NSClassFromString(@"LSApplicationWorkspace");
        SEL defSel = NSSelectorFromString(@"defaultWorkspace");
        id ws = (wsc && [wsc respondsToSelector:defSel]) ? [wsc performSelector:defSel] : nil;
        if (!ws) { NSLog(@"[FloatingURL] 无 LSApplicationWorkspace，打不开 %@", u); return; }
        // ★ 仍然丢后台队列：openSensitiveURL 会同步等 FrontBoard 拉起目标 App，主线程会被占死好几秒。
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            @try {
                SEL s1 = NSSelectorFromString(@"openSensitiveURL:withOptions:");
                if ([ws respondsToSelector:s1]) { [ws performSelector:s1 withObject:u withObject:nil]; return; }
                SEL s2 = NSSelectorFromString(@"openURL:");
                if ([ws respondsToSelector:s2]) { [ws performSelector:s2 withObject:u]; }
            } @catch (NSException *e) { NSLog(@"[FloatingURL] workspace 打开异常: %@", e); }
        });
    } @catch (NSException *e) { NSLog(@"[FloatingURL] openViaWorkspace 异常（已忽略）: %@", e); }
}

// v1.3.13：FrontBoard 异步接口。1.3.10 只用它、失败了也无声无息 → 用户看到的就是「点了没反应」。
- (void)fuOpenViaFBS:(NSURL *)u {
    @try {
        __weak FUFloatingManager *wself = self;
        Class fbsCls = NSClassFromString(@"FBSSystemService");
        SEL sharedSel = NSSelectorFromString(@"sharedService");
        SEL openSel = NSSelectorFromString(@"openURL:options:withResultBlock:");
        if (fbsCls && [fbsCls respondsToSelector:sharedSel]) {
            id svc = [fbsCls performSelector:sharedSel];
            if (svc && [svc respondsToSelector:openSel]) {
                void (^blk)(BOOL, NSError *) = ^(BOOL ok, NSError *err){
                    if (ok) return;
                    NSLog(@"[FloatingURL] FBSSystemService 未受理 → 继续兜底 workspace");
                    FUFloatingManager *ss = wself; if (ss) [ss fuOpenViaWorkspace:u];
                };
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(svc, openSel, u, @{}, blk);
                return;
            }
        }
        [self fuOpenViaWorkspace:u];
    } @catch (NSException *e) {
        NSLog(@"[FloatingURL] fuOpenViaFBS 异常（已忽略）: %@", e);
        [self fuOpenViaWorkspace:u];
    }
}

// v1.3.13 系统打开链路（每步都有回执，失败就往下走，绝不「点了没反应」）：
//   ① UIApplication openURL:options:completionHandler:  —— 系统标准入口，异步、不卡主线程；
//   ② FBSSystemService（FrontBoard）→ ③ LSApplicationWorkspace（后台队列）。
- (void)fuOpenViaSystem:(NSURL *)u {
    @try {
        __weak FUFloatingManager *wself = self;
        UIApplication *app = UIApplication.sharedApplication;
        if (app) {
            [app openURL:u options:@{} completionHandler:^(BOOL ok){
                if (ok) { NSLog(@"[FloatingURL] openURL 成功：%@", u); return; }
                NSLog(@"[FloatingURL] openURL 未受理 → 试 FBSSystemService");
                FUFloatingManager *ss = wself; if (ss) [ss fuOpenViaFBS:u];
            }];
            return;
        }
        [self fuOpenViaFBS:u];
    } @catch (NSException *e) {
        NSLog(@"[FloatingURL] fuOpenViaSystem 异常（已忽略）: %@", e);
        [self fuOpenViaFBS:u];
    }
}

// v1.3.12：网页统一入口。
//   ① 在前台 App 里点 → 交回该 App 进程用「内置浏览器」(SFSafariViewController) 打开
//      —— 与 1.2.1 体验一致（那时球在 App 进程里，所以网页能渲染）。
//   ② 在桌面点 / 交不出去 / App 1.1 秒内没接住 → 系统浏览器。
// 任何一步失败都会继续往下走，绝不会「点了没反应」。
- (void)fuOpenExternally:(NSString *)s {
    NSURL *u = [NSURL URLWithString:s]; if (!u) return;
    NSString *scheme = u.scheme.lowercaseString;
    BOOL isWeb = [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (isWeb && [self fuHandoffWebToFrontApp:u]) {
                // 已交给前台 App 的内置浏览器。**只认 App 的回执**（真弹出来了才发），
                // 1.5s 没回执 = App 没接住 / 不在前台 → 自动兜底系统浏览器。
                // （1.3.12 是看「交接文件是否被删」——App 删了文件却没弹出浏览器时，这里会以为已接住，
                //   结果什么都不开；用户反馈的「网页还是用不了」就是这个洞。）
                __weak FUFloatingManager *ws = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    FUFloatingManager *ss = ws; if (!ss) return;
                    if (!ss->_webAckPending) return;      // App 已弹出内置浏览器，收工
                    ss->_webAckPending = NO;
                    NSLog(@"[FloatingURL] App 未回执 → 改用系统浏览器打开");
                    [ss fuOpenViaSystem:u];
                });
                return;
            }
            [self fuOpenViaSystem:u];
        } @catch (NSException *e) {
            NSLog(@"[FloatingURL] fuOpenExternally 异常（已忽略）: %@", e);
            [self fuOpenViaSystem:u];
        }
    });
}

#pragma mark - 展开 / 收起 面板
- (void)expand {
    if (!_didSetup) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self expand]; }); return; }
    [self loadHistory];
    CGRect s = _overlay.bounds;
    CGFloat ww = MIN(_winW, s.size.width-16), hh = MIN(_winH, s.size.height-24);
    if (_hasLastFrame) { CGRect f = _lastPanelFrame; f.size.width = ww; f.size.height = hh;
        f.origin.x = MAX(0, MIN(s.size.width - f.size.width, f.origin.x));
        f.origin.y = MAX(0, MIN(s.size.height - f.size.height, f.origin.y)); _panel.frame = f; }
    else _panel.frame = CGRectMake((s.size.width-ww)/2.0, (s.size.height-hh)/2.0, ww, hh);
    _urlField.text = _url; _schemeBox.hidden = YES; _bar.hidden = NO; _webView.hidden = NO;
    _ball.hidden = YES; _expanded = YES; [self setInteractive:YES];   // 先把 overlay 设为 key，WKWebView 才能正常渲染
    [_overlay bringSubviewToFront:_panel]; _panel.hidden = NO; [self setHistoryVisible:NO];
    [self layoutPanel]; [_panel layoutIfNeeded]; [_webView layoutIfNeeded];
    // v1.3.0：等 key 窗口 + 布局生效后再发起加载（WKWebView 在非 key/零尺寸下加载会白屏）。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self loadURL]; });
    [self writeSync];
}
- (void)showSchemeBox:(NSString *)u {
    if (!_didSetup) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self showSchemeBox:u]; }); return; }
    CGRect s = _overlay.bounds;
    CGFloat ww = MIN(_winW, s.size.width-16), hh = MIN(_winH, s.size.height-24);
    if (_hasLastFrame) { CGRect f = _lastPanelFrame; f.size.width = ww; f.size.height = hh;
        f.origin.x = MAX(0, MIN(s.size.width - f.size.width, f.origin.x));
        f.origin.y = MAX(0, MIN(s.size.height - f.size.height, f.origin.y)); _panel.frame = f; }
    else _panel.frame = CGRectMake((s.size.width-ww)/2.0, (s.size.height-hh)/2.0, ww, hh);
    _schemeField.text = u; _url = u;
    [_overlay bringSubviewToFront:_panel]; _panel.hidden = NO;
    // 非网页模式：只显示输入框 + 打开按钮，隐藏网页工具条/网页视图/历史。
    _bar.hidden = YES; _webView.hidden = YES; [self setHistoryVisible:NO]; _schemeBox.hidden = NO;
    [self layoutPanel];
    _ball.hidden = YES; _expanded = YES; [self setInteractive:YES]; [self writeSync];
}
- (void)openScheme {
    NSString *u = _schemeField.text; if (!u.length) return;
    NSString *norm = [self normalizeURL:u];
    if (norm.length) [self pushHistory:norm];
    [self fuOpenExternally:norm];   // v1.3.2：网页/非网页都交给系统打开
    [self collapse];
}
- (void)collapse {
    [_urlField resignFirstResponder]; [_schemeField resignFirstResponder];
    [self setHistoryVisible:NO]; _panel.hidden = YES;
    _expanded = NO; [self setInteractive:NO]; [self writeSync];
    // v1.3.0：统一走 applyVisibility（同时尊重总开关 + 黑名单），不再只判 enabled。
    [self applyVisibility];
}
- (void)reload { [self loadURL]; }
- (void)urlGo {
    NSString *raw = _urlField.text; NSString *u = [self normalizeURL:raw];
    if (!u.length) { _urlField.text = _url; return; }
    _url = u; [self pushHistory:u]; [self loadURL]; [_urlField resignFirstResponder];
    [self setHistoryVisible:NO]; [self writeSync];
}
- (void)urlEditingBegan { [self setHistoryVisible:YES]; }
- (void)loadURL {
    NSURL *u = [NSURL URLWithString:_url]; if (!u || u.scheme == nil) u = [NSURL URLWithString:@"https://www.apple.com"];
    NSString *scheme = u.scheme.lowercaseString;
    NSSet *webSchemes = [NSSet setWithObjects:@"http",@"https",@"about",@"data",@"blob",@"file",@"javascript", nil];
    if (scheme.length && ![webSchemes containsObject:scheme]) {
        [self fuOpenExternally:u.absoluteString]; return;   // v1.3.5：统一走跨进程打开
    }
    [_webView loadRequest:[NSURLRequest requestWithURL:u]];
}
- (void)applyVisibility {
    if (!_didSetup) return;
    // v1.3.3：静默模式 → 整窗彻底休眠（球/环/面板全藏），App 端也跳过心跳，最省电。
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Media/FloatingURL_silent"]) {
        _overlay.hidden = YES; _ball.hidden = YES; _panel.hidden = YES;
        if (_fanOpen) [self closeFan];
        if (_expanded) { _expanded = NO; [self setInteractive:NO]; }
        return;
    }
    // 防御：直接读之前也刷新一次进程内偏好缓存，确保拿到设置里最新改的值。
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    // v1.3.2 黑名单语义（重写）：球只在 SpringBoard 里，所以判断对象是「当前前台 App」。
    // 前台 App 由各 App 进程的 Darwin 心跳上报（沙盒 App 读不到设置，但发跨进程通知没问题）；
    // 之前的写法把 SpringBoard 自己的 _hostBid 拿去比黑名单，永远比不中 → 黑名单形同虚设。
    BOOL hidden = NO;
    NSArray *list = [self fuBlacklist];
    NSString *front = _frontBid;
    if (front && (CFAbsoluteTimeGetCurrent() - _frontBidTs) > 3.0) front = nil;
    for (id b in list) {
        if (![b isKindOfClass:[NSString class]]) continue;
        if (front.length && [(NSString *)b caseInsensitiveCompare:front] == NSOrderedSame) { hidden = YES; break; }
        if (_hostBid.length && [(NSString *)b caseInsensitiveCompare:_hostBid] == NSOrderedSame) { hidden = YES; break; }
    }
    NSLog(@"[FloatingURL] visibility host=%@ front=%@ list=%@ -> hidden=%d", _hostBid, front, list, hidden);
    // v1.3.0 修「黑名单加了球还在 / QQ 残留 URL」：黑名单或总开关命中时直接隐藏整个
    // overlay 窗口（球、环、面板一锅端），比只藏球更彻底——之前只藏 _ball，环/面板
    // 以及某些时序下 re-show 的球都会漏出来，看起来就像「残留了第二个 URL」。
    // v1.3.1：桌面兜底球门控——前台是某个 App 时，SpringBoard 这份让位（否则叠成 2~3 个球）。
    // v1.3.2：不再需要「让位」——球只存在于 SpringBoard，App 进程根本不建球了。
    if (!_enabled || hidden) {
        _overlay.hidden = YES;
        _ball.hidden = YES; _panel.hidden = YES;
        // v1.3.1：隐藏时同步复位「展开态」，否则恢复显示时球仍 hidden、面板也 hidden → 屏幕上空无一物。
        if (_fanOpen) [self closeFan];
        if (_expanded) { _expanded = NO; [self setInteractive:NO]; }
        return;
    }
    _overlay.hidden = NO;   // 允许显示：确保窗口一定恢复（含控制中心收起后）
    if (!_expanded && !_fanOpen && !_draggingBall) { _ball.hidden = NO; _ball.alpha = 0.4f; [_overlay bringSubviewToFront:_ball]; [self setInteractive:NO]; }
}

#pragma mark - 跨 App 轻量同步（v1.3.2：只剩 SpringBoard 一个实例，同步已无意义，直接空转）
- (void)writeSync {
    return;   // v1.3.2：球只在 SpringBoard，跨进程面板镜像正是「QQ 里残留一个 URL」的来源，停用
    if (_applyingRemote) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"open"] = @(_expanded);
    if (_expanded) { d[@"url"] = _url ?: @""; d[@"panel"] = NSStringFromCGRect(_panel.frame); }
    CFPreferencesSetAppValue((__bridge CFStringRef)kFUSync, (__bridge CFPropertyListRef)d, (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    notify_post("com.yzdmm.floatingurl/syncChanged");
}
- (void)applySync {
    return;   // v1.3.2：球只在 SpringBoard，跨进程面板镜像停用（它就是「QQ 里残留 URL」的来源）
    if (_applyingRemote) return;
    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUSync, (__bridge CFStringRef)kFUSuite);
    if (!r) return;
    NSDictionary *d = (__bridge_transfer NSDictionary *)r;
    BOOL open = [d[@"open"] boolValue]; NSString *u = d[@"url"];
    if (open == _expanded && (!open || (_url && u && [_url isEqualToString:[self normalizeURL:u]]))) {
        NSString *pf = d[@"panel"];
        if (open && pf && _hasLastFrame) { CGRect f = CGRectFromString(pf);
            if (!CGRectIsNull(f) && !CGRectEqualToRect(f, _panel.frame)) { _lastPanelFrame = f; _panel.frame = f; [self layoutPanel]; } }
        return;
    }
    _applyingRemote = YES;
    if (open) {
        if (u.length) _url = [self normalizeURL:u];
        NSString *pf = d[@"panel"]; if (pf) { _lastPanelFrame = CGRectFromString(pf); _hasLastFrame = YES; }
        if (!_expanded) [self expand]; else { _urlField.text = _url; [self layoutPanel]; [self loadURL]; }
    } else { if (_expanded) [self collapse]; }
    _applyingRemote = NO;
}

#pragma mark - UITextFieldDelegate
- (BOOL)textFieldShouldReturn:(UITextField *)textField { [self urlGo]; return YES; }
- (BOOL)textFieldShouldClear:(UITextField *)textField { _historyTable.hidden = NO; return YES; }

#pragma mark - 历史 UITableView
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return _history.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cellId = @"FUHistCell";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cellId];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    c.textLabel.text = _history[ip.row]; c.textLabel.font = [UIFont systemFontOfSize:12];
    c.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    c.detailTextLabel.text = @"长按地址栏可切换工具条位置"; c.detailTextLabel.font = [UIFont systemFontOfSize:9];
    c.detailTextLabel.textColor = [UIColor tertiaryLabelColor]; return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSString *u = _history[ip.row]; _url = u; _urlField.text = u; [self loadURL]; [self pushHistory:u];
    [tv reloadData]; [self setHistoryVisible:NO]; [_urlField resignFirstResponder];
}
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
                                            forRowAtIndexPath:(NSIndexPath *)ip {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        [_history removeObjectAtIndex:ip.row]; [self saveHistory];
        [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationFade];
        if (_history.count == 0) _historyTable.hidden = YES;
    }
}
- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip { return @"删除"; }

#pragma mark - WKNavigationDelegate
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)nav {
    [_spinner startAnimating]; if (_webErrorLabel) _webErrorLabel.hidden = YES;   // 开始新加载 → 清掉旧错误
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)nav {
    [_spinner stopAnimating]; NSString *cur = webView.URL.absoluteString;
    if (cur.length && _expanded) { _url = cur; _urlField.text = cur; [self pushHistory:cur]; }
    [self applyWebZoom];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)nav withError:(NSError *)error {
    [_spinner stopAnimating]; [self showWebError:[error localizedDescription]];
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)nav withError:(NSError *)error {
    [_spinner stopAnimating]; [self showWebError:[error localizedDescription]];
}
- (void)showWebError:(NSString *)msg {
    if (!_webErrorLabel) return;
    _webErrorLabel.text = [NSString stringWithFormat:@"⚠️ 网页无法加载\n%@", msg ?: @"(无详细信息)"];
    _webErrorLabel.hidden = NO;
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                                                   decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *u = navigationAction.request.URL; NSString *scheme = u.scheme.lowercaseString;
    NSSet *webSchemes = [NSSet setWithObjects:@"http",@"https",@"about",@"data",@"blob",@"file",@"javascript", nil];
    if (u && scheme.length && ![webSchemes containsObject:scheme]) {
        [self fuOpenExternally:u.absoluteString];   // v1.3.5：统一走跨进程打开
        decisionHandler(WKNavigationActionPolicyCancel); return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

@end

// ============================================================
// 注入入口：Filter = Bundles(com.apple.UIKit) → 所有 App + SpringBoard 都会加载本 dylib。
// v1.3.2：分工明确（真机 frida 实测决定）——
//   · SpringBoard 进程：创建球/扇形/面板。**只有它能正确读到本 tweak 的设置**
//     （沙盒 App 进程读 prefs 全为 nil），而且层级最高、全 App + 主屏幕都能看到；
//   · 其它 App 进程：不建任何 UI，只上报「我在前台」的 Darwin 心跳，供桌面球判断黑名单；
//   · 设置 App（com.apple.Preferences）：完全跳过。
// ============================================================
%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if ([bid isEqualToString:@"com.apple.Preferences"]) return;   // 设置里不挂球
        if (![bid isEqualToString:@"com.apple.springboard"]) {
            fuStartAppHeartbeat(bid);   // 沙盒 App 读不到设置 → 只发心跳，不建球
            return;
        }
        if (!INCLUDE_SPRINGBOARD) return;
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *note){ [[FUFloatingManager shared] setupWhenHostReady]; }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [[FUFloatingManager shared] setupWhenHostReady]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [[FUFloatingManager shared] setupWhenHostReady]; });
    }
}
