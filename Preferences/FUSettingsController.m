#import <Preferences/Preferences.h>
#import <notify.h>
#import <PhotosUI/PhotosUI.h>
#import <QuartzCore/QuartzCore.h>   // v1.3.8：裁剪页取景框用 CAShapeLayer/kCAFillRuleEvenOdd

// LSApplicationWorkspace / LSApplicationProxy 为私有 API，不能直接引用类（会生成链接符号导致链接失败）。
// 改用 NSClassFromString + performSelector 在运行时取，避免链接私有框架。
static NSString * const kFUSuite        = @"com.yzdmm.floatingurl";
static NSString * const kFUEntryURL    = @"url";
static NSString * const kFUEntryChar   = @"char";
static NSString * const kFUEntryLetter = @"letter";
static NSString * const kFUEntryIcon   = @"icon";
static NSString * const kFUEntryColor  = @"color";     // v1.3.3 入口图标底色 hex（无图标时生效）
static NSString * const kFUURLs        = @"urls";
static NSString * const kFUEnabledApps = @"enabledApps";
static NSString * const kFUSide        = @"side";
static NSString * const kFUIconSize    = @"iconSize";
static NSString * const kFUIconGap     = @"iconGap";
static NSString * const kFUFanSpan     = @"fanSpan";    // v1.3.2 扇形角度 60~180°
static NSString * const kFUFanScale    = @"fanScale";   // v1.3.2 整体距离 %
static NSString * const kFULayer1Count = @"layer1";     // v1.3.3 第一层入口数（0=自动）
static NSString * const kFULayer2Count = @"layer2";     // v1.3.3 第二层入口数（0=自动）
static NSString * const kFULayer3Count = @"layer3";     // v1.3.3 第三层入口数（0=自动）
static NSString * const kFUSilent      = @"silent";     // v1.3.3 静默模式
static NSString * const kFUSnapMode    = @"snapMode";   // v1.3.5 0=自动吸附 1=全屏固定
static NSString * const kFUBallX       = @"ballX";      // v1.3.5 球中心 X（归一化）
static NSString * const kFUBallTitle   = @"ballTitle";  // v1.3.5 球的文字（默认 URL）
static NSString * const kFUBallIcon    = @"ballIcon";   // v1.3.5 球的图标（PNG data，v1.3.28 起仅作旧数据兜底）
static NSString * const kFUBallIconL   = @"ballIconLeft";  // v1.3.28 左半屏图标
static NSString * const kFUBallIconR   = @"ballIconRight"; // v1.3.28 右半屏图标
static NSString * const kFUBallColor   = @"ballColor";  // v1.3.5 球的底色 hex
static NSString * const kFUSnapDelay   = @"snapDelay";  // v1.3.13 吸附延时秒（松手后完整图标停留时长，默认 3）
static NSString * const kFUFanAutoHide = @"fanAutoHide"; // v1.3.21 扇形闲置多少秒自动收回（0=不自动收，默认 5）

// v1.3.25：秒数滑杆档位 —— 1~kFUSecMax 秒按 1 秒步进，最右一档 = 「常驻」（永不）
static const NSInteger kFUSecMax = 10;
static const NSInteger kFUMaxEntries   = 48;   // v1.3.6：上限 48（三层默认 8/16/24）
// v1.3.8：删掉 1.3.2 / 1.3.3 遗留的 kFULayer1Max / kFULayer2Max（早已不再使用，
//           各层上限统一由「布局调节」页的 8 / 16 / 24 控制）。

// ===== v1.3.7 统一调色板：48 色（够 48 个入口各用一色），末尾空串 = 默认（入口=默认蓝 / 球=玻璃） =====
static NSArray *FUColorPalette(void) {
    return @[
        // 浅色系（薄涂）
        @"#FF8787", @"#FFA94D", @"#FFD43B", @"#A9E34B", @"#63E6BE", @"#66D9E8", @"#74C0FC", @"#B197FC",
        // 亮色系
        @"#FF6B6B", @"#FF922B", @"#FCC419", @"#94D82D", @"#38D9A9", @"#22B8CF", @"#4DABF7", @"#9775FA",
        // 标准色
        @"#E03131", @"#F76707", @"#F59F00", @"#2F9E44", @"#0CA678", @"#1971C2", @"#7048E8", @"#D6336C",
        // 深色系
        @"#C92A2A", @"#D9480F", @"#E67700", @"#2B8A3E", @"#087F5B", @"#1864AB", @"#5F3DC4", @"#A61E4D",
        // 暗色系
        @"#8C1C1C", @"#9C3A0A", @"#A85B00", @"#1E5C2B", @"#05563D", @"#12457A", @"#4527A0", @"#7B1538",
        // 其它常用
        @"#F783AC", @"#E599F7", @"#8B5E3C", @"#20C997", @"#5C7CFA", @"#868E96", @"#343A40", @"#F1F3F5",
        @"",
    ];
}

#pragma mark - 方形裁剪控制器
// v1.3.8 修 05：以前是「盲裁」——图片铺满整屏，没有任何提示，用户根本不知道最终会取哪一块。
// 现在：屏幕正中固定一个正方形取景框（外部压暗 + 白描边 + 四角标记），图片可拖动/双指缩放到框内，
// 框内所见即所得；确定后按框内区域裁剪。
@interface FUCropVC : UIViewController <UIScrollViewDelegate>
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, copy)   void (^onCropped)(NSData *png);
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIImageView  *imgView;
@property (nonatomic, strong) CAShapeLayer *maskLayer;
@property (nonatomic, strong) CAShapeLayer *frameLayer;
@property (nonatomic, assign) BOOL didInit;
@end
@implementation FUCropVC
// 取景框边长（正方形，屏幕正中）
- (CGFloat)fuCropSide {
    CGFloat m = MIN(self.view.bounds.size.width, self.view.bounds.size.height);
    return MAX(120.0f, m - 84.0f);
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = [UIColor blackColor]; self.title = @"调整裁剪";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"确定"
        style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消"
        style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.delegate = self; _scroll.bounces = NO; _scroll.backgroundColor = [UIColor blackColor];
    _scroll.showsVerticalScrollIndicator = NO; _scroll.showsHorizontalScrollIndicator = NO;
    if (@available(iOS 11.0, *)) _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:_scroll];
    _imgView = [[UIImageView alloc] initWithImage:_image];
    _imgView.contentMode = UIViewContentModeScaleAspectFit;
    [_scroll addSubview:_imgView];
    // 取景框覆盖层（不接收触摸，触摸要透给下面的 scroll 拖动图片）
    UIView *ov = [[UIView alloc] initWithFrame:self.view.bounds];
    ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    ov.userInteractionEnabled = NO; ov.backgroundColor = [UIColor clearColor];
    _maskLayer = [CAShapeLayer layer];
    _maskLayer.fillRule  = kCAFillRuleEvenOdd;                       // 外框挖空中间的取景框
    _maskLayer.fillColor = [UIColor colorWithWhite:0.0 alpha:0.62].CGColor;
    [ov.layer addSublayer:_maskLayer];
    _frameLayer = [CAShapeLayer layer];
    _frameLayer.fillColor   = [UIColor clearColor].CGColor;
    _frameLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.9].CGColor;
    _frameLayer.lineWidth   = 2.0f;
    [ov.layer addSublayer:_frameLayer];
    [self.view addSubview:ov];
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 40)];
    hint.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    hint.tag = 9917; hint.numberOfLines = 0; hint.textAlignment = NSTextAlignmentCenter;
    hint.font = [UIFont systemFontOfSize:12]; hint.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    hint.text = @"拖动 / 双指缩放到框中 —— 白色方框内就是图标内容";
    [self.view addSubview:hint];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat W = self.view.bounds.size.width, H = self.view.bounds.size.height;
    UILabel *hint = [self.view viewWithTag:9917];
    hint.frame = CGRectMake(0, H - 52.0f, W, 40);
    CGFloat side = [self fuCropSide];
    CGRect box = CGRectMake((W - side)/2.0f, (H - side)/2.0f, side, side);
    UIBezierPath *outer = [UIBezierPath bezierPathWithRect:CGRectMake(0, 0, W, H)];
    [outer appendPath:[UIBezierPath bezierPathWithRect:box]];
    _maskLayer.frame  = self.view.bounds; _maskLayer.path  = outer.CGPath;
    _frameLayer.frame = self.view.bounds; _frameLayer.path = [UIBezierPath bezierPathWithRect:box].CGPath;
    if (!_didInit && W > 1 && H > 1) { _didInit = YES; [self fuApplyInitialZoom]; }
}
- (void)fuApplyInitialZoom {
    CGFloat side = [self fuCropSide];
    CGFloat z = side / MIN(_image.size.width, _image.size.height);
    _scroll.minimumZoomScale = z * 0.5f; _scroll.maximumZoomScale = z * 6.0f;
    _scroll.zoomScale = z;
    CGSize s = CGSizeMake(_image.size.width * z, _image.size.height * z);
    _imgView.frame = CGRectMake(0, 0, s.width, s.height); _scroll.contentSize = s;
    [self fuCenterContent];
}
// 用 contentInset 让「内容中心」能滚到「取景框中心」（两者都在屏幕正中）
- (void)fuCenterContent {
    CGFloat W = self.view.bounds.size.width, H = self.view.bounds.size.height;
    CGFloat side = [self fuCropSide];
    CGFloat ix = MAX(0, (W - side)/2.0f), iy = MAX(0, (H - side)/2.0f);
    _scroll.contentInset = UIEdgeInsetsMake(iy, ix, iy, ix);
    CGFloat ox = _scroll.contentSize.width  / 2.0f - W / 2.0f;
    CGFloat oy = _scroll.contentSize.height / 2.0f - H / 2.0f;
    CGFloat minX = -ix, maxX = _scroll.contentSize.width  - W + ix;
    CGFloat minY = -iy, maxY = _scroll.contentSize.height - H + iy;
    if (maxX < minX) maxX = minX;
    if (maxY < minY) maxY = minY;
    ox = MAX(minX, MIN(maxX, ox)); oy = MAX(minY, MIN(maxY, oy));
    _scroll.contentOffset = CGPointMake(ox, oy);
}
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)sv { return _imgView; }
- (void)scrollViewDidZoom:(UIScrollView *)sv {
    CGSize s = CGSizeMake(_imgView.frame.size.width, _imgView.frame.size.height);
    if (s.width > 1 && s.height > 1) _scroll.contentSize = s;
    [self fuCenterContent];
}
- (void)done {
    CGFloat side = [self fuCropSide];
    CGFloat z = _scroll.zoomScale; if (z <= 0.001f) z = 1.0f;
    CGFloat W = self.view.bounds.size.width, H = self.view.bounds.size.height;
    if (W < 2 || H < 2) { [self cancel]; return; }
    // 取景框左上角(屏幕坐标) -> 内容坐标 -> 原图像素坐标
    CGFloat cx = _scroll.contentOffset.x + (W - side)/2.0f;
    CGFloat cy = _scroll.contentOffset.y + (H - side)/2.0f;
    CGRect imgRect = CGRectMake(cx / z, cy / z, side / z, side / z);
    if (imgRect.size.width  > _image.size.width)  imgRect.size.width  = _image.size.width;
    if (imgRect.size.height > _image.size.height) imgRect.size.height = _image.size.height;
    imgRect.origin.x = MAX(0, MIN(_image.size.width  - imgRect.size.width,  imgRect.origin.x));
    imgRect.origin.y = MAX(0, MIN(_image.size.height - imgRect.size.height, imgRect.origin.y));
    CGImageRef cg = CGImageCreateWithImageInRect(_image.CGImage, imgRect);
    UIImage *sq = cg ? [UIImage imageWithCGImage:cg] : nil; if (cg) CGImageRelease(cg);
    NSData *out = nil;
    if (sq) {
        CGFloat max = 144.0; CGFloat s = MIN(1.0, max / MAX(sq.size.width, sq.size.height));
        CGSize ts = CGSizeMake(MAX(1.0, sq.size.width * s), MAX(1.0, sq.size.height * s));
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:ts];
        UIImage *small = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx){ [sq drawInRect:CGRectMake(0,0,ts.width,ts.height)]; }];
        out = UIImagePNGRepresentation(small);
    }
    if (_onCropped) _onCropped(out);
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

