#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <stdlib.h>
#import <notify.h>
#import <dlfcn.h>
#include <unistd.h>            // v1.3.27：usleep（截图前让渲染服务把球拿掉）
#import <QuartzCore/QuartzCore.h>  // v1.3.27：CATransaction flush

// PhotosUI 在 SDK14.5 下无法以模块方式编译（simd/cmath 缺失），tweak 里不 import 头文件，
// 改用运行时 NSClassFromString 调用 PHPicker，避免模块构建失败。
@class PHPickerConfiguration, PHPickerViewController, PHPickerResult, PHPickerFilter;
@protocol PHPickerViewControllerDelegate;

// ============================================================
// 悬浮URL —— 系统级悬浮窗 tweak（rootless / iOS16 / A14 arm64e）
// 包名：com.yzdmm.floatingurl
//
// v1.3.24 变更（两条主线）：
//  ① 彻底移除「内置小窗」：网页面板(WKWebView)、历史、确认框，以及「App 端内置浏览器交接」
//     （SFSafariViewController）全部删掉。点快捷入口 = 直接交给系统：网页走 Safari，scheme 走对应 App。
//  ② 交互与功耗：扇形永远往屏幕里展开、只有真贴到四角才走对角线；底部的上滑、顶部的下拉
//     会按球的位置动态让位给悬浮球（无定时器、无轮询）；息屏时完全停止轮询。
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
// v1.3.17：deb 升级后不再自动注销——postinst 写旗标 + 发本通知，由运行中的 tweak
// 弹「立即注销 / 稍后」让用户自己选。旗标留着 = 尚未注销生效，下次手动注销时 %ctor 清掉。
static NSString * const kFUNeedsRespring  = @"com.yzdmm.floatingurl/needsRespring";
static NSString * const kFURespringFlagPath = @"/var/mobile/Media/FloatingURL_respring";

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
static NSString * const kFUFanAutoHide = @"fanAutoHide"; // v1.3.21：扇形展开后闲置多少秒自动收回（0=不自动收，默认 5）
static NSString * const kFUCaptureHide = @"captureHide"; // v1.3.25：截图/录屏时自动收拢扇形并临时隐藏悬浮球（默认开）
static const NSInteger kFUKeepForever  = 999;            // v1.3.25：秒数滑杆最右一档「常驻」哨兵（永不吸附）
static NSString * const kFUFanScale    = @"fanScale";   // v1.3.2 整体距离（%，默认 100）
static NSString * const kFULayer1Count = @"layer1";     // v1.3.3：第一层入口数（0=自动）
static NSString * const kFULayer2Count = @"layer2";     // v1.3.3：第二层入口数（0=自动）
static NSString * const kFULayer3Count = @"layer3";     // v1.3.3：第三层入口数（0=自动）

static NSString * const kFUSnapMode    = @"snapMode";   // v1.3.5：0=自动吸附 1=全屏固定
static NSString * const kFUBallX       = @"ballX";      // v1.3.5：球中心 X（归一化 0~1）
static NSString * const kFUBallY       = @"ballY";      // v1.3.5：球中心 Y（归一化 0~1）
static NSString * const kFUBallTitle   = @"ballTitle";  // v1.3.5：球的文字（默认 URL）
static NSString * const kFUBallIcon    = @"ballIcon";   // v1.3.5：球的图标（PNG data，v1.3.28 起仅作旧数据兜底）
static NSString * const kFUBallIconL   = @"ballIconLeft";  // v1.3.28：球在「左半屏」时显示的图标
static NSString * const kFUBallIconR   = @"ballIconRight"; // v1.3.28：球在「右半屏」时显示的图标（任一侧缺省则镜像另一侧）
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
static void fuNeedsRespringCb(CFNotificationCenterRef center, void *observer,
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

// v1.3.13：App 端要看的「信箱」列表（桌面写哪处能成功，就走哪处）。
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

// 非 SpringBoard 进程：只广播前台状态，不建任何 UI、不加载设置。
static void fuStartAppHeartbeat(NSString *bid) {
    static BOOL started = NO; if (started) return; started = YES;
    if (!bid.length) return;
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
}

// v1.3.24：由根视图控制器告诉 UIKit「哪条边的系统手势要让位给我」。
// 之所以用协议：manager 的 @interface 在后面才出现，这里先定义能力再让 manager 实现。
@protocol FUDeferredEdgesProvider <NSObject>
- (UIRectEdge)fuDeferredEdges;
@end

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

#pragma mark - v1.3.24：悬浮球优先 —— 动态「压住」会撞车的系统手势边
// 现象：球停在底部会被「上滑回主屏」抢走；停在左上/右上会被「下拉通知 / 控制中心」抢走。
// UIKit 官方给的机制：preferredScreenEdgesDeferringSystemGestures 返回要压住的边。
// 这里做成**跟随球的位置动态变化** —— 球贴哪条边才压哪条边，球移到中间一条边都不压。
// 没有定时器、没有轮询，delegate 回调式，零额外耗电；被压住的那条边只是「第一次划先给悬浮球」，
// 立刻再划一次照样拉出系统面板，日常手感不受影响。
@interface FUOverlayRootController : UIViewController
@property (nonatomic, weak) id<FUDeferredEdgesProvider> edgesProvider;
@end
@implementation FUOverlayRootController
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return self.edgesProvider ? [self.edgesProvider fuDeferredEdges] : UIRectEdgeNone;
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
    // v1.3.17：初始缩放改为「整图适配」——整张照片居中完整可见，不再放大铺满裁剪框
    // （旧逻辑 z = side/MIN(w,h) 会把长方形照片放得巨大，用户看着就是「莫名放大、还不居中」）。
    // 想裁局部就用双指放大。想填满裁剪框也只需放大到覆盖即可。
    CGFloat iw = _image.size.width > 1 ? _image.size.width : 1;
    CGFloat ih = _image.size.height > 1 ? _image.size.height : 1;
    CGFloat fit = MIN(side / iw, side / ih);
    _scroll.minimumZoomScale = fit * 0.5;
    _scroll.maximumZoomScale = fit * 8.0;
    _scroll.zoomScale = fit;
    [self layoutContent];
    [self centerContent];
}
- (void)layoutContent {
    CGFloat z = _scroll.zoomScale;
    CGSize s = CGSizeMake(_image.size.width * z, _image.size.height * z);
    _imgView.frame = CGRectMake(0, 0, s.width, s.height);
    _scroll.contentSize = s;
}
// v1.3.17：居中改用 contentInset（内容比可视区小也能居中）。旧实现拿 side 当可视区宽高算
// contentOffset，而滚动条实际占满整个视图 → 偏移全错（图片顶到左上角、和居中的裁剪框对不上）。
- (void)centerContent {
    CGRect b = _scroll.bounds;
    CGSize cs = _scroll.contentSize;
    CGFloat ix = MAX(0, (b.size.width  - cs.width ) / 2.0);
    CGFloat iy = MAX(0, (b.size.height - cs.height) / 2.0);
    _scroll.contentInset = UIEdgeInsetsMake(iy, ix, iy, ix);
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutContent]; [self centerContent];   // 转屏/首次布局后兜底重算
}
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)sv { return _imgView; }
- (void)scrollViewDidZoom:(UIScrollView *)sv { [self centerContent]; }

- (void)done {
    CGFloat side = MIN(self.view.bounds.size.width, self.view.bounds.size.height) - 40;
    CGRect vb = self.view.bounds;
    CGRect sq = CGRectMake((vb.size.width - side)/2.0, (vb.size.height - side)/2.0, side, side);
    CGFloat z = _scroll.zoomScale;
    // v1.3.17：坐标换算重做。屏幕坐标 s 与内容坐标 p 的关系是 p = s + contentOffset
    // （contentInset 只是扩大偏移范围，不改变这个换算）。
    CGPoint off = _scroll.contentOffset;
    CGRect sqContent = CGRectMake(sq.origin.x + off.x, sq.origin.y + off.y, side, side);
    CGRect vis = CGRectMake(off.x, off.y, _scroll.bounds.size.width, _scroll.bounds.size.height);
    CGRect crop = CGRectIntersection(sqContent, vis);          // 裁剪框 ∩ 屏幕上可见区域
    CGPoint imgOrigin = _imgView.frame.origin;                 // 缩放锚点会让图片原点在内容坐标里漂移
    CGSize  cs = _scroll.contentSize;
    crop = CGRectIntersection(crop, CGRectMake(imgOrigin.x, imgOrigin.y, cs.width, cs.height)); // ∩ 图片实际区域
    CGRect imgRect;
    if (CGRectIsNull(crop) || crop.size.width < 4 || crop.size.height < 4) {
        // 兜底：取图片正中最大正方形
        CGFloat s2 = MIN(_image.size.width, _image.size.height);
        imgRect = CGRectMake((_image.size.width - s2)/2.0, (_image.size.height - s2)/2.0, s2, s2);
    } else {
        // 裁剪区不是正方形（图片小于框时）→ 取其正中最大正方形
        CGFloat s2 = MIN(crop.size.width, crop.size.height);
        crop = CGRectMake(crop.origin.x + (crop.size.width - s2)/2.0,
                          crop.origin.y + (crop.size.height - s2)/2.0, s2, s2);
        imgRect = CGRectMake((crop.origin.x - imgOrigin.x) / z, (crop.origin.y - imgOrigin.y) / z,
                             crop.size.width / z, crop.size.height / z);
    }
    CGImageRef cg = CGImageCreateWithImageInRect(_image.CGImage, imgRect);
    UIImage *sqImg = cg ? [UIImage imageWithCGImage:cg] : nil;
    if (cg) CGImageRelease(cg);
    NSData *out = nil;
    if (sqImg) {
        CGFloat max = 256.0;   // v1.3.21：120 → 256，Retina 屏上图标不再发糊
        CGFloat s = MIN(1.0, max / MAX(sqImg.size.width, sqImg.size.height));
        CGSize ts = CGSizeMake(sqImg.size.width * s, sqImg.size.height * s);
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:ts];
        UIImage *small = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx){
            [sqImg drawInRect:CGRectMake(0, 0, ts.width, ts.height)];
        }];
        out = UIImagePNGRepresentation(small);
    }
    if (_onCropped) _onCropped(out);
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

