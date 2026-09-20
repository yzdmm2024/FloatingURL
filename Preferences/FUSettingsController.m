#import <Preferences/Preferences.h>
#import <notify.h>
#import <PhotosUI/PhotosUI.h>

// LSApplicationWorkspace / LSApplicationProxy 为私有 API，运行时可用（设置进程允许）
@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (NSArray *)allApplications;
@end
@interface LSApplicationProxy : NSObject
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, copy) NSString *localizedName;
- (UIImage *)icon;
- (NSData *)iconDataForVariant:(int)v;
@end

static NSString * const kFUSuite        = @"com.yzdmm.floatingurl";
static NSString * const kFUEntryURL    = @"url";
static NSString * const kFUEntryChar   = @"char";
static NSString * const kFUEntryLetter = @"letter";
static NSString * const kFUEntryIcon   = @"icon";
static NSString * const kFUURLs        = @"urls";
static NSString * const kFUEnabledApps = @"enabledApps";
static const NSInteger kFUMaxEntries   = 6;

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
@property (nonatomic, strong) UITextField *urlField, *charField, *letterField;
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
    _charField   = (UITextField *)mkField(@"汉字（1个，如 微）", nil, UIKeyboardTypeDefault);
    _letterField = (UITextField *)mkField(@"字母（1个，如 W）", nil, UIKeyboardTypeDefault);
    _iconButton = [UIButton buttonWithType:UIButtonTypeSystem]; _iconButton.frame = CGRectMake(pad, y, w, 56);
    _iconButton.layer.cornerRadius = 10; _iconButton.layer.borderWidth = 1; _iconButton.layer.borderColor = [UIColor separatorColor].CGColor;
    [_iconButton setTitle:@"选择图标（从相册，方形裁剪）" forState:UIControlStateNormal];
    [_iconButton addTarget:self action:@selector(pickIcon) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:_iconButton]; y += 56 + 12;
    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem]; clear.frame = CGRectMake(pad, y, w, 40);
    [clear setTitle:@"清除图标（用汉字/字母显示）" forState:UIControlStateNormal];
    [clear addTarget:self action:@selector(clearIcon) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:clear]; y += 40 + 24; scroll.contentSize = CGSizeMake(self.view.bounds.size.width, y);
    if (_index >= 0) [self prefill];
}
- (void)prefill {
    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUURLs, (__bridge CFStringRef)kFUSuite);
    if (!r) return; NSArray *arr = (__bridge_transfer NSArray *)r;
    if ([arr isKindOfClass:[NSArray class]] && _index < (NSInteger)arr.count) {
        NSDictionary *e = arr[_index];
        _urlField.text = e[kFUEntryURL] ?: @""; _charField.text = e[kFUEntryChar] ?: @"";
        _letterField.text = e[kFUEntryLetter] ?: @""; _iconData = e[kFUEntryIcon]; [self refreshIcon:_iconData];
    }
}
- (BOOL)textField:(UITextField *)tf shouldChangeCharactersInRange:(NSRange)r replacementString:(NSString *)s {
    if (tf == _charField || tf == _letterField) {
        NSString *next = [tf.text stringByReplacingCharactersInRange:r withString:s]; return next.length <= 1;
    } return YES;
}
- (void)refreshIcon:(NSData *)d {
    UIImage *img = d.length ? [UIImage imageWithData:d] : nil;
    if (img) { [_iconButton setImage:[img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal];
        _iconButton.imageView.contentMode = UIViewContentModeScaleAspectFill; [_iconButton setTitle:nil forState:UIControlStateNormal]; }
    else { [_iconButton setImage:nil forState:UIControlStateNormal];
        [_iconButton setTitle:@"选择图标（从相册，方形裁剪）" forState:UIControlStateNormal]; }
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
    if (_charField.text.length)   e[kFUEntryChar]   = _charField.text;
    if (_letterField.text.length) e[kFUEntryLetter] = _letterField.text;
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
    static NSString *id = @"FUUrlCell"; UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:id];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:id];
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
        @{@"t":@"① 打开网页", @"c":@"https://www.baidu.com", @"d":@"地址栏或扇形入口填网址，点开即加载网页"},
        @{@"t":@"② 跳微信", @"c":@"weixin://", @"d":@"填 weixin:// 直接拉起微信"},
        @{@"t":@"③ 跳支付宝", @"c":@"alipay://", @"d":@"填 alipay:// 拉起支付宝"},
        @{@"t":@"④ 拨号", @"c":@"tel:10086", @"d":@"填 tel:10086 拉起拨号"},
        @{@"t":@"⑤ 发邮件", @"c":@"mailto:a@b.com", @"d":@"填 mailto: 拉起邮件"},
        @{@"t":@"⑥ 打开地图", @"c":@"maps://", @"d":@"填 maps:// 拉起地图"},
        @{@"t":@"⑦ 装插件(Cydia)", @"c":@"cydia://package/com.example.foo", @"d":@"填 cydia://package/包名 拉起 Cydia 装包"},
        @{@"t":@"⑧ 装插件(Sileo)", @"c":@"sileo://package/com.example.foo", @"d":@"填 sileo://package/包名 拉起 Sileo 装包"},
        @{@"t":@"⑨ 打开本地文件", @"c":@"file:///var/mobile/Containers/...", @"d":@"填 file:// 路径打开本地文件"},
        @{@"t":@"⑩ 如何获取URL", @"c":@"在 Safari 打开网页→分享→拷贝 即可得到网址", @"d":@"长按网页链接也可拷贝；把链接粘到地址栏/扇形入口即可"},
        @{@"t":@"⑪ 扇形菜单", @"c":@"设置→快捷URI 添加多个入口，点球展开扇形", @"d":@"球在右扇形朝左、球在左扇形朝右；长按扇形图标可就地编辑"},
    ];
    _tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.delegate = self; _tv.dataSource = self; [self.view addSubview:_tv];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
    [_tv addGestureRecognizer:lp];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _items.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *id = @"FUGuideCell"; UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:id];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:id];
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

