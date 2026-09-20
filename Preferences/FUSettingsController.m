#import <Preferences/Preferences.h>
#import <notify.h>
#import <PhotosUI/PhotosUI.h>

static NSString * const kFUSuite        = @"com.yzdmm.floatingurl";
static NSString * const kFUEntryURL    = @"url";
static NSString * const kFUEntryChar   = @"char";
static NSString * const kFUEntryLetter = @"letter";
static NSString * const kFUEntryIcon   = @"icon";
static const NSInteger kFUMaxEntries   = 6;

#pragma mark - 编辑单条 URI 的控制器

@interface FUUrlEditController : UIViewController <PHPickerViewControllerDelegate, UITextFieldDelegate>
@property (nonatomic, strong) NSMutableArray *entries;   // 共享的条目数组（同一引用）
@property (nonatomic, assign) NSInteger index;           // 编辑的下标
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UITextField *charField;
@property (nonatomic, strong) UITextField *letterField;
@property (nonatomic, strong) UIButton    *iconButton;
@end

@implementation FUUrlEditController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = (_index >= 0 && _index < (NSInteger)_entries.count) ? @"编辑URI" : @"新增URI";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(save)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(cancel)];

    __block CGFloat y = 20;
    CGFloat pad = 16, w = self.view.bounds.size.width - pad*2, h = 40;
    UIView * (^mkField)(NSString *, NSString *, UIKeyboardType) = ^UIView *(NSString *ph, NSString *val, UIKeyboardType kt){
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(pad, y, w, h)];
        tf.placeholder = ph; tf.text = val; tf.borderStyle = UITextBorderStyleRoundedRect;
        tf.keyboardType = kt; tf.font = [UIFont systemFontOfSize:14];
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.delegate = self;
        y += h + 12;
        [self.view addSubview:tf];
        return tf;
    };
    _urlField    = (UITextField *)mkField(@"网址 / scheme（如 https://a.com 或 weixin://）", nil, UIKeyboardTypeURL);
    _charField   = (UITextField *)mkField(@"汉字（1个，如 微）", nil, UIKeyboardTypeDefault);
    _letterField = (UITextField *)mkField(@"字母（1个，如 W）", nil, UIKeyboardTypeDefault);

    // 图标选择按钮
    _iconButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _iconButton.frame = CGRectMake(pad, y, w, 56);
    _iconButton.layer.cornerRadius = 10;
    _iconButton.layer.borderWidth = 1;
    _iconButton.layer.borderColor = [UIColor separatorColor].CGColor;
    [_iconButton setTitle:@"选择图标（从相册）" forState:UIControlStateNormal];
    [_iconButton addTarget:self action:@selector(pickIcon) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_iconButton];
    y += 56 + 12;

    // 清除图标
    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.frame = CGRectMake(pad, y, w, 40);
    [clear setTitle:@"清除图标（用汉字/字母显示）" forState:UIControlStateNormal];
    [clear addTarget:self action:@selector(clearIcon) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:clear];

    // 预填当前条目
    if (_index >= 0 && _index < (NSInteger)_entries.count) {
        NSDictionary *e = _entries[_index];
        _urlField.text    = e[kFUEntryURL] ?: @"";
        _charField.text   = e[kFUEntryChar] ?: @"";
        _letterField.text = e[kFUEntryLetter] ?: @"";
        [self refreshIconButton:e[kFUEntryIcon]];
    }
}

- (BOOL)textField:(UITextField *)tf shouldChangeCharactersInRange:(NSRange)r replacementString:(NSString *)s {
    // 汉字/字母字段限制 1 个字符
    if (tf == _charField || tf == _letterField) {
        NSString *next = [tf.text stringByReplacingCharactersInRange:r withString:s];
        return next.length <= 1;
    }
    return YES;
}

- (void)refreshIconButton:(NSData *)icon {
    UIImage *img = icon.length ? [UIImage imageWithData:icon] : nil;
    if (img) {
        [_iconButton setImage:[img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
                     forState:UIControlStateNormal];
        _iconButton.imageView.contentMode = UIViewContentModeScaleAspectFill;
        _iconButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
        [_iconButton setTitle:nil forState:UIControlStateNormal];
    } else {
        [_iconButton setImage:nil forState:UIControlStateNormal];
        [_iconButton setTitle:@"选择图标（从相册）" forState:UIControlStateNormal];
    }
}

- (void)pickIcon {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.selectionLimit = 1;
    cfg.filter = [PHPickerFilter imagesFilter];
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;
    [results.firstObject.itemProvider loadObjectOfClass:[UIImage class]
                                 completionHandler:^(__kindof id obj, NSError *err){
        if ([obj isKindOfClass:[UIImage class]]) {
            NSData *d = [self compressImage:obj];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.index >= 0 && self.index < (NSInteger)self.entries.count) {
                    NSMutableDictionary *e = [self.entries[self.index] mutableCopy];
                    if (d) e[kFUEntryIcon] = d; else [e removeObjectForKey:kFUEntryIcon];
                    self.entries[self.index] = e;
                }
                [self refreshIconButton:d];
            });
        }
    }];
}