#pragma mark - 条目编辑器（设置/长按扇形共用：URL+汉字+字母+图标）
@interface FUEntryEditorViewController : UIViewController <UITextFieldDelegate>
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
    _urlField    = (UITextField *)mkField(@"网址 / scheme（https://a.com、weixin://、prefs:root=xxx）", nil, UIKeyboardTypeURL);

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
    // 全是运行时调用（NSClassFromString + performSelector + setValue:forKey:），避免 import PhotosUI 触发模块构建失败；
    // 任何异常都 @try 兜住并退回「去设置里选」提示，绝不带崩 SpringBoard。
    @try {
        if (@available(iOS 14.0, *)) {
            Class pvClass = NSClassFromString(@"PHPickerViewController");
            Class cfgClass = NSClassFromString(@"PHPickerConfiguration");
            Class fltClass = NSClassFromString(@"PHPickerFilter");
            if (pvClass && cfgClass && fltClass) {
                // NSSelectorFromString 包住 alloc/init/initWithConfiguration: —— 它们是 objc 保留族选择器，
                // 直接用 @selector 传给 performSelector 会被 clang 当硬错误；动态拿 SEL 即可绕过。
                id cfg = [cfgClass performSelector:NSSelectorFromString(@"alloc")];
                cfg = [cfg performSelector:NSSelectorFromString(@"init")];
                id flt = [fltClass performSelector:@selector(imagesFilter)];
                [cfg setValue:@(1) forKey:@"selectionLimit"];
                [cfg setValue:flt forKey:@"filter"];
                id pv = [pvClass performSelector:NSSelectorFromString(@"alloc")];
                pv = [pv performSelector:NSSelectorFromString(@"initWithConfiguration:") withObject:cfg];
                [pv setValue:self forKey:@"delegate"];   // self 已声明遵循 PHPickerViewControllerDelegate
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
@interface FUFloatingManager : NSObject <FUDeferredEdgesProvider>
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
- (void)fuOpenViaSystem:(NSURL *)u;          // v1.3.13：系统打开链路（openURL → FBSSystemService → workspace）
- (void)showRespringPrompt;                  // v1.3.17：升级后「立即注销 / 稍后」选择框
- (void)fuOpenViaFBS:(NSURL *)u;             // v1.3.13：FrontBoard 异步接口（失败回调里继续往下兜底）
- (void)fuOpenViaWorkspace:(NSURL *)u;       // v1.3.13：LSApplicationWorkspace 最后兜底
- (void)fuOpenPrefsURL:(NSURL *)u;          // v1.3.26：设置页深链 prefs:/App-Prefs: 专用入口
- (BOOL)fuOpenPrefsOnce:(NSURL *)u method:(NSInteger)m;   // v1.3.29：prefs 深链单通道尝试
- (void)fuDeepLinkFailed:(NSString *)abs;                 // v1.3.29：深链无人受理 → 明确提示（去重）
- (void)fuCaptureWillHide;                             // v1.3.27：截图按下快门前收拢扇形 + 藏球
- (void)fuApplyCaptureExclusion;                       // v1.3.28：把悬浮窗从截图/录屏里彻底排除（私有 API）
- (void)fuApplySecureCaptureGuard;                     // v1.3.30：secureTextEntry 渲染层保护（截图/录屏必排除，不依赖截图入口）
- (NSArray *)fuFanPointArray;                           // v1.3.13：扇形点位（openFan 与拖动重排共用同一套算法）
- (void)fuScheduleFanAutoHide;                          // v1.3.21：重排「闲置自动收回」倒计时
- (void)fuCancelFanAutoHide;                            // v1.3.21：取消空闲收回倒计时
- (void)fuRelayoutFanInstant;                           // v1.3.13：拖动球时围绕球实时重排扇形
- (UIRectEdge)fuDeferredEdges;                          // v1.3.24：当前要让位给悬浮球的系统手势边
- (void)fuRefreshDeferredEdges;                         // v1.3.24：位置变了让 UIKit 重新问一次
- (void)cancelPendingSnap;                              // v1.3.13：取消「待吸附」
- (void)scheduleSnapAfterDrop;                          // v1.3.13：松手后按「吸附延时」归位
- (void)triggerEntry:(NSDictionary *)entry;          // v1.3.8：触发一条入口（扇形点击 / 单入口点球共用）
- (CGFloat)fuAngleToScreenCenter:(CGPoint)c;         // v1.3.8：球心 -> 屏幕中心 的方向角
@end

// v1.3.24 省电：息屏时直接跳过轮询（不读偏好、不判前台、不动 UI）。
// SpringBoard 里直接问 SBBacklightController（本 dylib 就跑在 SpringBoard，类是真实存在的）；
// 取不到就一律当作「亮屏」——最坏也只是回到原来的行为，不会锁死功能。
// ===== v1.3.28：图标「左右分置」=====
// 球在左半屏用「左图标」，在右半屏用「右图标」；任一侧没单独设，就镜像另一侧来填（保证两侧都有图）。
// 不再自动猜主体在哪侧（v1.3.27 的识别在不少图（如居中猫头、卡通脸）上判不准，用户也难预期）。
// 水平镜像（重绘一份，原图不动）
static UIImage *fuMirroredImage(UIImage *img) {
    if (!img) return nil;
    CGSize sz = img.size;
    if (sz.width < 1.0 || sz.height < 1.0) return img;
    UIGraphicsBeginImageContextWithOptions(sz, NO, img.scale);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(c, sz.width, 0);
    CGContextScaleCTM(c, -1.0, 1.0);
    [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out ?: img;
}

static BOOL fuScreenIsOn(void) {
    @try {
        Class cls = NSClassFromString(@"SBBacklightController");
        if (!cls) return YES;
        SEL si = NSSelectorFromString(@"sharedInstance");
        if (![cls respondsToSelector:si]) return YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id ctrl = [cls performSelector:si];
#pragma clang diagnostic pop
        SEL so = NSSelectorFromString(@"screenIsOn");
        if (!ctrl || ![ctrl respondsToSelector:so]) return YES;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[ctrl methodSignatureForSelector:so]];
        inv.selector = so;
        [inv invokeWithTarget:ctrl];
        BOOL on = YES;
        [inv getReturnValue:&on];
        return on;
    } @catch (NSException *e) { return YES; }
}

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

// ===== v1.3.29：prefs: 深链「多渠道」打开 =====
// 背景（实测 Snapper 4 5.2.0-40 的 deb 得出）：这类插件的 prefs:root=xxx **不是「设置页」**，
//   而是给手势插件用的**触发器** —— URL 被插件在系统层截住后执行动作（冻结 / 长截图 / 套壳 / 水印…），
//   设置 App 根本不会打开。Snapper 4 官方深链共 10 条（设置 → Snapper 4 → URL 深链）：
//     prefs:root=snapper4_freeze / snapper4_long
//     prefs:root=screenshot-shell / screenshot-watermark / screenshot-both / screenshot-off
//     prefs:root=recording-shell / recording-watermark / recording-both / recording-off
//   它是在 SpringBoard 侧钩 openURL 链路（MSHookMessageEx），而 v1.3.26 起「prefs: 一律先走
//   openSensitiveURL」会**绕开**这类拦截点 → 用户点了没反应（本次反馈的根因）。
// 所以改成按「从外到内」依次尝试，任一被受理立刻停：
//   ① UIApplication openURL:options:completionHandler:  调用方进程最先经过，插件最容易钩这里
//   ② LSApplicationWorkspace openURL:(withOptions:)     手势插件最常用的入口
//   ③ FBSSystemService openURL:options:withResultBlock: FrontBoard 用户动作通道
//   ④ LSApplicationWorkspace openSensitiveURL:withOptions: 私有 scheme 直通（系统设置页最终兜底）
// 触发器类深链只走 ①②③（没人接就明确提示，不去白开设置页）；普通设置页走 ①④（与 1.3.28 行为一致，无回归）。
// 另外：官方深链全是小写，而用户常写成 snapper4_Freeze —— 「xxx_yyy / xxx-yyy」形状的触发器 id
//   若含大写，先按全小写试一次，再退回原样。
static BOOL fuLooksLikeDeepLinkTrigger(NSString *v) {
    if (v.length < 3) return NO;
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9]+([-_][A-Za-z0-9]+)+$"
                                                      options:0 error:NULL];
    });
    if (!re) return NO;
    if ([re firstMatchInString:v options:0 range:NSMakeRange(0, v.length)] == nil) return NO;
    // 全大写（MOBILE_DATA_SETTINGS_ID 之类系统 id）不动
    if ([v isEqualToString:v.uppercaseString]) return NO;
    return YES;
}
// 从 prefs:root=X 里取出 root 的值（去掉 & 之后的附加参数）
static NSString *fuPrefsRootValue(NSString *abs) {
    if (![abs isKindOfClass:[NSString class]] || !abs.length) return nil;
    NSRange r = [abs rangeOfString:@"root=" options:NSCaseInsensitiveSearch];
    if (r.location == NSNotFound) return nil;
    NSString *v = [abs substringFromIndex:(r.location + r.length)];
    NSRange amp = [v rangeOfString:@"&"];
    if (amp.location != NSNotFound) v = [v substringToIndex:amp.location];
    return v;
}
// 展开成候选串：触发器 id 含大写时「全小写」优先
static NSArray<NSString *> *fuPrefsCandidates(NSString *abs) {
    NSMutableArray *out = [NSMutableArray array];
    if (![abs isKindOfClass:[NSString class]] || !abs.length) return out;
    NSRange r = [abs rangeOfString:@"root=" options:NSCaseInsensitiveSearch];
    if (r.location == NSNotFound) { [out addObject:abs]; return out; }
    NSString *head = [abs substringToIndex:(r.location + r.length)];
    NSString *rest = [abs substringFromIndex:(r.location + r.length)];
    NSRange amp = [rest rangeOfString:@"&"];
    NSString *core = rest, *tail = @"";
    if (amp.location != NSNotFound) {
        core = [rest substringToIndex:amp.location];
        tail = [rest substringFromIndex:amp.location];
    }
    NSString *low = core.lowercaseString;
    if (fuLooksLikeDeepLinkTrigger(core) && ![low isEqualToString:core]) {
        [out addObject:[head stringByAppendingFormat:@"%@%@", low, tail]];
    }
    [out addObject:[head stringByAppendingFormat:@"%@%@", core, tail]];
    return out;
}

