#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <notify.h>

// PhotosUI 在 SDK14.5 下无法以模块方式编译（simd/cmath 缺失），tweak 里不 import 头文件，
// 改用运行时 NSClassFromString 调用 PHPicker，避免模块构建失败。
@class PHPickerConfiguration, PHPickerViewController, PHPickerResult, PHPickerFilter;
@protocol PHPickerViewControllerDelegate;

// ============================================================
// 悬浮URL —— 系统级悬浮窗 tweak（rootless / iOS16 / A14 arm64e）
// 包名：com.yzdmm.floatingurl
//
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

static const NSInteger kFUMaxEntries = 10;   // v1.3.1：扇形两层（第一层 4 + 第二层 6 = 10）
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
    Class cfgCls = NSClassFromString(@"PHPickerConfiguration"); if (!cfgCls) return;
    id cfg = [[cfgCls alloc] init];
    [cfg setValue:@1 forKey:@"selectionLimit"];
    id filter = [NSClassFromString(@"PHPickerFilter") valueForKey:@"imagesFilter"];
    if (filter) [cfg setValue:filter forKey:@"filter"];
    Class pvcCls = NSClassFromString(@"PHPickerViewController"); if (!pvcCls) return;
    // 用 objc_msgSend 直接调 initWithConfiguration:，避开 performSelector 的 ARC 选择器归属告警（-Werror）。
    // 标注 ns_returns_retained 让 ARC 正确平衡 init 返回的 +1。
    typedef id (*FUPickerInit)(id, SEL, id) __attribute__((ns_returns_retained));
    SEL initSel = NSSelectorFromString(@"initWithConfiguration:");
    id p = ((FUPickerInit)objc_msgSend)([pvcCls alloc], initSel, cfg);
    [p setValue:self forKey:@"delegate"];
    [self presentViewController:p animated:YES completion:nil];
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
    NSString             *_frontBid;         // v1.3.2 当前前台 App 的 bundle id（来自 Darwin 心跳）
    CFAbsoluteTime        _frontBidTs;       // 心跳时间戳（>3s 视为过期）
    NSMutableSet         *_frontWatched;     // 已注册通知监听的黑名单 bundle id
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
        _frontWatched = [NSMutableSet set];
        _history = [NSMutableArray array]; _fanItems = [NSMutableArray array]; _fanOffsets = [NSMutableArray array];
        [self reloadPrefs]; [self loadHistory];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)(self), &fuPrefsChanged,
            (__bridge CFStringRef)kFUPrefsChanged, NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)(self), &fuSyncChanged,
            (__bridge CFStringRef)kFUSyncChanged, NULL, CFNotificationSuspensionBehaviorCoalesce);
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
    if (_layer1 < 0) _layer1 = 0; if (_layer1 > 10) _layer1 = 10;
    if (_layer2 < 0) _layer2 = 0; if (_layer2 > 10) _layer2 = 10;
    if (_layer3 < 0) _layer3 = 0; if (_layer3 > 10) _layer3 = 10;
    // v1.3.3：静默模式（旗标文件存在 = 开；App 心跳与桌面球都据此休眠）
    _silent = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Media/FloatingURL_silent"];
    [self loadEntries];
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
    _entries = arr.count ? arr : @[ @{ kFUEntryURL: (_url ?: @"https://www.apple.com") } ];
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
    // v1.3.1：球固定在左/右边（side），竖向往中；拖球仍可临时移动（松手按吸附逻辑归位）。
    CGFloat bw = w.bounds.size.width, bh = w.bounds.size.height;
    CGFloat x = (_side == 1) ? 4.0f : (bw - kFUButtonSize - 4.0f);
    CGFloat y = bh * 0.45f - kFUButtonSize/2.0f;
    _ball.frame = CGRectMake(x, MAX(2, MIN(bh - kFUButtonSize - 2, y)), kFUButtonSize, kFUButtonSize);
    _ball.alpha = 0.4f;   // 初始即半透明待机（拖动/点击会临时变实心）
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
    _ball.alpha = 1.0f;   // 点击唤醒：变实心，方便使用
    [self restoreBallFromSnap];   // 半隐吸附态 → 先拉回完整可见
    if (_expanded) { [self collapse]; return; }
    if (_fanOpen)  { [self closeFan]; return; }
    // 没有配置任何入口 → 直接展开默认网页；有入口 → 弹出扇形（几个入口排几个）。
    if (_entries.count == 0) { [self expand]; return; }
    [self openFan];
}
- (void)panBall:(UIPanGestureRecognizer *)g {
    if (!_ball) return;
    if (g.state == UIGestureRecognizerStateBegan) { _ballDragOrigin = _ball.frame.origin; _ball.alpha = 1.0f; }  // 拖动时变实心
    else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:_overlay];
        CGRect f = _ball.frame;
        f.origin.x = MAX(0, MIN(_overlay.bounds.size.width  - f.size.width,  _ballDragOrigin.x + t.x));
        f.origin.y = MAX(0, MIN(_overlay.bounds.size.height - f.size.height, _ballDragOrigin.y + t.y));
        CGPoint oldC = CGPointMake(CGRectGetMidX(_ball.frame), CGRectGetMidY(_ball.frame));
        _ball.frame = f;
        // 扇形展开时拖动球 → 扇形整体跟随球移动（按相对偏移平移）。
        if (_fanOpen && _fanItems.count == _fanOffsets.count) {
            CGPoint newC = CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f));
            CGPoint d = CGPointMake(newC.x - oldC.x, newC.y - oldC.y);
            for (NSUInteger k = 0; k < _fanItems.count; k++) {
                UIButton *it = _fanItems[k];
                it.center = CGPointMake(it.center.x + d.x, it.center.y + d.y);
            }
        }
    }
    else if (g.state == UIGestureRecognizerStateEnded) [self snapBallToEdge];   // 松手 → 近边才吸附 + 半透明
}
// v1.3.0 修复「没靠近屏幕边也自动吸走」：只有球心距某条边 ≤48pt 才吸附；
// 吸附态 = 图标只露出一半（另一半藏在屏幕外），带回弹动画。远处松手则原地半透明待机。
- (void)snapBallToEdge {
    if (!_ball) return;
    CGRect b = _ball.frame; CGRect s = _overlay.bounds;
    CGFloat cx = CGRectGetMidX(b), cy = CGRectGetMidY(b);
    CGFloat dl = cx, dr = s.size.width - cx, dt = cy, db = s.size.height - cy;
    CGFloat m = MIN(MIN(dl, dr), MIN(dt, db));
    if (m > kFUSnapThreshold) {   // 不靠近任何边 → 原地驻留，只回半透明
        [UIView animateWithDuration:0.2 animations:^{ _ball.alpha = 0.4f; }];
        return;
    }
    CGFloat half = b.size.width / 2.0f;
    CGRect f = b;
    if      (m == dl) f.origin.x = -half;                              // 左吸：只露右半
    else if (m == dr) f.origin.x = s.size.width - half;                // 右吸：只露左半
    else if (m == dt) f.origin.y = -half;                              // 上吸：只露下半
    else              f.origin.y = s.size.height - half;               // 下吸：只露上半
    [UIView animateWithDuration:0.3 delay:0.0 usingSpringWithDamping:0.65 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ _ball.frame = f; _ball.alpha = 0.4f; }
                     completion:nil];
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
- (CGFloat)fuFittingSpanForCenter:(CGFloat)center radii:(const CGFloat *)R caps:(const NSInteger *)caps
                            icon:(CGFloat)isz margin:(CGFloat)m maxSpan:(CGFloat)spanMax {
    CGRect sc = _overlay.bounds;
    CGPoint c = CGPointMake(CGRectGetMidX(_ball.frame), CGRectGetMidY(_ball.frame));
    for (CGFloat sp = spanMax; sp >= 60.0f; sp -= 5.0f) {
        BOOL ok = YES;
        for (int layer = 0; layer < 3 && ok; layer++) {
            NSInteger cnt = caps[layer]; if (cnt <= 0) continue;
            CGFloat a0 = center - sp/2.0f;
            CGFloat sp2 = (cnt > 1) ? sp / (CGFloat)(cnt - 1) : 0.0f;
            for (NSInteger k = 0; k < cnt; k++) {
                CGFloat a = (cnt > 1) ? (a0 + sp2 * (CGFloat)k) : center;
                CGFloat rad = a * (CGFloat)M_PI / 180.0f;
                CGFloat x = c.x + R[layer] * cosf(rad), y = c.y + R[layer] * sinf(rad);
                if (x - isz/2.0f < m || x + isz/2.0f > sc.size.width  - m ||
                    y - isz/2.0f < m || y + isz/2.0f > sc.size.height - m) { ok = NO; break; }
            }
        }
        if (ok) return sp;
    }
    return 60.0f;
}
- (void)openFan {
    if (_fanOpen || _entries.count < 1) return;   // 0 个入口不弹（loadEntries 至少兜底 1 个）
    _fanOpen = YES; _ball.alpha = 1.0f;           // 展开期间球保持实心可见
    [self closeFanItemsAnimated:NO];
    [self restoreBallFromSnap];                   // 半隐态先拉回，环才不会跟着缩在屏外
    // 环无需键盘，保持非 key（不抢 App 触摸）；触摸经 hitTest 正常命中图标按钮。
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
    // 2) 每层数量：用户可指定（0=自动）。先按指定值分配，剩余再自动填充到未指定层 / 兜底第三层。
    NSInteger n = (NSInteger)_entries.count;
    NSInteger want[3] = { _layer1, _layer2, _layer3 };
    NSInteger caps[3] = { 0, 0, 0 };
    NSInteger placed = 0;
    for (int i = 0; i < 3; i++) {
        if (want[i] > 0) {
            NSInteger c2 = MIN(want[i], n - placed);
            if (c2 > 0) { caps[i] = c2; placed += c2; }
        }
    }
    CGFloat spanMax = MAX(60.0f, MIN(180.0f, _fanSpan));
    NSInteger li = 0;
    while (placed < n) {
        NSInteger target = -1;
        for (int i = li; i < 3; i++) { if (want[i] == 0) { target = i; break; } }
        if (target < 0) target = 2;   // 全部指定仍不够 → 兜底第三层
        CGFloat arc = R[target] * spanMax * (CGFloat)M_PI / 180.0f;
        NSInteger autoCap = MAX(1, (NSInteger)floor(arc / (isz + gap)));
        if (autoCap > 8) autoCap = 8;
        NSInteger space = n - placed;
        NSInteger add = MIN(autoCap, space);
        caps[target] += add; placed += add;
        li = target + 1;
        if (li >= 3 && placed < n) { caps[2] += (n - placed); placed = n; }
    }
    CGFloat centerA = (_side != 1) ? 180.0f : 0.0f;   // 屏坐标：0°右 90°下 180°左 270°上
    CGFloat span = spanMax;   // v1.3.3：不再靠“缩小角度”避免重叠，而是整体平移到屏内（见下方 fit）
    // 3) 先按理想角度摆好（不裁剪），收集所有图标中心
    NSMutableArray *pts = [NSMutableArray array];
    placed = 0;
    for (NSInteger layer = 0; layer < 3; layer++) {
        NSInteger cnt = caps[layer];
        if (cnt <= 0) continue;
        CGFloat a0  = centerA - span/2.0f;
        CGFloat sp2 = (cnt > 1) ? span / (CGFloat)(cnt - 1) : 0.0f;
        for (NSInteger k = 0; k < cnt; k++) {
            if (placed >= n) break;
            placed++;
            CGFloat a = (cnt > 1) ? (a0 + sp2 * (CGFloat)k) : centerA;
            CGFloat rad = a * (CGFloat)M_PI / 180.0f;
            CGPoint p = CGPointMake(c.x + R[layer] * cosf(rad), c.y + R[layer] * sinf(rad));
            [pts addObject:[NSValue valueWithCGPoint:p]];
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
    // 5) 正式摆放（带轻微 clamp 兜底 + 缩放动画）
    [_fanOffsets removeAllObjects];
    placed = 0;
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
    NSString *u = entry[kFUEntryURL]; if (!u.length) return;
    NSString *norm = [self normalizeURL:u];
    BOOL web = [self isWebScheme:norm];
    // 确认模式（设置里可开）：不直接触发，先弹输入框+打开按钮，用户点「打开」才执行。
    if (_tapConfirm) { [self showSchemeBox:norm]; return; }
    if (web) {
        // v1.3.3：统一用内置可拖拽 / 双指缩放的 WKWebView 面板打开（桌面也是），不再跳系统浏览器。
        // 若面板实际加载失败（WKNavigation 回调）会显示错误提示，必要时可点地址栏重新加载。
        _url = norm; [self expand];
    }
    else {   // 非网页：直接拉起对应 app，不再多一步确认
        UIApplication *app = UIApplication.sharedApplication; NSURL *nu = [NSURL URLWithString:norm];
        if (app && nu) [app openURL:nu options:@{} completionHandler:nil];
    }
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
    if (!_ball.hidden) _ball.alpha = 0.4f;   // 关扇形 → 回到半透明待机
    [self setInteractive:NO];   // 关闭扇形 → 还给 App
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
- (void)fuOpenExternally:(NSString *)s {
    NSURL *u = [NSURL URLWithString:s]; if (!u) return;
    Class wsc = NSClassFromString(@"LSApplicationWorkspace");
    id ws = wsc ? [wsc performSelector:NSSelectorFromString(@"defaultWorkspace")] : nil;
    SEL selSensitive = NSSelectorFromString(@"openSensitiveURL:withOptions:");
    if (ws && [ws respondsToSelector:selSensitive]) {
        [ws performSelector:selSensitive withObject:u withObject:nil];
        return;
    }
    SEL selOpen = NSSelectorFromString(@"openURL:");
    if (ws && [ws respondsToSelector:selOpen]) { [ws performSelector:selOpen withObject:u]; return; }
    UIApplication *app = UIApplication.sharedApplication;
    if (app) [app openURL:u options:@{} completionHandler:nil];
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
        UIApplication *app = UIApplication.sharedApplication; if (app) [app openURL:u options:@{} completionHandler:nil]; return;
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
    if (!_expanded && !_fanOpen) { _ball.hidden = NO; _ball.alpha = 0.4f; [_overlay bringSubviewToFront:_ball]; [self setInteractive:NO]; }
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
        UIApplication *app = UIApplication.sharedApplication; if (app) [app openURL:u options:@{} completionHandler:nil];
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
