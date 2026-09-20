/**
 * RegionCacheKeeper v2.1
 * ============================================================
 * 无根外币同款 hook (从其 dylib 符号逐个还原, 纯 ObjC) + 切号(请求层注入)
 *
 * 无根外币同款 5 hook:
 *   SKProduct          -priceLocale                        → zh_CN
 *   _NSPlaceholderLocale -initWithLocaleIdentifier:        → zh_CN@currency=CNY (私有类!)
 *   NSLocale           -localeIdentifier                   → zh_CN@currency=CNY
 *   NSLocale           +localeWithLocaleIdentifier:        → zh_CN@currency=CNY
 *   NSLocale           +canonicalLanguageIdentifierFromString: → zh
 *
 * 切号部分(RegionCacheKeeper):
 *   %hook SKProductsRequest  -_urlRequest  注入 X-Apple-Store-Front: CHN
 *                                          → 苹果返回真实国区商品(价格数字变 CNY)
 *   %hook SKProductsResponse -products     国区商品进缓存
 *   %hook SKPayment/SKPaymentQueue         支付时替换为缓存的国区商品
 *
 * 无越狱屏蔽, 无界面, 安装即生效
 * ============================================================
 */

#import <StoreKit/StoreKit.h>
#import <objc/runtime.h>

// ===== 目标地区(硬编码, 无配置) =====
static NSString * const RCK_TARGET_STOREFRONT = @"CHN";
static NSString * const RCK_TARGET_LOCALE_ID  = @"zh_CN@currency=CNY";
static NSString * const RCK_TARGET_LOCALE_STR = @"zh_CN";

// ===== 全局 product cache =====
static NSMutableDictionary *gProductCache = nil;

#pragma mark - 注入门控(只对第三方 App 生效)

static BOOL RCKIsThirdPartyApp(void) {
    NSString *p = [NSBundle mainBundle].bundlePath ?: @"";
    if (p.length == 0) return NO;
    if ([p hasPrefix:@"/System/"]) return NO;
    if ([p hasPrefix:@"/Applications/"]) return NO;
    if ([p hasPrefix:@"/usr/"]) return NO;
    if ([p hasPrefix:@"/bin/"]) return NO;
    if ([p hasPrefix:@"/sbin/"]) return NO;
    if ([p hasPrefix:@"/Library/Application Support/"]) return NO;
    if ([p hasPrefix:@"/private/var/stash"]) return NO;
    return [NSBundle mainBundle].bundleIdentifier.length > 0;
}

#pragma mark - 无根外币同款: SKProduct.priceLocale

%hook SKProduct

- (NSLocale *)priceLocale {
    static NSLocale *fakeLocale = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fakeLocale = [NSLocale localeWithLocaleIdentifier:RCK_TARGET_LOCALE_STR];
    });
    return fakeLocale;
}

%end

#pragma mark - 无根外币同款: NSLocale 四个方法(含私有类 _NSPlaceholderLocale)

// 无根外币 hook 的是 _NSPlaceholderLocale(私有类, NSLocale init 的真正实现)
%hook _NSPlaceholderLocale

- (id)initWithLocaleIdentifier:(NSString *)identifier {
    if ([identifier hasPrefix:@"zh"]) return %orig;
    return %orig(RCK_TARGET_LOCALE_ID);
}

%end

%hook NSLocale

// 1) 实例 localeIdentifier: 非 zh 一律返回 zh_CN@currency=CNY
- (NSString *)localeIdentifier {
    NSString *orig = %orig;
    if ([orig hasPrefix:@"zh"]) return orig;
    return RCK_TARGET_LOCALE_ID;
}

// 2) 类方法 localeWithLocaleIdentifier: 强制构造目标 locale
+ (NSLocale *)localeWithLocaleIdentifier:(NSString *)identifier {
    return %orig(RCK_TARGET_LOCALE_ID);
}

// 3) 类方法 canonicalLanguageIdentifierFromString: 非 zh 返回 zh-Hans
+ (NSString *)canonicalLanguageIdentifierFromString:(NSString *)string {
    NSString *orig = %orig;
    if ([orig hasPrefix:@"zh"]) return orig;
    return @"zh-Hans";
}

%end

#pragma mark - 切号: 请求层注入 CN storefront

%hook SKProductsRequest

// StoreKit 内部构造 NSURLRequest 时会调 _urlRequest
- (id)_urlRequest {
    NSMutableURLRequest *req = %orig;
    if ([req isKindOfClass:[NSMutableURLRequest class]]) {
        [req setValue:RCK_TARGET_STOREFRONT forHTTPHeaderField:@"X-Apple-Store-Front"];
        [req setValue:RCK_TARGET_LOCALE_STR forHTTPHeaderField:@"Accept-Language"];
    }
    return req;
}

%end

#pragma mark - 切号: 响应里的国区 SKProduct 进缓存

%hook SKProductsResponse

- (NSArray *)products {
    NSArray *list = %orig;
    if (list.count > 0) {
        for (SKProduct *p in list) {
            if (p.productIdentifier) {
                gProductCache[p.productIdentifier] = p;
            }
        }
        NSLog(@"[RCK] cached %lu products", (unsigned long)list.count);
    }
    return list;
}

%end

#pragma mark - 切号: 支付时替换为缓存的国区商品

%hook SKPayment

+ (id)paymentWithProduct:(SKProduct *)product {
    if (product && product.productIdentifier) {
        SKProduct *cached = gProductCache[product.productIdentifier];
        if (cached && cached != product) {
            NSLog(@"[RCK] replace with cached CN product: %@", product.productIdentifier);
            return %orig(cached);
        }
    }
    return %orig;
}

%end

%hook SKMutablePayment

+ (id)paymentWithProduct:(SKProduct *)product {
    if (product && product.productIdentifier) {
        SKProduct *cached = gProductCache[product.productIdentifier];
        if (cached && cached != product) {
            return %orig(cached);
        }
    }
    return %orig;
}

%end

%hook SKPaymentQueue

- (void)addPayment:(SKPayment *)payment {
    SKProduct *product = nil;
    @try { product = [payment valueForKey:@"product"]; } @catch (NSException *e) { product = nil; }

    if (product && product.productIdentifier) {
        SKProduct *cached = gProductCache[product.productIdentifier];
        if (cached && cached != product) {
            NSLog(@"[RCK] addPayment: using cached CN product");
            SKMutablePayment *newPayment = [SKMutablePayment paymentWithProduct:cached];
            newPayment.quantity = payment.quantity;
            if ([payment respondsToSelector:@selector(applicationUsername)]) {
                @try { newPayment.applicationUsername = payment.applicationUsername; } @catch (NSException *e) {}
            }
            %orig(newPayment);
            return;
        }
    }
    %orig;
}

%end

#pragma mark - 注入入口

%ctor {
    @autoreleasepool {
        if (!RCKIsThirdPartyApp()) return;
        gProductCache = [NSMutableDictionary dictionary];
        NSLog(@"[RCK] v2.1 loaded in %@", [NSBundle mainBundle].bundleIdentifier ?: @"?");
    }
}
