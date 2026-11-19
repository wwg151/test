//
//  Tweak.xm
//  NotificationIsland — 最小可编译的「通知进灵动岛」骨架
//
//  链路（双层拦截）：
//    ① NCNotificationDispatcher -postNotificationWithRequest:  ← 全量入口
//       所有 App 的新通知都经过这里，与"是否弹横幅""是否锁屏"无关
//    ② SBNotificationBannerDestination -postNotificationRequest:  ← 横幅入口（去重后只负责淡横幅）
//    → 建 4 槽位视图 → SBUISystemApertureContentProvider →
//      SBAlertProvidedContentElement（缺失时退回 runtime 子类）→
//      SBSystemApertureController registerElement: → 定时 invalidate
//
//  仅依赖 runtime + 私有类名字符串，不引入任何私有头文件，iOS 16 起可用。
//  已知未做：多通知堆叠、点击打开 App、下载进度、设置面板。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <unistd.h>

#define NIILog(fmt, ...) NSLog(@"[NotificationIsland] " fmt, ##__VA_ARGS__)

// ============================== 配置 ==============================

static NSString *const kNIIDomain     = @"com.example.notificationisland";
static NSString *const kNIIBreadcrumb = @"/tmp/notificationisland.element";

static BOOL      sNIIEnabled    = YES;
static BOOL      sNIIHideBanner = YES;
static BOOL      sNIIOnlyThirdParty  = NO;   // YES 时只处理第三方 App（跳过 com.apple.*）
static BOOL      sNIIIncludeModified = NO;   // 是否把"通知更新"也当新通知上岛
static BOOL      sNIIUseSystemAlert  = NO;   // YES = 引擎B（系统告警上岛），NO = 引擎A（registerElement）
static double    sNIIDuration   = 4.0;   // alert 存活秒数
static NSInteger sNIILayout     = 3;     // 0 compact / 2 wide / 3 expanded
static BOOL      sNIIUnsafe     = NO;    // 崩溃恢复窗口内不建元素

static __weak id sNIIController;                 // SBSystemApertureController
static NSMutableDictionary *sNIICurrent;         // 当前岛上的那条通知
static NSMutableArray *sNIIQueue;                // 排队等待上岛的 request（最多 3 条）
static const NSUInteger kNIIQueueLimit = 3;
static BOOL sNIIHookInstalled = NO;
static BOOL sNIIGuardInstalled = NO;   // promotion guard 是否已装
static BOOL sNIIGuardDisabled  = NO;   // 连续异常后本次 respring 内不再建元素
static BOOL sNIIGuardHandling  = NO;   // guard 正在清理，防止重入
static int  sNIIGuardFailures  = 0;

static void NIILoadPrefs(void) {
    id value;

    value = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("Enabled"), (__bridge CFStringRef)kNIIDomain);
    sNIIEnabled = value ? [value boolValue] : YES;

    value = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("HideBanner"), (__bridge CFStringRef)kNIIDomain);
    sNIIHideBanner = value ? [value boolValue] : YES;

    value = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("Duration"), (__bridge CFStringRef)kNIIDomain);
    sNIIDuration = value ? MAX(1.0, MIN(12.0, [value doubleValue])) : 4.0;

    value = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("LayoutMode"), (__bridge CFStringRef)kNIIDomain);
    sNIILayout = value ? [value integerValue] : 3;
    if (sNIILayout != 0 && sNIILayout != 2 && sNIILayout != 3) sNIILayout = 3;

    value = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("OnlyThirdParty"), (__bridge CFStringRef)kNIIDomain);
    sNIIOnlyThirdParty = value ? [value boolValue] : NO;

    value = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("IncludeModified"), (__bridge CFStringRef)kNIIDomain);
    sNIIIncludeModified = value ? [value boolValue] : NO;

    value = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("UseSystemAlert"), (__bridge CFStringRef)kNIIDomain);
    sNIIUseSystemAlert = value ? [value boolValue] : NO;

    NIILog(@"prefs: enabled=%d hideBanner=%d duration=%.1fs layout=%ld onlyThirdParty=%d includeModified=%d useSystemAlert=%d",
           sNIIEnabled, sNIIHideBanner, sNIIDuration, (long)sNIILayout,
           sNIIOnlyThirdParty, sNIIIncludeModified, sNIIUseSystemAlert);
}

// 元素活着的面包屑：崩溃后下次启动留出 60s 恢复窗口，避免 SpringBoard boot loop
static void NIIEvaluateBreadcrumb(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kNIIBreadcrumb]) return;
    [fm removeItemAtPath:kNIIBreadcrumb error:nil];
    sNIIUnsafe = YES;
    NIILog(@"检测到上次异常退出（元素未销毁），60s 内只走系统横幅");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        sNIIUnsafe = NO;
        NIILog(@"恢复窗口结束，通知可以重新上岛");
    });
}

// ============================== 运行时工具 ==============================