- (NSData *)compressImage:(UIImage *)image {
    CGFloat max = 120.0;
    CGFloat scale = MIN(1.0, max / MAX(image.size.width, image.size.height));
    CGSize s = CGSizeMake(image.size.width * scale, image.size.height * scale);
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:s];
    UIImage *small = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx){
        [image drawInRect:CGRectMake(0, 0, s.width, s.height)];
    }];
    return UIImagePNGRepresentation(small);
}

- (void)clearIcon {
    if (_index >= 0 && _index < (NSInteger)_entries.count) {
        NSMutableDictionary *e = [_entries[_index] mutableCopy];
        [e removeObjectForKey:kFUEntryIcon];
        _entries[_index] = e;
    }
    [self refreshIconButton:nil];
}

- (void)save {
    NSMutableDictionary *e = [NSMutableDictionary dictionary];
    e[kFUEntryURL] = (_urlField.text.length ? _urlField.text : @"");
    if (_charField.text.length)   e[kFUEntryChar]   = _charField.text;
    if (_letterField.text.length) e[kFUEntryLetter] = _letterField.text;
    if (_index >= 0 && _index < (NSInteger)_entries.count) {
        NSDictionary *old = _entries[_index];
        if (old[kFUEntryIcon]) e[kFUEntryIcon] = old[kFUEntryIcon];
        _entries[_index] = e;
    } else {
        if (_entries.count >= kFUMaxEntries) {
            [self cancel]; return;
        }
        [_entries addObject:e];
    }
    [self writeEntries];
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)cancel { [self.navigationController popViewControllerAnimated:YES]; }

- (void)writeEntries {
    CFPreferencesSetAppValue((__bridge CFStringRef)@"urls",
        (__bridge CFPropertyListRef)_entries, (__bridge CFStringRef)kFUSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
    notify_post("com.yzdmm.floatingurl/settingsChanged");
}

@end

#pragma mark - URI 列表控制器

@interface FUUrlListController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSMutableArray *entries;
@property (nonatomic, strong) UITableView *tv;
@end

@implementation FUUrlListController

- (void)loadEntries {
    CFPropertyListRef r = CFPreferencesCopyAppValue((__bridge CFStringRef)@"urls",
                                (__bridge CFStringRef)kFUSuite);
    NSArray *arr = nil;
    if (r) { arr = (__bridge_transfer NSArray *)r; if (![arr isKindOfClass:[NSArray class]]) arr = nil; }
    _entries = arr.count ? [arr mutableCopy] : [NSMutableArray array];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"快捷URI";
    [self loadEntries];
    _tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.delegate = self; _tv.dataSource = self;
    [self.view addSubview:_tv];

    if (_entries.count < kFUMaxEntries) {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                         target:self action:@selector(addEntry)];
    }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:[NSString stringWithFormat:@"添加(%lu/%ld)", (unsigned long)_entries.count, (long)kFUMaxEntries]
                style:UIBarButtonItemStylePlain target:self action:@selector(addEntry)];
    self.navigationItem.rightBarButtonItem.enabled = (_entries.count < kFUMaxEntries);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadEntries];
    self.navigationItem.rightBarButtonItem.enabled = (_entries.count < kFUMaxEntries);
    [_tv reloadData];
}

- (void)addEntry {
    FUUrlEditController *ed = [[FUUrlEditController alloc] init];
    ed.entries = _entries;
    ed.index = -1;
    [self.navigationController pushViewController:ed animated:YES];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _entries.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *id = @"FUUrlCell";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:id];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:id];
    NSDictionary *e = _entries[ip.row];
    c.textLabel.text = [NSString stringWithFormat:@"%@ %@  %@",
                        e[kFUEntryChar] ?: @"", e[kFUEntryLetter] ?: @"", e[kFUEntryURL] ?: @""];
    c.textLabel.font = [UIFont systemFontOfSize:13];
    c.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    c.detailTextLabel.text = e[kFUEntryURL] ?: @"";
    c.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSData *icon = e[kFUEntryIcon];
    c.imageView.image = icon.length ? [UIImage imageWithData:icon] : nil;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    FUUrlEditController *ed = [[FUUrlEditController alloc] init];
    ed.entries = _entries;
    ed.index = ip.row;
    [self.navigationController pushViewController:ed animated:YES];
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)st
    forRowAtIndexPath:(NSIndexPath *)ip {
    if (st == UITableViewCellEditingStyleDelete) {
        [_entries removeObjectAtIndex:ip.row];
        CFPreferencesSetAppValue((__bridge CFStringRef)@"urls",
            (__bridge CFPropertyListRef)_entries, (__bridge CFStringRef)kFUSuite);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kFUSuite);
        notify_post("com.yzdmm.floatingurl/settingsChanged");
        [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationFade];
        self.navigationItem.rightBarButtonItem.enabled = (_entries.count < kFUMaxEntries);
    }
}

@end

#pragma mark - 主设置控制器

@interface FUSettingsController : PSListController
@end

@implementation FUSettingsController

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    notify_post("com.yzdmm.floatingurl/settingsChanged");
}

// PSButtonCell 触发：管理快捷URI 列表
- (void)manageUrls {
    FUUrlListController *list = [[FUUrlListController alloc] init];
    [self.navigationController pushViewController:list animated:YES];
}

@end