#pragma mark - 编辑单条 URI（含方形裁剪）
@interface FUUrlEditController : UIViewController <PHPickerViewControllerDelegate, UITextFieldDelegate, UIColorPickerViewControllerDelegate>
@property (nonatomic, strong) NSMutableArray *entries;
@property (nonatomic, assign) NSInteger index;
@property (nonatomic, strong) UITextField *urlField, *labelField;
@property (nonatomic, strong) UIButton    *iconButton;
@property (nonatomic, strong) NSData      *iconData;
@property (nonatomic, copy)   NSString    *colorHex;     // v1.3.3 自定义图标底色（hex）
@property (nonatomic, strong) NSMutableArray *colorButtons;
@property (nonatomic, strong) NSArray     *colorPresets;
@property (nonatomic, strong) UIButton    *customColorButton;   // v1.3.7 任意色入口
@end
@implementation FUUrlEditController
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = (_index >= 0) ? @"编辑入口" : @"新增入口";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存"
        style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消"
        style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag; [self.view addSubview:scroll];
    __block CGFloat y = 20; CGFloat pad = 16, w = self.view.bounds.size.width - pad*2, h = 40;
    UIView *(^mkField)(NSString *, NSString *, UIKeyboardType) = ^UIView *(NSString *ph, NSString *val, UIKeyboardType kt){
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(pad, y, w, h)];
        tf.placeholder = ph; tf.text = val; tf.borderStyle = UITextBorderStyleRoundedRect;
        tf.keyboardType = kt; tf.font = [UIFont systemFontOfSize:14];
        tf.autocorrectionType = UITextAutocorrectionTypeNo; tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.delegate = self; y += h + 12; [scroll addSubview:tf]; return tf;
    };
    _urlField    = (UITextField *)mkField(@"网址 / scheme（https://a.com、weixin://、prefs:root=xxx）", nil, UIKeyboardTypeURL);

    // 文字（名称，最多 8 字）—— 合并为单框
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
    _iconButton = [UIButton buttonWithType:UIButtonTypeSystem]; _iconButton.frame = CGRectMake((w - sq)/2.0 + pad, y, sq, sq);
    _iconButton.layer.cornerRadius = 14; _iconButton.layer.borderWidth = 1.5; _iconButton.layer.borderColor = [UIColor separatorColor].CGColor;
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

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem]; clear.frame = CGRectMake(pad, y, w, 40);
    [clear setTitle:@"清除图标（用文字显示）" forState:UIControlStateNormal];
    [clear addTarget:self action:@selector(clearIcon) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:clear]; y += 40 + 20;
    // v1.3.3：图标底色选择（不填图标时生效）
    UILabel *colLab = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w, 18)];
    colLab.font = [UIFont systemFontOfSize:12]; colLab.textColor = [UIColor secondaryLabelColor];
    colLab.text = @"图标底色（48 色 + 自定义任意色；不填图标时生效，留空 = 默认蓝）";
    [scroll addSubview:colLab]; y += 22;
    _colorPresets = FUColorPalette();
    _colorButtons = [NSMutableArray array];
    CGFloat csp = 8; NSInteger cols = 8;
    CGFloat sw = (CGFloat)((NSInteger)((w - csp * (cols - 1)) / cols));
    if (sw < 26) { cols = 6; sw = (CGFloat)((NSInteger)((w - csp * (cols - 1)) / cols)); }
    CGFloat cx = pad;
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
    y += sw + 14;
    // v1.3.7：48 色不够就调系统取色器，任意色
    _customColorButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _customColorButton.frame = CGRectMake(pad, y, w, 38);
    _customColorButton.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _customColorButton.layer.cornerRadius = 9; _customColorButton.clipsToBounds = YES;
    _customColorButton.titleLabel.font = [UIFont systemFontOfSize:13];
    [_customColorButton addTarget:self action:@selector(pickCustomColor) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:_customColorButton]; y += 38 + 16;
    scroll.contentSize = CGSizeMake(self.view.bounds.size.width, y);
    if (_index >= 0) [self prefill];
    [self refreshColor];
}
- (void)prefill {
    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUURLs, (__bridge CFStringRef)kFUSuite);
    if (!r) return; NSArray *arr = (__bridge_transfer NSArray *)r;
    if ([arr isKindOfClass:[NSArray class]] && _index < (NSInteger)arr.count) {
        NSDictionary *e = arr[_index];
        _urlField.text = e[kFUEntryURL] ?: @""; NSString *ch = e[kFUEntryChar] ?: @""; NSString *lt = e[kFUEntryLetter] ?: @"";
        _labelField.text = ch.length ? ch : lt;
        _iconData = e[kFUEntryIcon]; _colorHex = e[kFUEntryColor];
        [self refreshIcon:_iconData]; [self refreshColor];
    }
}
- (BOOL)textField:(UITextField *)tf shouldChangeCharactersInRange:(NSRange)r replacementString:(NSString *)s {
    if (tf == _labelField) {
        NSString *next = [tf.text stringByReplacingCharactersInRange:r withString:s];
        if (next.length > 8) return NO;   // v1.3.3：名称最多 8 个字符（汉字/字母/数字均可）
    } return YES;
}
- (void)refreshIcon:(NSData *)d {
    UIImage *img = d.length ? [UIImage imageWithData:d] : nil;
    if (img) { [_iconButton setImage:[img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal];
        _iconButton.imageView.contentMode = UIViewContentModeScaleAspectFill; [_iconButton setTitle:nil forState:UIControlStateNormal]; }
    else { [_iconButton setImage:nil forState:UIControlStateNormal];
        [_iconButton setTitle:@"选择图标\n（从相册，方形裁剪）" forState:UIControlStateNormal]; }
}
- (void)pickIcon {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.selectionLimit = 1; cfg.filter = [PHPickerFilter imagesFilter];
    PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:cfg]; p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil]; if (!results.count) return;
    [results.firstObject.itemProvider loadObjectOfClass:[UIImage class]
                                 completionHandler:^(__kindof id obj, NSError *err){
        if ([obj isKindOfClass:[UIImage class]]) dispatch_async(dispatch_get_main_queue(), ^{
            FUCropVC *crop = [[FUCropVC alloc] init]; crop.image = obj;
            crop.onCropped = ^(NSData *png){ self.iconData = png; [self refreshIcon:png]; };
            UINavigationController *nc = [[UINavigationController alloc] initWithRootViewController:crop];
            [self presentViewController:nc animated:YES completion:nil];
        });
    }];
}
- (void)clearIcon { _iconData = nil; [self refreshIcon:nil]; }
#pragma mark v1.3.7 任意色（系统取色器，iOS 14+）
- (void)pickCustomColor {
    if (@available(iOS 14.0, *)) {
        UIColorPickerViewController *p = [[UIColorPickerViewController alloc] init];
        p.supportsAlpha = NO;
        UIColor *cur = [self colorFromHex:_colorHex];
        if (cur) p.selectedColor = cur;
        p.delegate = self;
        [self presentViewController:p animated:YES completion:nil];
    }
}
- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)viewController {
    [self applyPickedColor:viewController.selectedColor];
}
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    [self applyPickedColor:viewController.selectedColor];
}
- (void)applyPickedColor:(UIColor *)c {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (!c || ![c getRed:&r green:&g blue:&b alpha:&a]) return;
    _colorHex = [NSString stringWithFormat:@"#%02X%02X%02X",
                 (int)(r * 255.0 + 0.5), (int)(g * 255.0 + 0.5), (int)(b * 255.0 + 0.5)];
    [self refreshColor];
}
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
    [self refreshCustomButton];
}
- (void)refreshCustomButton {
    NSString *cur = _colorHex ?: @"";
    BOOL inPreset = NO;
    for (NSString *h in _colorPresets) {
        if (h.length && cur.length && [h caseInsensitiveCompare:cur] == NSOrderedSame) { inPreset = YES; break; }
    }
    [_customColorButton setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    if (cur.length && !inPreset)
        [_customColorButton setTitle:[NSString stringWithFormat:@"自定义色 %@（点这里换）", cur] forState:UIControlStateNormal];
    else
        [_customColorButton setTitle:@"＋ 自定义颜色（任意色，48 色不够时用）" forState:UIControlStateNormal];
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
    if (lab.length) e[kFUEntryChar] = lab;   // v1.3.3：存名称（最多 8 字）
    if (_iconData) e[kFUEntryIcon] = _iconData;
    if (_colorHex.length) e[kFUEntryColor] = _colorHex;
    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUURLs, (__bridge CFStringRef)kFUSuite);
    NSMutableArray *arr = nil; if (r) { NSArray *a = (__bridge_transfer NSArray *)r; arr = [a mutableCopy]; }
    if (!arr) arr = [NSMutableArray array];
    if (_index >= 0 && _index < (NSInteger)arr.count) arr[_index] = e;
    else { if (arr.count >= kFUMaxEntries) { [self cancel]; return; } [arr addObject:e]; }
    CFPreferencesSetAppValue((__bridge CFStringRef)kFUURLs, (__bridge CFPropertyListRef)arr, (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    notify_post("com.yzdmm.floatingurl/settingsChanged");
    [self.navigationController popViewControllerAnimated:YES];
}
- (void)cancel { [self.navigationController popViewControllerAnimated:YES]; }
@end

#pragma mark - v1.3.5 悬浮球外观编辑（名称 / 图标 / 底色）
@interface FUBallEditController : UIViewController <PHPickerViewControllerDelegate, UITextFieldDelegate, UIColorPickerViewControllerDelegate>
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UIButton    *iconButtonL;   // v1.3.28 左半屏图标按钮
@property (nonatomic, strong) UIButton    *iconButtonR;   // v1.3.28 右半屏图标按钮
@property (nonatomic, strong) NSData      *iconDataL;     // v1.3.28 左半屏图标
@property (nonatomic, strong) NSData      *iconDataR;     // v1.3.28 右半屏图标
@property (nonatomic, assign) NSInteger   pickSide;       // v1.3.28 当前正在选哪一侧（0=左 1=右）
@property (nonatomic, copy)   NSString    *colorHex;
@property (nonatomic, strong) NSMutableArray *colorButtons;
@property (nonatomic, strong) NSArray     *colorPresets;
@property (nonatomic, strong) UIButton    *customColorButton;   // v1.3.7 任意色入口
@end
@implementation FUBallEditController
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"悬浮球外观";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存"
        style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消"
        style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag; [self.view addSubview:scroll];
    __block CGFloat y = 20; CGFloat pad = 16, w = self.view.bounds.size.width - pad*2;
    // 读取现有值
    CFPropertyListRef bt = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUBallTitle, (__bridge CFStringRef)kFUSuite);
    NSString *curTitle = nil;
    if (bt) { curTitle = (__bridge_transfer NSString *)bt; if (![curTitle isKindOfClass:[NSString class]]) curTitle = nil; }
    // v1.3.28：读取左右图标；若新键都没写过（老用户），用旧 ballIcon 兜底（两侧同图）。
    CFPropertyListRef bl = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUBallIconL, (__bridge CFStringRef)kFUSuite);
    if (bl) { _iconDataL = (__bridge_transfer NSData *)bl; if (![_iconDataL isKindOfClass:[NSData class]]) _iconDataL = nil; }
    CFPropertyListRef br = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUBallIconR, (__bridge CFStringRef)kFUSuite);
    if (br) { _iconDataR = (__bridge_transfer NSData *)br; if (![_iconDataR isKindOfClass:[NSData class]]) _iconDataR = nil; }
    if (!_iconDataL && !_iconDataR) {   // 新键都没写过 → 旧数据兜底
        CFPropertyListRef bo = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUBallIcon, (__bridge CFStringRef)kFUSuite);
        NSData *legacy = nil;
        if (bo) { legacy = (__bridge_transfer NSData *)bo; if (![legacy isKindOfClass:[NSData class]]) legacy = nil; }
        _iconDataL = legacy; _iconDataR = legacy;
    }
    CFPropertyListRef bc = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUBallColor, (__bridge CFStringRef)kFUSuite);
    if (bc) { _colorHex = (__bridge_transfer NSString *)bc; if (![_colorHex isKindOfClass:[NSString class]]) _colorHex = nil; }
    // 名称
    UILabel *nl = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w, 18)];
    nl.font = [UIFont systemFontOfSize:12]; nl.textColor = [UIColor secondaryLabelColor];
    nl.text = @"悬浮球名称（最多 8 字，默认 URL）"; [scroll addSubview:nl]; y += 22;
    _nameField = [[UITextField alloc] initWithFrame:CGRectMake(pad, y, w, 40)];
    _nameField.placeholder = @"如 URL / 快捷 / 工具";
    _nameField.text = curTitle.length ? curTitle : @"";
    _nameField.borderStyle = UITextBorderStyleRoundedRect;
    _nameField.font = [UIFont systemFontOfSize:14]; _nameField.textAlignment = NSTextAlignmentCenter;
    _nameField.autocorrectionType = UITextAutocorrectionTypeNo;
    _nameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _nameField.delegate = self;
    [scroll addSubview:_nameField]; y += 40 + 18;
    // 图标：左半屏 / 右半屏 各一个（任一侧没设就镜像另一侧）
    CGFloat sq = 130;
    NSArray *titles = @[@"左半屏图标（球在屏幕左边时用）", @"右半屏图标（球在屏幕右边时用）"];
    NSArray *clears = @[@"清除左图标（用名称/底色）", @"清除右图标（用名称/底色）"];
    for (NSInteger s = 0; s < 2; s++) {
        UILabel *il = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w, 18)];
        il.font = [UIFont systemFontOfSize:12]; il.textColor = [UIColor secondaryLabelColor];
        il.text = titles[s]; [scroll addSubview:il]; y += 22;
        UIButton *ib = [UIButton buttonWithType:UIButtonTypeSystem];
        ib.frame = CGRectMake((w - sq)/2.0 + pad, y, sq, sq);
        ib.layer.cornerRadius = 14; ib.layer.borderWidth = 1.5;
        ib.layer.borderColor = [UIColor separatorColor].CGColor; ib.clipsToBounds = YES;
        ib.titleLabel.textAlignment = NSTextAlignmentCenter;
        ib.titleLabel.numberOfLines = 0; ib.titleLabel.font = [UIFont systemFontOfSize:13];
        [ib setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
        ib.tag = 700 + s;   // 700=左 701=右
        [ib addTarget:self action:@selector(pickIcon:) forControlEvents:UIControlEventTouchUpInside];
        [scroll addSubview:ib];
        if (s == 0) _iconButtonL = ib; else _iconButtonR = ib;
        y += sq + 8;
        UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
        clear.frame = CGRectMake(pad, y, w, 40);
        [clear setTitle:clears[s] forState:UIControlStateNormal];
        clear.tag = 710 + s;   // 710=清左 711=清右
        [clear addTarget:self action:@selector(clearIcon:) forControlEvents:UIControlEventTouchUpInside];
        [scroll addSubview:clear]; y += 40 + 16;
    }
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w, 40)];
    hint.font = [UIFont systemFontOfSize:11]; hint.textColor = [UIColor tertiaryLabelColor];
    hint.numberOfLines = 0;
    hint.text = @"两侧都设就各用各的；只设一侧，另一侧会自动镜像这一侧（保证左右都有图）。都不设则显示名称。";
    [scroll addSubview:hint]; y += 44;
    // 底色
    UILabel *cl = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w, 18)];
    cl.font = [UIFont systemFontOfSize:12]; cl.textColor = [UIColor secondaryLabelColor];
    cl.text = @"悬浮球底色（48 色 + 自定义任意色；不设图标时生效，留空 = 玻璃质感）"; [scroll addSubview:cl]; y += 22;
    _colorPresets = FUColorPalette();
    _colorButtons = [NSMutableArray array];
    CGFloat csp = 8; NSInteger cols = 8;
    CGFloat sw = (CGFloat)((NSInteger)((w - csp * (cols - 1)) / cols));
    if (sw < 26) { cols = 6; sw = (CGFloat)((NSInteger)((w - csp * (cols - 1)) / cols)); }
    CGFloat cx = pad;
    for (NSString *hex in _colorPresets) {
        if (cx + sw > pad + w) { cx = pad; y += sw + csp; }
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(cx, y, sw, sw);
        b.layer.cornerRadius = sw/2.0f; b.layer.borderWidth = 2.0f;
        b.layer.borderColor = [UIColor separatorColor].CGColor; b.clipsToBounds = YES;
        if (hex.length) b.backgroundColor = [self colorFromHex:hex];
        else { b.backgroundColor = [UIColor secondarySystemBackgroundColor];
               [b setTitle:@"玻璃" forState:UIControlStateNormal]; b.titleLabel.font = [UIFont systemFontOfSize:10];
               [b setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal]; }
        b.tag = 900 + [_colorPresets indexOfObject:hex];
        [b addTarget:self action:@selector(colorTapped:) forControlEvents:UIControlEventTouchUpInside];
        [scroll addSubview:b]; [_colorButtons addObject:b]; cx += sw + csp;
    }
    y += sw + 14;
    _customColorButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _customColorButton.frame = CGRectMake(pad, y, w, 38);
    _customColorButton.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _customColorButton.layer.cornerRadius = 9; _customColorButton.clipsToBounds = YES;
    _customColorButton.titleLabel.font = [UIFont systemFontOfSize:13];
    [_customColorButton addTarget:self action:@selector(pickCustomColor) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:_customColorButton]; y += 38 + 16;
    scroll.contentSize = CGSizeMake(self.view.bounds.size.width, y);
    [self refreshIcon:_iconDataL side:0]; [self refreshIcon:_iconDataR side:1]; [self refreshColor];
}
- (BOOL)textField:(UITextField *)tf shouldChangeCharactersInRange:(NSRange)r replacementString:(NSString *)s {
    if (tf == _nameField) {
        NSString *next = [tf.text stringByReplacingCharactersInRange:r withString:s];
        if (next.length > 8) return NO;
    } return YES;
}
- (void)refreshIcon:(NSData *)d side:(NSInteger)s {
    UIButton *b = (s == 0) ? _iconButtonL : _iconButtonR;
    NSString *ph = (s == 0) ? @"选左图标\n（从相册，方形裁剪）" : @"选右图标\n（从相册，方形裁剪）";
    UIImage *img = d.length ? [UIImage imageWithData:d] : nil;
    if (img) { [b setImage:[img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal];
        b.imageView.contentMode = UIViewContentModeScaleAspectFill; [b setTitle:nil forState:UIControlStateNormal]; }
    else { [b setImage:nil forState:UIControlStateNormal]; [b setTitle:ph forState:UIControlStateNormal]; }
}
- (void)pickIcon:(UIButton *)sender {
    _pickSide = (sender.tag == 701) ? 1 : 0;
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.selectionLimit = 1; cfg.filter = [PHPickerFilter imagesFilter];
    PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:cfg]; p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil]; if (!results.count) return;
    [results.firstObject.itemProvider loadObjectOfClass:[UIImage class]
                                 completionHandler:^(__kindof id obj, NSError *err){
        if ([obj isKindOfClass:[UIImage class]]) dispatch_async(dispatch_get_main_queue(), ^{
            FUCropVC *crop = [[FUCropVC alloc] init]; crop.image = obj;
            crop.onCropped = ^(NSData *png){
                if (self.pickSide == 0) { self.iconDataL = png; [self refreshIcon:png side:0]; }
                else { self.iconDataR = png; [self refreshIcon:png side:1]; }
            };
            UINavigationController *nc = [[UINavigationController alloc] initWithRootViewController:crop];
            [self presentViewController:nc animated:YES completion:nil];
        });
    }];
}
- (void)clearIcon:(UIButton *)sender {
    NSInteger s = (sender.tag == 711) ? 1 : 0;   // 710=清左 711=清右
    if (s == 0) { _iconDataL = nil; [self refreshIcon:nil side:0]; }
    else { _iconDataR = nil; [self refreshIcon:nil side:1]; }
}
#pragma mark v1.3.7 任意色（系统取色器，iOS 14+）
- (void)pickCustomColor {
    if (@available(iOS 14.0, *)) {
        UIColorPickerViewController *p = [[UIColorPickerViewController alloc] init];
        p.supportsAlpha = NO;
        UIColor *cur = [self colorFromHex:_colorHex];
        if (cur) p.selectedColor = cur;
        p.delegate = self;
        [self presentViewController:p animated:YES completion:nil];
    }
}
- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)viewController {
    [self applyPickedColor:viewController.selectedColor];
}
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    [self applyPickedColor:viewController.selectedColor];
}
- (void)applyPickedColor:(UIColor *)c {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (!c || ![c getRed:&r green:&g blue:&b alpha:&a]) return;
    _colorHex = [NSString stringWithFormat:@"#%02X%02X%02X",
                 (int)(r * 255.0 + 0.5), (int)(g * 255.0 + 0.5), (int)(b * 255.0 + 0.5)];
    [self refreshColor];
}
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
    [self refreshCustomButton];
}
- (void)refreshCustomButton {
    NSString *cur = _colorHex ?: @"";
    BOOL inPreset = NO;
    for (NSString *h in _colorPresets) {
        if (h.length && cur.length && [h caseInsensitiveCompare:cur] == NSOrderedSame) { inPreset = YES; break; }
    }
    [_customColorButton setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    if (cur.length && !inPreset)
        [_customColorButton setTitle:[NSString stringWithFormat:@"自定义色 %@（点这里换）", cur] forState:UIControlStateNormal];
    else
        [_customColorButton setTitle:@"＋ 自定义颜色（任意色，48 色不够时用）" forState:UIControlStateNormal];
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
    NSString *t = _nameField.text ?: @"";
    if (t.length) CFPreferencesSetAppValue((__bridge CFStringRef)kFUBallTitle,
        (__bridge CFPropertyListRef)t, (__bridge CFStringRef)kFUSuite);
    else CFPreferencesSetAppValue((__bridge CFStringRef)kFUBallTitle,
        (__bridge CFPropertyListRef)@"URL", (__bridge CFStringRef)kFUSuite);
    // v1.3.8 修 05：**不要用 NULL「删键」**！
    // 设置页跑在「设置」进程里，而球在 SpringBoard 进程里画。删键后 SpringBoard 的 CFPreferences
    // 缓存里可能仍留着旧值 → 症状正是「删了图标，球上照片还在 / 设了颜色没变化」。
    // 改成写「空值」：图标写空 NSData、颜色写空字符串，tweak 侧读到 length==0 即视为「未设置」，
    // 任何缓存状态下都能立刻刷新。
    // v1.3.28：左右图标分开存；任一侧没设就写空 NSData（tweak 侧会镜像另一侧 / 回退旧值）。
    CFPreferencesSetAppValue((__bridge CFStringRef)kFUBallIconL,
        (__bridge CFPropertyListRef)(_iconDataL.length ? _iconDataL : [NSData data]), (__bridge CFStringRef)kFUSuite);
    CFPreferencesSetAppValue((__bridge CFStringRef)kFUBallIconR,
        (__bridge CFPropertyListRef)(_iconDataR.length ? _iconDataR : [NSData data]), (__bridge CFStringRef)kFUSuite);
    CFPreferencesSetAppValue((__bridge CFStringRef)kFUBallColor,
        (__bridge CFPropertyListRef)(_colorHex.length ? _colorHex : @""), (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    notify_post("com.yzdmm.floatingurl/settingsChanged");
    [self.navigationController popViewControllerAnimated:YES];
}
- (void)cancel { [self.navigationController popViewControllerAnimated:YES]; }
@end

#pragma mark - URI 列表控制器（v1.3.21：已移除搜索/筛选/全选/批量 按钮栏）
#pragma mark - URI 列表控制器
@interface FUUrlListController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSMutableArray *entries;
@property (nonatomic, strong) NSMutableArray *shown;     // 要显示的下标（NSNumber）
@property (nonatomic, strong) UITableView    *tv;
@property (nonatomic, strong) UILabel        *empty;
@property (nonatomic, assign) BOOL             pendingScrollEnd;   // 保存返回后滚到最新一条
@end
@implementation FUUrlListController
- (void)loadEntries {
    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUURLs, (__bridge CFStringRef)kFUSuite);
    NSArray *arr = nil; if (r) { arr = (__bridge_transfer NSArray *)r; if (![arr isKindOfClass:[NSArray class]]) arr = nil; }
    _entries = (arr.count ? [arr mutableCopy] : [NSMutableArray array]);
    if (!_shown) _shown = [NSMutableArray array];
}
- (void)saveEntries {
    CFPreferencesSetAppValue((__bridge CFStringRef)kFUURLs, (__bridge CFPropertyListRef)_entries, (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    notify_post("com.yzdmm.floatingurl/settingsChanged");
}
- (void)refreshCount {
    NSUInteger cnt = _entries.count;
    self.title = [NSString stringWithFormat:@"快捷URI (%lu/%ld)", (unsigned long)cnt, (long)kFUMaxEntries];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:[NSString stringWithFormat:@"添加(%lu/%ld)", (unsigned long)cnt, (long)kFUMaxEntries]
                style:UIBarButtonItemStylePlain target:self action:@selector(addEntry)];
    self.navigationItem.rightBarButtonItem.enabled = (cnt < (NSUInteger)kFUMaxEntries);
    self.navigationItem.leftBarButtonItem = nil;
}
- (void)scrollToLastRow {
    if (_shown.count == 0) return;
    NSInteger row = (NSInteger)_shown.count - 1;
    __weak FUUrlListController *ws = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        FUUrlListController *ss = ws; if (!ss) return;
        if (row < (NSInteger)[ss->_tv numberOfRowsInSection:0])
            [ss->_tv scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]
                           atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
    });
}
// v1.3.21：搜索/筛选/批量 已整体移除 → 列表直接显示全部条目（按原顺序）。
- (void)applyFilter {
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)_entries.count; i++) [out addObject:@(i)];
    _shown = out;
    [_tv reloadData];
    if (_empty) _empty.hidden = (_shown.count > 0);
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.edgesForExtendedLayout = UIRectEdgeNone;      // 让系统把内容排到导航栏下方
    [self loadEntries];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    _tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.delegate = self; _tv.dataSource = self;
    _tv.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:_tv];
    CGFloat H = self.view.bounds.size.height, W = self.view.bounds.size.width;
    _empty = [[UILabel alloc] initWithFrame:CGRectMake(24, H/2.0 - 30, W - 48, 60)];
    _empty.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
                            | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    _empty.numberOfLines = 0; _empty.textAlignment = NSTextAlignmentCenter;
    _empty.font = [UIFont systemFontOfSize:14]; _empty.textColor = [UIColor secondaryLabelColor];
    _empty.text = @"还没有快捷 URL\n点右上角「添加」新建";
    _empty.hidden = YES;
    [self.view addSubview:_empty];
    [self refreshCount];
    [self applyFilter];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadEntries];
    [self refreshCount];
    [self applyFilter];
    if (_pendingScrollEnd) { _pendingScrollEnd = NO; [self scrollToLastRow]; }
}
- (void)addEntry {
    _pendingScrollEnd = YES;
    FUUrlEditController *ed = [[FUUrlEditController alloc] init]; ed.entries = _entries; ed.index = -1;
    [self.navigationController pushViewController:ed animated:YES];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _shown.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cellId = @"FUUrlCell"; UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cellId];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    if (ip.row >= (NSInteger)_shown.count) return c;
    NSInteger ei = [_shown[ip.row] integerValue];
    if (ei < 0 || ei >= (NSInteger)_entries.count) return c;
    NSDictionary *e = _entries[ei];
    NSString *nm = [e[kFUEntryChar] isKindOfClass:[NSString class]] ? e[kFUEntryChar] : @"";
    if (!nm.length && [e[kFUEntryLetter] isKindOfClass:[NSString class]]) nm = e[kFUEntryLetter];
    NSString *u = [e[kFUEntryURL] isKindOfClass:[NSString class]] ? e[kFUEntryURL] : @"";
    c.textLabel.text = [NSString stringWithFormat:@"%ld. %@  %@", (long)(ip.row + 1), nm, u];
    c.textLabel.font = [UIFont systemFontOfSize:13]; c.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    c.detailTextLabel.text = u; c.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSData *icon = [e[kFUEntryIcon] isKindOfClass:[NSData class]] ? e[kFUEntryIcon] : nil;
    c.imageView.image = icon.length ? [UIImage imageWithData:icon] : nil;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= (NSInteger)_shown.count) return;
    NSInteger ei = [_shown[ip.row] integerValue];
    FUUrlEditController *ed = [[FUUrlEditController alloc] init]; ed.entries = _entries; ed.index = ei;
    [self.navigationController pushViewController:ed animated:YES];
}
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)st forRowAtIndexPath:(NSIndexPath *)ip {
    if (st != UITableViewCellEditingStyleDelete) return;
    if (ip.row >= (NSInteger)_shown.count) return;
    NSInteger ei = [_shown[ip.row] integerValue];
    if (ei < 0 || ei >= (NSInteger)_entries.count) return;
    [_entries removeObjectAtIndex:ei];
    [self saveEntries];
    [self refreshCount];
    [self applyFilter];
}
@end