static id NIISafeValue(id object, NSString *key) {
    if (!object) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *NIISafeString(id object, NSString *key) {
    id value = NIISafeValue(object, key);
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
}

static void NIISetInteger(id object, NSString *selectorName, NSInteger value) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(object, selector, value);
}

static void NIISetObject(id object, NSString *selectorName, id value) {
    if (!value) return;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
}

// ============================== 标识对象 ==============================
// Apple 会向 identifier 发 -elementIdentifier；直接传 NSString 会 unrecognized selector 崩溃。

@interface NIIslandIdentifier : NSObject <NSCopying>
@property (nonatomic, copy) NSString *value;
@end

@implementation NIIslandIdentifier

- (id)elementIdentifier { return self.value; }
- (id)clientIdentifier { return @"com.apple.springboard"; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (NSString *)description { return self.value ?: @"NIIslandIdentifier"; }

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [super methodSignatureForSelector:selector] ?: [NSMethodSignature signatureWithObjCTypes:"@@:"];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    NSString *name = NSStringFromSelector(invocation.selector);
    id result = [name rangeOfString:@"dentifier"].location != NSNotFound ? self.value : nil;
    void *pointer = (__bridge void *)result;
    [invocation setReturnValue:&pointer];
}

@end

// ============================== 通知内容 → 视图 ==============================

static NSDictionary<NSString *, NSString *> *NIIInfoFromRequest(id request) {
    id content = NIISafeValue(request, @"content");
    NSString *bundleID = NIISafeString(request, @"sectionIdentifier")
                      ?: NIISafeString(request, @"bundleIdentifier") ?: @"";
    NSString *header   = NIISafeString(request, @"header") ?: NIISafeString(content, @"header") ?: @"";
    NSString *title    = NIISafeString(content, @"title") ?: @"";
    NSString *subtitle = NIISafeString(content, @"subtitle") ?: @"";
    NSString *message  = NIISafeString(content, @"message") ?: @"";
    return @{ @"bundleID": bundleID, @"header": header, @"title": title,
              @"subtitle": subtitle, @"message": message };
}

static UIImage *NIIAppIcon(NSString *bundleID, CGFloat side) {
    if (!bundleID.length) return nil;
    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![UIImage respondsToSelector:selector]) return nil;
    UIImage *icon = ((id (*)(id, SEL, NSString *, int, CGFloat))objc_msgSend)(
        [UIImage class], selector, bundleID, 0, [UIScreen mainScreen].scale);
    return [icon isKindOfClass:[UIImage class]] ? icon : nil;
}

static NSString *NIIShortText(NSString *text, NSUInteger limit) {
    if (!text.length) return @"";
    NSString *flat = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    return flat.length > limit ? [[flat substringToIndex:limit] stringByAppendingString:@"…"] : flat;
}

static void NIIBuildViews(NSDictionary<NSString *, NSString *> *info,
                          UIView **leadingOut, UIView **trailingOut,
                          UIView **primaryOut, UIView **secondaryOut) {
    NSString *bundleID = info[@"bundleID"] ?: @"";
    NSString *header   = info[@"header"] ?: @"";
    NSString *title    = info[@"title"] ?: @"";
    NSString *subtitle = info[@"subtitle"] ?: @"";
    NSString *message  = info[@"message"] ?: @"";

    NSString *headline = title.length ? title : (header.length ? header : message);
    NSString *body = message;
    if (subtitle.length) body = message.length ? [NSString stringWithFormat:@"%@：%@", subtitle, message] : subtitle;
    if (!title.length && !header.length) body = @"";

    // leading：App 图标（22pt），拿不到就退回首字母
    UIImage *icon = NIIAppIcon(bundleID, 22);
    UIView *leading;
    if (icon) {
        UIImageView *iconView = [[UIImageView alloc] initWithImage:icon];
        iconView.frame = CGRectMake(0, 0, 22, 22);
        iconView.layer.cornerRadius = 5;
        iconView.clipsToBounds = YES;
        leading = iconView;
    } else {
        UILabel *initial = [[UILabel alloc] init];
        initial.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        initial.textColor = [UIColor whiteColor];
        NSString *text = header.length ? header : headline;
        initial.text = text.length ? [text substringToIndex:1] : @"•";
        [initial sizeToFit];
        leading = initial;
    }

    // trailing：短标题（compact 状态显示）
    UILabel *trailing = [[UILabel alloc] init];
    trailing.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    trailing.textColor = [UIColor whiteColor];
    trailing.text = NIIShortText(headline, 12);
    [trailing sizeToFit];

    // primary：标题（展开状态）
    UILabel *primary = [[UILabel alloc] init];
    primary.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    primary.textColor = [UIColor whiteColor];
    primary.lineBreakMode = NSLineBreakByTruncatingTail;
    primary.text = headline;
    CGSize primarySize = [primary sizeThatFits:CGSizeMake(260, CGFLOAT_MAX)];
    primary.frame = CGRectMake(0, 0, MIN(260, ceil(primarySize.width)), ceil(primarySize.height));

    // secondary：正文（最多 2 行）
    UILabel *secondary = [[UILabel alloc] init];
    secondary.font = [UIFont systemFontOfSize:13];
    secondary.textColor = [UIColor colorWithWhite:1.0 alpha:0.8];
    secondary.numberOfLines = 2;
    secondary.lineBreakMode = NSLineBreakByTruncatingTail;
    secondary.text = body;
    secondary.preferredMaxLayoutWidth = 260;
    CGSize secondarySize = [secondary sizeThatFits:CGSizeMake(260, CGFLOAT_MAX)];
    secondary.frame = CGRectMake(0, 0, MIN(260, ceil(secondarySize.width)), ceil(secondarySize.height));

    *leadingOut = leading;
    *trailingOut = trailing;
    *primaryOut = primary;
    *secondaryOut = secondary;
}

