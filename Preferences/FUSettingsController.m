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
static NSString * const kFUURLs        = @"urls";
static NSString * const kFUEnabledApps = @"enabledApps";
static NSString * const kFUPosX        = @"posX";
static NSString * const kFUPosY        = @"posY";
static NSString * const kFUIconSize    = @"iconSize";
static NSString * const kFUIconGap     = @"iconGap";
static const NSInteger kFUMaxEntries   = 16;   // v1.3.0：内环 6 + 外环 10

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
@interface FUUrlEditController : UIViewController <PHPickerViewControllerDelegate, UITextFieldDelegate>
@property (nonatomic, strong) NSMutableArray *entries;
@property (nonatomic, assign) NSInteger index;
@property (nonatomic, strong) UITextField *urlField, *labelField;
@property (nonatomic, strong) UIButton    *iconButton;
@property (nonatomic, strong) NSData      *iconData;
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
    tip.text = @"提示：图标会自动压缩成 120×120 正方形；图标与文字二选一，不填图标则显示上方文字。";
    [scroll addSubview:tip]; y += 44 + 12;

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem]; clear.frame = CGRectMake(pad, y, w, 40);
    [clear setTitle:@"清除图标（用文字显示）" forState:UIControlStateNormal];
    [clear addTarget:self action:@selector(clearIcon) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:clear]; y += 40 + 24; scroll.contentSize = CGSizeMake(self.view.bounds.size.width, y);
    if (_index >= 0) [self prefill];
}
- (void)prefill {
    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUURLs, (__bridge CFStringRef)kFUSuite);
    if (!r) return; NSArray *arr = (__bridge_transfer NSArray *)r;
    if ([arr isKindOfClass:[NSArray class]] && _index < (NSInteger)arr.count) {
        NSDictionary *e = arr[_index];
        _urlField.text = e[kFUEntryURL] ?: @""; NSString *ch = e[kFUEntryChar] ?: @""; NSString *lt = e[kFUEntryLetter] ?: @"";
        _labelField.text = ch.length ? ch : lt;
        _iconData = e[kFUEntryIcon]; [self refreshIcon:_iconData];
    }
}
- (BOOL)textField:(UITextField *)tf shouldChangeCharactersInRange:(NSRange)r replacementString:(NSString *)s {
    if (tf == _labelField) {
        NSString *next = [tf.text stringByReplacingCharactersInRange:r withString:s]; return next.length <= 1;
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
- (void)save {
    NSMutableDictionary *e = [NSMutableDictionary dictionary];
    e[kFUEntryURL] = (_urlField.text.length ? _urlField.text : @"");
    NSString *lab = _labelField.text ?: @"";
    if (lab.length) e[kFUEntryChar] = [lab substringToIndex:1];
    if (_iconData) e[kFUEntryIcon] = _iconData;
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
        @{@"t":@"⑫ 多环快捷菜单", @"c":@"设置→快捷URI 添加入口（内环6+外环10，最多16个）", @"d":@"点球展开三层层叠环：URL 球居中不变；长按环上图标可就地编辑；拖球时整环跟随"},
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
    if (q.length) {
        NSString *l = [q lowercaseString];
        _filtered = [NSMutableArray array];
        for (NSDictionary *d in _allApps) if ([[d[@"name"] lowercaseString] containsString:l] ||
                                             [[d[@"bid"] lowercaseString] containsString:l]) [_filtered addObject:d];
    } else _filtered = [_allApps mutableCopy];
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
        [_search.trailingAnchor constraintEqualToAnchor:all.leadingAnchor constant:-8],
        [all.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-8],
        [all.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [all.widthAnchor constraintEqualToConstant:72],
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
@property (nonatomic, assign) CGFloat posX, posY, iconSize, iconGap;   // posX/posY: 0~100
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
    CGFloat bs = MAX(24.0f, s.size.width * 0.11f);       // 预览里球的直径（对应 40pt 基准）
    CGFloat scale = bs / 40.0f;
    CGFloat isz = _iconSize * scale;
    CGFloat gap = _iconGap * scale;
    CGPoint c = CGPointMake(_posX / 100.0f * s.size.width, _posY / 100.0f * s.size.height);
    CGFloat R1 = bs/2.0f + isz/2.0f + gap;
    CGFloat R2 = R1 + isz + gap;
    // 圈层参考虚线
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.14].CGColor);
    CGContextSetLineWidth(ctx, 1.0f);
    CGContextAddArc(ctx, c.x, c.y, R1, 0, M_PI*2, 0); CGContextStrokePath(ctx);
    CGContextAddArc(ctx, c.x, c.y, R2, 0, M_PI*2, 0); CGContextStrokePath(ctx);
    // 中心球（URL 不变）
    [self fuCircleAt:c size:bs img:nil ch:@"URL" fs:bs*0.24f];
    // 快捷图标：内环 6 + 外环 10（有几条显示几条）
    NSInteger n  = (NSInteger)_entries.count;
    NSInteger n1 = MIN(n, 6), n2 = MIN(MAX(0, n - n1), 10);
    for (NSInteger layer = 0; layer < 2; layer++) {
        NSInteger cnt = (layer == 0) ? n1 : n2;
        if (cnt <= 0) break;
        CGFloat R = (layer == 0) ? R1 : R2;
        CGFloat step = 360.0f / (CGFloat)cnt;
        CGFloat a0 = -90.0f + ((layer == 1) ? step/2.0f : 0.0f);
        for (NSInteger k = 0; k < cnt; k++) {
            NSInteger idx = (layer == 0) ? k : 6 + k;
            if (idx >= n) break;
            NSDictionary *e = _entries[idx];
            CGFloat rad = (a0 + step*(CGFloat)k) * M_PI / 180.0f;
            CGPoint p = CGPointMake(c.x + R*cos(rad), c.y + R*sin(rad));
            NSData *ic = e[@"icon"];
            UIImage *img = ([ic isKindOfClass:[NSData class]] && ic.length) ? [UIImage imageWithData:ic] : nil;
            NSString *ch = e[@"char"] ?: @"";
            [self fuCircleAt:p size:isz img:img ch:ch fs:isz*0.42f];
        }
    }
}
- (void)fuFill:(UIColor *)col rect:(CGRect)r {
    CGContextSetFillColorWithColor(UIGraphicsGetCurrentContext(), col.CGColor);
    CGContextFillRect(UIGraphicsGetCurrentContext(), r);
}
- (void)fuCircleAt:(CGPoint)ctr size:(CGFloat)d img:(UIImage *)img ch:(NSString *)ch fs:(CGFloat)fs {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect r = CGRectMake(ctr.x - d/2.0f, ctr.y - d/2.0f, d, d);
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.20].CGColor);
    CGContextFillEllipseInRect(ctx, r);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.55].CGColor);
    CGContextSetLineWidth(ctx, 1.0f);
    CGContextStrokeEllipseInRect(ctx, r);
    if (img) {
        CGContextSaveGState(ctx);
        UIBezierPath *clip = [UIBezierPath bezierPathWithOvalInRect:r];
        [clip addClip];
        [img drawInRect:r];
        CGContextRestoreGState(ctx);
    } else if (ch.length) {
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter;
        [ch drawInRect:r withAttributes:@{
            NSFontAttributeName: [UIFont boldSystemFontOfSize:fs],
            NSForegroundColorAttributeName: [UIColor whiteColor],
            NSParagraphStyleAttributeName: ps }];
    }
}
@end