@implementation FUFloatingManager {
    FUOverlayWindow        *_overlay;
    UIViewController      *_overlayRoot;   // disabled 透明 vc，用于承载编辑器 + 安全穿透
    UIButton              *_ball;
    UIVisualEffectView    *_ballBlur;
    UILabel               *_ballLabel;
    // v1.3.18：桌面小窗网页「尽力开放 + 绝不卡白屏」三件套。
    //  桌面（SpringBoard）里 WKWebView 能不能真渲染网页，在不同越狱/环境上结论不一（用户反馈过
    //  「以前能打开」，也实测过「WebContent 起不来白屏」）。与其二选一赌一边，这里做成：
    //  先按用户想要的方式开内置小窗 → 加载失败或超时未完成就自动兜底外部浏览器 →
    //  并且本会话内记下「这台机器渲染不了」，之后不再白等，直接走浏览器（秒开）。
    BOOL                  _didSetup;
    BOOL                  _enabled;
    BOOL                  _fanOpen;
    // v1.3.21：扇形闲置自动收回（设置里可调秒数，0=永不自动收）
    NSTimer              *_fanHideTimer;
    BOOL                  _edgeGuard;     // v1.3.24：悬浮球是否在「会撞车的边」上压住系统手势（默认开）
    BOOL                  _captureHide;   // v1.3.25：截图/录屏时自动收拢扇形 + 临时隐藏悬浮球（默认开）
    BOOL                  _captureHiding; // v1.3.25：当前正处于「截图/录屏隐藏」中
    NSInteger             _captureToken;  // v1.3.25：隐藏→恢复的代次，防止画面还没拍完就提前把球显示回来
    BOOL                  _captureExclusionOK; // v1.3.28：悬浮窗是否支持「截图/录屏排除」（支持则球永不进画面，最稳）
    UITextField          *_secureGuard;   // v1.3.30：secureTextEntry 渲染层保护（截图/录屏/第三方截取都拍不到，Telegram 同款）
    BOOL                  _ballShownMirrored; // v1.3.27：球图标当前是否已镜像（变更检测用）
    BOOL                  _screenWasOn;   // v1.3.24：上次轮询时的亮屏状态（亮屏瞬间补一次完整刷新）
    CGFloat               _fanAutoHide;
    BOOL                  _applyingRemote;

    NSString              *_url;
    CGPoint               _ballDragOrigin;

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
    NSInteger             _snapMode;         // v1.3.5 0=自动吸附 1=全屏固定
    NSString             *_ballTitle;        // v1.3.5 球上的文字
    NSData               *_ballIcon;         // v1.3.5 球的图标（v1.3.28 起仅作旧数据兜底）
    NSData               *_ballIconL;        // v1.3.28 左半屏图标
    NSData               *_ballIconR;        // v1.3.28 右半屏图标
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
    BOOL                  _respringPromptShowing;   // v1.3.17：注销选择框防重复弹
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
        _didSetup = NO; _fanOpen = NO;
        _side = 0; _iconSize = 24.0f; _iconGap = 12.0f;   // v1.3.34：默认图标 24 / 间隔 12，球停靠右侧
        _fanSpan = 180.0f; _fanScale = 160.0f;            // v1.3.34 默认扇形角度 180° / 整体距离 160%
        _fanAutoHide = 5.0f;                              // v1.3.21：默认闲置 5 秒自动收回扇形
        _snapMode = 0; _webMode = 0; _ballTitle = @"URL";  // v1.3.5 默认：自动吸附 + 系统浏览器
        _snapDelay = 3.0;                                  // v1.3.13：默认吸附延时 3 秒（松手后先给完整图标）
        _layer1 = 0; _layer2 = 0; _layer3 = 0;           // v1.3.31：默认「自动分层」= 按实际 URL 数量排（先满第1层≤8、再第2层≤16、再第3层≤24）；0 即自动，每层数量滑杆拖到 0 同义
        _edgeGuard = YES; _screenWasOn = YES;              // v1.3.24：默认压住冲突边 + 起始按亮屏算
        _captureHide = YES; _captureHiding = NO; _captureToken = 0; _captureExclusionOK = NO;   // v1.3.25 / v1.3.28
        _ballShownMirrored = NO;   // v1.3.27：图标镜像变更检测
        _frontWatched = [NSMutableSet set];
        _fanItems = [NSMutableArray array]; _fanOffsets = [NSMutableArray array];
        [self reloadPrefs];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)(self), &fuPrefsChanged,
            (__bridge CFStringRef)kFUPrefsChanged, NULL, CFNotificationSuspensionBehaviorCoalesce);
        // v1.3.17：deb 升级完成（postinst 发出）→ 弹「立即注销 / 稍后」
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)(self), &fuNeedsRespringCb,
            (__bridge CFStringRef)kFUNeedsRespring, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
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
    [mgr applyVisibility];
}
// v1.3.13：前台 App 的内置浏览器真的弹出来了 → 撤销系统浏览器兜底

// ---- v1.3.17：升级后「立即注销 / 稍后」选择弹窗 ----
static void fuNeedsRespringCb(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    FUFloatingManager *mgr = (__bridge FUFloatingManager *)observer; if (!mgr) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ fuNeedsRespringCb(center, observer, name, object, userInfo); });
        return;
    }
    [mgr showRespringPrompt];
}