// ============================== 元素 ==============================

static Class NIINoticeElementClass(void) {
    static Class elementClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 优先用系统原生 alert 元素类（已实现 <SAAlertBehavior>，含 alertHost），
        // 退回 SBSystemApertureProvidedContentElement 时靠下面 class_addMethod 补 hasAlertBehavior。
        Class base = NSClassFromString(@"SBAlertProvidedContentElement");
        if (!base) base = NSClassFromString(@"SBSystemApertureProvidedContentElement");
        if (!base) {
            NIILog(@"缺少 SBAlertProvidedContentElement / SBSystemApertureProvidedContentElement，系统版本可能不支持");
            return;
        }
        Class existing = NSClassFromString(@"NIINotificationElement");
        if (existing) { elementClass = existing; return; }

        Class created = objc_allocateClassPair(base, "NIINotificationElement", 0);
        if (!created) { NIILog(@"objc_allocateClassPair 失败"); return; }

        class_addMethod(created, NSSelectorFromString(@"hasAlertBehavior"),
                        imp_implementationWithBlock(^BOOL(id receiver) { return YES; }), "B16@0:8");
        class_addMethod(created, NSSelectorFromString(@"hasActivityBehavior"),
                        imp_implementationWithBlock(^BOOL(id receiver) { return NO; }), "B16@0:8");
        class_addMethod(created, NSSelectorFromString(@"hasIndicatorBehavior"),
                        imp_implementationWithBlock(^BOOL(id receiver) { return NO; }), "B16@0:8");
        class_addMethod(created, NSSelectorFromString(@"preferredAlertingDuration:"),
                        imp_implementationWithBlock(^(id receiver, double suggested) {
                            return (double)sNIIDuration;
                        }), "d24@0:8d16");

        // 锁屏 / CoverSheet 下也允许显示（基类默认会在锁屏时抑制元素）
        class_addMethod(created, NSSelectorFromString(@"_canShowWhileLocked"),
                        imp_implementationWithBlock(^BOOL(id receiver) { return YES; }), "B16@0:8");
        class_addMethod(created, NSSelectorFromString(@"shouldSuppressElementWhileOnCoversheet"),
                        imp_implementationWithBlock(^BOOL(id receiver) { return NO; }), "B16@0:8");

        objc_registerClassPair(created);
        elementClass = created;
        NIILog(@"已创建元素类 NIINotificationElement（基类 %@）", NSStringFromClass(base));
    });
    return elementClass;
}

static void NIIApplyLayout(id element) {
    NSInteger preferred = sNIILayout;
    NSInteger minimum = 1;
    NSInteger maximum = sNIILayout == 0 ? 1 : sNIILayout;
    if (sNIILayout == 0) preferred = 1;

    NIISetInteger(element, @"setMinimumSupportedLayoutMode:", minimum);
    NIISetInteger(element, @"setMaximumSupportedLayoutMode:", maximum);
    NIISetInteger(element, @"setPreferredLayoutMode:", preferred);
    NIILog(@"布局预设 preferred=%ld min=%ld max=%ld", (long)preferred, (long)minimum, (long)maximum);
}

// ============================== 横幅窗口压制 ==============================

static const void *kOriginalAlphaKey = &kOriginalAlphaKey;

static BOOL sBannerHideActive = NO;
static BOOL sBannerSawBanner = NO;
static BOOL sBannerCanProbe = NO;
static CFAbsoluteTime sBannerHideStart = 0;
static __weak id sBannerDestination;

static NSArray<UIWindow *> *NIIBannerWindows(void) {
    NSMutableArray<UIWindow *> *result = [NSMutableArray array];
    Class bannerClass = NSClassFromString(@"SBBannerWindow");
    if (!bannerClass) return result;

    SEL selector = NSSelectorFromString(@"allWindowsIncludingInternalWindows:onlyVisibleWindows:");
    if (![UIWindow respondsToSelector:selector]) return result;
    NSArray *all = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)([UIWindow class], selector, YES, NO);
    for (UIWindow *window in all) {
        if ([window isKindOfClass:bannerClass]) [result addObject:window];
    }
    return result;
}

