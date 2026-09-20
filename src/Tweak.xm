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

static NSString * const kFUURLs        = @"urls";
static NSString * const kFUEntryURL    = @"url";
static NSString * const kFUEntryChar   = @"char";
static NSString * const kFUEntryLetter = @"letter";
static NSString * const kFUEntryIcon   = @"icon";
static NSString * const kFUSync        = @"sync";
static NSString * const kFUEnabledApps = @"enabledApps";

static const NSInteger kFUMaxEntries = 6;
static const CGFloat   kFUButtonSize = 40.0f;   // 悬浮球与扇形图标统一尺寸

static void fuPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo);
static void fuSyncChanged(CFNotificationCenterRef center, void *observer,
                          CFStringRef name, const void *object, CFDictionaryRef userInfo);

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
    _labelField.placeholder = @"汉字或字母（1 个字符，如 微 / W）";
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
    tip.text = @"提示：图标会自动压缩成 120×120 正方形；图标与文字二选一，不填图标则显示上方文字。";
    [scroll addSubview:tip]; y += 44 + 12;

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.frame = CGRectMake(pad, y, w, 40);
    [clear setTitle:@"清除图标（用文字显示）" forState:UIControlStateNormal];
    [clear addTarget:self action:@selector(clearIcon) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:clear]; y += 40 + 24;
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
        [self refreshIcon:_iconData];
    }
}
- (BOOL)textField:(UITextField *)tf shouldChangeCharactersInRange:(NSRange)r
                                              replacementString:(NSString *)s {
    if (tf == _labelField) {
        NSString *next = [tf.text stringByReplacingCharactersInRange:r withString:s];
        return next.length <= 1;
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
- (void)save {
    NSMutableDictionary *e = [NSMutableDictionary dictionary];
    e[kFUEntryURL] = (_urlField.text.length ? _urlField.text : @"");
    NSString *lab = _labelField.text ?: @"";
    if (lab.length) e[kFUEntryChar] = [lab substringToIndex:1];
    if (_iconData) e[kFUEntryIcon] = _iconData;

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
@property (nonatomic, strong) UIView      *schemeBox;     // 非网页入口的简单输入框容器
@property (nonatomic, strong) UITextField *schemeField;
@property (nonatomic, strong) UIButton    *schemeOpenBtn;
@end

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
    NSString              *_hostBid;     // 当前宿主 App 的 bundle id（用于「作用 App」网关）
    BOOL                  _interactive;  // 是否已临时当 key（避免重复 rekey）
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
        _history = [NSMutableArray array]; _fanItems = [NSMutableArray array];
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
    [self loadEntries];
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
        _overlay.windowLevel = 1000;
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
    [self onBecomeActive];
}
- (void)onBecomeActive {
    if (!_didSetup) return;
    [self reloadPrefs];
    [self applyVisibility];
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
    _webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    _webView.navigationDelegate = self;
    _webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _webView.scrollView.bounces = YES; [_panel addSubview:_webView];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [_webView addSubview:_spinner];

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
    _ball.frame = CGRectMake(w.bounds.size.width - kFUButtonSize - 4, w.bounds.size.height * 0.45, kFUButtonSize, kFUButtonSize);
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
    if (_expanded) { [self collapse]; return; }
    if (_fanOpen)  { [self closeFan]; return; }
    // 没有配置任何入口 → 直接展开默认网页；有入口 → 弹出扇形（几个入口排几个）。
    if (_entries.count == 0) { [self expand]; return; }
    [self openFan];
}
- (void)panBall:(UIPanGestureRecognizer *)g {
    if (!_ball) return;
    if (g.state == UIGestureRecognizerStateBegan) _ballDragOrigin = _ball.frame.origin;
    else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:_overlay];
        CGRect f = _ball.frame;
        f.origin.x = MAX(0, MIN(_overlay.bounds.size.width  - f.size.width,  _ballDragOrigin.x + t.x));
        f.origin.y = MAX(0, MIN(_overlay.bounds.size.height - f.size.height, _ballDragOrigin.y + t.y));
        _ball.frame = f;
    }
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

#pragma mark - 扇形菜单（图标尺寸 = 球尺寸；长按可编辑）
- (void)openFan {
    if (_fanOpen || _entries.count < 1) return;   // 0 个入口不弹（loadEntries 至少兜底 1 个）
    _fanOpen = YES; [self closeFanItemsAnimated:NO];
    // 扇形无需键盘，保持非 key（不抢 App 触摸）；触摸经 hitTest 正常命中扇形按钮。
    CGPoint c = CGPointMake(CGRectGetMidX(_ball.frame), CGRectGetMidY(_ball.frame));
    BOOL left = (c.x > _overlay.bounds.size.width / 2.0);
    NSInteger n = _entries.count;
    CGFloat base = left ? 180.0f : 0.0f;          // 球在右侧就向左展开，反之向右
    // n==1 时 span=0，直接放在 base 方向（避免除以 (n-1)=0 得到 NaN）；n>1 才真正扇形展开。
    CGFloat span = (n <= 1) ? 0.0f : MIN(140.0f, 40.0f + 30.0f * (n - 1));
    CGFloat R = 96.0f;
    for (NSInteger i = 0; i < n; i++) {
        // n==1 时直接放在 base 方向（避免除以 (n-1)=0 得到 NaN）。
        CGFloat a = (n <= 1) ? base : (base - span/2.0f + span * ((CGFloat)i / (CGFloat)(n - 1)));
        CGFloat rad = a * M_PI / 180.0f;
        CGFloat x = c.x + R * cos(rad), y = c.y + R * sin(rad);
        UIButton *it = [self buildFanItem:_entries[i] index:i];
        CGRect target = CGRectMake(x - kFUButtonSize/2.0, y - kFUButtonSize/2.0, kFUButtonSize, kFUButtonSize);
        target.origin.x = MAX(2, MIN(_overlay.bounds.size.width  - kFUButtonSize - 2, target.origin.x));
        target.origin.y = MAX(2, MIN(_overlay.bounds.size.height - kFUButtonSize - 2, target.origin.y));
        it.frame = CGRectMake(c.x - kFUButtonSize/2.0, c.y - kFUButtonSize/2.0, kFUButtonSize, kFUButtonSize);
        it.alpha = 0.0f; it.transform = CGAffineTransformMakeScale(0.1f, 0.1f);
        [_overlay addSubview:it]; [_fanItems addObject:it];
        [UIView animateWithDuration:0.22 delay:0.02*i usingSpringWithDamping:0.7 initialSpringVelocity:0.6
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ it.frame = target; it.alpha = 1.0f; it.transform = CGAffineTransformIdentity; }
                         completion:nil];
    }
}
- (UIButton *)buildFanItem:(NSDictionary *)entry index:(NSInteger)idx {
    UIButton *it = [UIButton buttonWithType:UIButtonTypeCustom];
    it.layer.cornerRadius = kFUButtonSize/2.0; it.layer.shadowColor = [UIColor blackColor].CGColor;
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
        it.backgroundColor = [UIColor colorWithHue:((CGFloat)idx / (CGFloat)kFUMaxEntries)
                                         saturation:0.6 brightness:0.95 alpha:1.0];
    }
    UILabel *lab = [[UILabel alloc] initWithFrame:it.bounds];
    lab.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    lab.textAlignment = NSTextAlignmentCenter; lab.textColor = [UIColor whiteColor];
    NSString *ch = entry[kFUEntryChar] ?: @""; NSString *lt = entry[kFUEntryLetter] ?: @"";
    lab.numberOfLines = 0; lab.font = [UIFont boldSystemFontOfSize:img ? 11 : 17];
    lab.text = img ? [NSString stringWithFormat:@"%@\n%@", ch, lt] : ch;
    if (img) lab.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    [it addSubview:lab];
    [it addTarget:self action:@selector(fanItemTapped:) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(fanItemLongPressed:)];
    [it addGestureRecognizer:lp];
    return it;
}
- (void)fanItemTapped:(UIButton *)sender {
    NSInteger idx = sender.tag; if (idx < 0 || idx >= (NSInteger)_entries.count) { [self closeFan]; return; }
    NSDictionary *entry = _entries[idx]; [self closeFan];
    NSString *u = entry[kFUEntryURL]; if (!u.length) return;
    NSString *norm = [self normalizeURL:u];
    BOOL web = [self isWebScheme:norm];
    // 确认模式（设置里可开）：不直接触发，先弹输入框+打开按钮，用户点「打开」才执行。
    if (_tapConfirm) { [self showSchemeBox:norm]; return; }
    if (web) { _url = norm; [self expand]; }
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
    [self setInteractive:NO];   // 关闭扇形 → 还给 App
}
- (void)closeFanItemsAnimated:(BOOL)animated {
    NSArray *items = [_fanItems copy]; [_fanItems removeAllObjects];
    CGPoint c = _ball ? CGPointMake(CGRectGetMidX(_ball.frame), CGRectGetMidY(_ball.frame))
                      : CGPointMake(_overlay.bounds.size.width - 20, _overlay.bounds.size.height/2.0);
    for (UIButton *it in items) {
        if (animated) [UIView animateWithDuration:0.18 animations:^{
            it.alpha = 0.0f; it.transform = CGAffineTransformMakeScale(0.1f, 0.1f); it.center = c;
        } completion:^(BOOL f){ [it removeFromSuperview]; }];
        else [it removeFromSuperview];
    }
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
    _urlField.text = _url; [self layoutPanel]; [self loadURL];
    [_overlay bringSubviewToFront:_panel]; _panel.hidden = NO; _historyTable.hidden = YES;
    _schemeBox.hidden = YES; _bar.hidden = NO; _webView.hidden = NO;   // 网页模式：显示工具条与网页
    _ball.hidden = YES; _expanded = YES; [self setInteractive:YES];
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
    _bar.hidden = YES; _webView.hidden = YES; _historyTable.hidden = YES; _schemeBox.hidden = NO;
    [self layoutPanel];
    _ball.hidden = YES; _expanded = YES; [self setInteractive:YES]; [self writeSync];
}
- (void)openScheme {
    NSString *u = _schemeField.text; if (!u.length) return;
    NSString *norm = [self normalizeURL:u];
    if ([self isWebScheme:norm]) { _url = norm; [self expand]; return; }
    UIApplication *app = UIApplication.sharedApplication; NSURL *nu = [NSURL URLWithString:norm];
    if (app && nu) [app openURL:nu options:@{} completionHandler:nil];
    [self collapse];
}
- (void)collapse {
    [_urlField resignFirstResponder]; [_schemeField resignFirstResponder];
    _historyTable.hidden = YES; _panel.hidden = YES;
    _ball.hidden = !_enabled; _expanded = NO; [self setInteractive:NO]; [self writeSync];
}
- (void)reload { [self loadURL]; }
- (void)urlGo {
    NSString *raw = _urlField.text; NSString *u = [self normalizeURL:raw];
    if (!u.length) { _urlField.text = _url; return; }
    _url = u; [self pushHistory:u]; [self loadURL]; [_urlField resignFirstResponder];
    _historyTable.hidden = YES; [self writeSync];
}
- (void)urlEditingBegan { [_historyTable reloadData]; _historyTable.hidden = _history.count == 0; }
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
    // 防御：直接读之前也刷新一次进程内偏好缓存，确保拿到设置里最新改的值。
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    // 黑名单语义：enabledApps 里列出的 App 在「该 App 内」隐藏悬浮窗；列表为空 = 全部显示。
    // 桌面(SpringBoard) 同样遵循黑名单（用户不勾它就不会隐藏）。全局 enabled 关闭则全部隐藏。
    BOOL hidden = NO;
    if (_hostBid.length) {
        CFPropertyListRef arr = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUEnabledApps, (__bridge CFStringRef)kFUSuite);
        NSArray *list = nil; if (arr) list = (__bridge_transfer NSArray *)arr;
        if ([list isKindOfClass:[NSArray class]] && [list containsObject:_hostBid]) hidden = YES;
    }
    if (!_enabled || hidden) { _ball.hidden = YES; _panel.hidden = YES; if (_fanOpen) [self closeFan]; return; }
    if (!_expanded && !_fanOpen) { _ball.hidden = NO; [_overlay bringSubviewToFront:_ball]; [self setInteractive:NO]; }
}

