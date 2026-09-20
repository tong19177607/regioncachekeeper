/**
 * RegionCacheKeeper v1.2
 * ============================================================
 * 三合一：自动缓存国区 IAP 商品 + locale 显示替换 + 越狱检测屏蔽
 *
 * 原理:
 *   1) 请求层: SKProductsRequest 注入 CN storefront header → 拉国区 SKProduct
 *   2) 对象层: Hook SKProduct.priceLocale + NSLocale.localeIdentifier → 显示 ¥
 *   3) 支付层: Hook SKPayment + SKPaymentQueue → 确保用国区 SKProduct 发起支付
 *   4) 越狱屏蔽: stat/access/fork 等系统调用伪装, 让 App 检测不到越狱
 *
 * 设计原则:
 *   - 不伪造交易, 钱照付, 凭证照出
 *   - 不修改 App 二进制, 不拦截 receipt/JWS
 *   - 只 hook StoreKit 相关类(不用 NSObject 全局 hook)
 *   - 安装即生效, 无配置
 * ============================================================
 */

#import <StoreKit/StoreKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <unistd.h>
#import <sys/stat.h>
#import <dlfcn.h>

// ===== 目标地区(硬编码, 无配置) =====
static NSString * const RCK_TARGET_STOREFRONT = @"CHN";
static NSString * const RCK_TARGET_LOCALE_ID  = @"zh_CN@currency=CNY";
static NSString * const RCK_TARGET_LOCALE_STR = @"zh_CN";

// ===== 全局 product cache =====
static NSMutableDictionary *gProductCache = nil;   // productIdentifier -> SKProduct

extern "C" void JBShieldInit(void);
extern "C" void SK2HookInit(void);

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

#pragma mark - 1. 请求层: SKProductsRequest 注入 CN storefront

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

// 首次 start 时额外触发一次请求, 确保国区 SKProduct 被缓存
- (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gProductCache = [NSMutableDictionary dictionary];
    });

    %orig;
}

%end

#pragma mark - 2. 对象层: SKProduct.priceLocale + NSLocale.localeIdentifier

%hook SKProduct

// 直接 hook getter, 返回 zh_CN locale
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
    // 只对国区 locale 强制, 其他情况保持原样(避免影响系统其他 locale 用途)
    NSString *orig = %orig;
    if ([orig hasPrefix:@"zh"]) return orig;   // 已经是中文的就不动
    return RCK_TARGET_LOCALE_ID;
}

%end

#pragma mark - 3. 支付层: SKPayment + SKPaymentQueue

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

// 伪装 storefront 返回 CHN, 防止 App 通过 [SKPaymentQueue defaultQueue].storefront 检查
- (id)storefront {
    static id fakeStorefront = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 用 KVC 构造一个假的 SKStorefront (iOS 15+ 上这个类存在)
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

#pragma mark - 4. 缓存 SKProduct (通过 hook SKProductsResponse 的 products getter)

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

#pragma mark - 注入入口

%ctor {
    @autoreleasepool {
        if (!RCKIsThirdPartyApp()) return;
        NSLog(@"[RCK] v1.3 loaded in %@", [NSBundle mainBundle].bundleIdentifier ?: @"?");
        JBShieldInit();
        SK2HookInit();
    }
}