#pragma mark - 偏好读取（v1.3.36：只读磁盘，单一权威源）
// 「时灵时不灵」的完整病历：
//   1.3.33 只读磁盘：设置页只写 cfprefsd、刷盘异步 → 磁盘滞后 → 改了时灵时不灵。
//   1.3.34 双源合并（live 覆盖磁盘）：cfprefsd 跨进程偶发回旧值 → 旧值盖新值，复发。
//   1.3.35 翻转（磁盘覆盖 live）：设置页写的是 cfprefsd 内存，刚改完的瞬间磁盘还是旧值
//          → 旧磁盘值盖掉新 live 值 → 关总开关球还在、调布局扇形不变，复发。
//   1.3.36 根治：设置页每次写入后立刻把该键原子写进磁盘 plist（FU_MirrorKeyToDisk），
//          磁盘永远是最新值 → 这边只读磁盘，不再存在「两份数据打架」的任何可能。
//          磁盘完全没有 plist 时（首次安装还没动过设置）才兜底读 cfprefsd 实时值。
- (NSDictionary *)fuSuiteDict {
    static NSString *const cands[] = {
        @"/var/mobile/Library/Preferences/com.yzdmm.floatingurl.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.yzdmm.floatingurl.plist",
        nil
    };
    for (NSInteger i = 0; cands[i]; i++) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:cands[i]];
        if ([d isKindOfClass:[NSDictionary class]]) return d;   // 只取第一个存在的文件，绝不跨文件合并
    }
    // 兜底：还没有磁盘文件（首次安装）→ 读 cfprefsd 实时值
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    NSArray *liveKeys = @[
        @"enabled", @"url", @"edgeGuard", @"captureHide", @"side", @"iconSize", @"iconGap",
        @"fanSpan", @"fanScale", @"fanAutoHide", @"layer1", @"layer2", @"layer3",
        @"snapMode", @"webMode", @"snapDelay", @"ballTitle", @"ballIconLeft", @"ballIconRight",
        @"ballIcon", @"ballColor", kFUURLs, kFUEnabledApps
    ];
    for (NSString *k in liveKeys) {
        CFTypeRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)k, (__bridge CFStringRef)kFUSuite);
        if (!v) continue;
        CFTypeID t = CFGetTypeID(v);
        if (t == CFStringGetTypeID() || t == CFNumberGetTypeID() || t == CFBooleanGetTypeID() ||
            t == CFDataGetTypeID() || t == CFArrayGetTypeID() || t == CFDictionaryGetTypeID())
            merged[k] = (__bridge_transfer id)v;
        else
            CFRelease(v);
    }
    return [merged copy];
}
- (void)reloadPrefs {
    NSDictionary *suite = [self fuSuiteDict];
    BOOL hasFile = (suite != nil);
    BOOL (^fb)(NSString*,BOOL) = ^BOOL(NSString *k, BOOL d){
        id v = suite[k]; return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : d;
    };
    NSInteger (^fi)(NSString*,NSInteger) = ^NSInteger(NSString *k, NSInteger d){
        id v = suite[k]; return [v isKindOfClass:[NSNumber class]] ? [v integerValue] : d;
    };
    // 总开关（没文件时默认开，避免首次进桌面没球）
    _enabled = hasFile ? fb(@"enabled", YES) : YES;
    id urlRef = suite[@"url"];
    if ([urlRef isKindOfClass:[NSString class]] && [urlRef length]) _url = urlRef;
    _edgeGuard = hasFile ? fb(@"edgeGuard", YES) : YES;
    _captureHide = hasFile ? fb(@"captureHide", YES) : YES;
    // 布局：停靠边 + 图标大小 + 图标间隔
    id sdRef = suite[@"side"];     if ([sdRef isKindOfClass:[NSNumber class]]) _side = [sdRef integerValue];
    id isRef = suite[@"iconSize"]; if ([isRef isKindOfClass:[NSNumber class]]) _iconSize = [isRef floatValue];
    id igRef = suite[@"iconGap"];  if ([igRef isKindOfClass:[NSNumber class]]) _iconGap = [igRef floatValue];
    if (_side != 0) _side = 1;
    if (_iconSize < 24) _iconSize = 24; if (_iconSize > 64) _iconSize = 64;
    if (_iconGap  < 12) _iconGap  = 12; if (_iconGap  > 120) _iconGap = 120;
    // 扇形角度 / 整体距离
    id fspRef = suite[@"fanSpan"];  if ([fspRef isKindOfClass:[NSNumber class]]) _fanSpan = [fspRef floatValue];
    id fscRef = suite[@"fanScale"]; if ([fscRef isKindOfClass:[NSNumber class]]) _fanScale = [fscRef floatValue];
    if (_fanSpan  < 60.0f) _fanSpan = 60.0f;  if (_fanSpan  > 180.0f) _fanSpan = 180.0f;
    // 扇形闲置自动收回（秒）；0 = 永不
    id ahRef = suite[@"fanAutoHide"];
    _fanAutoHide = [ahRef isKindOfClass:[NSNumber class]] ? [ahRef doubleValue] : 5.0;
    if (_fanAutoHide < 0) _fanAutoHide = 0; if (_fanAutoHide > 60.0) _fanAutoHide = 60.0;
    if (_fanScale < 60.0f) _fanScale = 60.0f; if (_fanScale > 160.0f) _fanScale = 160.0f;
    // 每层数量（0=自动）
    id l1 = suite[@"layer1"], l2 = suite[@"layer2"], l3 = suite[@"layer3"];
    if ([l1 isKindOfClass:[NSNumber class]]) _layer1 = [l1 integerValue];
    if ([l2 isKindOfClass:[NSNumber class]]) _layer2 = [l2 integerValue];
    if ([l3 isKindOfClass:[NSNumber class]]) _layer3 = [l3 integerValue];
    if (_layer1 < 0) _layer1 = 0; if (_layer1 > 8)  _layer1 = 8;
    if (_layer2 < 0) _layer2 = 0; if (_layer2 > 16) _layer2 = 16;
    if (_layer3 < 0) _layer3 = 0; if (_layer3 > 24) _layer3 = 24;
    // 吸附模式 / 网页方式
    id smRef = suite[@"snapMode"]; if ([smRef isKindOfClass:[NSNumber class]]) _snapMode = [smRef integerValue];
    if (_snapMode != 1) _snapMode = 0;
    _webMode = fb(@"webMode", NO) ? 1 : 0;
    // 吸附延时（秒）
    id sdlyRef = suite[@"snapDelay"];
    _snapDelay = [sdlyRef isKindOfClass:[NSNumber class]] ? [sdlyRef doubleValue] : 3.0;
    if (_snapDelay < 0) _snapDelay = 0; if (_snapDelay > 15.0 && _snapDelay < kFUKeepForever) _snapDelay = 15.0;
    // 球外观
    id btRef = suite[@"ballTitle"]; _ballTitle = ([btRef isKindOfClass:[NSString class]] && [btRef length]) ? btRef : nil;
    if (!_ballTitle.length) _ballTitle = @"URL";
    id lRef = suite[@"ballIconLeft"], rRef = suite[@"ballIconRight"];
    BOOL haveNew = (lRef != nil) || (rRef != nil);
    if (haveNew) {
        _ballIconL = [lRef isKindOfClass:[NSData class]] ? lRef : nil;
        _ballIconR = [rRef isKindOfClass:[NSData class]] ? rRef : nil;
        _ballIcon = nil;
    } else {
        id biRef = suite[@"ballIcon"];
        _ballIcon = [biRef isKindOfClass:[NSData class]] ? biRef : nil;
        _ballIconL = _ballIcon; _ballIconR = _ballIcon;
    }
    id bcRef = suite[@"ballColor"]; _ballColor = [bcRef isKindOfClass:[NSString class]] ? bcRef : nil;
    NSInteger oldEntryCount = (NSInteger)_entries.count;
    [self loadEntries];
    if (_didSetup) {
        [self applyBallAppearance];          // 外观变化立即生效
        [self fuApplyCaptureExclusion];       // captureHide 开关变化同步截图排除
        if (_fanOpen) [self fuRelayoutFanInstant];   // v1.3.33：几何（大小/间隔/角度/距离/层数）变了立即重排扇形
    }
}
#pragma mark - v1.3.2 黑名单（前台 App 心跳驱动）
- (NSArray *)fuBlacklist {
    // v1.3.33：直接读磁盘偏好，绕过 cfprefsd 跨进程缓存（否则黑名单在守护进程里读不到最新值）
    NSDictionary *suite = [self fuSuiteDict];
    id v = suite[@"enabledApps"];
    if ([v isKindOfClass:[NSArray class]]) return v;
    return @[];
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
    // v1.3.33：直接读磁盘 plist（与 reloadPrefs 同一权威来源），避免 cfprefsd 跨进程缓存读旧值。
    NSDictionary *suite = [self fuSuiteDict];
    id r = suite[kFUURLs];
    NSArray *arr = [r isKindOfClass:[NSArray class]] ? r : nil;
    // v1.3.5 修 06：用户把快捷 URL 全删了（urls 存在但为空数组）→ 就是「没有入口」，
    // 绝不能再用默认网址兜底（那正是「删完还弹出一个打不开的网页」的根因）。
    if (arr) { _entries = arr; return; }
    // 兼容老版本：只设了主 URL、没有 urls 数组 → 当成唯一一条入口。
    id ur = suite[@"url"];
    NSString *u = [ur isKindOfClass:[NSString class]] ? ur : nil;
    _entries = (u.length) ? @[ @{ kFUEntryURL: u } ] : @[];
}