#pragma mark - 布局调节器（位置/图标大小/图标间隔 滑杆 + 实时预览，改动即时全局生效）
@interface FULayoutController : UIViewController
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) FUPreviewView *preview;
@property (nonatomic, strong) UISlider *sx, *sy, *ss, *sg;
@property (nonatomic, strong) UILabel *lx, *ly, *ls, *lg;
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
- (void)loadEntriesForPreview {
    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUURLs, (__bridge CFStringRef)kFUSuite);
    NSArray *arr = nil;
    if (r) { arr = (__bridge_transfer NSArray *)r; if (![arr isKindOfClass:[NSArray class]]) arr = nil; }
    _preview.entries = arr ?: @[];
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"布局调节（实时预览）";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"恢复默认"
        style:UIBarButtonItemStylePlain target:self action:@selector(reset)];
    CGFloat w = self.view.bounds.size.width;
    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_scroll];
    __block CGFloat y = 16;
    // ---- 预览画布：按 iPhone 屏比例（≈1:2.16）----
    CGFloat pw = w - 32;
    _preview = [[FUPreviewView alloc] initWithFrame:CGRectMake(16, y, pw, pw * 2.16f)];
    _preview.layer.cornerRadius = 18; _preview.clipsToBounds = YES;
    _preview.posX = [self prefFloat:kFUPosX dft:92];
    _preview.posY = [self prefFloat:kFUPosY dft:45];
    _preview.iconSize = [self prefFloat:kFUIconSize dft:40];
    _preview.iconGap  = [self prefFloat:kFUIconGap dft:56];
    [self loadEntriesForPreview];
    [_scroll addSubview:_preview]; y += _preview.frame.size.height + 6;
    UILabel *pvTip = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w-32, 30)];
    pvTip.numberOfLines = 0; pvTip.font = [UIFont systemFontOfSize:11];
    pvTip.textColor = [UIColor tertiaryLabelColor];
    pvTip.text = @"▲ 实时预览：按你已添加的快捷URI 渲染三层（URL + 内环6 + 外环10）。拖动下方滑杆，预览和手机上的悬浮球都会立刻变化。";
    [pvTip sizeToFit]; [_scroll addSubview:pvTip]; y += pvTip.frame.size.height + 12;
    // ---- 滑杆区 ----
    CGFloat px = [self prefFloat:kFUPosX dft:92], py = [self prefFloat:kFUPosY dft:45];
    CGFloat pis = [self prefFloat:kFUIconSize dft:40], pig = [self prefFloat:kFUIconGap dft:56];
    _sx = [self mkSlider:CGRectMake(16, y, w-32, 52) min:0 max:100 val:px label:@"位置 · 横向" out:&y lout:&_lx];
    _sy = [self mkSlider:CGRectMake(16, y, w-32, 52) min:0 max:100 val:py label:@"位置 · 纵向" out:&y lout:&_ly];
    _ss = [self mkSlider:CGRectMake(16, y, w-32, 52) min:24 max:64 val:pis label:@"图标大小" out:&y lout:&_ls];
    _sg = [self mkSlider:CGRectMake(16, y, w-32, 52) min:12 max:120 val:pig label:@"图标间隔" out:&y lout:&_lg];
    _sx.tag = 0; _sy.tag = 1; _ss.tag = 2; _sg.tag = 3;
    [_sx addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [_sy addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [_ss addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [_sg addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
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
- (void)sliderChanged:(UISlider *)sl {
    CGFloat v = roundf(sl.value);
    NSString *key = nil; UILabel *l = nil; NSString *name = @"";
    switch (sl.tag) {
        case 0: key = kFUPosX; l = _lx; name = @"位置 · 横向"; _preview.posX = v; break;
        case 1: key = kFUPosY; l = _ly; name = @"位置 · 纵向"; _preview.posY = v; break;
        case 2: key = kFUIconSize; l = _ls; name = @"图标大小"; _preview.iconSize = v; break;
        case 3: key = kFUIconGap; l = _lg; name = @"图标间隔"; _preview.iconGap = v; break;
    }
    if (!key) return;
    l.text = [NSString stringWithFormat:@"%@（当前 %.0f）", name, v];
    [self writeFloat:key value:v];
    [_preview refresh];
}
- (void)reset {
    _sx.value = 92; _sy.value = 45; _ss.value = 40; _sg.value = 56;
    _lx.text = @"位置 · 横向（当前 92）"; _ly.text = @"位置 · 纵向（当前 45）";
    _ls.text = @"图标大小（当前 40）"; _lg.text = @"图标间隔（当前 56）";
    _preview.posX = 92; _preview.posY = 45; _preview.iconSize = 40; _preview.iconGap = 56;
    [self writeFloat:kFUPosX value:92]; [self writeFloat:kFUPosY value:45];
    [self writeFloat:kFUIconSize value:40]; [self writeFloat:kFUIconGap value:56];
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
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated];
    notify_post("com.yzdmm.floatingurl/settingsChanged"); }
- (void)manageUrls { FUUrlListController *list = [[FUUrlListController alloc] init];
    [self.navigationController pushViewController:list animated:YES]; }
- (void)showLayout { FULayoutController *lc = [[FULayoutController alloc] init];
    [self.navigationController pushViewController:lc animated:YES]; }
- (void)showGuide { FUGuideController *g = [[FUGuideController alloc] init];
    [self.navigationController pushViewController:g animated:YES]; }
- (void)showAppList { FUAppListController *a = [[FUAppListController alloc] init];
    [self.navigationController pushViewController:a animated:YES]; }
@end
