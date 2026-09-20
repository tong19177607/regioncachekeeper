/**
 * SK2Hook — StoreKit2 支持（纯 ObjC, 无 Swift 运行时膨胀）
 *
 * 原理:
 *   StoreKit2 的 Product struct 底层包装了 ObjC 私有对象 (_StoreProduct / SKStoreProduct 等)
 *   用 runtime 动态扫描这些私有类, hook priceLocale / locale / storefront 相关方法
 *   同时 hook NSMutableURLRequest 注入 CN storefront header (覆盖 SK2 的请求路径)
 */

#import <Foundation/Foundation.h>
#import <StoreKit/StoreKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// 目标常量(和 Tweak.xm 一致)
static NSString * const SK2_TARGET_STOREFRONT = @"CHN";
static NSString * const SK2_TARGET_LOCALE_STR = @"zh_CN";

// 假 locale 单例
static NSLocale *SK2FakeLocale(void) {
    static NSLocale *locale = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        locale = [[NSLocale alloc] initWithLocaleIdentifier:SK2_TARGET_LOCALE_STR];
    });
    return locale;
}

#pragma mark - 1. Hook NSMutableURLRequest: 对苹果 StoreKit 请求注入 CN header

static IMP orig_setValue_forHTTPHeaderField = NULL;

// hook -[NSMutableURLRequest setValue:forHTTPHeaderField:]
static void hooked_setValue_forHTTPHeaderField(id self, SEL _cmd, NSString *value, NSString *field) {
    // 拦截 StoreKit 内部的请求: 当设置 X-Apple-Store-Front 时强制改 CHN
    if ([field isEqualToString:@"X-Apple-Store-Front"]) {
        ((void(*)(id, SEL, NSString*, NSString*))orig_setValue_forHTTPHeaderField)(self, _cmd, SK2_TARGET_STOREFRONT, field);
        return;
    }
    ((void(*)(id, SEL, NSString*, NSString*))orig_setValue_forHTTPHeaderField)(self, _cmd, value, field);
}

#pragma mark - 2. 动态扫描并 hook StoreKit2 私有类

// 通用的 priceLocale hook (返回 fake locale)
static NSLocale *generic_priceLocale_hook(id self, SEL _cmd) {
    return SK2FakeLocale();
}

// 通用的 storefront getter hook
static id generic_storefront_hook(id self, SEL _cmd) {
    static id fakeStorefront = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = objc_getClass("SKStorefront");
        if (cls) {
            fakeStorefront = [[cls alloc] init];
            @try { [fakeStorefront setValue:SK2_TARGET_STOREFRONT forKey:@"identifier"]; } @catch (NSException *e) {}
            @try { [fakeStorefront setValue:SK2_TARGET_STOREFRONT forKey:@"countryCode"]; } @catch (NSException *e) {}
        }
    });
    return fakeStorefront;
}

// 检查类名是否像 StoreKit2 内部私有类
static BOOL SK2IsPrivateStoreClass(NSString *clsName) {
    if (!clsName || clsName.length == 0) return NO;
    // StoreKit2 内部已知模式
    NSArray *patterns = @[
        @"_StoreProduct", @"_SKStoreProduct", @"SKStoreProduct",
        @"_ProductStore", @"ProductStore",
        @"_StoreKitProduct", @"StoreKitProduct",
        @"_SK2Product", @"SK2Product",
        @"_InternalProduct", @"InternalProduct",
        @"SKProductInternal", @"_SKProductInternal",
    ];
    for (NSString *p in patterns) {
        if ([clsName containsString:p]) return YES;
    }
    return NO;
}