#pragma mark - 历史
- (NSString *)normalizeURL:(NSString *)raw {
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) return nil;
    // v1.3.26：自己按 RFC 3986 切一次 scheme。
    //   scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )，必须出现在第一个 '/'、'?'、'#' 之前，且不含 '.'。
    //   「不含 '.'」是用来把 weixin:// / prefs:root=X 这类真 scheme 与 www.a.com:8080 这种裸域名区分开。
    //   旧写法依赖 NSURLComponents，碰到 prefs:root=X 这种没有「//」的串不稳，会被误加 https:// 前缀 —— 那正是
    //   「设置页 URL 填了却点了没反应」的元凶之一。
    NSRange cut = [s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/?#"]];
    NSRange colon = [s rangeOfString:@":"];
    if (colon.location != NSNotFound && colon.location > 0 &&
        (cut.location == NSNotFound || colon.location < cut.location)) {
        NSString *sch = [s substringToIndex:colon.location];
        NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
                                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-."] invertedSet];
        if ([sch rangeOfCharacterFromSet:bad].location == NSNotFound &&
            [sch rangeOfString:@"."].location == NSNotFound) {
            // scheme 统一小写：输入 Prefs: / APP-PREFS: 一样能开
            return [[sch lowercaseString] stringByAppendingString:[s substringFromIndex:colon.location]];
        }
    }
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
        FUOverlayRootController *root = [FUOverlayRootController new];
        root.edgesProvider = self;   // v1.3.24：让 rootVC 能动态问出「要压住哪条边」
        _overlayRoot = root;
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
    [self fuSetupCaptureObservers];   // v1.3.25：截图 / 录屏 / 第三方局部截图 → 自动收拢 + 临时隐藏
    [self fuApplyCaptureExclusion];   // v1.3.28：把悬浮窗从截图/录屏里彻底排除（最稳，不靠钩子时序）
    // v1.3.0 兜底：每秒重读偏好并重判黑名单/开关。Darwin 通知在某些 App（如 QQ）里会被
    // 延迟或吞掉，导致「设置里加了黑名单、球还在」——轮询保证 1 秒内必生效。
    if (!_pollTimer) {
        // v1.3.24：1 秒 → 2 秒（黑名单仍有 2 秒内响应），再叠加「息屏完全停轮询」，CPU 唤醒减半以上。
        _pollTimer = [NSTimer timerWithTimeInterval:2.0 target:self selector:@selector(onBecomeActive)
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
        // v1.3.24：息屏 → 什么都不做（不读偏好、不判前台、不刷 UI），这是最大的一块省电。
        // 刚亮屏那一轮会立刻补一次完整刷新，所以不会出现「解锁后黑名单/开关不生效」。
        if (!fuScreenIsOn()) { _screenWasOn = NO; return; }
        _screenWasOn = YES;
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
        if (_fanOpen) [self fuRelayoutFanInstant];   // v1.3.35：展开中改了布局，轮询内即时重排（≈2 秒内生效）
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
    [self fuRefreshDeferredEdges];   // v1.3.24：按恢复出来的位置压住对应边
}
// v1.3.5 修 05：把自定义的名称/图标/底色应用到悬浮球（图标优先于文字）
// v1.3.28：图标「左右分置」—— 球在左半屏用「左图标」，在右半屏用「右图标」；
// 任一侧没单独设，就镜像另一侧来填（保证两侧都有图，不会空白）；都没设则回退旧的 ballIcon。
// 不再自动猜主体在哪侧（v1.3.27 的识别在居中脸/卡通图上判不准，用户也难预期）。
- (void)applyBallAppearance {
    if (!_ball) return;
    NSString *titleNow = (_ballTitle.length ? _ballTitle : @"URL");
    // v1.3.13：这个方法每秒都会被轮询调到 —— 外观没变就直接返回，别反复解码球图标（省电、少卡顿）。
    CGRect bs = _overlay ? _overlay.bounds : [UIScreen mainScreen].bounds;
    CGFloat bmx = _ball ? CGRectGetMidX(_ball.frame) : bs.size.width / 2.0f;
    BOOL ballRight = (bmx > bs.size.width / 2.0f);
    // v1.3.28：按所在半屏挑图标；缺省侧镜像另一侧；都不设才回退旧 ballIcon。
    NSData *src = nil; BOOL mirrorNow = NO;
    if (ballRight) {
        if (_ballIconR.length)      { src = _ballIconR; mirrorNow = NO; }
        else if (_ballIconL.length) { src = _ballIconL; mirrorNow = YES; }   // 右半屏没设 → 镜像左半屏的
        else if (_ballIcon.length)  { src = _ballIcon;  mirrorNow = NO; }    // 旧数据兜底
    } else {
        if (_ballIconL.length)      { src = _ballIconL; mirrorNow = NO; }
        else if (_ballIconR.length) { src = _ballIconR; mirrorNow = YES; }   // 左半屏没设 → 镜像右半屏的
        else if (_ballIcon.length)  { src = _ballIcon;  mirrorNow = NO; }
    }
    BOOL iconChanged = !((src == nil && _ballIconShown == nil) ||
                         (src != nil && _ballIconShown != nil && [src isEqualToData:_ballIconShown]));
    if (_ballImageView) {
        BOOL sameTitle = [_ballShownTitle isEqualToString:titleNow];
        BOOL sameColor = (_ballColor == nil && _ballShownColor == nil) ||
                         (_ballColor != nil && _ballShownColor != nil && [_ballColor isEqualToString:_ballShownColor]);
        if (!iconChanged && sameTitle && sameColor && mirrorNow == _ballShownMirrored) return;
    }
    _ballIconShown = src; _ballShownTitle = titleNow; _ballShownColor = _ballColor;
    _ballShownMirrored = mirrorNow;
    if (!_ballImageView) {
        _ballImageView = [[UIImageView alloc] initWithFrame:_ball.bounds];
        _ballImageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _ballImageView.contentMode = UIViewContentModeScaleAspectFill;
        _ballImageView.clipsToBounds = YES;
        _ballImageView.layer.cornerRadius = kFUButtonSize/2.0f;
        [_ballBlur.contentView addSubview:_ballImageView];
    }
    UIImage *img = src.length ? [UIImage imageWithData:src] : nil;
    if (img && mirrorNow) img = fuMirroredImage(img);   // v1.3.28：缺省侧镜像另一侧
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
// v1.3.24：当前要让位给悬浮球的系统手势边（由 FUOverlayRootController 每帧回调时查询）。
//   球贴底 ⇒ 压底边（上滑回主屏让位）；球贴顶 ⇒ 压顶边（下拉通知/控制中心让位）；
//   拖动中 / 扇形展开中 ⇒ 上下两条边都压住，防止半路被系统抢走触点；
//   球移到中间 ⇒ 一条边都不压，系统手势 100% 恢复正常。
- (UIRectEdge)fuDeferredEdges {
    if (!_edgeGuard) return UIRectEdgeNone;
    if (!_ball || _ball.hidden || !_overlay || _overlay.hidden) return UIRectEdgeNone;
    if (_draggingBall || _fanOpen) return (UIRectEdge)(UIRectEdgeTop | UIRectEdgeBottom);
    CGRect s = _overlay.bounds;
    if (s.size.width < 1 || s.size.height < 1) return UIRectEdgeNone;
    CGPoint c = CGPointMake(CGRectGetMidX(_ball.frame), CGRectGetMidY(_ball.frame));
    CGFloat band = MAX(kFUButtonSize * 1.6f, MIN(s.size.width, s.size.height) * 0.18f);
    UIRectEdge e = UIRectEdgeNone;
    if (c.y < band)                 { e = (UIRectEdge)(e | UIRectEdgeTop); }
    if (s.size.height - c.y < band) { e = (UIRectEdge)(e | UIRectEdgeBottom); }
    return e;
}
// v1.3.24：位置/状态变了，让 UIKit 重新问一次（只在落点确定的时刻调用，拖动过程中不刷，省开销）
- (void)fuRefreshDeferredEdges {
    [_overlayRoot setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
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

#pragma mark - 交互
- (void)ballTapped {
    [self cancelPendingSnap];     // v1.3.13：点球 = 取消待吸附（否则扇形刚弹出球就被吸走）
    _ball.alpha = 1.0f;   // 点击唤醒：变实心，方便使用
    [self restoreBallFromSnap];   // 半隐吸附态 → 先拉回完整可见
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
        [self fuRefreshDeferredEdges];   // v1.3.24：一抓住球就把上下两条边压住，拖动不会被系统抢走
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
        [self fuRefreshDeferredEdges];   // v1.3.24：松手后按新落点重算要压住的边
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
    if (_captureHiding) return;   // v1.3.25：截图/录屏隐藏期间不要把球重新点亮
    _snapGen++; NSInteger myGen = _snapGen;
    [self clampBallFullyIntoView];
    [self persistBallPos];       // 先把「完整可见」的落点记下来（重启后原位恢复）
    if (_snapMode == 1) {        // 全屏固定：永不吸附，直接半透明待机
        _snapPending = NO; _ball.alpha = 0.4f; return;
    }
    _ball.alpha = 1.0f;          // ★ 延时期间 = 完整的悬浮图标（用户明确要的效果）
    if (_fanOpen) { _snapPending = YES; return; }   // 扇形还开着 → 等关掉再排（见 closeFan）
    _snapPending = NO;
    if (_snapDelay >= (NSTimeInterval)kFUKeepForever) { _ball.alpha = 1.0f; return; }   // v1.3.25：常驻 = 永不吸附，一直完整显示
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
    if (_snapMode == 1 || _fanOpen) return;
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
        [ss fuRefreshDeferredEdges];   // v1.3.24：吸附归位后按最终位置重算
    }];
}
// 球处于「半隐吸附态」时，点击先把它完整拉回屏幕内（再弹环/面板）。

#pragma mark - v1.3.25：截图 / 录屏时自动收拢并隐藏（不把悬浮球和扇形拍进画面）
// 触发源（全部靠系统通知，不轮询、不额外耗电）：
//   ① UIApplicationUserDidTakeScreenshotNotification —— 系统截图，瞬时事件，隐藏 1.6 秒
//   ② UIScreenCapturedDidChangeNotification —— 录屏 / 第三方局部截图会置位 isCaptured，
//      整个期间持续隐藏，停止后再自动恢复并把悬浮按钮显示出来
// Darwin Notify 跨进程回调前向声明（定义见下方 fuSetupCaptureObservers 之后）
static void fuDarwinCaptureNotify(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo);
- (void)fuSetupCaptureObservers {
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(fuCapturedStateChanged)
        name:UIScreenCapturedDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(fuScreenshotTaken)
        name:UIApplicationUserDidTakeScreenshotNotification object:nil];
    // v1.3.37：跨进程通道。第三方/自有「局部截图」tweak 若自己抓像素（不置 isCaptured、不走系统截图键），
    // 上面两条系统通知都不会触发 → 扇形收不回。让它用 Darwin Notify 广播下面两个名字，
    // 即可 100% 可靠地指挥本 tweak 在「按下快门前」隐藏、截完恢复。SpringBoard 能收到跨进程通知。
    // 注意：NSDistributedNotificationCenter 是 macOS 专属、iOS 上不存在，必须用 CFNotificationCenterGetDarwinNotifyCenter。
    CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(dc, (__bridge const void *)(self), &fuDarwinCaptureNotify,
        CFSTR("yz.FloatingURL.willCapture"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(dc, (__bridge const void *)(self), &fuDarwinCaptureNotify,
        CFSTR("yz.FloatingURL.didCapture"),  NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
// Darwin Notify 桥接：把跨进程通知转成本类的实例方法调用（CF 回调签名固定，无法直接 objc 方法）
static void fuDarwinCaptureNotify(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @autoreleasepool {
        FUFloatingManager *mgr = (__bridge FUFloatingManager *)observer;
        NSString *n = (__bridge NSString *)name;
        if ([n isEqualToString:@"yz.FloatingURL.willCapture"]) [mgr fuDistributedCaptureWill];
        else if ([n isEqualToString:@"yz.FloatingURL.didCapture"])  [mgr fuDistributedCaptureDid];
    }
}
- (void)fuDistributedCaptureWill { if (!_captureHide) return; [self fuBeginCaptureHide]; }
- (void)fuDistributedCaptureDid  { [self fuEndCaptureHide]; }
- (void)fuScreenshotTaken {
    if (!_captureHide) return;
    [self fuBeginCaptureHide];
    NSInteger tk = ++_captureToken;
    __weak FUFloatingManager *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FUFloatingManager *ss = ws; if (!ss) return;
        if (ss->_captureToken != tk) return;
        if ([UIScreen mainScreen].captured) return;   // 还在录屏/截取中 → 交给状态回调收尾
        [ss fuEndCaptureHide];
    });
}
- (void)fuCapturedStateChanged {
    BOOL cap = [UIScreen mainScreen].captured;
    if (cap && _captureHide) { _captureToken++; [self fuBeginCaptureHide]; }
    else if (!cap && _captureHiding) { _captureToken++; [self fuEndCaptureHide]; }
}
// v1.3.27：截图「按下快门之前」就收拢扇形 + 藏球。
// 为什么必须有它：球和扇形只建在 SpringBoard 里（别的 App 进程只发心跳），而
// UIApplicationUserDidTakeScreenshotNotification 是发给「最前面的那个 App」的 —— SpringBoard 收不到，
// 所以 1.3.25 的截图路径永远不触发（录屏用的 UIScreenCapturedDidChangeNotification 是全局屏幕状态，
// SpringBoard 能收到，所以只有录屏生效）。这里由 SpringBoard 侧的截图钩子直接调用。
- (void)fuCaptureWillHide {
    if (![NSThread isMainThread]) {
        __weak FUFloatingManager *ww = self;
        dispatch_async(dispatch_get_main_queue(), ^{ FUFloatingManager *ss = ww; if (ss) [ss fuCaptureWillHide]; });
        return;
    }
    if (!_captureHide) return;
    [self fuBeginCaptureHide];
    NSInteger tk = ++_captureToken;
    __weak FUFloatingManager *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FUFloatingManager *ss = ws; if (!ss) return;
        if (ss->_captureToken != tk) return;
        if ([UIScreen mainScreen].captured) return;   // 还在录屏/截取中 → 交给状态回调收尾
        [ss fuEndCaptureHide];
    });
}

// 收拢扇形 + 临时藏球（悬浮球与扇形都不会出现在截图/录像里）
- (void)fuBeginCaptureHide {
    if (!_ball || !_overlay) return;
    // v1.3.37：截图隐藏必须「瞬时」，不能走 closeFan 的 0.18s 渐隐动画。
    // 实测：第三方局部截图（SuperScreenshot 的 MaskCropWindow / Snapper4 的 SSCoordinator）在「界面弹出」
    // 那一刻就同步冻屏抓底图，而 closeFan 的渐隐要 ~200ms 才跑完 → 球/扇形被冻进底图。
    // 这里直接把扇形成员即时移除（无动画），球也即时透明，确保「冻屏前」画面里已无本插件 UI。
    if (_fanOpen) { _fanOpen = NO; [self closeFanItemsAnimated:NO]; [self setInteractive:NO]; }
    if (_captureHiding) return;
    _captureHiding = YES;
    for (UIButton *it in _fanItems) it.alpha = 0.0f;
    _ball.userInteractionEnabled = NO;
    _ball.alpha = 0.0f;
}
// 恢复：重新显示悬浮按钮，并按「吸附延时」重新排队归位
- (void)fuEndCaptureHide {
    if (!_captureHiding) return;
    _captureHiding = NO;
    if (!_ball) return;
    _ball.userInteractionEnabled = YES;
    // v1.3.31：收尾交给 applyVisibility —— 它才是显隐的权威来源，会尊重「启用悬浮窗」开关与黑名单，
    // 不会再出现「截图结束把本该隐藏的球重新点亮」的问题（这正是开关关不掉球的一大诱因）。
    [self applyVisibility];
}

- (void)restoreBallFromSnap {
    if (!_ball) return;
    CGRect s = _overlay.bounds; CGRect f = _ball.frame;
    CGRect clamped = CGRectMake(MAX(0, MIN(s.size.width  - f.size.width,  f.origin.x)),
                                MAX(0, MIN(s.size.height - f.size.height, f.origin.y)),
                                f.size.width, f.size.height);
    if (!CGRectEqualToRect(f, clamped))
        [UIView animateWithDuration:0.2 animations:^{ _ball.frame = clamped; }];
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
    NSInteger autoMax[3] = { 8, 16, 24 };   // v1.3.31：自动模式每层容量上限（先满第1层再第2层再第3层）
    NSInteger caps[3] = { 0, 0, 0 };   // 预估每圈容量（仅供下面「角度收缩」检查用）
    CGFloat spanMax = MAX(60.0f, MIN(180.0f, _fanSpan));
    {
        CGFloat spanRad0 = spanMax * (CGFloat)M_PI / 180.0f;
        NSInteger placed2 = 0;
        for (int i = 0; i < 3 && placed2 < n; i++) {
            NSInteger capArc = MAX(1, (NSInteger)floor(R[i] * spanRad0 / (isz + gap)));
            if (want[i] > 0) capArc = MIN(capArc, want[i]);
            else capArc = MIN(capArc, autoMax[i]);   // v1.3.31：自动模式按「先满第1层再第2、第3层」分层
            NSInteger add = MIN(capArc, n - placed2);
            caps[i] = add; placed2 += add;
        }
    }
    // v1.3.24：朝向判定重写。旧版用「屏幕三等分」判角落 → 屏幕一大片区域都算角落，扇形乱指。
    //   改成按「离边的绝对距离」判，只有**真的快贴到角了**才走对角线：
    //     · 四个角      → 沿对角线朝屏幕内侧散开（左上 45° / 右上 135° / 左下 -45° / 右下 -135°）
    //     · 正上边(非角)→ 朝正下方 90°      · 正下边(非角) → 朝正上方 -90°
    //     · 左 / 右边   → 水平朝屏幕内（0° / 180°），保留老行为
    //   无论朝哪 APC 不准的就是弧覆盖固定角度，下面还有「收缩 + 整体平移」双重兜底，绝不越界。
    CGFloat band = MAX(kFUButtonSize * 1.8f, MIN(sc.size.width, sc.size.height) * 0.22f);
    BOOL nearL = (c.x < band), nearR = (sc.size.width  - c.x < band);
    BOOL nearT = (c.y < band), nearB = (sc.size.height - c.y < band);
    CGFloat centerA;
    if      (nearT && nearL) centerA =  45.0f;    // 左上角 → 朝右下（斜角对角）
    else if (nearT && nearR) centerA = 135.0f;    // 右上角 → 朝左下
    else if (nearB && nearL) centerA = -45.0f;    // 左下角 → 朝右上
    else if (nearB && nearR) centerA = -135.0f;   // 右下角 → 朝左上
    else if (nearT)          centerA =  90.0f;    // 正上边 → 朝下铺开
    else if (nearB)          centerA = -90.0f;    // 正下边 → 朝上铺开
    else                     centerA = [self fuBallSide] ? 0.0f : 180.0f;   // 左/右边 → 水平朝内
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
            if (ring < 3) {
                if (want[ring] > 0) capArc = MIN(capArc, want[ring]);
                else capArc = MIN(capArc, autoMax[ring]);   // v1.3.31：自动模式容量上限
            }
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
// v1.3.22：小窗展开时球是隐藏的，但它的坐标还停在打开前的旧位置 ——
// 于是「拖动/缩放小窗到屏幕下方后收起」，球会突然出现在完全不相干的上面。
// 解决：小窗每动一次就把球悄悄挪到小窗中心（此刻球不可见，看不出位移），
// 收起时球自然就在小窗刚才的位置。
- (void)fuRelayoutFanInstant {
    if (!_fanOpen || !_ball || !_overlay) return;
    [self restoreBallFromSnap];
    [self fuScheduleFanAutoHide];   // v1.3.21：拖球 = 还在操作，重新计时
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
    [self reloadPrefs];   // v1.3.35：每次展开都先重载偏好，确保布局/开关即时生效（即便没收到通知也不会弹旧布局）
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
    [self fuScheduleFanAutoHide];   // v1.3.21：开始「闲置自动收回」倒计时
}
// v1.3.21：扇形展开后闲置 N 秒自动收回；拖动/点到入口/再点球收拢都会重排或取消倒计时。
- (void)fuCancelFanAutoHide {
    if (_fanHideTimer) { [_fanHideTimer invalidate]; _fanHideTimer = nil; }
}
- (void)fuScheduleFanAutoHide {
    [self fuCancelFanAutoHide];
    if (!_fanOpen || _fanAutoHide < 0.5) return;   // 0 秒 = 永不自动收
    __weak FUFloatingManager *ws = self;
    _fanHideTimer = [NSTimer timerWithTimeInterval:_fanAutoHide repeats:NO block:^(NSTimer *t){
        FUFloatingManager *ss = ws; if (!ss) return;
        if (!ss->_fanOpen) return;
        if (ss->_draggingBall) { [ss fuScheduleFanAutoHide]; return; }  // 正在拖 → 再给一轮
        [ss closeFan];   // 收拢 → 球按「吸附延时」归位到半透明待机，恢复原状
    }];
    // v1.3.37 修：挂到 NSRunLoopCommonModes（与心跳/轮询定时器一致）。
    // 原写法用 scheduledTimerWithTimeInterval: 默认 NSDefaultRunLoopMode —— 手指按住拖球 /
    // 局部截图拖选区时主 RunLoop 进入 UITrackingRunLoopMode，default-mode 定时器不触发，
    // 表现为「扇形闲置自动收回」失效、局部截图按住时扇形收不回来。
    [[NSRunLoop mainRunLoop] addTimer:_fanHideTimer forMode:NSRunLoopCommonModes];
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
    NSString *ch = entry[kFUEntryChar] ?: @"";   // 现可存 2 汉字 / 3 字母
    // v1.3.21 修「上传的照片灰蒙蒙」：以前不管是照片还是纯色图标，都盖一层占满整个圆形的
    // 半透明黑底（alpha 0.45）用来衬名称 —— 没填名称时也照盖，于是每张自定义照片都被蒙成灰色。
    // 现在改成：① 没名称就不加任何蒙层（照片原样显示）；
    //           ② 有名称时只在底部留一条窄标题带，不再糊住整张图；
    //           ③ 只有无照片的纯色图标才保留整块居中文字（那种情况本来就需要衬底）。
    UILabel *lab = [[UILabel alloc] initWithFrame:it.bounds];
    if (img) {
        if (!ch.length) {
            // 纯照片、无名称 → 一点都不遮
        } else {
            CGFloat h = MAX(12.0f, isz * 0.34f);
            lab.frame = CGRectMake(0, it.bounds.size.height - h, it.bounds.size.width, h);
            lab.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
            lab.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
            lab.textAlignment = NSTextAlignmentCenter; lab.textColor = [UIColor whiteColor];
            lab.numberOfLines = 1;
            lab.font = [UIFont boldSystemFontOfSize:MAX(8.0f, h * 0.62f)];
            lab.text = ch;
            [it addSubview:lab];
        }
    } else {
        lab.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        lab.textAlignment = NSTextAlignmentCenter; lab.textColor = [UIColor whiteColor];
        lab.numberOfLines = 0;
        CGFloat fs = isz * 0.42f;
        if (ch.length >= 3) fs = isz * 0.26f; else if (ch.length == 2) fs = isz * 0.32f;
        lab.font = [UIFont boldSystemFontOfSize:fs];
        lab.text = ch;
        [it addSubview:lab];
    }
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
    // v1.3.24：内置小窗整套移除 → 点哪个入口都直接交给系统：
    //   网页走 Safari（默认浏览器），scheme 走对应 App。没有任何中间弹窗。
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
    [self fuCancelFanAutoHide];   // v1.3.21：手动/触发性收拢时取消倒计时
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

// v1.3.2：跨进程打开 URL。SpringBoard 里 UIApplication.openURL 不稳，优先用 LSApplicationWorkspace。
// v1.3.8 修 01（卡死 bug）：**绝不能在主线程同步调用** —— openSensitiveURL:withOptions: 会一路同步等
// FrontBoard 把目标 App 拉起，Safari/微信冷启动时要好几秒，这几秒里 SpringBoard 主线程被占死，
// 表现就是「点了网页 -> 整机卡住、屏幕动不了」。这里整段丢到后台队列，主线程立刻返回。
// v1.3.13：返回「可以投递的信箱路径」列表（按优先级）。桌面写目标 App 容器常被沙盒拒绝，
// 所以多准备一个 /var/mobile/Media 下的公共信箱 —— 哪个写成功就用哪个，App 端两处都看。


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
// v1.3.29：prefs 深链单通道尝试（返回「是否被受理」）。
//   m=0 UIApplication openURL:options:completionHandler:（主线程异步，用信号量等回执）
//   m=1 LSApplicationWorkspace openURL:(withOptions:)           手势插件最常用入口
//   m=2 FBSSystemService openURL:options:withResultBlock:       FrontBoard 用户动作通道
//   m=3 LSApplicationWorkspace openSensitiveURL:withOptions:    私有 scheme 直通（系统设置页兜底）
- (BOOL)fuOpenPrefsOnce:(NSURL *)u method:(NSInteger)m {
    @try {
        if (m == 0) {
            __block BOOL accepted = NO;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    UIApplication *app = UIApplication.sharedApplication;
                    if (app) [app openURL:u options:@{} completionHandler:^(BOOL ok){ accepted = ok; dispatch_semaphore_signal(sem); }];
                    else dispatch_semaphore_signal(sem);
                } @catch (NSException *e) { dispatch_semaphore_signal(sem); }
            });
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));
            return accepted;
        }
        Class wsc = NSClassFromString(@"LSApplicationWorkspace");
        SEL defSel = NSSelectorFromString(@"defaultWorkspace");
        id ws = (wsc && [wsc respondsToSelector:defSel]) ? [wsc performSelector:defSel] : nil;
        if (m == 1) {
            SEL s1 = NSSelectorFromString(@"openURL:withOptions:");
            if (ws && [ws respondsToSelector:s1])
                return ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, s1, u, nil);
            SEL s2 = NSSelectorFromString(@"openURL:");
            if (ws && [ws respondsToSelector:s2])
                return ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, s2, u);
            return NO;
        }
        if (m == 2) {
            Class fbc = NSClassFromString(@"FBSSystemService");
            SEL sh = NSSelectorFromString(@"sharedService");
            SEL op = NSSelectorFromString(@"openURL:options:withResultBlock:");
            if (!fbc || ![fbc respondsToSelector:sh]) return NO;
            id svc = [fbc performSelector:sh];
            if (!svc || ![svc respondsToSelector:op]) return NO;
            __block BOOL accepted = NO;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            void (^blk)(BOOL, NSError *) = ^(BOOL ok, NSError *err){ accepted = ok; dispatch_semaphore_signal(sem); };
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(svc, op, u, @{}, blk);
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));
            return accepted;
        }
        // m == 3：私有 scheme 直通
        SEL sen = NSSelectorFromString(@"openSensitiveURL:withOptions:");
        if (ws && [ws respondsToSelector:sen])
            return ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, sen, u, nil);
        return NO;
    } @catch (NSException *e) {
        NSLog(@"[FloatingURL] prefs 通道 %ld 异常（已忽略）: %@", (long)m, e);
        return NO;
    }
}