static void NIIHideBannerWindows(void) {
    for (UIWindow *window in NIIBannerWindows()) {
        if (!objc_getAssociatedObject(window, kOriginalAlphaKey)) {
            objc_setAssociatedObject(window, kOriginalAlphaKey, @(window.alpha),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (window.alpha != 0) window.alpha = 0;
    }
}

static void NIIRestoreBannerWindows(void) {
    for (UIWindow *window in NIIBannerWindows()) {
        NSNumber *original = objc_getAssociatedObject(window, kOriginalAlphaKey);
        if (!original) continue;
        CGFloat value = original.doubleValue;
        window.alpha = value > 0.01 ? value : 1.0;
        objc_setAssociatedObject(window, kOriginalAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void NIIPollBannerHide(void);

static void NIIBeginBannerHide(id destination) {
    sBannerDestination = destination;
    sBannerCanProbe = [destination respondsToSelector:NSSelectorFromString(@"presentedBanner")];
    sBannerHideStart = CFAbsoluteTimeGetCurrent();
    sBannerSawBanner = NO;
    NIIHideBannerWindows();
    if (!sBannerHideActive) {
        sBannerHideActive = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NIIPollBannerHide();
        });
    }
}

static void NIIPollBannerHide(void) {
    if (!sBannerHideActive) return;
    CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - sBannerHideStart;
    id presented = sBannerCanProbe ? NIISafeValue(sBannerDestination, @"presentedBanner") : nil;
    if (presented) sBannerSawBanner = YES;

    BOOL done;
    if (sBannerCanProbe) {
        done = (sBannerSawBanner && !presented && elapsed > 1.0)
            || (!sBannerSawBanner && elapsed > 4.0)
            || elapsed > 12.0;
    } else {
        done = elapsed > 7.0;
    }

    if (done) {
        NIIRestoreBannerWindows();
        sBannerHideActive = NO;
        NIILog(@"横幅窗口已恢复（%.1fs, sawBanner=%d probe=%d）", elapsed, sBannerSawBanner, sBannerCanProbe);
        return;
    }

    NIIHideBannerWindows();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NIIPollBannerHide();
    });
}

// ============================== 引擎 B：借道系统告警上岛 ==============================
// 原理：SpringBoard 的 SBAlertItemsController 自带 systemApertureAlertItemPresenter。
// 只要把告警的 prefersSystemAperturePresentation 设为 YES 并填好
// systemApertureContentDefinition，activateAlertItem: 时系统就会自己建岛元素。
// 与引擎 A（registerElement:）的区别：UI 由系统渲染，只有标题/正文/图标/颜色/按钮，
// 没有自定义四槽位视图；但锁屏、消失、按钮行为都交给系统管。

static Class NIIAlertClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class base = NSClassFromString(@"SBUserNotificationAlert");
        if (!base) return;
        Class created = objc_allocateClassPair(base, "NIISystemAlert", 0);
        if (!created) { cls = base; return; }
        // elementIdentifier 必须稳定：同一实例多次调用要返回同一个值
        class_addMethod(created, NSSelectorFromString(@"elementIdentifier"),
                        imp_implementationWithBlock(^id(id receiver) {
                            NSString *identifier = objc_getAssociatedObject(receiver, "niiElementID");
                            if (!identifier) {
                                identifier = [NSString stringWithFormat:@"nii.alert.%@", [[NSUUID UUID] UUIDString]];
                                objc_setAssociatedObject(receiver, "niiElementID", identifier, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            }
                            return identifier;
                        }), "@@:");
        objc_registerClassPair(created);
        cls = created;
    });
    return cls;
}

static BOOL NIIPresentViaSystemAlert(NSDictionary<NSString *, NSString *> *info) {
    Class alertClass = NIIAlertClass();
    Class controllerClass = NSClassFromString(@"SBAlertItemsController");
    Class defClass = NSClassFromString(@"SBSUserNotificationSystemApertureContentDefinition");
    if (!alertClass || !controllerClass || !defClass) {
        NIILog(@"引擎B缺少类：alert=%@ controller=%@ def=%@",
               NSStringFromClass(alertClass), NSStringFromClass(controllerClass), NSStringFromClass(defClass));
        return NO;
    }

    @try {
        id def = [[defClass alloc] init];
        [def setValue:info[@"title"] forKey:@"alertHeader"];
        [def setValue:info[@"message"] forKey:@"alertMessage"];
        // preventsAutomaticDismissal 保持默认 NO，让系统按自己的节奏收起

        id alert = [[alertClass alloc] init];
        if (!alert) { NIILog(@"引擎B：SBUserNotificationAlert 初始化失败"); return NO; }
        [alert setValue:@YES forKey:@"prefersSystemAperturePresentation"];
        [alert setValue:def forKey:@"systemApertureContentDefinition"];
        [alert setValue:info[@"title"] forKey:@"alertHeader"];
        [alert setValue:info[@"message"] forKey:@"alertMessage"];

        id controller = ((id (*)(Class, SEL))objc_msgSend)(controllerClass, NSSelectorFromString(@"sharedInstance"));
        if (!controller) { NIILog(@"引擎B：拿不到 SBAlertItemsController"); return NO; }

        SEL animated = NSSelectorFromString(@"activateAlertItem:animated:");
        if ([controller respondsToSelector:animated]) {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(controller, animated, alert, YES);
        } else {
            ((void (*)(id, SEL, id))objc_msgSend)(controller, NSSelectorFromString(@"activateAlertItem:"), alert);
        }
        NIILog(@"引擎B已提交系统告警：%@ | %@", info[@"bundleID"], NIIShortText(info[@"title"], 30));
        return YES;
    } @catch (NSException *exception) {
        NIILog(@"引擎B异常：%@", exception);
        return NO;
    }
}