#pragma mark - 说明书 / 玩法（长按复制）
@interface FUGuideController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) NSArray *items;   // {title, text, copy}
@end
@implementation FUGuideController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"说明书 / 玩法";
    _items = @[
        @{@"t":@"① 打开网页", @"c":@"https://www.baidu.com", @"d":@"地址栏或快捷入口填网址，点开即加载网页"},
        @{@"t":@"② 跳微信", @"c":@"weixin://", @"d":@"填 weixin:// 直接拉起微信"},
        @{@"t":@"③ 跳支付宝", @"c":@"alipay://", @"d":@"填 alipay:// 拉起支付宝"},
        @{@"t":@"④ 拨号", @"c":@"tel:10086", @"d":@"填 tel:10086 拉起拨号"},
        @{@"t":@"⑤ 发短信", @"c":@"sms:10086", @"d":@"填 sms:号码 拉起短信（可加 ?&body=预填内容）"},
        @{@"t":@"⑥ 发邮件", @"c":@"mailto:a@b.com", @"d":@"填 mailto: 拉起邮件"},
        @{@"t":@"⑦ 打开地图", @"c":@"maps://", @"d":@"填 maps:// 拉起地图导航"},
        @{@"t":@"⑧ 装插件(Cydia)", @"c":@"cydia://package/com.example.foo", @"d":@"填 cydia://package/包名 拉起 Cydia 装包"},
        @{@"t":@"⑨ 装插件(Sileo)", @"c":@"sileo://package/com.example.foo", @"d":@"填 sileo://package/包名 拉起 Sileo 装包"},
        @{@"t":@"⑩ 打开本地文件", @"c":@"file:///var/jb/...", @"d":@"填 file:// 路径打开本地文件（rootless 路径以 /var/jb 开头）"},
        @{@"t":@"⑪ 如何获取URL", @"c":@"在 Safari 打开网页→分享→拷贝 即可得到网址", @"d":@"长按网页链接也可拷贝；把链接粘到地址栏/快捷入口即可"},
        @{@"t":@"⑫ 多环快捷菜单", @"c":@"设置→快捷URI 添加入口（最多 48 个，默认按第一层8/第二层16/第三层24 分）", @"d":@"点球展开扇形快捷环：URL 球固定不动；添加几个就排几个，第一层满了自动溢到第二、三层；每层数量可在「布局调节」里改（拖到 0 = 该层自动）；长按环上图标可就地编辑；拖球时整环跟随"},
        @{@"t":@"⑬ 布局调节", @"c":@"设置→布局调节（实时预览）", @"d":@"滑杆调位置/图标大小/图标间隔，预览即时变化，手机上同时生效"},
        @{@"t":@"⑭ 支付宝付款码", @"c":@"alipays://platformapi/startapp?appId=20000056", @"d":@"一键拉起支付宝付款码，付款更快"},
        @{@"t":@"⑮ 淘宝", @"c":@"taobao://", @"d":@"拉起手机淘宝；商品页链接前缀换成 taobao:// 可直达商品"},
        @{@"t":@"⑯ 京东", @"c":@"openapp.jdmobile://", @"d":@"拉起京东 App"},
        @{@"t":@"⑰ 拼多多", @"c":@"pinduoduo://", @"d":@"拉起拼多多"},
        @{@"t":@"⑱ 抖音", @"c":@"snssdk1128://", @"d":@"拉起抖音"},
        @{@"t":@"⑲ B站", @"c":@"bilibili://", @"d":@"拉起哔哩哔哩；bilibili://video/可直达视频"},
        @{@"t":@"⑳ 高铁/12306", @"c":@"cn.12306://", @"d":@"拉起铁路12306 查票改签"},
        @{@"t":@"㉑ 跳系统设置", @"c":@"App-prefs:", @"d":@"填 App-prefs: 打开系统设置；App-prefs:Bluetooth 直达蓝牙等子页"},
        @{@"t":@"㉒ App Store 应用页", @"c":@"itms-apps://itunes.apple.com/app/id123456", @"d":@"把 id 换成应用 AppID，一键跳应用详情/评分"},
        @{@"t":@"㉓ 工作门户", @"c":@"把公司 OA / 项目系统网址设为主 URL", @"d":@"悬浮球一键直达工作台，点开直接跳 Safari，全屏看最舒服"},
        @{@"t":@"㉔ 直播监控", @"c":@"监控摄像头/直播流的 http 网页地址", @"d":@"点开直接在 Safari 里打开监控画面，不用再挂着浮窗"},
        @{@"t":@"㉕ 查快递", @"c":@"快递查询网页 + 运单号参数", @"d":@"常用查件页设成快捷入口，收件高峰一键查"},
        @{@"t":@"㉖ 直达设置某一页", @"c":@"prefs:root=WIFI", @"d":@"填 prefs:root=页面ID 直接跳到「设置」里某一页（例：WIFI / Bluetooth / Battery / General）。第三方插件也走这个：ID 就是它设置面板的标识 —— PreferenceBundle 的 .bundle 目录名、或 PreferenceLoader 的 .plist 文件名，去掉后缀。ID 写错或该页不存在时，只会停在设置首页，不会报错。"},
        @{@"t":@"㉘ 图标自动分左右", @"c":@"上传的自定义图标会自动「跟边」", @"d":@"球在屏幕左半边，图标主体就显示在左边；球在右半边，主体显示在右边（主体偏一侧的图会自动水平镜像）。判不出来居中的图不翻。开关在「悬浮球外观」里，默认开。"},
        @{@"t":@"㉗ 直达本插件设置", @"c":@"prefs:root=FloatingURLPrefs", @"d":@"本插件设置页 ID 就是 FloatingURLPrefs，填这个可一键跳到「悬浮URL」设置页。同理 prefs:root=snapper4_Freeze 这类写法要生效，前提是设备上真装了那个插件、且它的设置面板名字与冒号后的 ID 完全一致。"},
        @{@"t":@"㉙ Snapper 4 深链", @"c":@"设置→Snapper 4→URL 深链 自查", @"d":@"把下面任意一条填进快捷入口，点一下直接触发（不会打开设置）。官方 id 全小写：\nprefs:root=snapper4_freeze 冻结截图\nprefs:root=snapper4_long 长截图\nprefs:root=screenshot-shell 仅截屏套壳\nprefs:root=screenshot-watermark 仅截图水印\nprefs:root=screenshot-both 截屏套壳＋水印\nprefs:root=screenshot-off 关闭截屏套壳/水印\nprefs:root=recording-shell 仅录屏套壳\nprefs:root=recording-watermark 仅录屏水印\nprefs:root=recording-both 录屏套壳＋水印\nprefs:root=recording-off 关闭录屏套壳/水印\n注意：写成 snapper4_Freeze 这类大写匹配不到；前提是设备真装了 Snapper 4 且它的设置面板 ID 与冒号后完全一致。"},
    ];
    _tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.delegate = self; _tv.dataSource = self; [self.view addSubview:_tv];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
    [_tv addGestureRecognizer:lp];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _items.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cellId = @"FUGuideCell"; UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cellId];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    NSDictionary *d = _items[ip.row];
    c.textLabel.text = d[@"t"]; c.textLabel.font = [UIFont boldSystemFontOfSize:14];
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@", d[@"c"], d[@"d"]];
    c.detailTextLabel.numberOfLines = 0; c.detailTextLabel.font = [UIFont systemFontOfSize:11];
    c.selectionStyle = UITableViewCellSelectionStyleNone; return c;
}
- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [g locationInView:_tv]; NSIndexPath *ip = [_tv indexPathForRowAtPoint:p];
    if (!ip) return; NSDictionary *d = _items[ip.row];
    [UIPasteboard generalPasteboard].string = d[@"c"];
    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 160, 36)];
    tip.center = CGPointMake(self.view.bounds.size.width/2.0, self.view.bounds.size.height/2.0);
    tip.text = @"已复制"; tip.textAlignment = NSTextAlignmentCenter; tip.textColor = [UIColor whiteColor];
    tip.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8]; tip.layer.cornerRadius = 8; tip.clipsToBounds = YES;
    tip.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                           UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:tip];
    [UIView animateWithDuration:0.8 delay:0.3 options:0 animations:^{ tip.alpha = 0; }
                     completion:^(BOOL f){ [tip removeFromSuperview]; }];
}
@end