// v1.3.29：prefs: 深链统一入口。
//   触发器类（snapper4_freeze / screenshot-shell …）：只走 ①②③ —— 由目标插件在系统层截住执行动作；
//     没人接说明插件没装 / 版本太旧，明确弹框告知，**不去白开设置页**（设置里根本没有这个页面）。
//   普通设置页（WIFI、Bluetooth、com.xxx.tweak …）：① 不行就直接 ④ 私有 scheme 直通，与 1.3.28 行为一致。
- (void)fuOpenPrefsURL:(NSURL *)u {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        @try {
            NSString *abs = u.absoluteString;
            NSArray *cands = fuPrefsCandidates(abs);
            if (!cands.count) cands = @[abs];
            BOOL trigger = fuLooksLikeDeepLinkTrigger(fuPrefsRootValue(abs) ?: @"");
            NSArray *methods = trigger ? @[@0, @1, @2] : @[@0, @3];
            for (NSNumber *mn in methods) {
                for (NSString *c in cands) {
                    NSURL *cu = [NSURL URLWithString:c]; if (!cu) continue;
                    if ([self fuOpenPrefsOnce:cu method:mn.integerValue]) {
                        NSLog(@"[FloatingURL] prefs 深链已受理（通道 %@）：%@", mn, c);
                        return;
                    }
                }
            }
            if (!trigger) {
                // ④ 也不行 → 换 App-Prefs: 壳再来一次（个别 iOS 只认其中一种写法）
                NSString *last = cands.lastObject;
                if ([last.lowercaseString hasPrefix:@"prefs:"]) {
                    NSString *alt = [@"App-Prefs:" stringByAppendingString:[last substringFromIndex:6]];
                    NSURL *au = [NSURL URLWithString:alt];
                    if (au && [self fuOpenPrefsOnce:au method:3]) {
                        NSLog(@"[FloatingURL] prefs 深链已受理（App-Prefs 壳）：%@", alt);
                        return;
                    }
                }
            }
            NSLog(@"[FloatingURL] prefs 深链无人受理：%@", abs);
            [self fuDeepLinkFailed:abs];
        } @catch (NSException *e) { NSLog(@"[FloatingURL] prefs 深链异常（已忽略）: %@", e); }
    });
}

