//
//  EditAndSend.m
//  微信插件：长按聊天图片 → 菜单在“保存图片”上方加“编辑发送” → 编辑 → 直接发到当前会话
//
//  目标：微信 iOS 8.0.76 / 证书自签注入（全能签 / 轻松签）
//  写法：纯 ObjC runtime，不依赖 CydiaSubstrate / Theos / Logos，单个 .m 文件
//
//  编译（示例，需要 iOS SDK + clang）：
//    clang -dynamiclib -arch arm64 -mios-version-min=12.0 -fobjc-arc \
//      -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//      -framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore \
//      EditAndSend.m -o EditAndSend.dylib
//
//  安装：全能签 / 轻松签 → 导入已砸壳的微信 8.0.76 IPA → 注入本 dylib → 证书签名 → 安装。
//  注意：证书到期会掉签（免费个人证书 7 天），微信升级后插件大概率失效；
//  微信技术上能发现注入（枚举 dylib、校验签名），账号风险自己承担。
//
//  ─── 验证状态（2026-11-15 查实，来源见 README）───
//  ✅ WCActionSheet / buttonTitleList / addButtonWithTitle:atIndex: / showInView:
//  ✅ BaseMsgContentViewController / ImageMessageNodeView / CMessageWrap（type 3 = 图片）
//  ✅ CMessageMgr 取法：[[MMServiceCenter defaultCenter] getService:[CMessageMgr class]]
//  ✅ 自签注入：insert_dylib 插 LC_LOAD_DYLIB，纯 runtime swizzling，无需 substrate
//  ⚠️ TODO(1)：发图片的私有方法名。公开资料没有 8.0.76 的头文件，必须对已砸壳的
//     8.0.76 二进制 class-dump 后确认（命令见文件末尾）。目前直发走 TODO 占位，
//     默认走“复制到剪贴板 → 输入框粘贴发送”的可用兜底。
//  ⚠️ TODO(2)：被长按图片的 UIImage 与当前会话用户名，代码用运行时 ivar 扫描做
//     最佳努力（best-effort）；若 8.0.76 改了 ivar 名会拿不到，届时用 class-dump
//     的头文件对一下名字即可。
//  ⚠️ TODO(3)：微信内置图片编辑器的类名公开资料查不到，本插件自带一个简易编辑器
//     （涂鸦 / 文字 / 马赛克 / 撤销），不依赖微信编辑器。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 前向声明（只声明本次用到的、已查实的方法；类型未知的用 id）

@interface WCActionSheet : UIWindow
@property (nonatomic, strong) NSMutableArray *buttonTitleList;
- (long long)addButtonWithTitle:(NSString *)title atIndex:(unsigned long long)index;
- (long long)addButtonWithTitle:(NSString *)title;
- (void)showInView:(id)view;
@end

@interface MMServiceCenter : NSObject
+ (instancetype)defaultCenter;
- (id)getService:(Class)service;
@end

// CMessageWrap / CMessageMgr 的字段一律用 valueForKey: 读（KVC 会退到 ivar），
// 不声明 @property，避免真实 accessor 不存在导致崩溃。
@interface CMessageWrap : NSObject
@end

@interface CMessageMgr : NSObject
@end

#pragma mark - 常量与关联对象

static NSString * const kESMenuTitle      = @"编辑发送";
static NSString * const kESSaveTitle      = @"保存图片";
static const BOOL kESUsePlaceholderHack   = YES;   // 见 WeChatShot 踩坑：先插一个空占位项，
                                                   // 防止点“取消”/空白区域误触到新加的第一项。
                                                   // 若空项在菜单里显示成一条空白行，把它改成 NO。

static char kESInsertedIndexKey;   // NSNumber：占位项在 sheet 里的 index（-1 表示未插入）
static char kESImageKey;           // UIImage：被长按的那张图
static char kESPeerKey;            // NSString：当前会话用户名

#pragma mark - 小工具

static UIViewController *ES_TopViewController(void) {
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { window = w; break; }
        }
    }
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        vc = [(UINavigationController *)vc visibleViewController];
    }
    return vc;
}