// ============================== 展示 / 销毁 ==============================

static void NIIRemoveCurrent(NSString *reason);

static BOOL NIIPresent(id request) {
    if (![NSThread isMainThread]) {
        id requestRef = request;
        dispatch_async(dispatch_get_main_queue(), ^{ NIIPresent(requestRef); });
        return YES;
    }
    if (!sNIIEnabled || sNIIUnsafe || sNIIGuardDisabled) return NO;

    if (sNIIUseSystemAlert) {
        // 引擎B：展示交给系统，不走自建元素 / 队列 / 面包屑 / 定时销毁
        return NIIPresentViaSystemAlert(NIIInfoFromRequest(request));
    }

    Class contentProviderClass = NSClassFromString(@"SBUISystemApertureContentProvider");
    Class slotProviderClass    = NSClassFromString(@"SBUISystemApertureCustomContentProvider");
    Class elementClass         = NIINoticeElementClass();
    id registrar               = sNIIController;

    if (!contentProviderClass || !slotProviderClass || !elementClass || !registrar) {
        NIILog(@"缺件：contentProvider=%d slotProvider=%d element=%d registrar=%d",
               contentProviderClass != nil, slotProviderClass != nil,
               elementClass != nil, registrar != nil);
        if (!registrar) {
            NIILog(@"registrar 为空：有岛机型请先解锁一次；无岛机型必须先装造岛 tweak"
                   "（Insula / VisibleIsland / DynamicNotLand 等），否则 SpringBoard 不会创建 SystemAperture 场景");
        }
        return NO;
    }

    if (sNIICurrent) {
        // 岛上已经有通知：排队而不是顶掉，保证每条第三方通知都有机会显示
        if (!sNIIQueue) sNIIQueue = [NSMutableArray array];
        if (request) {
            if (sNIIQueue.count >= kNIIQueueLimit) [sNIIQueue removeObjectAtIndex:0];
            [sNIIQueue addObject:request];
            NIILog(@"岛上已有通知，新通知排队（当前队列 %lu 条）", (unsigned long)sNIIQueue.count);
        }
        return YES;
    }

    @try {
        NSDictionary<NSString *, NSString *> *info = NIIInfoFromRequest(request);
        NIILog(@"准备上岛：%@ | %@ | %@", info[@"bundleID"], info[@"title"], info[@"message"]);

        UIView *leading = nil, *trailing = nil, *primary = nil, *secondary = nil;
        NIIBuildViews(info, &leading, &trailing, &primary, &secondary);

        SEL initWithView = NSSelectorFromString(@"initWithView:");
        id leadingProvider   = ((id (*)(id, SEL, id))objc_msgSend)([slotProviderClass alloc], initWithView, leading ?: [UIView new]);
        id trailingProvider  = ((id (*)(id, SEL, id))objc_msgSend)([slotProviderClass alloc], initWithView, trailing ?: [UIView new]);
        id primaryProvider   = ((id (*)(id, SEL, id))objc_msgSend)([slotProviderClass alloc], initWithView, primary ?: [UIView new]);
        id secondaryProvider = ((id (*)(id, SEL, id))objc_msgSend)([slotProviderClass alloc], initWithView, secondary ?: [UIView new]);

        id provider = ((id (*)(id, SEL))objc_msgSend)([contentProviderClass alloc], NSSelectorFromString(@"init"));
        NIISetObject(provider, @"setLeadingContentViewProvider:", leadingProvider);
        NIISetObject(provider, @"setTrailingContentViewProvider:", trailingProvider);
        NIISetObject(provider, @"setPrimaryContentViewProvider:", primaryProvider);
        NIISetObject(provider, @"setSecondaryContentViewProvider:", secondaryProvider);

        NIIslandIdentifier *identifier = [NIIslandIdentifier new];
        identifier.value = [NSString stringWithFormat:@"com.example.notificationisland.notice.%@",
                            [NSUUID UUID].UUIDString];

        id element = ((id (*)(id, SEL, id, id))objc_msgSend)(
            [elementClass alloc], NSSelectorFromString(@"initWithIdentifier:contentProvider:"),
            identifier, provider);

        if (!element) {
            NIILog(@"元素创建失败");
            return NO;
        }

        NIIApplyLayout(element);

        // 注册是风险最高的一步：先落面包屑
        [@{ @"time": @(CFAbsoluteTimeGetCurrent()), @"pid": @(getpid()) }
            writeToFile:kNIIBreadcrumb atomically:YES];

        SEL registerSelector = NSSelectorFromString(@"registerElement:");
        if (![registrar respondsToSelector:registerSelector]) {
            NIILog(@"registrar 不支持 registerElement:");
            return NO;
        }
        id registration = ((id (*)(id, SEL, id))objc_msgSend)(registrar, registerSelector, element);
        if (!registration) {
            // 没拿到 assertion = 系统没接受这个元素。必须按失败处理，否则会把横幅也淡掉 → 吞通知。
            NIILog(@"registerElement: 返回 nil，放弃上岛并保留系统横幅");
            [[NSFileManager defaultManager] removeItemAtPath:kNIIBreadcrumb error:nil];
            return NO;
        }
        NIILog(@"已注册：registration=%@", NSStringFromClass([registration class]));

        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"element"] = element;
        item[@"provider"] = provider;
        item[@"registration"] = registration;
        item[@"manager"] = registrar;
        item[@"leadingView"] = leading;
        item[@"trailingView"] = trailing;
        item[@"primaryView"] = primary;
        item[@"secondaryView"] = secondary;
        sNIICurrent = item;

        __weak NSMutableDictionary *weakItem = item;
        dispatch_block_t timeout = dispatch_block_create(0, ^{
            NSMutableDictionary *strongItem = weakItem;
            if (strongItem && strongItem == sNIICurrent) NIIRemoveCurrent(@"timeout");
        });
        item[@"timeout"] = timeout;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sNIIDuration * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), timeout);

        return YES;
    } @catch (NSException *exception) {
        NIILog(@"建元素抛异常：%@ %@", exception.name, exception.reason);
        [[NSFileManager defaultManager] removeItemAtPath:kNIIBreadcrumb error:nil];
        return NO;
    }
}