// v1.3.29：深链没人接 → 直接说清原因（同一条只提示一次，最多 3 条，别烦人）。
// 临时把悬浮窗变成 key，保证弹框一定显示得出来（跟编辑器同一套做法）。
- (void)fuDeepLinkFailed:(NSString *)abs {
    static NSMutableSet *notified = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ notified = [NSMutableSet set]; });
    @synchronized (notified) {
        if ([notified containsObject:abs] || notified.count >= 3) return;
        [notified addObject:abs];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"这条深链没有被受理"
                message:[NSString stringWithFormat:@"%@\n\n可能原因：\n• 目标插件没装或版本太旧（Snapper 4 的 URL 深链需 5.x）\n• 拼写不对 —— 官方深链全是小写，是 prefs:root=snapper4_freeze，不是 snapper4_Freeze", abs]
                preferredStyle:UIAlertControllerStyleAlert];
            __weak FUFloatingManager *ws = self;
            [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:^(UIAlertAction *act){
                FUFloatingManager *ss = ws; if (ss) [ss setInteractive:NO];
            }]];
            UIViewController *host = _overlayRoot ? (_overlayRoot.presentedViewController ?: _overlayRoot) : fuTopViewController();
            if (!host) return;
            [self setInteractive:YES];
            [host presentViewController:a animated:YES completion:nil];
        } @catch (NSException *e) { NSLog(@"[FloatingURL] 深链提示异常（已忽略）: %@", e); }
    });
}

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

// v1.3.24：唯一的打开入口 —— 一律交给系统（Safari / 对应 App）。
- (void)fuOpenExternally:(NSString *)s {
    NSURL *u = [NSURL URLWithString:s]; if (!u) return;
    // v1.3.26：设置页深链走专用通道 —— openURL 对 prefs:/App-Prefs: 无效（静默失败）。
    NSString *sch = u.scheme.lowercaseString ?: @"";
    if ([sch isEqualToString:@"prefs"] || [sch isEqualToString:@"app-prefs"]) {
        [self fuOpenPrefsURL:u];
        return;
    }
    // v1.3.24：内置面板 / App 端内置浏览器两套链路全部删除 —— 现在只有一条路：交给系统。
    //   http(s) → Safari（用户默认浏览器）；weixin://、tel:、alipay:// 等 → 对应 App。
    //  少一层就少一个故障点：以前「点了弹 App 内小窗」「点了半天没反应」都是从这两条链路漏出来的。
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { [self fuOpenViaSystem:u]; }
        @catch (NSException *e) {
            NSLog(@"[FloatingURL] fuOpenExternally 异常（已忽略）: %@", e);
            [self fuOpenViaSystem:u];
        }
    });
}

#pragma mark - 展开 / 收起 面板
// v1.3.17：升级后「立即注销 / 稍后」选择弹窗（postinst 发 needsRespring 通知后走到这里）
- (void)showRespringPrompt {
    @try {
        if (_respringPromptShowing) return;
        _respringPromptShowing = YES;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"悬浮URL 已更新"
            message:@"新版本需要注销（Respring）后才会加载。\n点「立即注销」马上重启桌面；点「稍后」继续用当前版本，之后手动注销也行。"
            preferredStyle:UIAlertControllerStyleAlert];
        __weak FUFloatingManager *ws = self;
        [a addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:^(UIAlertAction *act){
            FUFloatingManager *ss = ws; if (ss) ss->_respringPromptShowing = NO;
            [ss setInteractive:NO];   // 把 key 还给原窗口
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"立即注销" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act){
            FUFloatingManager *ss = ws; if (ss) ss->_respringPromptShowing = NO;
            [ss setInteractive:NO];
            // 马上要注销了，清掉旗标（重启后新版本生效，不必再提示）
            [[NSFileManager defaultManager] removeItemAtPath:kFURespringFlagPath error:NULL];
            // 等弹窗动画收尾再重启桌面（exit(0) 后 launchd 会自动拉起 SpringBoard）
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ exit(0); });
        }]];
        UIViewController *host = fuTopViewController();
        if (!host && _overlayRoot) host = _overlayRoot;
        if (!host) { _respringPromptShowing = NO; return; }
        [host presentViewController:a animated:YES completion:nil];
        NSLog(@"[FloatingURL] 已弹出升级注销选择框");
    } @catch (NSException *e) {
        NSLog(@"[FloatingURL] showRespringPrompt 异常（已忽略）: %@", e);
        _respringPromptShowing = NO;
    }
}