static BOOL ES_IsChatViewController(UIViewController *vc) {
    return vc && [NSStringFromClass([vc class]) isEqualToString:@"BaseMsgContentViewController"];
}

// 在 obj 的 ivar 里找第一个 class 名等于 className 的对象（沿继承链向上找）
static id ES_FindIvarObjectOfClass(id obj, NSString *className) {
    if (!obj || !className) return nil;
    Class cls = [obj class];
    while (cls && cls != [NSObject class]) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (type && type[0] == '@') {
                id value = object_getIvar(obj, ivars[i]);
                if (value && [NSStringFromClass([value class]) isEqualToString:className]) {
                    free(ivars);
                    return value;
                }
            }
        }
        free(ivars);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

// 安全读 KVC，失败返回 nil（不崩）
static id ES_ValueForKeySafe(id obj, NSString *key) {
    if (!obj || !key) return nil;
    @try { return [obj valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

// 递归遍历 view 层级，收集所有 class 名等于 className 的 view
static void ES_CollectViewsOfClass(UIView *root, NSString *className, NSMutableArray *out) {
    if (!root) return;
    if ([NSStringFromClass([root class]) isEqualToString:className]) [out addObject:root];
    for (UIView *sub in root.subviews) ES_CollectViewsOfClass(sub, className, out);
}

static void ES_CollectImageViews(UIView *root, NSMutableArray *out) {
    if (!root) return;
    if ([root isKindOfClass:[UIImageView class]] && ((UIImageView *)root).image) [out addObject:root];
    for (UIView *sub in root.subviews) ES_CollectImageViews(sub, out);
}

#pragma mark - 上下文：被长按的图片 + 当前会话用户名

// 找当前被长按的图片消息 wrap（m_uiMessageType == 3）
static id ES_FindImageMessageWrap(UIViewController *chatVC) {
    if (!chatVC) return nil;
    Class cls = [chatVC class];
    while (cls && cls != [NSObject class]) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (type && type[0] == '@') {
                id value = object_getIvar(chatVC, ivars[i]);
                if (value && [NSStringFromClass([value class]) isEqualToString:@"CMessageWrap"]) {
                    NSNumber *msgType = ES_ValueForKeySafe(value, @"m_uiMessageType");
                    if (msgType && [msgType intValue] == 3) { free(ivars); return value; }
                }
            }
        }
        free(ivars);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

// 根据 wrap 找到它对应的 ImageMessageNodeView，再取里面的 UIImage
static UIImage *ES_FindImageForWrap(UIViewController *chatVC, id wrap) {
    if (!chatVC || !wrap) return nil;
    NSMutableArray *nodes = [NSMutableArray array];
    ES_CollectViewsOfClass(chatVC.view, @"ImageMessageNodeView", nodes);
    for (UIView *node in nodes) {
        // node 里找 CMessageNodeData，再比对它的 m_msgWrap 是不是同一条消息
        id nodeData = ES_FindIvarObjectOfClass(node, @"CMessageNodeData");
        id nodeWrap = nodeData ? ES_ValueForKeySafe(nodeData, @"m_msgWrap") : nil;
        if (nodeWrap == wrap) {
            NSMutableArray *imageViews = [NSMutableArray array];
            ES_CollectImageViews(node, imageViews);
            if (imageViews.count > 0) return ((UIImageView *)imageViews[0]).image;
        }
    }
    return nil;
}

static NSString *ES_SelfUserName(void) {
    Class centerCls = NSClassFromString(@"MMServiceCenter");
    Class contactMgrCls = NSClassFromString(@"CContactMgr");
    if (!centerCls || !contactMgrCls) return nil;
    id center = [centerCls performSelector:@selector(defaultCenter)];
    if (!center || ![center respondsToSelector:@selector(getService:)]) return nil;
    id mgr = [center performSelector:@selector(getService:) withObject:contactMgrCls];
    if (!mgr || ![mgr respondsToSelector:@selector(getSelfContact)]) return nil;
    id contact = [mgr performSelector:@selector(getSelfContact)];
    id name = ES_ValueForKeySafe(contact, @"m_nsUsrName");
    return [name isKindOfClass:[NSString class]] ? name : nil;
}

// 当前会话用户名：先试 VC 上的候选属性，再用 wrap 的 from/to 推导
static NSString *ES_PeerUserName(UIViewController *chatVC, id wrap) {
    for (NSString *key in @[@"m_nsChatName", @"chatName", @"m_chatName", @"m_nsUsrName"]) {
        id v = ES_ValueForKeySafe(chatVC, key);
        if ([v isKindOfClass:[NSString class]] && ((NSString *)v).length > 0) return v;
    }
    NSString *from = ES_ValueForKeySafe(wrap, @"m_nsFromUsr");
    NSString *to   = ES_ValueForKeySafe(wrap, @"m_nsToUsr");
    NSString *selfName = ES_SelfUserName();
    if (selfName) {
        if ([from isEqualToString:selfName]) return to;
        if ([to isEqualToString:selfName])   return from;
    }
    // 兜底：群聊时 to 是群 ID；单聊时 to/from 其中一个就是对方
    return to ?: from;
}

#pragma mark - 简易图片编辑器（自带，不依赖微信编辑器）

typedef NS_ENUM(NSInteger, ESEditorTool) { ESEditorToolDraw, ESEditorToolMosaic, ESEditorToolText };

static UIImage *ES_PixelatedImage(UIImage *image, CGSize size) {
    if (!image || size.width <= 0 || size.height <= 0) return nil;
    CGSize tiny = CGSizeMake(48, MAX(1, 48 * size.height / size.width));
    UIGraphicsBeginImageContextWithOptions(tiny, YES, 1.0);
    [image drawInRect:CGRectMake(0, 0, tiny.width, tiny.height)];
    UIImage *small = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    [small drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *big = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return big;
}

@interface ESEditorDrawView : UIView
@property (nonatomic, strong) UIImage *pixelatedImage;
@property (nonatomic, strong) NSMutableArray *strokes;      // 每个元素：@{@"points":NSMutableArray<NSValue *>, @"mode":NSNumber(ESEditorTool), @"color":UIColor, @"width":NSNumber}
@property (nonatomic, strong) NSMutableArray *labels;       // UILabel 列表（文字）
@property (nonatomic, strong) UIImage *mosaicCanvas;        // 马赛克图层
@property (nonatomic, assign) ESEditorTool currentTool;
@property (nonatomic, strong) UIColor *penColor;
- (void)undoLast;
- (void)rebuildMosaicCanvas;
@end

@implementation ESEditorDrawView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.strokes = [NSMutableArray array];
        self.labels = [NSMutableArray array];
        self.currentTool = ESEditorToolDraw;
        self.penColor = [UIColor redColor];
        self.multipleTouchEnabled = NO;
    }
    return self;
}

- (void)rebuildMosaicCanvas {
    UIGraphicsBeginImageContextWithOptions(self.bounds.size, NO, 0);
    for (NSDictionary *stroke in self.strokes) {
        if ([stroke[@"mode"] integerValue] != ESEditorToolMosaic) continue;
        for (NSValue *v in stroke[@"points"]) {
            CGPoint p = [v CGPointValue];
            CGFloat r = 14;
            CGContextRef ctx = UIGraphicsGetCurrentContext();
            CGContextSaveGState(ctx);
            CGContextAddEllipseInRect(ctx, CGRectMake(p.x - r, p.y - r, r * 2, r * 2));
            CGContextClip(ctx);
            [self.pixelatedImage drawInRect:self.bounds];
            CGContextRestoreGState(ctx);
        }
    }
    self.mosaicCanvas = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
}

- (void)undoLast {
    // 先撤文字，再撤笔画（按加入顺序倒序）
    if (self.labels.count > 0) {
        UILabel *label = self.labels.lastObject;
        [label removeFromSuperview];
        [self.labels removeLastObject];
        return;
    }
    if (self.strokes.count > 0) {
        NSDictionary *last = self.strokes.lastObject;
        [self.strokes removeLastObject];
        if ([last[@"mode"] integerValue] == ESEditorToolMosaic) [self rebuildMosaicCanvas];
        [self setNeedsDisplay];
    }
}

- (void)drawRect:(CGRect)rect {
    [self.mosaicCanvas drawInRect:self.bounds];
    for (NSDictionary *stroke in self.strokes) {
        if ([stroke[@"mode"] integerValue] == ESEditorToolMosaic) continue;
        NSArray *points = stroke[@"points"];
        if (points.count == 0) continue;
        UIBezierPath *path = [UIBezierPath bezierPath];
        path.lineCapStyle = kCGLineCapRound;
        path.lineJoinStyle = kCGLineJoinRound;
        path.lineWidth = [stroke[@"width"] floatValue];
        [path moveToPoint:[points[0] CGPointValue]];
        for (NSUInteger i = 1; i < points.count; i++) [path addLineToPoint:[points[i] CGPointValue]];
        [stroke[@"color"] setStroke];
        [path stroke];
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.currentTool == ESEditorToolText) return;
    CGPoint p = [[touches anyObject] locationInView:self];
    NSMutableDictionary *stroke = [@{
        @"points": [NSMutableArray arrayWithObject:[NSValue valueWithCGPoint:p]],
        @"mode": @(self.currentTool),
        @"color": self.penColor,
        @"width": @(self.currentTool == ESEditorToolMosaic ? 28 : 4),
    } mutableCopy];
    [self.strokes addObject:stroke];
    if (self.currentTool == ESEditorToolMosaic) [self rebuildMosaicCanvas];
    [self setNeedsDisplay];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.currentTool == ESEditorToolText) return;
    CGPoint p = [[touches anyObject] locationInView:self];
    NSMutableDictionary *stroke = self.strokes.lastObject;
    if (!stroke) return;
    [stroke[@"points"] addObject:[NSValue valueWithCGPoint:p]];
    if (self.currentTool == ESEditorToolMosaic) [self rebuildMosaicCanvas];
    [self setNeedsDisplay];
}

@end

@interface ESEditorViewController : UIViewController
@property (nonatomic, strong) UIImage *sourceImage;
@property (nonatomic, copy) void (^completion)(UIImage *editedImage);
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) ESEditorDrawView *drawView;
@property (nonatomic, strong) NSArray<UIButton *> *toolButtons;
- (instancetype)initWithImage:(UIImage *)image completion:(void (^)(UIImage *editedImage))completion;
@end