static void NIIRemoveCurrent(NSString *reason) {
    NSMutableDictionary *item = sNIICurrent;
    if (!item) return;
    sNIICurrent = nil;

    dispatch_block_t timeout = item[@"timeout"];
    if (timeout) dispatch_block_cancel(timeout);

    id registration = item[@"registration"];
    id manager      = item[@"manager"];
    id element      = item[@"element"];
    BOOL done = NO;

    SEL invalidate = NSSelectorFromString(@"invalidateWithReason:layoutModeChangeReason:");
    if (registration && [registration respondsToSelector:invalidate]) {
        @try {
            ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(registration, invalidate,
                                                            reason ?: @"NotificationIsland", 0);
            done = YES;
        } @catch (NSException *exception) {
            NIILog(@"invalidateWithReason: 抛异常 %@", exception.name);
        }
    }

    if (!done) {
        for (NSString *name in @[@"invalidate", @"invalidateWithReason:"]) {
            SEL selector = NSSelectorFromString(name);
            if (registration && [registration respondsToSelector:selector]) {
                @try {
                    if ([name hasSuffix:@":"]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(registration, selector, reason ?: @"NotificationIsland");
                    } else {
                        ((void (*)(id, SEL))objc_msgSend)(registration, selector);
                    }
                    done = YES;
                } @catch (__unused NSException *exception) {}
                if (done) break;
            }
        }
    }

    if (!done && manager && element) {
        for (NSString *name in @[@"unregisterElement:", @"removeElement:", @"invalidateElement:"]) {
            SEL selector = NSSelectorFromString(name);
            if (![manager respondsToSelector:selector]) continue;
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(manager, selector, element);
                done = YES;
            } @catch (__unused NSException *exception) {}
            if (done) break;
        }
    }

    [[NSFileManager defaultManager] removeItemAtPath:kNIIBreadcrumb error:nil];
    NIILog(@"元素已移除（%@，方式=%@）", reason, done ? @"registration" : @"未找到可用失效方法");

    // 队列里还有通知就接着上岛；guard 停用 / 恢复窗口内不继续，避免连锁崩溃
    if (sNIIQueue.count && sNIIEnabled && !sNIIUnsafe && !sNIIGuardDisabled) {
        id next = sNIIQueue.firstObject;
        [sNIIQueue removeObjectAtIndex:0];
        dispatch_async(dispatch_get_main_queue(), ^{
            NIIPresent(next);
        });
    } else if (!sNIIQueue.count) {
        sNIIQueue = nil;
    }
}