- (void)applyVisibility {
    if (!_didSetup) return;
    // 非桌面进程一律不建 UI（沙盒 App 读不到偏好），这里兜底防守。
    if (!fuIsSpringBoard()) return;
    // v1.3.31：截图 / 录屏进行中，球保持隐藏——否则 2 秒轮询 / 状态回调可能把球重新点亮，被拍进画面。
    if (_captureHiding) { _overlay.hidden = NO; _ball.hidden = YES; [self setInteractive:NO]; return; }
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
        _ball.hidden = YES;
        if (_fanOpen) [self closeFan];
        [self setInteractive:NO];
        return;
    }
    _overlay.hidden = NO;   // 允许显示：确保窗口一定恢复（含控制中心收起后）
    if (!_fanOpen && !_draggingBall) { _ball.hidden = NO; _ball.alpha = 0.4f; [_overlay bringSubviewToFront:_ball]; [self setInteractive:NO]; }
    [self fuRefreshDeferredEdges];   // v1.3.24：显隐变化会影响要不要压系统手势边
}





// v1.3.28：把悬浮窗从「截图 / 录屏」里彻底排除（Apple 私有 API）。
// 这是最稳的手段——不依赖钩住某个系统截图入口（iOS 各版本类名/方法名会变，钩子可能失效），
// 也不靠「截图前赶在 0.2 秒内把球藏起来」的时序赌博。设上后球在画面里照常可见，
// 但截出来的图 / 录出来的屏里它就是一片透明，绝对不会带进去。captureHide 关掉则恢复正常（可被拍到）。
- (void)fuApplyCaptureExclusion {
    if (!_overlay) return;
    SEL s = NSSelectorFromString(@"_setExcludedFromScreenCapture:");
    if ([_overlay respondsToSelector:s]) {
        _captureExclusionOK = YES;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[_overlay methodSignatureForSelector:s]];
        [inv setSelector:s]; [inv setTarget:_overlay];
        BOOL v = _captureHide ? YES : NO;
        [inv setArgument:&v atIndex:2];
        @try { [inv invoke]; } @catch (NSException *e) { NSLog(@"[FloatingURL] 排除截图异常（已忽略）: %@", e); }
    } else {
        // v1.3.30：iOS16 实测很多机型没有这个私有方法，1.3.28 在那些机上就是空操作 → 球照拍。
        _captureExclusionOK = NO;
    }
    [self fuApplySecureCaptureGuard];   // v1.3.30：主力的渲染层排除（不依赖任何截图入口/系统版本）
}

// v1.3.32：禁用 v1.3.30 引入的「secureTextEntry 渲染层保护」。
// 原实现在启动期把 overlay 根视图的 CALayer 手动摘下、挂到 secure UITextField 内部层，
// 导致「视图树」与「图层树」脱节，SpringBoard 在图层合成阶段直接 EXC_BAD_ACCESS 硬崩
// → 安全模式循环（每注销一次崩一次，设备进不了桌面）。@try/@catch 只能接 Objective-C
// 异常、接不住内存崩溃，所以它无法自保。
// 现改为禁用；截图排除回退到两条安全的路径：
//   ① _setExcludedFromScreenCapture:（私有 API，存在则生效、不存在则安全空操作，绝不崩）
//   ② 电源+音量组合键的系统截图钩子（始终生效，系统截图前先藏球）
// 后续会以「视图树一致」的方式（用 addSubview 让 UIKit 自己搬层，而非手动动 CALayer）
// 安全地重做 secure 保护，目前以「设备能正常进桌面」为第一优先级。
- (void)fuApplySecureCaptureGuard {
    return;   // v1.3.32：禁用会崩的图层重父化，见上方注释。_secureGuard 暂不创建。
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
// ===== v1.3.27：SpringBoard 侧「截图」钩子 =====
// 截图手势 = 电源 + 音量上，最终走到 SBCombinationHardwareButtonActions -performTakeScreenshotAction。
// 在这一步先收拢 + 藏球，再放行去拍 —— 截出来的图里就不会带悬浮球和扇形。
// 兜底再挂一个 SBScreenFlash（闪光出现时再收一次），万一上面的入口在某个系统版本改名了也不至于全瞎。
static CFAbsoluteTime fuLastCaptureSignal = 0;
static void (*fuOrigTakeScreenshot)(id, SEL) = NULL;
static void (*fuOrigFlashWhite)(id, SEL, id) = NULL;
// v1.3.37：第三方局部/长截图 tweak 入口（SuperScreenshot / Snapper4）。它们「界面弹出 / 开始捕获」那一刻
// 就同步冻屏抓底图，且自身不置 isCaptured、不走系统硬件键 → 系统通知/硬件钩子全收不到。
// 改在它们的入口「调原始实现之前」先把本插件 UI 瞬时隐藏并等一帧渲染，球/扇形就不会被冻进底图。
static void (*fuOrigMaskCropShow)(id, SEL) = NULL;        // SuperScreenshot：MaskCropWindow - show
static void (*fuOrigSn4Begin)(id, SEL, NSInteger) = NULL; // Snapper 4：SSCoordinator - beginCaptureWithMode:

static void fuSignalCaptureWill(BOOL allowDelay) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ fuSignalCaptureWill(allowDelay); });
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL first = (now - fuLastCaptureSignal) > 1.0;   // 同一次截图只等一次，别叠加延迟
    fuLastCaptureSignal = now;
    [[FUFloatingManager shared] fuCaptureWillHide];
    if (allowDelay) {
        [CATransaction flush];           // 把「球已隐藏」这一帧立刻提交给渲染服务
        if (first) usleep(200 * 1000);   // 再留 0.2s，确保渲染服务真的把它从画面里拿掉
    }
}
static void fuHookTakeScreenshot(id self, SEL _cmd) {
    fuSignalCaptureWill(YES);
    if (fuOrigTakeScreenshot) fuOrigTakeScreenshot(self, _cmd);
}
static void fuHookFlashWhite(id self, SEL _cmd, id completion) {
    fuSignalCaptureWill(NO);
    if (fuOrigFlashWhite) fuOrigFlashWhite(self, _cmd, completion);
}
// v1.3.37：第三方截图入口钩子。在原始实现「之前」先隐藏并等帧，确保冻屏时已无本插件 UI。
static void fuHookMaskCropShow(id self, SEL _cmd) {
    fuSignalCaptureWill(YES);
    if (fuOrigMaskCropShow) fuOrigMaskCropShow(self, _cmd);
}
static void fuHookSn4Begin(id self, SEL _cmd, NSInteger mode) {
    fuSignalCaptureWill(YES);
    if (fuOrigSn4Begin) fuOrigSn4Begin(self, _cmd, mode);
}
static void fuInstallCaptureHooks(void) {
    @try {
        // v1.3.37：前两个是系统截图（硬件键/闪光）；后两个是第三方局部/长截图 tweak 入口。
        // 注：iOS 16 上并不存在 SBScreenShotter（已 frida 实测），系统截图真名是 SBScreenshotManager，
        // 但它只能兜底「拍照后」，对「拍照前隐藏」无意义（硬件键钩子已覆盖），故此处不挂，避免参数不匹配崩。
        const char *names[4] = {"SBCombinationHardwareButtonActions", "SBScreenFlash", "MaskCropWindow", "SSCoordinator"};
        const char *sels[4]  = {"performTakeScreenshotAction", "flashWhiteWithCompletion:", "show", "beginCaptureWithMode:"};
        IMP imps[4] = {(IMP)fuHookTakeScreenshot, (IMP)fuHookFlashWhite, (IMP)fuHookMaskCropShow, (IMP)fuHookSn4Begin};
        void **slots[4] = {(void **)&fuOrigTakeScreenshot, (void **)&fuOrigFlashWhite, (void **)&fuOrigMaskCropShow, (void **)&fuOrigSn4Begin};
        const char *types[4] = {"v@:", "v@:@", "v@:", "v@:q"};
        for (int i = 0; i < 4; i++) {
            Class c = objc_getClass(names[i]);
            if (!c) continue;
            SEL s = sel_registerName(sels[i]);
            Method m = class_getInstanceMethod(c, s);
            if (!m) continue;
            if (class_addMethod(c, s, imps[i], types[i])) {
                Method pm = class_getInstanceMethod(class_getSuperclass(c), s);
                *slots[i] = pm ? (void *)method_getImplementation(pm) : NULL;
            } else {
                *slots[i] = (void *)method_getImplementation(m);
                method_setImplementation(m, imps[i]);
            }
            NSLog(@"[FloatingURL] capture hook installed: %s -%s", names[i], sels[i]);
        }
    } @catch (NSException *e) { NSLog(@"[FloatingURL] 装截图钩子异常（已忽略）: %@", e); }
}


%ctor {
    @autoreleasepool {
        fuInstallCaptureHooks();   // v1.3.27：截图前收拢 + 藏球（只有 SpringBoard 里存在这俩类）
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if ([bid isEqualToString:@"com.apple.Preferences"]) return;   // 设置里不挂球
        if (![bid isEqualToString:@"com.apple.springboard"]) {
            fuStartAppHeartbeat(bid);   // 沙盒 App 读不到设置 → 只发心跳，暂不建球
            return;
        }
        if (!INCLUDE_SPRINGBOARD) return;
        // v1.3.17：能走到这里说明刚注销完 → 升级旗标已失效（新版本已在跑），清掉。
        [[NSFileManager defaultManager] removeItemAtPath:kFURespringFlagPath error:NULL];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *note){ [[FUFloatingManager shared] setupWhenHostReady]; }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [[FUFloatingManager shared] setupWhenHostReady]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [[FUFloatingManager shared] setupWhenHostReady]; });
    }
}
