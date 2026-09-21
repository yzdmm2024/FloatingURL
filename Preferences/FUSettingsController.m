#import <Preferences/Preferences.h>
#import <notify.h>
#import <PhotosUI/PhotosUI.h>

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
static NSString * const kFUBallIcon    = @"ballIcon";   // v1.3.5 球的图标（PNG data）
static NSString * const kFUBallColor   = @"ballColor";  // v1.3.5 球的底色 hex
static const NSInteger kFUMaxEntries   = 48;   // v1.3.6：上限 48（三层默认 8/16/24）
static const NSInteger kFULayer1Max    = 4;    // 第一层（内环）最多 4 个
static const NSInteger kFULayer2Max    = 6;    // 第二层（外环）最多 6 个

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
@interface FUCropVC : UIViewController <UIScrollViewDelegate>
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, copy)   void (^onCropped)(NSData *png);
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIImageView  *imgView;
@end
@implementation FUCropVC
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = [UIColor blackColor]; self.title = @"调整裁剪";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"确定"
        style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消"
        style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.delegate = self; _scroll.bounces = NO; _scroll.backgroundColor = [UIColor blackColor];
    [self.view addSubview:_scroll];
    _imgView = [[UIImageView alloc] initWithImage:_image]; _imgView.contentMode = UIViewContentModeScaleAspectFit;
    [_scroll addSubview:_imgView];
    CGFloat side = MIN(self.view.bounds.size.width, self.view.bounds.size.height) - 40;
    CGFloat z = side / MIN(_image.size.width, _image.size.height);
    _scroll.minimumZoomScale = z * 0.5; _scroll.maximumZoomScale = z * 4.0; _scroll.zoomScale = z;
    [self layoutContent]; [self centerContent];
}
- (void)layoutContent {
    CGFloat z = _scroll.zoomScale; CGSize s = CGSizeMake(_image.size.width * z, _image.size.height * z);
    _imgView.frame = CGRectMake(0, 0, s.width, s.height); _scroll.contentSize = s;
}
- (void)centerContent {
    CGFloat side = MIN(self.view.bounds.size.width, self.view.bounds.size.height) - 40;
    _scroll.contentOffset = CGPointMake(MAX(0, (_scroll.contentSize.width - side)/2.0),
                                        MAX(0, (_scroll.contentSize.height - side)/2.0));
}
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)sv { return _imgView; }
- (void)scrollViewDidZoom:(UIScrollView *)sv { [self centerContent]; }
- (void)done {
    CGFloat side = MIN(self.view.bounds.size.width, self.view.bounds.size.height) - 40;
    CGFloat z = _scroll.zoomScale;
    CGRect imgRect = CGRectMake(_scroll.contentOffset.x / z, _scroll.contentOffset.y / z, side / z, side / z);
    CGImageRef cg = CGImageCreateWithImageInRect(_image.CGImage, imgRect);
    UIImage *sq = cg ? [UIImage imageWithCGImage:cg] : nil; if (cg) CGImageRelease(cg);
    NSData *out = nil;
    if (sq) {
        CGFloat max = 120.0; CGFloat s = MIN(1.0, max / MAX(sq.size.width, sq.size.height));
        CGSize ts = CGSizeMake(sq.size.width * s, sq.size.height * s);
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
    _urlField    = (UITextField *)mkField(@"网址 / scheme（如 https://a.com 或 weixin://）", nil, UIKeyboardTypeURL);

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
@property (nonatomic, strong) UIButton    *iconButton;
@property (nonatomic, strong) NSData      *iconData;
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
    CFPropertyListRef bi = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUBallIcon, (__bridge CFStringRef)kFUSuite);
    if (bi) { _iconData = (__bridge_transfer NSData *)bi; if (![_iconData isKindOfClass:[NSData class]]) _iconData = nil; }
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
    // 图标
    UILabel *il = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w, 18)];
    il.font = [UIFont systemFontOfSize:12]; il.textColor = [UIColor secondaryLabelColor];
    il.text = @"悬浮球图标（从相册选取，方形裁剪；设了图标就盖住文字）"; [scroll addSubview:il]; y += 22;
    CGFloat sq = 150;
    _iconButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _iconButton.frame = CGRectMake((w - sq)/2.0 + pad, y, sq, sq);
    _iconButton.layer.cornerRadius = 14; _iconButton.layer.borderWidth = 1.5;
    _iconButton.layer.borderColor = [UIColor separatorColor].CGColor; _iconButton.clipsToBounds = YES;
    _iconButton.titleLabel.textAlignment = NSTextAlignmentCenter;
    _iconButton.titleLabel.numberOfLines = 0; _iconButton.titleLabel.font = [UIFont systemFontOfSize:13];
    [_iconButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    [_iconButton addTarget:self action:@selector(pickIcon) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:_iconButton]; y += sq + 8;
    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.frame = CGRectMake(pad, y, w, 40);
    [clear setTitle:@"清除图标（用名称/底色显示）" forState:UIControlStateNormal];
    [clear addTarget:self action:@selector(clearIcon) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:clear]; y += 40 + 16;
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
    [self refreshIcon:_iconData]; [self refreshColor];
}
- (BOOL)textField:(UITextField *)tf shouldChangeCharactersInRange:(NSRange)r replacementString:(NSString *)s {
    if (tf == _nameField) {
        NSString *next = [tf.text stringByReplacingCharactersInRange:r withString:s];
        if (next.length > 8) return NO;
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
    NSString *t = _nameField.text ?: @"";
    if (t.length) CFPreferencesSetAppValue((__bridge CFStringRef)kFUBallTitle,
        (__bridge CFPropertyListRef)t, (__bridge CFStringRef)kFUSuite);
    else CFPreferencesSetAppValue((__bridge CFStringRef)kFUBallTitle,
        (__bridge CFPropertyListRef)@"URL", (__bridge CFStringRef)kFUSuite);
    if (_iconData) CFPreferencesSetAppValue((__bridge CFStringRef)kFUBallIcon,
        (__bridge CFPropertyListRef)_iconData, (__bridge CFStringRef)kFUSuite);
    else CFPreferencesSetAppValue((__bridge CFStringRef)kFUBallIcon, NULL, (__bridge CFStringRef)kFUSuite);
    if (_colorHex.length) CFPreferencesSetAppValue((__bridge CFStringRef)kFUBallColor,
        (__bridge CFPropertyListRef)_colorHex, (__bridge CFStringRef)kFUSuite);
    else CFPreferencesSetAppValue((__bridge CFStringRef)kFUBallColor, NULL, (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    notify_post("com.yzdmm.floatingurl/settingsChanged");
    [self.navigationController popViewControllerAnimated:YES];
}
- (void)cancel { [self.navigationController popViewControllerAnimated:YES]; }
@end

#pragma mark - URI 列表控制器
@interface FUUrlListController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSMutableArray *entries;
@property (nonatomic, strong) UITableView *tv;
@end
@implementation FUUrlListController
- (void)loadEntries {
    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUURLs, (__bridge CFStringRef)kFUSuite);
    NSArray *arr = nil; if (r) { arr = (__bridge_transfer NSArray *)r; if (![arr isKindOfClass:[NSArray class]]) arr = nil; }
    _entries = arr.count ? [arr mutableCopy] : [NSMutableArray array];
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"快捷URI"; [self loadEntries];
    _tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.delegate = self; _tv.dataSource = self; [self.view addSubview:_tv];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:[NSString stringWithFormat:@"添加(%lu/%ld)", (unsigned long)_entries.count, (long)kFUMaxEntries]
                style:UIBarButtonItemStylePlain target:self action:@selector(addEntry)];
    self.navigationItem.rightBarButtonItem.enabled = (_entries.count < kFUMaxEntries);
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; [self loadEntries];
    self.navigationItem.rightBarButtonItem.enabled = (_entries.count < kFUMaxEntries); [_tv reloadData];
}
- (void)addEntry {
    FUUrlEditController *ed = [[FUUrlEditController alloc] init]; ed.entries = _entries; ed.index = -1;
    [self.navigationController pushViewController:ed animated:YES];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _entries.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cellId = @"FUUrlCell"; UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cellId];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    NSDictionary *e = _entries[ip.row];
    c.textLabel.text = [NSString stringWithFormat:@"%@ %@  %@", e[kFUEntryChar] ?: @"", e[kFUEntryLetter] ?: @"", e[kFUEntryURL] ?: @""];
    c.textLabel.font = [UIFont systemFontOfSize:13]; c.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    c.detailTextLabel.text = e[kFUEntryURL] ?: @""; c.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSData *icon = e[kFUEntryIcon]; c.imageView.image = icon.length ? [UIImage imageWithData:icon] : nil;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    FUUrlEditController *ed = [[FUUrlEditController alloc] init]; ed.entries = _entries; ed.index = ip.row;
    [self.navigationController pushViewController:ed animated:YES];
}
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)st forRowAtIndexPath:(NSIndexPath *)ip {
    if (st == UITableViewCellEditingStyleDelete) {
        [_entries removeObjectAtIndex:ip.row];
        CFPreferencesSetAppValue((__bridge CFStringRef)kFUURLs, (__bridge CFPropertyListRef)_entries, (__bridge CFStringRef)kFUSuite);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
        notify_post("com.yzdmm.floatingurl/settingsChanged");
        [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationFade];
        self.navigationItem.rightBarButtonItem.enabled = (_entries.count < kFUMaxEntries);
    }
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
        @{@"t":@"㉓ 工作门户", @"c":@"把公司 OA / 项目系统网址设为主 URL", @"d":@"悬浮球一键直达工作台，配合窗口大小调节当小窗浏览器用"},
        @{@"t":@"㉔ 直播监控", @"c":@"监控摄像头/直播流的 http 网页地址", @"d":@"点开即小窗看画面，拖动+双指缩放随意摆位"},
        @{@"t":@"㉕ 查快递", @"c":@"快递查询网页 + 运单号参数", @"d":@"常用查件页设成快捷入口，收件高峰一键查"},
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
    NSInteger n = (NSInteger)_entries.count;
    // v1.3.3：每层数量可指定（0=自动），与 tweak 内 openFan 同套逻辑
    NSInteger want[3] = { _layer1, _layer2, _layer3 };
    NSInteger caps[3] = { 0, 0, 0 };
    NSInteger placed = 0;
    for (int i = 0; i < 3; i++) {
        if (want[i] > 0) {
            NSInteger c2 = MIN(want[i], n - placed);
            if (c2 > 0) { caps[i] = c2; placed += c2; }
        }
    }
    CGFloat spanMax = MAX(60.0f, MIN(180.0f, (_span > 0 ? _span : 180.0f)));
    NSInteger li = 0;
    while (placed < n) {
        NSInteger target = -1;
        for (int i = li; i < 3; i++) { if (want[i] == 0) { target = i; break; } }
        if (target < 0) target = 2;
        CGFloat arc = R[target] * spanMax * (CGFloat)M_PI / 180.0f;
        NSInteger autoCap = MAX(1, (NSInteger)floor(arc / (isz + gap)));
        if (autoCap > 8) autoCap = 8;
        NSInteger space = n - placed;
        NSInteger add = MIN(autoCap, space);
        caps[target] += add; placed += add;
        li = target + 1;
        if (li >= 3 && placed < n) { caps[2] += (n - placed); placed = n; }
    }
    CGFloat centerA = (_side != 1) ? 180.0f : 0.0f;    // 屏坐标：0°右 90°下 180°左 270°上
    CGFloat span = spanMax;                             // v1.3.3：预览用满角度（贴边平移在真机处理）
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
    for (NSInteger layer = 0; layer < 3; layer++) {
        NSInteger cnt = caps[layer]; if (cnt <= 0) continue;
        CGFloat a0 = centerA - span/2.0f, sp2 = (cnt > 1) ? span/(CGFloat)(cnt-1) : 0.0f;
        for (NSInteger i2 = 0; i2 < cnt; i2++) {
            if (placed >= n) break;
            NSDictionary *e = _entries[placed]; placed++;
            CGFloat a = (cnt > 1) ? (a0 + sp2*(CGFloat)i2) : centerA;
            CGFloat rad = a * M_PI / 180.0;
            CGPoint p = CGPointMake(c.x + R[layer]*cos(rad), c.y + R[layer]*sin(rad));
            NSData *ic = e[@"icon"];
            UIImage *img = ([ic isKindOfClass:[NSData class]] && ic.length) ? [UIImage imageWithData:ic] : nil;
            NSString *ch = e[@"char"] ?: @"";
            CGFloat fs = isz * 0.42f; if (ch.length >= 3) fs = isz * 0.26f; else if (ch.length == 2) fs = isz * 0.32f;
            [self fuCircleAt:p size:isz img:img ch:ch fs:fs glass:NO];
        }
    }
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
@property (nonatomic, strong) UISlider *modeS;                 // v1.3.5 吸附模式（0=自动吸附 1=全屏固定）
@property (nonatomic, strong) UILabel *lmode;                  // v1.3.5 模式说明
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
    CGFloat w = self.view.bounds.size.width;
    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_scroll];
    __block CGFloat y = 16;
    // ---- 预览画布（仅展示扇形排列，尺寸缩小）----
    CGFloat pw = w - 32;
    _preview = [[FUPreviewView alloc] initWithFrame:CGRectMake(16, y, pw, pw * 1.5f)];
    _preview.layer.cornerRadius = 18; _preview.clipsToBounds = YES;
    _preview.side     = (NSInteger)[self prefFloat:kFUSide dft:0];
    _preview.iconSize = [self prefFloat:kFUIconSize dft:40];
    _preview.iconGap  = [self prefFloat:kFUIconGap dft:56];
    _preview.span     = [self prefFloat:kFUFanSpan dft:180];
    _preview.scale    = [self prefFloat:kFUFanScale dft:100];
    _preview.layer1   = [self prefInt:kFULayer1Count dft:8];
    _preview.layer2   = [self prefInt:kFULayer2Count dft:16];
    _preview.layer3   = [self prefInt:kFULayer3Count dft:24];
    [self loadEntriesForPreview];
    [_scroll addSubview:_preview]; y += _preview.frame.size.height + 6;
    UILabel *pvTip = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w-32, 30)];
    pvTip.numberOfLines = 0; pvTip.font = [UIFont systemFontOfSize:11];
    pvTip.textColor = [UIColor tertiaryLabelColor];
    pvTip.text = @"▲ 实时预览：虚线 = 屏幕中心线。球在中心线左边 → 自动吸左边、扇形朝右展开；在右边 → 吸右边、扇形朝左展开。每层数量可单独设定（0=自动）。";
    [pvTip sizeToFit]; [_scroll addSubview:pvTip]; y += pvTip.frame.size.height + 16;
    // ---- v1.3.5 修 02：吸附模式（滑动选择，滑到哪个就是哪个模式）----
    _lmode = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w-32, 20)];
    _lmode.font = [UIFont systemFontOfSize:12]; _lmode.textColor = [UIColor secondaryLabelColor];
    [_scroll addSubview:_lmode]; y += 22;
    _modeS = [[UISlider alloc] initWithFrame:CGRectMake(16, y, w-32, 30)];
    _modeS.minimumValue = 0; _modeS.maximumValue = 1;
    _modeS.value = ([self prefInt:kFUSnapMode dft:0] == 1) ? 1.0f : 0.0f;
    _modeS.continuous = NO; _modeS.tag = 9;
    [_modeS addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [_scroll addSubview:_modeS]; y += 36;
    [self refreshModeLabel];
    // ---- v1.3.5 修 03：真实运行时按「屏幕中心线」自动识别左右；这里只切换预览画哪一侧 ----
    UILabel *sideLab = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w-32, 20)];
    sideLab.font = [UIFont systemFontOfSize:12]; sideLab.textColor = [UIColor secondaryLabelColor];
    sideLab.text = @"预览方位（真实运行时按屏幕中心线自动识别左右）";
    [_scroll addSubview:sideLab]; y += 24;
    _sideSeg = [[UISegmentedControl alloc] initWithItems:@[@"球在右侧", @"球在左侧"]];
    _sideSeg.frame = CGRectMake(16, y, w-32, 32);
    CGFloat pbx = [self prefFloat:kFUBallX dft:0.92f];
    _sideSeg.selectedSegmentIndex = (pbx < 0.5f) ? 1 : 0;   // 跟随球当前实际位置
    _preview.side = _sideSeg.selectedSegmentIndex;
    [_sideSeg addTarget:self action:@selector(sideChanged:) forControlEvents:UIControlEventValueChanged];
    [_scroll addSubview:_sideSeg]; y += 44;
    // ---- 滑杆：图标大小 / 间隔 / 扇形角度 / 整体距离 ----
    y += 4;
    CGFloat pis = [self prefFloat:kFUIconSize dft:40], pig = [self prefFloat:kFUIconGap dft:56];
    CGFloat psp = [self prefFloat:kFUFanSpan dft:180], psc = [self prefFloat:kFUFanScale dft:100];
    _ss = [self mkSlider:CGRectMake(16, y, w-32, 52) min:24 max:64 val:pis label:@"图标大小" out:&y lout:&_ls];
    _sg = [self mkSlider:CGRectMake(16, y, w-32, 52) min:12 max:120 val:pig label:@"图标间隔" out:&y lout:&_lg];
    _span = [self mkSlider:CGRectMake(16, y, w-32, 52) min:60 max:180 val:psp label:@"扇形角度°" out:&y lout:&_lspan];
    _sc = [self mkSlider:CGRectMake(16, y, w-32, 52) min:60 max:160 val:psc label:@"整体距离%" out:&y lout:&_lsc];
    _ss.tag = 2; _sg.tag = 3; _span.tag = 4; _sc.tag = 5;
    for (UISlider *sl in @[_ss, _sg, _span, _sc])
        [sl addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    y += 8;
    // ---- v1.3.3：每层数量（0=自动）----
    UILabel *lLab = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w-32, 20)];
    lLab.font = [UIFont systemFontOfSize:12]; lLab.textColor = [UIColor secondaryLabelColor];
    lLab.text = @"每层数量（默认 8 / 16 / 24，合计最多 48；拖到 0 = 该层自动按弧长排）";
    [_scroll addSubview:lLab]; y += 24;
    NSInteger pl1 = [self prefInt:kFULayer1Count dft:8], pl2 = [self prefInt:kFULayer2Count dft:16], pl3 = [self prefInt:kFULayer3Count dft:24];
    _l1s = [self mkSlider:CGRectMake(16, y, w-32, 52) min:0 max:8  val:pl1 label:@"第一层数量" out:&y lout:&_ll1];
    _l2s = [self mkSlider:CGRectMake(16, y, w-32, 52) min:0 max:16 val:pl2 label:@"第二层数量" out:&y lout:&_ll2];
    _l3s = [self mkSlider:CGRectMake(16, y, w-32, 52) min:0 max:24 val:pl3 label:@"第三层数量" out:&y lout:&_ll3];
    _l1s.tag = 6; _l2s.tag = 7; _l3s.tag = 8;
    for (UISlider *sl in @[_l1s, _l2s, _l3s])
        [sl addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    y += 12; _scroll.contentSize = CGSizeMake(w, y);
}
- (UISlider *)mkSlider:(CGRect)f min:(CGFloat)mn max:(CGFloat)mx val:(CGFloat)v
                label:(NSString *)lab out:(CGFloat *)y lout:(UILabel * __strong *)lout {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, f.origin.y, f.size.width, 20)];
    l.font = [UIFont systemFontOfSize:12]; l.textColor = [UIColor secondaryLabelColor];
    l.text = [NSString stringWithFormat:@"%@（当前 %.0f）", lab, v];
    [_scroll addSubview:l]; *lout = l;
    UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(16, f.origin.y + 22, f.size.width, 30)];
    sl.minimumValue = mn; sl.maximumValue = mx; sl.value = v;
    [_scroll addSubview:sl];
    *y = f.origin.y + 22 + 34 + 6;
    return sl;
}
// v1.3.5 修 03：这里只切「预览画哪一侧」（真实运行时球在哪半边就自动按哪半边算，
// 右侧→扇形朝左展开，左侧→扇形朝右展开），不再写死一个 side 设置。
- (void)sideChanged:(UISegmentedControl *)seg {
    _preview.side = seg.selectedSegmentIndex;   // 0=球在右 1=球在左
    [_preview refresh];
}
- (void)refreshModeLabel {
    BOOL fix = (_modeS && _modeS.value >= 0.5f);
    if (_lmode) _lmode.text = fix ? @"吸附模式：全屏固定（松手停在哪就停哪，不自动吸附）"
                                  : @"吸附模式：自动吸附（按屏幕中心线：左半屏吸左、右半屏吸右）";
}
- (void)sliderChanged:(UISlider *)sl {
    CGFloat v = roundf(sl.value);
    NSString *key = nil; UILabel *l = nil; NSString *name = @"";
    switch (sl.tag) {
        case 2: key = kFUIconSize; l = _ls; name = @"图标大小"; _preview.iconSize = v; break;
        case 3: key = kFUIconGap;  l = _lg; name = @"图标间隔"; _preview.iconGap = v; break;
        case 4: key = kFUFanSpan;  l = _lspan; name = @"扇形角度°"; _preview.span = v; break;
        case 5: key = kFUFanScale; l = _lsc; name = @"整体距离%"; _preview.scale = v; break;
        case 6: key = kFULayer1Count; l = _ll1; name = @"第一层数量"; _preview.layer1 = (NSInteger)v; break;
        case 7: key = kFULayer2Count; l = _ll2; name = @"第二层数量"; _preview.layer2 = (NSInteger)v; break;
        case 8: key = kFULayer3Count; l = _ll3; name = @"第三层数量"; _preview.layer3 = (NSInteger)v; break;
        case 9:
            [self writeInt:kFUSnapMode value:(v >= 1.0f ? 1 : 0)];
            [self refreshModeLabel];
            return;
    }
    if (!key) return;
    l.text = [NSString stringWithFormat:@"%@（当前 %.0f）", name, v];
    if (sl.tag >= 6) [self writeInt:key value:(NSInteger)v];
    else [self writeFloat:key value:v];
    [_preview refresh];
}
- (void)reset {
    _sideSeg.selectedSegmentIndex = 0; _modeS.value = 0; [self refreshModeLabel];
    _ss.value = 40; _sg.value = 56; _span.value = 180; _sc.value = 100;
    _l1s.value = 8; _l2s.value = 16; _l3s.value = 24;
    _ls.text = @"图标大小（当前 40）"; _lg.text = @"图标间隔（当前 56）";
    _lspan.text = @"扇形角度°（当前 180）"; _lsc.text = @"整体距离%（当前 100）";
    _ll1.text = @"第一层数量（当前 8）"; _ll2.text = @"第二层数量（当前 16）"; _ll3.text = @"第三层数量（当前 24）";
    _preview.side = 0; _preview.iconSize = 40; _preview.iconGap = 56;
    _preview.span = 180; _preview.scale = 100;
    _preview.layer1 = 8; _preview.layer2 = 16; _preview.layer3 = 24;
    [self writeInt:kFUSnapMode value:0];
    [self writeFloat:kFUIconSize value:40]; [self writeFloat:kFUIconGap value:56];
    [self writeFloat:kFUFanSpan value:180]; [self writeFloat:kFUFanScale value:100];
    [self writeInt:kFULayer1Count value:8]; [self writeInt:kFULayer2Count value:16]; [self writeInt:kFULayer3Count value:24];
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
// v1.3.3：静默模式开关回调。旗标文件存在=开（App 跳过心跳、桌面球休眠）。
// 不依赖偏好位时序：直接翻转旗标文件当前状态，保证开关与实际一致。
- (void)setSilent:(id)sender {
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Media/FloatingURL_silent"];
    if (exists) [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/Media/FloatingURL_silent" error:nil];
    else        [@"" writeToFile:@"/var/mobile/Media/FloatingURL_silent" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    CFPreferencesSetAppValue((__bridge CFStringRef)kFUSilent, (__bridge CFPropertyListRef)@(!exists), (__bridge CFStringRef)kFUSuite);
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