#pragma mark - 隐藏悬浮窗的 App（黑名单：勾选 = 在该 App 内隐藏球）
@interface FUAppListController : UIViewController <UITableViewDelegate, UITableViewDataSource,
                                                    UISearchBarDelegate>
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) UISearchBar *search;
@property (nonatomic, strong) UILabel     *countLabel;
@property (nonatomic, strong) NSMutableArray *allApps;     // {bid, name, icon}
@property (nonatomic, strong) NSMutableArray *filtered;
@property (nonatomic, strong) NSMutableArray *selected;    // bundle ids（黑名单：这些 App 内隐藏球）
@property (nonatomic, assign) BOOL onlyHidden;             // v1.3.3：只看已隐藏
@property (nonatomic, strong) UIButton *onlyBtn;           // v1.3.3：只看已隐藏 切换按钮
@end
@implementation FUAppListController
- (UIImage *)scaledIcon:(UIImage *)src toSize:(CGFloat)s {
    if (!src) return nil;
    CGRect r = CGRectMake(0, 0, s, s);
    UIGraphicsImageRenderer *rr = [[UIGraphicsImageRenderer alloc] initWithSize:r.size];
    return [rr imageWithActions:^(UIGraphicsImageRendererContext *ctx){
        [src drawInRect:r]; }];
}
- (void)loadApps {
    _allApps = [NSMutableArray array]; _selected = [NSMutableArray array];
    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUEnabledApps, (__bridge CFStringRef)kFUSuite);
    if (r) { NSArray *a = (__bridge_transfer NSArray *)r; if ([a isKindOfClass:[NSArray class]]) [_selected addObjectsFromArray:a]; }
    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    id ws = wsCls ? [wsCls performSelector:@selector(defaultWorkspace)] : nil;
    // 取 app 图标的稳健方式：iOS16 上 LSApplicationProxy.icon 返回的是 LSApplicationIcon（不是 UIImage），
    // 旧写法 isKindOfClass:[UIImage] 永远失败 → 列表只剩名字没图标。改用 UIImage 私有方法直接拿 UIImage。
    Class uiImg = NSClassFromString(@"UIImage");
    SEL iconSel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (ws) {
        NSArray *apps = [ws performSelector:@selector(allApplications)];
        for (id p in apps) {
            NSString *bid = [p performSelector:@selector(bundleIdentifier)]; if (!bid.length) continue;
            if ([bid isEqualToString:@"com.apple.Preferences"]) continue;
            // ★ ARC 坑：getReturnValue: 直接把返回的对象指针拷进变量，ARC 不会为其插入 retain，
            //   而该对象通常已在 autorelease 池里——必须用 __autoreleasing，否则作用域结束 ARC 多 release 一次 → 崩溃（闪退）。
            UIImage *__autoreleasing icon = nil;
            if (uiImg && [uiImg respondsToSelector:iconSel]) {
                int fmt = 2; CGFloat scale = (UIScreen.mainScreen ? UIScreen.mainScreen.scale : 2.0f);
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:
                    [uiImg methodSignatureForSelector:iconSel]];
                [inv setTarget:uiImg]; [inv setSelector:iconSel];
                [inv setArgument:&bid atIndex:2]; [inv setArgument:&fmt atIndex:3]; [inv setArgument:&scale atIndex:4];
                [inv invoke]; [inv getReturnValue:&icon];
            }
            if (!icon && [p respondsToSelector:@selector(iconDataForVariant:)]) {
                id d = [p performSelector:@selector(iconDataForVariant:) withObject:@(2)];
                if ([d isKindOfClass:[NSData class]]) icon = [UIImage imageWithData:d];
            }
            if (icon) icon = [self scaledIcon:icon toSize:40];   // 统一缩到 40×40，避免大图标在列表里显得过大
            NSString *name = [p performSelector:@selector(localizedName)];
            [_allApps addObject:@{@"bid":bid, @"name":(name.length ? name : bid), @"icon":(icon ?: [NSNull null])}];
        }
    }
    [_allApps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    [self applyFilter:@""];
}
- (void)applyFilter:(NSString *)q {
    NSMutableArray *base = [_allApps mutableCopy];
    if (_onlyHidden) {   // v1.3.3：只看已隐藏（勾选了黑名单的）
        NSMutableArray *f = [NSMutableArray array];
        for (NSDictionary *d in base) if ([_selected containsObject:d[@"bid"]]) [f addObject:d];
        base = f;
    }
    if (q.length) {
        NSString *l = [q lowercaseString];
        NSMutableArray *f = [NSMutableArray array];
        for (NSDictionary *d in base) if ([[d[@"name"] lowercaseString] containsString:l] ||
                                         [[d[@"bid"] lowercaseString] containsString:l]) [f addObject:d];
        _filtered = f;
    } else _filtered = base;
    [self updateCount]; [_tv reloadData];
}
- (void)updateCount {
    if (_countLabel) _countLabel.text = [NSString stringWithFormat:@"已勾选 %lu 个（这些 App 内不显示球）", (unsigned long)_selected.count];
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"隐藏悬浮窗的 App";
    // 顶部说明条
    _countLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _countLabel.font = [UIFont systemFontOfSize:12]; _countLabel.textColor = [UIColor secondaryLabelColor];
    _countLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_countLabel];
    // 搜索 + 全选 一行（Auto Layout + 安全区，避免 viewDidLoad 时 bounds 未就绪导致溢出屏幕）
    UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
    bar.translatesAutoresizingMaskIntoConstraints = NO; bar.backgroundColor = [UIColor secondarySystemBackgroundColor];
    [self.view addSubview:bar];
    _search = [[UISearchBar alloc] initWithFrame:CGRectZero];
    _search.translatesAutoresizingMaskIntoConstraints = NO; _search.placeholder = @"搜索 App"; _search.delegate = self;
    [bar addSubview:_search];
    UIButton *all = [UIButton buttonWithType:UIButtonTypeSystem];
    all.translatesAutoresizingMaskIntoConstraints = NO;
    [all setTitle:@"全选" forState:UIControlStateNormal]; all.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [all addTarget:self action:@selector(toggleAll) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:all];
    // v1.3.3：只看已隐藏（只看勾选了黑名单的 App）
    _onlyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _onlyBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_onlyBtn setTitle:@"只看已隐藏" forState:UIControlStateNormal];
    _onlyBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [_onlyBtn addTarget:self action:@selector(toggleOnlyHidden) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:_onlyBtn];
    [NSLayoutConstraint activateConstraints:@[
        [_countLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_countLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_countLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_countLabel.heightAnchor constraintEqualToConstant:28],
        [bar.topAnchor constraintEqualToAnchor:_countLabel.bottomAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.heightAnchor constraintEqualToConstant:56],
        [_search.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:8],
        [_search.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [_search.trailingAnchor constraintEqualToAnchor:_onlyBtn.leadingAnchor constant:-8],
        [_onlyBtn.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [_onlyBtn.widthAnchor constraintEqualToConstant:92],
        [_onlyBtn.trailingAnchor constraintEqualToAnchor:all.leadingAnchor constant:-8],
        [all.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-8],
        [all.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [all.widthAnchor constraintEqualToConstant:56],
    ]];
    _tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tv.translatesAutoresizingMaskIntoConstraints = NO; _tv.delegate = self; _tv.dataSource = self;
    [self.view addSubview:_tv];
    [NSLayoutConstraint activateConstraints:@[
        [_tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tv.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [_tv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self loadApps];
}
- (void)toggleOnlyHidden {
    _onlyHidden = !_onlyHidden;   // v1.3.3：切换“只看已隐藏”
    [_onlyBtn setTitle:(_onlyHidden ? @"显示全部" : @"只看已隐藏") forState:UIControlStateNormal];
    [self applyFilter:_search.text ?: @""];
}
- (void)toggleAll {
    // 若当前可见项已全部在黑名单 → 取消全部（显示）；否则把可见项全部加入黑名单（隐藏）。
    BOOL allIn = YES;
    for (NSDictionary *d in _filtered) if (![_selected containsObject:d[@"bid"]]) { allIn = NO; break; }
    for (NSDictionary *d in _filtered) {
        if (allIn) [_selected removeObject:d[@"bid"]];
        else if (![_selected containsObject:d[@"bid"]]) [_selected addObject:d[@"bid"]];
    }
    [self save]; [self updateCount]; [_tv reloadData];
}
- (void)save {
    CFPreferencesSetAppValue((__bridge CFStringRef)kFUEnabledApps, (__bridge CFPropertyListRef)[_selected copy],
        (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    // ★ 关键：黑名单保存后必须发 Darwin 通知，让正在运行的 App（如 QQ）立刻重新读取并隐藏球；
    //   否则只能等 App 再次进入前台才生效，用户体感就是「加了黑名单球还在」。
    notify_post("com.yzdmm.floatingurl/settingsChanged");
}
- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)t { [self applyFilter:t]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _filtered.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cellId = @"FUAppCell"; UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cellId];
    if (!c) { c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        c.selectionStyle = UITableViewCellSelectionStyleNone; }
    NSDictionary *d = _filtered[ip.row];
    BOOL sel = [_selected containsObject:d[@"bid"]];
    c.textLabel.text = d[@"name"]; c.textLabel.textColor = sel ? [UIColor systemRedColor] : [UIColor labelColor];
    c.detailTextLabel.text = sel ? [NSString stringWithFormat:@"%@  · 已隐藏", d[@"bid"]] : d[@"bid"];
    c.detailTextLabel.font = [UIFont systemFontOfSize:10];
    id ic = d[@"icon"]; c.imageView.image = (ic && ic != [NSNull null]) ? ic : nil;
    // 双重标记：勾选 + 浅红底，确保「选择」一眼可见
    c.accessoryType = sel ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    c.backgroundColor = sel ? [UIColor colorWithRed:1.0 green:0.94 blue:0.90 alpha:1.0] : [UIColor clearColor];
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *d = _filtered[ip.row];
    if ([_selected containsObject:d[@"bid"]]) [_selected removeObject:d[@"bid"]];
    else [_selected addObject:d[@"bid"]];
    [self save]; [self updateCount]; [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
}
@end

#pragma mark - 布局实时预览画布（与 tweak 内环形公式完全一致）
@interface FUPreviewView : UIView
@property (nonatomic, assign) NSInteger side;        // 0=右 1=左
@property (nonatomic, assign) CGFloat iconSize, iconGap;
@property (nonatomic, assign) CGFloat span, scale;   // v1.3.2 扇形角度 / 整体距离%
@property (nonatomic, assign) NSInteger layer1, layer2, layer3;   // v1.3.3 每层数量（0=自动）
@property (nonatomic, strong) NSArray *entries;
- (void)refresh;
@end
@implementation FUPreviewView
- (void)refresh { [self setNeedsDisplay]; }
// v1.3.8 修 02/06：预览与 tweak 内 openFan 用**同一套**公式（朝向按球位置、角度自适应收缩）。
- (BOOL)fuSpanOK:(CGFloat)sp center:(CGFloat)centerA radii:(const CGFloat *)R caps:(const NSInteger *)caps
            icon:(CGFloat)isz rect:(CGRect)sc ball:(CGPoint)c checkFit:(BOOL)checkFit {
    for (int layer = 0; layer < 3; layer++) {
        NSInteger cnt = caps[layer]; if (cnt <= 0) continue;
        CGFloat sp2 = (cnt > 1) ? sp / (CGFloat)(cnt - 1) : 0.0f;
        if (cnt > 1) {
            CGFloat arcStep = sp2 * (CGFloat)M_PI / 180.0f * R[layer];
            if (arcStep < isz * 1.02f) return NO;
        }
        if (!checkFit) continue;
        CGFloat a0 = centerA - sp / 2.0f;
        for (NSInteger k = 0; k < cnt; k++) {
            CGFloat a = (cnt > 1) ? (a0 + sp2 * (CGFloat)k) : centerA;
            CGFloat rad = a * (CGFloat)M_PI / 180.0f;
            CGFloat x = c.x + R[layer] * cosf(rad), y = c.y + R[layer] * sinf(rad);
            if (x - isz/2.0f < 6.0f || x + isz/2.0f > sc.size.width  - 6.0f ||
                y - isz/2.0f < 6.0f || y + isz/2.0f > sc.size.height - 6.0f) return NO;
        }
    }
    return YES;
}
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect s = self.bounds;
    // 模拟屏幕底色（深色，像熄屏桌面）
    [self fuFill:[UIColor colorWithRed:0.07 green:0.09 blue:0.12 alpha:1.0] rect:s];
    // v1.3.5：画出「屏幕中心线」，让左右一眼可辨（球在哪半边 → 吸附哪边 + 扇形朝内展开）
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.22].CGColor);
    CGContextSetLineWidth(ctx, 1.0f);
    CGContextSetLineDash(ctx, 0, (CGFloat[]){ 4.0f, 4.0f }, 2);
    CGContextMoveToPoint(ctx, s.size.width/2.0f, 0);
    CGContextAddLineToPoint(ctx, s.size.width/2.0f, s.size.height);
    CGContextStrokePath(ctx);
    CGContextSetLineDash(ctx, 0, NULL, 0);
    CGFloat bs = MAX(24.0f, s.size.width * 0.11f);       // 预览里球的直径（对应 40pt 基准）
    CGFloat k  = bs / 40.0f;                             // 真机 pt → 预览 px 的缩放
    CGFloat isz = _iconSize * k;
    CGFloat gap = MAX(4.0f, _iconGap * 0.5f) * k;        // 图标之间至少留的净空隙
    CGFloat stepR = (_iconSize + _iconGap) * k;          // 相邻圈层的半径差
    CGFloat kscale = MAX(0.6f, MIN(1.6f, (_scale > 0 ? _scale : 100.0f) / 100.0f));
    CGFloat cx = (_side == 1) ? (bs/2.0f + 6.0f) : (s.size.width - bs/2.0f - 6.0f);
    CGPoint c = CGPointMake(cx, s.size.height * 0.5f);
    // ---- v1.3.2：三层半径 + 数量驱动分层 + 贴边自动变形（与 tweak 内 openFan 同一套公式）----
    CGFloat R[3];
    R[0] = (bs/2.0f + isz/2.0f + _iconGap * k) * kscale;
    R[1] = R[0] + stepR * kscale;
    R[2] = R[1] + stepR * kscale;
    // v1.3.14：预览严格按「设置里每层数量」渲染（有显式数量就按数量画，不再自动补满 48）。
    // 这样拖动任意一层滑杆，预览里对应圈的点数都会立刻变化；只有三层都设为 0（自动）时才铺满 48。
    NSInteger n = 48;
    NSInteger want[3] = { _layer1, _layer2, _layer3 };
    NSInteger caps[3] = { 0, 0, 0 };
    BOOL anyExplicit = (want[0] > 0) || (want[1] > 0) || (want[2] > 0);
    CGFloat spanMax = MAX(60.0f, MIN(180.0f, (_span > 0 ? _span : 180.0f)));
    CGFloat spanRad = spanMax * (CGFloat)M_PI / 180.0f;
    NSInteger placed = 0;
    if (!anyExplicit) {
        // 全部自动：按弧长把 48 个铺满三层（与 tweak 内 openFan 同套）
        NSInteger li = 0;
        while (placed < n) {
            NSInteger target = -1;
            for (int i = li; i < 3; i++) { if (want[i] == 0) { target = i; break; } }
            if (target < 0) target = 2;
            CGFloat arc = R[target] * spanRad;
            NSInteger autoCap = MAX(1, (NSInteger)floor(arc / (isz + gap)));
            if (autoCap > 24) autoCap = 24;
            NSInteger space = n - placed;
            NSInteger add = MIN(autoCap, space);
            caps[target] += add; placed += add;
            li = target + 1;
            if (li >= 3 && placed < n) { caps[2] += (n - placed); placed = n; }
        }
    } else {
        // 有显式数量：每层最多画用户指定的个数（受该层弧长容量与 48 上限约束），不自动补满
        for (int i = 0; i < 3; i++) {
            if (want[i] > 0) {
                CGFloat arc = R[i] * spanRad;
                NSInteger arcCap = MAX(1, (NSInteger)floor(arc / (isz + gap)));
                NSInteger c = MIN(want[i], arcCap);
                c = MIN(c, n - placed);
                if (c > 0) { caps[i] = c; placed += c; }
            }
        }
    }
    // v1.3.8 修 02：朝向 = 球心指向画布中心（与真机 fuAngleToScreenCenter: 同源）
    CGFloat centerA = atan2f((s.size.height/2.0f) - c.y, (s.size.width/2.0f) - c.x) * 180.0f / (CGFloat)M_PI;
    // v1.3.8 修 02：角度自适应收缩，保证预览里图标不会画出画布（真机同一套逻辑）
    CGFloat span = spanMax;
    while (span > 45.0f) {
        if ([self fuSpanOK:span center:centerA radii:R caps:caps icon:isz rect:s ball:c checkFit:YES]) break;
        CGFloat next = span - 5.0f;
        if (![self fuSpanOK:next center:centerA radii:R caps:caps icon:isz rect:s ball:c checkFit:NO]) break;
        span = next;
    }
    // 圈层参考弧
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.13].CGColor);
    CGContextSetLineWidth(ctx, 1.0f);
    for (int i = 0; i < 3; i++) {
        if (caps[i] <= 0) continue;
        CGContextAddArc(ctx, c.x, c.y, R[i], (centerA - span/2.0f)*M_PI/180.0, (centerA + span/2.0f)*M_PI/180.0, 0);
        CGContextStrokePath(ctx);
    }
    // 中心球（URL 玻璃球）
    [self fuCircleAt:c size:bs img:nil ch:@"URL" fs:bs*0.24f glass:YES];
    // 快捷图标：有几个排几个，第 1 层排满溢到第 2、3 层
    placed = 0;   // 复用上方的 placed（cap 分配已完成，这里重置为绘制起点）
    NSInteger real = (NSInteger)_entries.count;
    for (NSInteger layer = 0; layer < 3; layer++) {
        NSInteger cnt = caps[layer]; if (cnt <= 0) continue;
        CGFloat a0 = centerA - span/2.0f, sp2 = (cnt > 1) ? span/(CGFloat)(cnt-1) : 0.0f;
        for (NSInteger i2 = 0; i2 < cnt; i2++) {
            if (placed >= n) break;
            NSDictionary *e = (placed < real) ? _entries[placed] : nil;   // 超出真实条目的用序号占位
            NSInteger slot = placed; placed++;
            CGFloat a = (cnt > 1) ? (a0 + sp2*(CGFloat)i2) : centerA;
            CGFloat rad = a * M_PI / 180.0;
            CGPoint p = CGPointMake(c.x + R[layer]*cos(rad), c.y + R[layer]*sin(rad));
            NSData *ic = e[@"icon"];
            UIImage *img = ([ic isKindOfClass:[NSData class]] && ic.length) ? [UIImage imageWithData:ic] : nil;
            NSString *ch = e[@"char"] ?: @"";
            if (!ch.length) ch = e[@"letter"] ?: @"";
            if (!ch.length && !img) ch = [NSString stringWithFormat:@"%ld", (long)(slot + 1)];
            CGFloat fs = isz * 0.42f; if (ch.length >= 3) fs = isz * 0.26f; else if (ch.length == 2) fs = isz * 0.32f;
            [self fuCircleAt:p size:isz img:img ch:ch fs:fs glass:NO];
        }
    }
    // 底部小字：说明当前实际条目数（预览固定按 48 个满配画）
    NSString *cap = [NSString stringWithFormat:@"实际 %ld 个入口 · 预览按设置排 %ld 个", (long)real, (long)(caps[0]+caps[1]+caps[2])];
    [cap drawInRect:CGRectMake(8, s.size.height - 18.0f, s.size.width - 16.0f, 14.0f) withAttributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:9],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.45]}];
}
- (void)fuFill:(UIColor *)col rect:(CGRect)r {
    CGContextSetFillColorWithColor(UIGraphicsGetCurrentContext(), col.CGColor);
    CGContextFillRect(UIGraphicsGetCurrentContext(), r);
}
- (void)fuCircleAt:(CGPoint)ctr size:(CGFloat)d img:(UIImage *)img ch:(NSString *)ch fs:(CGFloat)fs glass:(BOOL)glass {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect r = CGRectMake(ctr.x - d/2.0f, ctr.y - d/2.0f, d, d);
    if (glass) {
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.20].CGColor);
        CGContextFillEllipseInRect(ctx, r);
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.55].CGColor);
        CGContextSetLineWidth(ctx, 1.0f);
        CGContextStrokeEllipseInRect(ctx, r);
    } else {
        // 无图标入口：区分色（蓝）实心，避免和 URL 玻璃球撞脸
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.20 green:0.52 blue:0.90 alpha:0.92].CGColor);
        CGContextFillEllipseInRect(ctx, r);
    }
    if (img) {
        CGContextSaveGState(ctx);
        UIBezierPath *clip = [UIBezierPath bezierPathWithOvalInRect:r];
        [clip addClip];
        [img drawInRect:r];
        CGContextRestoreGState(ctx);
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.55].CGColor);
        CGContextSetLineWidth(ctx, 1.0f);
        CGContextStrokeEllipseInRect(ctx, r);
    } else if (ch.length) {
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter;
        [ch drawInRect:r withAttributes:@{
            NSFontAttributeName: [UIFont boldSystemFontOfSize:fs],
            NSForegroundColorAttributeName: [UIColor whiteColor],
            NSParagraphStyleAttributeName: ps }];
    }
}
@end