@implementation ESEditorViewController

- (instancetype)initWithImage:(UIImage *)image completion:(void (^)(UIImage *))completion {
    self = [super init];
    if (self) {
        _sourceImage = image;
        _completion = [completion copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    CGFloat topH = 88, bottomH = 76;
    CGRect content = CGRectMake(0, topH, self.view.bounds.size.width, self.view.bounds.size.height - topH - bottomH);
    CGFloat scale = MIN(content.size.width / self.sourceImage.size.width,
                        content.size.height / self.sourceImage.size.height);
    CGSize disp = CGSizeMake(self.sourceImage.size.width * scale, self.sourceImage.size.height * scale);
    CGRect imageRect = CGRectMake(CGRectGetMidX(content) - disp.width / 2,
                                  CGRectGetMidY(content) - disp.height / 2,
                                  disp.width, disp.height);

    self.imageView = [[UIImageView alloc] initWithFrame:imageRect];
    self.imageView.image = self.sourceImage;
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.view addSubview:self.imageView];

    self.drawView = [[ESEditorDrawView alloc] initWithFrame:imageRect];
    self.drawView.pixelatedImage = ES_PixelatedImage(self.sourceImage, imageRect.size);
    [self.view addSubview:self.drawView];

    // 顶栏：取消 / 发送
    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
    cancelBtn.tintColor = [UIColor whiteColor];
    cancelBtn.frame = CGRectMake(16, 44, 60, 36);
    [cancelBtn addTarget:self action:@selector(onCancel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:cancelBtn];

    UIButton *sendBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [sendBtn setTitle:@"发送" forState:UIControlStateNormal];
    sendBtn.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    sendBtn.tintColor = [UIColor colorWithRed:0.1 green:0.8 blue:0.2 alpha:1];
    sendBtn.frame = CGRectMake(self.view.bounds.size.width - 76, 44, 60, 36);
    [sendBtn addTarget:self action:@selector(onSend) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:sendBtn];

    // 底栏：涂鸦 / 马赛克 / 文字 / 撤销
    NSArray *titles = @[@"涂鸦", @"马赛克", @"文字", @"撤销"];
    NSMutableArray *buttons = [NSMutableArray array];
    CGFloat w = self.view.bounds.size.width / titles.count;
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.tintColor = [UIColor whiteColor];
        b.frame = CGRectMake(w * i, self.view.bounds.size.height - 64, w, 52);
        b.tag = i;
        [b addTarget:self action:@selector(onTool:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:b];
        [buttons addObject:b];
    }
    self.toolButtons = buttons;
    [self updateToolSelection];
}

- (void)updateToolSelection {
    for (UIButton *b in self.toolButtons) {
        BOOL selected = (b.tag == 0 && self.drawView.currentTool == ESEditorToolDraw) ||
                        (b.tag == 1 && self.drawView.currentTool == ESEditorToolMosaic);
        b.tintColor = selected ? [UIColor colorWithRed:0.1 green:0.8 blue:0.2 alpha:1] : [UIColor whiteColor];
    }
}

- (void)onTool:(UIButton *)sender {
    if (sender.tag == 0) { self.drawView.currentTool = ESEditorToolDraw; }
    else if (sender.tag == 1) { self.drawView.currentTool = ESEditorToolMosaic; }
    else if (sender.tag == 2) { [self addTextLabel]; return; }
    else if (sender.tag == 3) { [self.drawView undoLast]; return; }
    [self updateToolSelection];
}

- (void)addTextLabel {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加文字"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"输入文字"; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *text = alert.textFields[0].text;
        if (text.length == 0) return;
        UILabel *label = [[UILabel alloc] init];
        label.text = text;
        label.font = [UIFont boldSystemFontOfSize:28];
        label.textColor = [UIColor whiteColor];
        label.shadowColor = [UIColor blackColor];
        label.shadowOffset = CGSizeMake(0, 1);
        [label sizeToFit];
        label.center = CGPointMake(CGRectGetMidX(weakSelf.drawView.bounds), CGRectGetMidY(weakSelf.drawView.bounds));
        label.userInteractionEnabled = YES;
        [label addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:weakSelf action:@selector(onDragLabel:)]];
        [weakSelf.drawView addSubview:label];
        [weakSelf.drawView.labels addObject:label];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)onDragLabel:(UIPanGestureRecognizer *)g {
    UIView *label = g.view;
    CGPoint t = [g translationInView:self.drawView];
    label.center = CGPointMake(label.center.x + t.x, label.center.y + t.y);
    [g setTranslation:CGPointZero inView:self.drawView];
}

- (UIImage *)renderedImage {
    UIGraphicsBeginImageContextWithOptions(self.sourceImage.size, NO, self.sourceImage.scale);
    [self.sourceImage drawAtPoint:CGPointZero];
    CGFloat sx = self.sourceImage.size.width / self.drawView.bounds.size.width;
    CGFloat sy = self.sourceImage.size.height / self.drawView.bounds.size.height;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    CGContextScaleCTM(ctx, sx, sy);
    [self.drawView.layer renderInContext:ctx];
    CGContextRestoreGState(ctx);
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out;
}

- (void)onCancel {
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.completion) self.completion(nil);
    }];
}