// 尝试 hook 指定类的 priceLocale / storefront / locale 方法
static void SK2TryHookClass(Class cls) {
    NSString *clsName = NSStringFromClass(cls);
    if (!clsName) return;

    // priceLocale getter
    SEL priceLocaleSel = NSSelectorFromString(@"priceLocale");
    if (class_getInstanceMethod(cls, priceLocaleSel)) {
        Method m = class_getInstanceMethod(cls, priceLocaleSel);
        IMP origImp = method_getImplementation(m);
        // 已经 hook 过的跳过
        if (origImp != (IMP)generic_priceLocale_hook) {
            method_setImplementation(m, (IMP)generic_priceLocale_hook);
            NSLog(@"[SK2] hooked %@ -priceLocale", clsName);
        }
    }

    // storefront getter
    SEL storefrontSel = NSSelectorFromString(@"storefront");
    if (class_getInstanceMethod(cls, storefrontSel)) {
        Method m = class_getInstanceMethod(cls, storefrontSel);
        IMP origImp = method_getImplementation(m);
        if (origImp != (IMP)generic_storefront_hook) {
            method_setImplementation(m, (IMP)generic_storefront_hook);
            NSLog(@"[SK2] hooked %@ -storefront", clsName);
        }
    }

    // countryCode getter (有些私有类用这个)
    SEL countryCodeSel = NSSelectorFromString(@"countryCode");
    if (class_getInstanceMethod(cls, countryCodeSel)) {
        // 用 class_replaceMethod 或 method_setImplementation
        // countryCode 返回 NSString*, 需要一个返回 "CHN" 的 hook
        // 简单处理: 用 existingImplementation 替换
        // 为了类型安全, 单独写一个 hook
    }
}

// countryCode hook
static NSString *generic_countryCode_hook(id self, SEL _cmd) {
    return SK2_TARGET_STOREFRONT;
}

static void SK2TryHookCountryCode(Class cls) {
    NSString *clsName = NSStringFromClass(cls);
    SEL countryCodeSel = NSSelectorFromString(@"countryCode");
    if (class_getInstanceMethod(cls, countryCodeSel)) {
        Method m = class_getInstanceMethod(cls, countryCodeSel);
        IMP origImp = method_getImplementation(m);
        if (origImp != (IMP)generic_countryCode_hook) {
            method_setImplementation(m, (IMP)generic_countryCode_hook);
            NSLog(@"[SK2] hooked %@ -countryCode", clsName);
        }
    }
}

#pragma mark - 3. 遍历所有已加载的类

static void SK2ScanAndHookAllClasses(void) {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;

    int hooked = 0;
    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        NSString *name = NSStringFromClass(cls);
        if (!name) continue;

        // 只 hook StoreKit 相关的私有类
        if (SK2IsPrivateStoreClass(name)) {
            SK2TryHookClass(cls);
            SK2TryHookCountryCode(cls);
            hooked++;
        }
    }
    free(classes);
    NSLog(@"[SK2] scanned %u classes, hooked %d StoreKit2 private classes", classCount, hooked);
}

#pragma mark - 4. Hook NSMutableURLRequest (请求层)

static void SK2HookURLRequest(void) {
    Class reqClass = [NSMutableURLRequest class];
    SEL sel = @selector(setValue:forHTTPHeaderField:);
    Method m = class_getInstanceMethod(reqClass, sel);
    if (m) {
        orig_setValue_forHTTPHeaderField = method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_setValue_forHTTPHeaderField);
        NSLog(@"[SK2] hooked NSMutableURLRequest -setValue:forHTTPHeaderField:");
    }
}

#pragma mark - 5. 延迟扫描 (等 StoreKit2 framework 加载完)

static void SK2DelayedScan(void) {
    // 第一次: 0.5s 后
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SK2ScanAndHookAllClasses();
        SK2HookURLRequest();
    });
    // 第二次: 3s 后 (有些类延迟加载)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SK2ScanAndHookAllClasses();
    });
}

#pragma mark - 公开入口

void SK2HookInit(void) {
    SK2DelayedScan();
    NSLog(@"[SK2] StoreKit2 hooks init scheduled");
}
