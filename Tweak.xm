/**
 * RegionCacheKeeper v1.5
 * ============================================================
 * 无根外币模式 + 切号插件功能 (精简版, 去掉越狱屏蔽/全局hook)
 *
 *  - 请求层(切号): SKProductsRequest 注入 CN storefront header
 *                  → 苹果返回真实国区 SKProduct (价格数字就是 CNY)
 *  - 缓存层(切号): SKProductsResponse 收到的商品进缓存
 *  - 支付层(切号): 发起支付时替换为缓存的国区 SKProduct
 *  - 显示层(外币): SKProduct.priceLocale / NSLocale 伪装 zh_CN
 *                  (Swift 端增强见 SK2SwiftHook.swift, 无根外币同款)
 *
 *  - 无越狱屏蔽, 无界面, 安装即生效
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

#pragma mark - 1. 请求层(切号): SKProductsRequest 注入 CN storefront

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

#pragma mark - 2. 缓存层(切号): 响应里的国区 SKProduct 进缓存

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

#pragma mark - 3. 显示层(外币): SKProduct.priceLocale

%hook SKProduct

- (NSLocale *)priceLocale {
    static NSLocale *fakeLocale = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fakeLocale = [[NSLocale alloc] initWithLocaleIdentifier:RCK_TARGET_LOCALE_STR];
    });
    return fakeLocale;
}

%end

%hook NSLocale

// hook localeIdentifier getter, 防止 App 自己检查 locale
- (NSString *)localeIdentifier {
    NSString *orig = %orig;
    if ([orig hasPrefix:@"zh"]) return orig;   // 已经是中文的就不动
    return RCK_TARGET_LOCALE_ID;
}

%end

#pragma mark - 4. 支付层(切号): 替换为缓存的国区 SKProduct

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

// 伪装 storefront 返回 CHN
- (id)storefront {
    static id fakeStorefront = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = objc_getClass("SKStorefront");
        if (cls) {
            fakeStorefront = [[cls alloc] init];
            @try { [fakeStorefront setValue:RCK_TARGET_STOREFRONT forKey:@"identifier"]; } @catch (NSException *e) {}
            @try { [fakeStorefront setValue:RCK_TARGET_STOREFRONT forKey:@"countryCode"]; } @catch (NSException *e) {}
        }
    });
    if (fakeStorefront) return fakeStorefront;
    return %orig;
}

%end

#pragma mark - 注入入口

%ctor {
    @autoreleasepool {
        if (!RCKIsThirdPartyApp()) return;
        gProductCache = [NSMutableDictionary dictionary];

        NSLog(@"[RCK] v1.5 loaded in %@", [NSBundle mainBundle].bundleIdentifier ?: @"?");

        // Swift 端(无根外币同款): NSLocale init/canonicalLanguage/components
        Class cls = objc_getClass("SK2SwiftHook");
        if (!cls) cls = objc_getClass("RegionCacheKeeper.SK2SwiftHook");
        if (cls && [cls respondsToSelector:@selector(install)]) {
            [cls performSelector:@selector(install)];
        }
    }
}