- (void)onSend {
    UIImage *edited = [self renderedImage];
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.completion) self.completion(edited);
    }];
}

@end

#pragma mark - 发送（直发待确认 + 现在能用的兜底）

static void ESSendEditedImage(UIImage *image, NSString *peerUserName, UIViewController *fromVC) {
    if (!image || !fromVC) return;
    (void)peerUserName; // 直发通道接通后用它当收件人；目前兜底不需要
    // ── TODO(1)：直发通道 ──
    // 发图片在微信底层是两步：先把图片传到 CDN 拿到 key，再发消息关联该 CDN 对象。
    // 公开资料里没有 8.0.76 的 CMessageMgr 发图片方法名，必须先 class-dump：
    //   class-dump -H /path/to/WeChat.app/WeChat -o ~/wx-headers
    //   grep -n "Image\|AddMsg\|SendMsg" ~/wx-headers/CMessageMgr.h
    // 再找上传管理器（搜 "UploadImage" / "CUploadImageMgr"）：
    //   ls ~/wx-headers | grep -i "Upload.*Image\|Image.*Upload"
    // 确认后，按头文件构造 CMessageWrap（type 3，content 为图片 XML），
    // 走“上传 → 发消息”两步发送，并把这段兜底换掉。
    // 在那之前，走下面这条现在就能用的兜底：
    [[UIPasteboard generalPasteboard] setImage:image];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"已复制图片"
                         message:@"直接发送还差一个微信 8.0.76 的接口没确认。先这样用：点输入框 → 粘贴 → 发送，就发到当前会话了。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [fromVC presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Hook：WCActionSheet 加项

static void (*ESOrigShowInView)(id, SEL, id);

static void ES_ShowInView(id self, SEL _cmd, id view) {
    UIViewController *topVC = ES_TopViewController();
    if (ES_IsChatViewController(topVC)) {
        @try {
            WCActionSheet *sheet = (WCActionSheet *)self;
            // 安全门：只有菜单的 delegate 是聊天窗口控制器时才加项。
            // 若 8.0.76 换了 delegate 或换了菜单实现，就不插——菜单保持原样，不会点错。
            id delegate = ES_ValueForKeySafe(sheet, @"delegate");
            if (!delegate) delegate = ES_ValueForKeySafe(sheet, @"m_delegate");
            BOOL delegateIsChatVC = delegate &&
                [NSStringFromClass([delegate class]) isEqualToString:@"BaseMsgContentViewController"];
            if (delegateIsChatVC) {
                NSMutableArray *titles = sheet.buttonTitleList;
                NSInteger saveIndex = -1;
                for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
                    id item = titles[i];
                    // buttonTitleList 里可能是 NSString，也可能是带 title 属性的对象：
                    // 没拿到 8.0.76 头文件确认之前，两种都认，不赌其中一种。
                    // （原代码只按后者取；若实际是 NSString，valueForKey 会抛异常被吞掉，
                    //  saveIndex 永远找不到，菜单项悄悄插不进去。）
                    NSString *t = nil;
                    if ([item isKindOfClass:[NSString class]]) {
                        t = item;
                    } else {
                        t = ES_ValueForKeySafe(item, @"title");
                    }
                    if ([t isEqualToString:kESSaveTitle]) { saveIndex = i; break; }
                }
                if (saveIndex >= 0) {
                    NSInteger insertAt = saveIndex;
                    if (kESUsePlaceholderHack) {
                        [sheet addButtonWithTitle:@"" atIndex:(unsigned long long)saveIndex];
                        insertAt = saveIndex + 1;
                    }
                    [sheet addButtonWithTitle:kESMenuTitle atIndex:(unsigned long long)insertAt];
                    objc_setAssociatedObject(self, &kESInsertedIndexKey, @(insertAt),
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    // 此时长按刚发生，顺手把上下文（图片 + 会话）存到 sheet 上
                    id wrap = ES_FindImageMessageWrap(topVC);
                    UIImage *img = ES_FindImageForWrap(topVC, wrap);
                    if (img) objc_setAssociatedObject(self, &kESImageKey, img,
                                                      OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    NSString *peer = ES_PeerUserName(topVC, wrap);
                    if (peer) objc_setAssociatedObject(self, &kESPeerKey, peer,
                                                       OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                } else {
                    objc_setAssociatedObject(self, &kESInsertedIndexKey, @(-1),
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            }
        } @catch (__unused NSException *e) {
            // 加项失败也不影响原菜单
        }
    }
    ESOrigShowInView(self, _cmd, view);
}

#pragma mark - Hook：菜单点击分发

static void (*ESOrigActionSheetClicked)(id, SEL, id, long long);

static void ES_ActionSheetClicked(id self, SEL _cmd, id sheet, long long index) {
    NSNumber *insertedNum = objc_getAssociatedObject(sheet, &kESInsertedIndexKey);
    NSInteger inserted = insertedNum ? [insertedNum integerValue] : -1;
    if (inserted < 0) {
        ESOrigActionSheetClicked(self, _cmd, sheet, index);
        return;
    }
    NSInteger placeholder = kESUsePlaceholderHack ? inserted - 1 : -1;
    if (index == placeholder) {
        return; // 点到占位项：什么都不做
    }
    if (index == inserted) {
        // 点了“编辑发送”
        UIImage *image = objc_getAssociatedObject(sheet, &kESImageKey);
        NSString *peer = objc_getAssociatedObject(sheet, &kESPeerKey);
        UIViewController *topVC = ES_TopViewController();
        if (!image) {
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"没拿到这张图"
                                 message:@"换一张图片长按再试一次。"
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
            [topVC presentViewController:alert animated:YES completion:nil];
            return;
        }
        ESEditorViewController *editor = [[ESEditorViewController alloc] initWithImage:image
                                                                              completion:^(UIImage *editedImage) {
            if (editedImage) ESSendEditedImage(editedImage, peer, ES_TopViewController());
        }];
        editor.modalPresentationStyle = UIModalPresentationFullScreen;
        dispatch_async(dispatch_get_main_queue(), ^{
            [topVC presentViewController:editor animated:YES completion:nil];
        });
        return;
    }
    // 原有菜单项：index 被插入项顶后移了，减回去再交给原实现
    NSInteger shift = kESUsePlaceholderHack ? 2 : 1;
    long long origIndex = index > inserted ? index - shift : index;
    ESOrigActionSheetClicked(self, _cmd, sheet, origIndex);
}

#pragma mark - 安装

static void ESSwizzleMethod(Class cls, SEL sel, IMP newImp, IMP *origStore) {
    if (!cls || !sel || !newImp || !origStore) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return; // 这个版本没有该方法：不装 hook，不崩
    IMP orig = method_getImplementation(m);
    if (class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) {
        *origStore = orig; // 方法原来在父类：子类新增一层，orig 仍指向父类实现
    } else {
        *origStore = orig;
        method_setImplementation(m, newImp);
    }
}

__attribute__((constructor)) static void ESInit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class sheetCls = NSClassFromString(@"WCActionSheet");
        if (sheetCls) {
            ESSwizzleMethod(sheetCls, @selector(showInView:),
                            (IMP)ES_ShowInView, (IMP *)&ESOrigShowInView);
        }
        Class chatCls = NSClassFromString(@"BaseMsgContentViewController");
        if (chatCls) {
            ESSwizzleMethod(chatCls, @selector(actionSheet:clickedButtonAtIndex:),
                            (IMP)ES_ActionSheetClicked, (IMP *)&ESOrigActionSheetClicked);
        }
    });
}

// ─── 补全 TODO(1) 的步骤 ───
// 1) 拿到已砸壳的微信 8.0.76 IPA，解压出 WeChat.app/WeChat（Mach-O 二进制）。
// 2) class-dump -H WeChat -o ~/wx-headers
// 3) 在 ~/wx-headers 里确认：
//      WCActionSheet 是否还在，addButtonWithTitle:atIndex: / showInView: / buttonTitleList 是否还在；
//      BaseMsgContentViewController 的 actionSheet:clickedButtonAtIndex: 是否还在；
//      CMessageMgr 里发图片的方法名（grep "Image\|AddMsg\|SendMsg" CMessageMgr.h）；
//      上传图片的管理器类名（ls | grep -i Upload）；
//      图片编辑器 VC 的真实类名（Reveal 看编辑器页面，或 grep -i "Edit" *Image*.h）。
// 4) 把确认到的方法名填进 ESSendEditedImage 的 TODO(1) 处，
//    并把 ES_FindImageMessageWrap / ES_PeerUserName 里的 ivar 名按头文件对一遍。
// 5) 重新编译、注入、签名、安装验证。