// ============================== promotion guard ==============================
// 注册 / 失效元素都会触发 -_reevaluatePromotedElements，这是做岛 tweak 最常见的崩溃点。
// 只吞"我们自己的元素活着时"的异常；否则原样抛出，不改变 Apple 行为。

static void NIIInstallPromotionGuard(void) {
    if (sNIIGuardInstalled) return;

    Class managerClass = NSClassFromString(@"SAUISystemApertureManager");
    SEL selector = NSSelectorFromString(@"_reevaluatePromotedElements");
    Method method = managerClass ? class_getInstanceMethod(managerClass, selector) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding || strcmp(encoding, "v16@0:8") != 0) {
        NIILog(@"promotion guard 未安装（encoding=%s）", encoding ?: "none");
        return;
    }

    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(id receiver) {
        @try {
            ((void (*)(id, SEL))original)(receiver, selector);
        } @catch (NSException *exception) {
            if (sNIIGuardHandling) {
                // 正在清理时再次异常：吞掉，绝不能在清理路径里再把 SpringBoard 抛崩
                NIILog(@"guard 重入异常已吞掉：%@", exception.name);
                return;
            }
            if (!sNIICurrent) @throw;

            NIILog(@"promotion guard 捕获 %@: %@", exception.name, exception.reason);
            if (++sNIIGuardFailures >= 5) {
                sNIIGuardDisabled = YES;
                NIILog(@"已连续 %d 次异常，本次 respring 前不再创建元素", sNIIGuardFailures);
            }
            sNIIGuardHandling = YES;
            NIIRemoveCurrent(@"promotion-guard");
            sNIIGuardHandling = NO;
        }
    });

    class_replaceMethod(managerClass, selector, replacement, encoding);
    sNIIGuardInstalled = YES;
    NIILog(@"promotion guard 已安装在 -[SAUISystemApertureManager _reevaluatePromotedElements]");
}

// ============================== 横幅钩子 ==============================

static void NIIHandleBanner(id destination, id request);

static void NIILogBannerCandidates(Class cls) {
    NSArray<NSString *> *keywords = @[@"post", @"present", @"request", @"banner", @"notification"];
    NSUInteger lines = 0;
    for (Class c = cls; c && c != [NSObject class] && lines < 80; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);
        if (!methods) continue;
        for (unsigned int i = 0; i < count && lines < 80; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            BOOL related = NO;
            for (NSString *keyword in keywords) {
                if ([name rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    related = YES;
                    break;
                }
            }
            if (!related) continue;
            NIILog(@"候选 %@ -%@ [%s]", NSStringFromClass(c), name, method_getTypeEncoding(methods[i]) ?: "?");
            lines++;
        }
        free(methods);
    }
}

static NSString *NIIFindBannerMethod(Class cls, Class *definingOut, const char **encodingOut, int *argsOut) {
    for (Class c = cls; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);
        if (!methods) continue;
        NSString *found = nil;
        for (unsigned int i = 0; i < count && !found; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            const char *encoding = method_getTypeEncoding(methods[i]);
            if (!encoding || ![name hasPrefix:@"postNotificationRequest"]) continue;
            if (strcmp(encoding, "v32@0:8@16@24") == 0) {
                *argsOut = 2; *encodingOut = encoding; *definingOut = c; found = name;
            } else if (strcmp(encoding, "v24@0:8@16") == 0) {
                *argsOut = 1; *encodingOut = encoding; *definingOut = c; found = name;
            }
        }
        free(methods);
        if (found) return found;
    }
    return nil;
}

// ============================== 全量入口：过滤与去重 ==============================
// 分发层（NCNotificationDispatcher）和横幅层（SBNotificationBannerDestination）都会拿到同一条
// NCNotificationRequest，用 uuid / notificationIdentifier 去重，避免同一条通知建两次元素。

static NSString *sNIILastKey;
static CFAbsoluteTime sNIILastKeyTime = 0;

static NSString *NIIRequestKey(id request) {
    id uuid = NIISafeValue(request, @"uuid");
    if ([uuid isKindOfClass:[NSUUID class]]) {
        NSString *uuidString = [(NSUUID *)uuid UUIDString];
        if (uuidString.length) return uuidString;
    }
    NSString *identifier = NIISafeString(request, @"notificationIdentifier");
    if (identifier.length) return identifier;
    NSDictionary<NSString *, NSString *> *info = NIIInfoFromRequest(request);
    return [NSString stringWithFormat:@"%@|%@|%@", info[@"bundleID"], info[@"title"], info[@"message"]];
}

static BOOL NIIAlreadyHandled(id request) {
    NSString *key = NIIRequestKey(request);
    return key.length && sNIILastKey && [key isEqualToString:sNIILastKey]
           && (CFAbsoluteTimeGetCurrent() - sNIILastKeyTime) < 2.0;
}