#pragma mark - 布局调节器（左/右停靠 + 图标大小/间隔 滑杆 + 实时预览，改动即时全局生效）
@interface FULayoutController : UIViewController
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) FUPreviewView *preview;
@property (nonatomic, strong) UISegmentedControl *sideSeg;
@property (nonatomic, strong) UISlider *ss, *sg, *span, *sc;
@property (nonatomic, strong) UILabel *ls, *lg, *lspan, *lsc;
@property (nonatomic, strong) UISlider *l1s, *l2s, *l3s;   // v1.3.3 每层数量
@property (nonatomic, strong) UILabel *ll1, *ll2, *ll3;
@property (nonatomic, strong) UISegmentedControl *modeSeg;   // v1.3.8 吸附模式（0=自动吸附 1=全屏固定）
@property (nonatomic, strong) UILabel *lmode;                  // 模式说明
@property (nonatomic, strong) UISlider *delayS;                // v1.3.13 吸附延时秒
@property (nonatomic, strong) UILabel *ldelay;
@property (nonatomic, strong) UISlider *fanHideS;              // v1.3.25 扇形闲置收回秒（整秒步进，最右=常驻）
@property (nonatomic, strong) UILabel *lfanHide;
@end
@implementation FULayoutController
- (CGFloat)prefFloat:(NSString *)key dft:(CGFloat)d {
    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kFUSuite);
    if (!r) return d;
    CGFloat v = d;
    if (CFGetTypeID(r) == CFNumberGetTypeID()) v = [(__bridge NSNumber *)r floatValue];
    CFRelease(r); return v;
}
- (void)writeFloat:(NSString *)key value:(CGFloat)v {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)[NSNumber numberWithFloat:v],
        (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    notify_post("com.yzdmm.floatingurl/settingsChanged");
}
- (void)writeSide:(NSInteger)v {
    CFPreferencesSetAppValue((__bridge CFStringRef)kFUSide, (__bridge CFPropertyListRef)[NSNumber numberWithInteger:v],
        (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    notify_post("com.yzdmm.floatingurl/settingsChanged");
}
- (NSInteger)prefInt:(NSString *)key dft:(NSInteger)d {
    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kFUSuite);
    if (!r) return d;
    NSInteger v = d;
    if (CFGetTypeID(r) == CFNumberGetTypeID()) v = [(__bridge NSNumber *)r integerValue];
    CFRelease(r); return v;
}
- (void)writeInt:(NSString *)key value:(NSInteger)v {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)[NSNumber numberWithInteger:v],
        (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    notify_post("com.yzdmm.floatingurl/settingsChanged");
}
- (void)loadEntriesForPreview {
    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUURLs, (__bridge CFStringRef)kFUSuite);
    NSArray *arr = nil;
    if (r) { arr = (__bridge_transfer NSArray *)r; if (![arr isKindOfClass:[NSArray class]]) arr = nil; }
    _preview.entries = arr ?: @[];
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"布局调节";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"恢复默认"
        style:UIBarButtonItemStylePlain target:self action:@selector(reset)];
    CGFloat w = self.view.bounds.size.width, H = self.view.bounds.size.height;
    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];
    // ---- v1.3.8 修 06：预览改矮（按屏高自适应，最多占 1/3 屏），保证下面的调节滑杆也在一屏内。
    //      以前是 pw*1.5（约 540pt），把整页调节项全部顶到第二屏去了。----
    CGFloat y = 10, pw = w - 32;
    CGFloat ph = MIN(pw * 1.06f, H * 0.33f);
    _preview = [[FUPreviewView alloc] initWithFrame:CGRectMake(16, y, pw, ph)];
    _preview.layer.cornerRadius = 14; _preview.clipsToBounds = YES;
    _preview.side     = (NSInteger)[self prefFloat:kFUSide dft:0];
    _preview.iconSize = [self prefFloat:kFUIconSize dft:40];
    _preview.iconGap  = [self prefFloat:kFUIconGap dft:56];
    _preview.span     = [self prefFloat:kFUFanSpan dft:180];
    _preview.scale    = [self prefFloat:kFUFanScale dft:100];
    _preview.layer1   = [self prefInt:kFULayer1Count dft:0];
    _preview.layer2   = [self prefInt:kFULayer2Count dft:0];
    _preview.layer3   = [self prefInt:kFULayer3Count dft:0];
    [self loadEntriesForPreview];
    [_scroll addSubview:_preview]; y += ph + 12;
    // ---- v1.3.8 修 03：吸附模式改成真正的「分段选择器」：选中的一边蓝色、另一边灰色。
    //      以前是 0~1 的连续滑杆——手感怪，还能滑到 0.5 这种不左不右的中间值。----
    UILabel *mLab = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w-32, 16)];
    mLab.font = [UIFont systemFontOfSize:12]; mLab.textColor = [UIColor secondaryLabelColor];
    mLab.text = @"吸附模式"; [_scroll addSubview:mLab]; y += 18;
    _modeSeg = [[UISegmentedControl alloc] initWithItems:@[@"自动吸附", @"全屏固定"]];
    _modeSeg.frame = CGRectMake(16, y, w - 32, 32);
    _modeSeg.selectedSegmentIndex = ([self prefInt:kFUSnapMode dft:0] == 1) ? 1 : 0;
    if (@available(iOS 13.0, *)) _modeSeg.selectedSegmentTintColor = [UIColor systemBlueColor];
    [_modeSeg setTitleTextAttributes:@{NSForegroundColorAttributeName:[UIColor whiteColor]}
                            forState:UIControlStateSelected];
    [_modeSeg setTitleTextAttributes:@{NSForegroundColorAttributeName:[UIColor secondaryLabelColor]}
                            forState:UIControlStateNormal];
    [_modeSeg addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    [_scroll addSubview:_modeSeg]; y += 36;
    _lmode = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w-32, 28)];
    _lmode.numberOfLines = 0;
    _lmode.font = [UIFont systemFontOfSize:11]; _lmode.textColor = [UIColor tertiaryLabelColor];
    [_scroll addSubview:_lmode]; y += 30; [self refreshModeLabel];
    // ---- 预览方位（真机按球的实际位置自动识别左右，这里只决定预览画哪一侧）----
    UILabel *sideLab = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w-32, 16)];
    sideLab.font = [UIFont systemFontOfSize:12]; sideLab.textColor = [UIColor secondaryLabelColor];
    sideLab.text = @"预览方位（真机按球的实际位置自动识别）";
    [_scroll addSubview:sideLab]; y += 18;
    _sideSeg = [[UISegmentedControl alloc] initWithItems:@[@"球在右侧", @"球在左侧"]];
    _sideSeg.frame = CGRectMake(16, y, w-32, 32);
    CGFloat pbx = [self prefFloat:kFUBallX dft:0.92f];
    _sideSeg.selectedSegmentIndex = (pbx < 0.5f) ? 1 : 0;   // 跟随球当前实际位置
    _preview.side = _sideSeg.selectedSegmentIndex;
    [_sideSeg addTarget:self action:@selector(sideChanged:) forControlEvents:UIControlEventValueChanged];
    [_scroll addSubview:_sideSeg]; y += 38;
    // ---- v1.3.8 修 06：滑杆改「两列紧凑布局」，一行放两根（以前一根占 52pt，8 根就是一屏多）----
    CGFloat colGap = 12.0f, colW = (w - 32 - colGap) / 2.0f;
    CGFloat x0 = 16, x1 = 16 + colW + colGap;
    CGFloat pis = [self prefFloat:kFUIconSize dft:40], pig = [self prefFloat:kFUIconGap dft:56];
    CGFloat psp = [self prefFloat:kFUFanSpan dft:180], psc = [self prefFloat:kFUFanScale dft:100];
    _ss   = [self mkSliderAt:x0 width:colW y:y min:24 max:64  val:pis label:@"图标大小"  lout:&_ls];
    _sg   = [self mkSliderAt:x1 width:colW y:y min:12 max:120 val:pig label:@"图标间隔"  lout:&_lg];
    _ss.tag = 2; _sg.tag = 3; y += 46;
    _span = [self mkSliderAt:x0 width:colW y:y min:60 max:180 val:psp label:@"扇形角度°" lout:&_lspan];
    _sc   = [self mkSliderAt:x1 width:colW y:y min:60 max:160 val:psc label:@"整体距离%" lout:&_lsc];
    _span.tag = 4; _sc.tag = 5; y += 48;
    NSInteger pl1 = [self prefInt:kFULayer1Count dft:0], pl2 = [self prefInt:kFULayer2Count dft:0], pl3 = [self prefInt:kFULayer3Count dft:0];
    _l1s  = [self mkSliderAt:x0 width:colW y:y min:0 max:8  val:pl1 label:@"第一层" lout:&_ll1];
    _l2s  = [self mkSliderAt:x1 width:colW y:y min:0 max:16 val:pl2 label:@"第二层" lout:&_ll2];
    _l1s.tag = 6; _l2s.tag = 7; y += 46;
    _l3s  = [self mkSliderAt:x0 width:colW y:y min:0 max:24 val:pl3 label:@"第三层" lout:&_ll3];
    _l3s.tag = 8; y += 48;
    // v1.3.31：分层滑杆 0 = 自动；标签按 0 显示「自动」，其余显示数字
    _ll1.text = (pl1 == 0) ? @"第一层 自动" : [NSString stringWithFormat:@"第一层 %ld", (long)pl1];
    _ll2.text = (pl2 == 0) ? @"第二层 自动" : [NSString stringWithFormat:@"第二层 %ld", (long)pl2];
    _ll3.text = (pl3 == 0) ? @"第三层 自动" : [NSString stringWithFormat:@"第三层 %ld", (long)pl3];
    // ---- v1.3.25：两个「秒数」滑杆统一改成整秒步进，最低 1 秒，最右一档 = 常驻（永不）----
    NSInteger dSlot = [self fuSecSlot:[self prefFloat:kFUSnapDelay dft:3] keep:999];
    _delayS = [self mkSliderAt:16 width:w - 32 y:y min:1 max:(kFUSecMax + 1) val:dSlot
                         label:@"吸附延时（松手后完整图标停留）" lout:&_ldelay];
    _delayS.tag = 10; _ldelay.text = [self fuSecText:@"吸附延时（松手后完整图标停留）" slot:dSlot keepTitle:@"常驻（永不吸附）"]; y += 46;
    NSInteger fSlot = [self fuSecSlot:[self prefFloat:kFUFanAutoHide dft:5] keep:0];
    _fanHideS = [self mkSliderAt:16 width:w - 32 y:y min:1 max:(kFUSecMax + 1) val:fSlot
                           label:@"扇形闲置自动收回" lout:&_lfanHide];
    _fanHideS.tag = 11; _lfanHide.text = [self fuSecText:@"扇形闲置自动收回" slot:fSlot keepTitle:@"常驻（不自动收回）"]; y += 46;
    for (UISlider *sl in @[_ss, _sg, _span, _sc, _l1s, _l2s, _l3s, _delayS, _fanHideS])
        [sl addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    UILabel *foot = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w-32, 28)];
    foot.numberOfLines = 0; foot.font = [UIFont systemFontOfSize:10];
    foot.textColor = [UIColor tertiaryLabelColor];
    foot.text = @"每层数量 0 = 该层按弧长自动排。下面两根滑杆都按 1 秒步进，最低 1 秒，拖到最右显示「常驻」：吸附延时常驻 = 球永远保持完整图标不吸附；扇形闲置收回常驻 = 扇形展开后不会自动收回来。改动立即生效，球的位置也会被记住。";
    [_scroll addSubview:foot]; y += 30;
    _scroll.contentSize = CGSizeMake(w, y);
}
// v1.3.25：存储值 → 滑块档位（1..kFUSecMax 秒，kFUSecMax+1 = 常驻）
- (NSInteger)fuSecSlot:(CGFloat)stored keep:(CGFloat)keepValue {
    if (stored >= keepValue && keepValue > 0) return kFUSecMax + 1;
    if (keepValue <= 0 && stored <= 0.5f) return kFUSecMax + 1;   // 扇形收回：0 = 不自动收回
    NSInteger v = (NSInteger)lroundf(stored);
    if (v < 1) v = 1;
    if (v > kFUSecMax) v = kFUSecMax;
    return v;
}
// v1.3.25：滑块档位 → 存储值（最右一档写回「常驻」哨兵）
- (CGFloat)fuSecStored:(NSInteger)slot keep:(CGFloat)keepValue {
    if (slot >= kFUSecMax + 1) return keepValue;
    return (CGFloat)MAX(1, slot);
}
// v1.3.25：显示文案（常驻档不显示数字）
- (NSString *)fuSecText:(NSString *)name slot:(NSInteger)slot keepTitle:(NSString *)keepTitle {
    if (slot >= kFUSecMax + 1) return [NSString stringWithFormat:@"%@ %@", name, keepTitle];
    return [NSString stringWithFormat:@"%@ %ld 秒", name, (long)MAX(1, slot)];
}