#pragma mark - 作用 App 列表（搜索 + 全选一行；图标 + 名字）
@interface FUAppListController : UIViewController <UITableViewDelegate, UITableViewDataSource,
                                                    UISearchBarDelegate>
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) NSMutableArray *allApps;     // {bid, name, icon}
@property (nonatomic, strong) NSMutableArray *filtered;
@property (nonatomic, strong) NSMutableArray *selected;    // bundle ids
@property (nonatomic, strong) UISearchBar *search;
@end
@implementation FUAppListController
- (void)loadApps {
    _allApps = [NSMutableArray array]; _selected = [NSMutableArray array];
    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)kFUEnabledApps, (__bridge CFStringRef)kFUSuite);
    if (r) { NSArray *a = (__bridge_transfer NSArray *)r; if ([a isKindOfClass:[NSArray class]]) [_selected addObjectsFromArray:a]; }
    LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
    if (ws) {
        NSArray *apps = [ws allApplications];
        for (LSApplicationProxy *p in apps) {
            NSString *bid = p.bundleIdentifier; if (!bid.length) continue;
            if ([bid isEqualToString:@"com.apple.Preferences"]) continue;
            UIImage *icon = nil;
            if ([p respondsToSelector:@selector(icon)]) icon = [p icon];
            if (!icon && [p respondsToSelector:@selector(iconDataForVariant:)]) {
                NSData *d = [p iconDataForVariant:2]; if (d) icon = [UIImage imageWithData:d];
            }
            [_allApps addObject:@{@"bid":bid, @"name":(p.localizedName ?: bid), @"icon":(icon ?: [NSNull null])}];
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
    [_tv reloadData];
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"作用 App";
    // 顶部：搜索 + 全选 一行
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 56)];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth; bar.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _search = [[UISearchBar alloc] initWithFrame:CGRectMake(8, 8, self.view.bounds.size.width - 8 - 88, 40)];
    _search.placeholder = @"搜索 App"; _search.delegate = self; [bar addSubview:_search];
    UIButton *all = [UIButton buttonWithType:UIButtonTypeSystem];
    all.frame = CGRectMake(self.view.bounds.size.width - 80, 8, 72, 40);
    all.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [all setTitle:@"全选" forState:UIControlStateNormal]; all.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [all addTarget:self action:@selector(toggleAll) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:all];
    _tv = [[UITableView alloc] initWithFrame:CGRectMake(0, 56, self.view.bounds.size.width, self.view.bounds.size.height - 56)
                                       style:UITableViewStylePlain];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.delegate = self; _tv.dataSource = self;
    [self.view addSubview:bar]; [self.view addSubview:_tv];
    [self loadApps];
}
- (void)toggleAll {
    BOOL allSel = YES;
    for (NSDictionary *d in _filtered) if (![_selected containsObject:d[@"bid"]]) { allSel = NO; break; }
    for (NSDictionary *d in _filtered) {
        if (allSel) [_selected removeObject:d[@"bid"]]; else if (![_selected containsObject:d[@"bid"]]) [_selected addObject:d[@"bid"]];
    }
    [self save]; [_tv reloadData];
}
- (void)save {
    CFPreferencesSetAppValue((__bridge CFStringRef)kFUEnabledApps, (__bridge CFPropertyListRef)[_selected copy],
        (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    // 作用 App 列表改动在对应 App 重启后生效（tweak 在进程启动时读取）
}
- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)t { [self applyFilter:t]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _filtered.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *id = @"FUAppCell"; UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:id];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:id];
    NSDictionary *d = _filtered[ip.row];
    c.textLabel.text = d[@"name"]; c.detailTextLabel.text = d[@"bid"]; c.detailTextLabel.font = [UIFont systemFontOfSize:10];
    id ic = d[@"icon"]; c.imageView.image = (ic && ic != [NSNull null]) ? ic : nil;
    c.accessoryType = [_selected containsObject:d[@"bid"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *d = _filtered[ip.row];
    if ([_selected containsObject:d[@"bid"]]) [_selected removeObject:d[@"bid"]];
    else [_selected addObject:d[@"bid"]];
    [self save]; [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
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
- (void)showGuide { FUGuideController *g = [[FUGuideController alloc] init];
    [self.navigationController pushViewController:g animated:YES]; }
- (void)showAppList { FUAppListController *a = [[FUAppListController alloc] init];
    [self.navigationController pushViewController:a animated:YES]; }
@end