static void NIIMarkHandled(id request) {
    NSString *key = NIIRequestKey(request);
    if (!key.length) return;
    sNIILastKey = key;
    sNIILastKeyTime = CFAbsoluteTimeGetCurrent();
}

static BOOL NIIShouldIncludeRequest(id request) {
    if (!request) return NO;
    if (!sNIIOnlyThirdParty) return YES;
    NSString *bundleID = NIISafeString(request, @"sectionIdentifier")
                      ?: NIISafeString(request, @"bundleIdentifier");
    if (!bundleID.length) return NO;
    return ![bundleID hasPrefix:@"com.apple."];
}

// 分发层入口：所有 App 的新通知都经过这里，跟"是否弹横幅""是否锁屏"无关
static void NIIHandleIncomingRequest(id request, BOOL isModify) {
    if (!sNIIEnabled) return;
    if (isModify && !sNIIIncludeModified) return;
    if (!NIIShouldIncludeRequest(request)) return;
    if (NIIAlreadyHandled(request)) return;
    NIIMarkHandled(request);

    NSDictionary<NSString *, NSString *> *info = NIIInfoFromRequest(request);
    NIILog(@"分发层收到通知%@：%@ | %@ | %@", isModify ? @"（更新）" : @"",
           info[@"bundleID"], NIIShortText(info[@"title"], 30), NIIShortText(info[@"message"], 60));

    id requestRef = request;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sNIIEnabled || sNIIUnsafe || sNIIGuardDisabled) return;
        NIIPresent(requestRef);   // 只负责上岛；系统横幅由横幅钩子负责淡掉
    });
}

static void NIIInstallBannerHook(void) {
    if (sNIIHookInstalled) return;

    Class cls = NSClassFromString(@"SBNotificationBannerDestination");
    if (!cls) {
        NIILog(@"SBNotificationBannerDestination 尚未加载，稍后重试");
        return;
    }

    Class defining = Nil;
    const char *encoding = NULL;
    int args = 0;
    NSString *name = NIIFindBannerMethod(cls, &defining, &encoding, &args);

    if (!name) {
        NIILog(@"没找到 postNotificationRequest*，下面是候选方法：");
        NIILogBannerCandidates(cls);
        return;
    }

    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(defining, selector);
    IMP original = method ? method_getImplementation(method) : NULL;
    if (!original) {
        NIILog(@"%@ 无实现", name);
        return;
    }

    IMP replacement;
    if (args == 2) {
        replacement = imp_implementationWithBlock(^(id receiver, id request, id other) {
            ((void (*)(id, SEL, id, id))original)(receiver, selector, request, other);
            NIIHandleBanner(receiver, request);
        });
    } else {
        replacement = imp_implementationWithBlock(^(id receiver, id request) {
            ((void (*)(id, SEL, id))original)(receiver, selector, request);
            NIIHandleBanner(receiver, request);
        });
    }

    class_replaceMethod(defining, selector, replacement, encoding);
    sNIIHookInstalled = YES;
    NIILog(@"横幅钩子已装在 -[%@ %@]（%d 个参数）", NSStringFromClass(defining), name, args);
}

static void NIIHandleBanner(id destination, id request) {
    if (!sNIIEnabled) return;
    if (!NIIShouldIncludeRequest(request)) return;

    // 分发层已经把这条通知送上岛的话，这里只负责淡横幅，不再重复建元素
    BOOL already = NIIAlreadyHandled(request);
    NIIMarkHandled(request);

    id requestRef = request;
    __weak id weakDestination = destination;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sNIIEnabled || sNIIUnsafe || sNIIGuardDisabled) return;
        BOOL shown = already ? (sNIICurrent != nil) : NIIPresent(requestRef);
        if (shown && sNIIHideBanner) NIIBeginBannerHide(weakDestination);
    });
}

// ============================== Hooks ==============================

%hook SBSystemApertureController

- (id)initWithWindowScene:(id)scene {
    id result = %orig;
    if (result) {
        sNIIController = result;
        NIILog(@"已捕获 SBSystemApertureController");
    }
    return result;
}

- (id)registerElement:(id)element {
    if (!sNIIController) sNIIController = self;
    return %orig;
}

%end

%hook NCNotificationDispatcher

// 全量入口：所有 App 的新通知（含锁屏、含未开横幅的 App）都会经过这里
- (void)postNotificationWithRequest:(id)request {
    %orig;
    NIIHandleIncomingRequest(request, NO);
}

// 已有通知被更新（默认不上岛，可用 IncludeModified 打开）
- (void)modifyNotificationWithRequest:(id)request {
    %orig;
    NIIHandleIncomingRequest(request, YES);
}

%end

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    NIIInstallBannerHook();
}

%end

%ctor {
    @autoreleasepool {
        NIILoadPrefs();
        NIIEvaluateBreadcrumb();
        NIIInstallBannerHook();
        NIIInstallPromotionGuard();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NIIInstallBannerHook();
            NIIInstallPromotionGuard();
        });
    }
}