// v1.3.8：两列紧凑版滑杆（标签 15pt + 滑杆 30pt）
- (UISlider *)mkSliderAt:(CGFloat)x width:(CGFloat)cw y:(CGFloat)fy min:(CGFloat)mn max:(CGFloat)mx
                     val:(CGFloat)v label:(NSString *)lab lout:(UILabel * __strong *)lout {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(x, fy, cw, 15)];
    l.font = [UIFont systemFontOfSize:11]; l.textColor = [UIColor secondaryLabelColor];
    l.text = [NSString stringWithFormat:@"%@ %.0f", lab, v];
    [_scroll addSubview:l]; if (lout) *lout = l;
    UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(x, fy + 15, cw, 28)];
    sl.minimumValue = mn; sl.maximumValue = mx; sl.value = v;
    [_scroll addSubview:sl];
    return sl;
}
// v1.3.5 修 03：这里只切「预览画哪一侧」（真实运行时球在哪半边就自动按哪半边算，
// 右侧→扇形朝左展开，左侧→扇形朝右展开），不再写死一个 side 设置。
- (void)sideChanged:(UISegmentedControl *)seg {
    _preview.side = seg.selectedSegmentIndex;   // 0=球在右 1=球在左
    [_preview refresh];
}
- (void)refreshModeLabel {
    BOOL fix = (_modeSeg && _modeSeg.selectedSegmentIndex == 1);
    if (_lmode) _lmode.text = fix
        ? @"全屏固定：松手停在哪就停在哪，不自动吸附（扇形仍按球的位置朝屏幕内侧展开）。"
        : @"自动吸附：按屏幕中心线归位 —— 球在左半屏吸左边、右半屏吸右边（只露一半，点击拉回）。松手后先保持完整图标，过「吸附延时」秒再吸附（默认 3 秒）。";
}
// v1.3.8 修 03：分段选择器回调
- (void)modeChanged:(UISegmentedControl *)seg {
    [self writeInt:kFUSnapMode value:(seg.selectedSegmentIndex == 1 ? 1 : 0)];
    [self refreshModeLabel];
}
- (void)sliderChanged:(UISlider *)sl {
    CGFloat v = roundf(sl.value);
    NSString *key = nil; UILabel *l = nil; NSString *name = @"";
    switch (sl.tag) {
        case 2: key = kFUIconSize; l = _ls; name = @"图标大小"; _preview.iconSize = v; break;
        case 3: key = kFUIconGap;  l = _lg; name = @"图标间隔"; _preview.iconGap = v; break;
        case 4: key = kFUFanSpan;  l = _lspan; name = @"扇形角度°"; _preview.span = v; break;
        case 5: key = kFUFanScale; l = _lsc; name = @"整体距离%"; _preview.scale = v; break;
        case 6: key = kFULayer1Count; l = _ll1; name = @"第一层"; _preview.layer1 = (NSInteger)v; break;
        case 7: key = kFULayer2Count; l = _ll2; name = @"第二层"; _preview.layer2 = (NSInteger)v; break;
        case 8: key = kFULayer3Count; l = _ll3; name = @"第三层"; _preview.layer3 = (NSInteger)v; break;
        case 10: {   // v1.3.25：整秒步进 + 常驻
            NSInteger slot = [self fuSecSlot:v keep:999];
            if (v >= kFUSecMax + 1) slot = kFUSecMax + 1;
            sl.value = slot; v = slot;
            [self writeFloat:kFUSnapDelay value:[self fuSecStored:slot keep:999]];
            _ldelay.text = [self fuSecText:@"吸附延时（松手后完整图标停留）" slot:slot keepTitle:@"常驻（永不吸附）"];
            return;
        }
        case 11: {   // v1.3.25：扇形闲置收回，整秒步进 + 常驻
            NSInteger slot = [self fuSecSlot:v keep:0];
            if (v >= kFUSecMax + 1) slot = kFUSecMax + 1;
            sl.value = slot;
            [self writeFloat:kFUFanAutoHide value:[self fuSecStored:slot keep:0]];
            _lfanHide.text = [self fuSecText:@"扇形闲置自动收回" slot:slot keepTitle:@"常驻（不自动收回）"];
            return;
        }
    }
    if (!key) return;
    // v1.3.31：分层滑杆 0 = 自动，标签显示「自动」而非「0」
    if (sl.tag >= 6 && sl.tag <= 8) {
        l.text = (v == 0) ? [NSString stringWithFormat:@"%@ 自动", name] : [NSString stringWithFormat:@"%@ %.0f", name, v];
        [self writeInt:key value:(NSInteger)v];
    } else {
        l.text = [NSString stringWithFormat:@"%@ %.0f", name, v];
        [self writeFloat:key value:v];
    }
    [_preview refresh];
}
- (void)reset {
    _sideSeg.selectedSegmentIndex = 0; _modeSeg.selectedSegmentIndex = 0; [self refreshModeLabel];
    _ss.value = 40; _sg.value = 56; _span.value = 180; _sc.value = 100;
    _l1s.value = 0; _l2s.value = 0; _l3s.value = 0;   // v1.3.31：恢复默认 = 自动分层（按实际 URL 数量排）
    _ls.text = @"图标大小 40"; _lg.text = @"图标间隔 56";
    _lspan.text = @"扇形角度° 180"; _lsc.text = @"整体距离% 100";
    _ll1.text = @"第一层 自动"; _ll2.text = @"第二层 自动"; _ll3.text = @"第三层 自动";
    _delayS.value = 3; _ldelay.text = @"吸附延时（松手后完整图标停留） 3 秒";    // v1.3.25
    _fanHideS.value = 5; _lfanHide.text = @"扇形闲置自动收回 5 秒";
    _preview.side = 0; _preview.iconSize = 40; _preview.iconGap = 56;
    _preview.span = 180; _preview.scale = 100;
    _preview.layer1 = 0; _preview.layer2 = 0; _preview.layer3 = 0;
    [self writeInt:kFUSnapMode value:0];
    [self writeFloat:kFUIconSize value:40]; [self writeFloat:kFUIconGap value:56];
    [self writeFloat:kFUFanSpan value:180]; [self writeFloat:kFUFanScale value:100];
    [self writeInt:kFULayer1Count value:0]; [self writeInt:kFULayer2Count value:0]; [self writeInt:kFULayer3Count value:0];
    [self writeFloat:kFUSnapDelay value:3];   // v1.3.13：吸附延时恢复默认 3 秒
    [self writeFloat:kFUFanAutoHide value:5]; // v1.3.25：扇形闲置收回恢复默认 5 秒
    [_preview refresh];
}
@end