#pragma mark - 跨 App 轻量同步
- (void)writeSync {
    if (_applyingRemote) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"open"] = @(_expanded);
    if (_expanded) { d[@"url"] = _url ?: @""; d[@"panel"] = NSStringFromCGRect(_panel.frame); }
    CFPreferencesSetAppValue((__bridge CFStringRef)kFUSync, (__bridge CFPropertyListRef)d, (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    notify_post("com.yzdmm.floatingurl/syncChanged");
}
- (void)applySync {
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
    [tv reloadData]; _historyTable.hidden = YES; [_urlField resignFirstResponder];
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
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)nav { [_spinner startAnimating]; }
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)nav {
    [_spinner stopAnimating]; NSString *cur = webView.URL.absoluteString;
    if (cur.length && _expanded) { _url = cur; _urlField.text = cur; [self pushHistory:cur]; }
    [self applyWebZoom];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)nav withError:(NSError *)error { [_spinner stopAnimating]; }
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)nav withError:(NSError *)error { [_spinner stopAnimating]; }
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
// 注入入口：Filter = Bundles(com.apple.UIKit)，全 App + 主屏幕。设置进程跳过。
// 新增「作用 App」限制：勾选后仅指定 App 显示（桌面始终显示）。
// ============================================================
%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if ([bid isEqualToString:@"com.apple.Preferences"]) return;   // 设置里不挂球
        if (!INCLUDE_SPRINGBOARD && [bid isEqualToString:@"com.apple.springboard"]) return;
        // 不再这里 early-return：「作用 App」网关改为运行时（applyVisibility + 进入前台）实时判断，
        // 球始终创建，被限制的 App 由 applyVisibility 隐藏，无需重启 App 才生效。
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *note){ [[FUFloatingManager shared] setupWhenHostReady]; }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [[FUFloatingManager shared] setupWhenHostReady]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [[FUFloatingManager shared] setupWhenHostReady]; });
    }
}