#pragma mark - 主设置控制器
@interface FUSettingsController : PSListController
@end
@implementation FUSettingsController
- (id)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    // v1.3.3：让“静默模式”开关显示与实际旗标文件一致（旗标文件才是运行时权威来源）
    BOOL on = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Media/FloatingURL_silent"];
    CFPreferencesSetAppValue((__bridge CFStringRef)kFUSilent, (__bridge CFPropertyListRef)@(on), (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
}
// v1.3.33：静默模式开关回调。改用布尔（与启用开关一致）——直接翻转 suite 里的 silent 位。
// 不再写旗标文件：沙盒 Preferences 进程在 rootless 上未必能写 /var/mobile/Media，导致静默时灵时不灵。
// v1.3.33：PSSwitchCell 在调用 action 前已把新值写入 plist。这里只「同步 + 通知」，
// 绝不能再翻转（否则写回旧值，开关不生效）。若框架未自动保存，则读开关当前态手动写入。
- (void)setSilent:(id)sender {
    BOOL on;
    if ([sender respondsToSelector:@selector(isOn)]) on = [(UISwitch *)sender isOn];   // sender 是 UISwitch
    else if ([sender isKindOfClass:[NSObject class]] && [sender respondsToSelector:@selector(control)] && [[(id)sender control] isKindOfClass:[UISwitch class]])
        on = [(UISwitch *)[(id)sender control] isOn];                                    // sender 是 PSSwitchCell
    else { Boolean cur = false; on = !CFPreferencesGetAppBooleanValue((__bridge CFStringRef)kFUSilent, (__bridge CFStringRef)kFUSuite, &cur); }
    CFPreferencesSetAppValue((__bridge CFStringRef)kFUSilent, (__bridge CFPropertyListRef)@(on), (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    notify_post("com.yzdmm.floatingurl/settingsChanged");
}
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated];
    notify_post("com.yzdmm.floatingurl/settingsChanged"); }
- (void)manageUrls { FUUrlListController *list = [[FUUrlListController alloc] init];
    [self.navigationController pushViewController:list animated:YES]; }
- (void)showBallEdit { FUBallEditController *b = [[FUBallEditController alloc] init];
    [self.navigationController pushViewController:b animated:YES]; }
- (void)showLayout { FULayoutController *lc = [[FULayoutController alloc] init];
    [self.navigationController pushViewController:lc animated:YES]; }
- (void)showGuide { FUGuideController *g = [[FUGuideController alloc] init];
    [self.navigationController pushViewController:g animated:YES]; }
- (void)showAppList { FUAppListController *a = [[FUAppListController alloc] init];
    [self.navigationController pushViewController:a animated:YES]; }
@end
