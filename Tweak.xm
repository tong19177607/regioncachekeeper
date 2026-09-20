/**
 * RegionCacheKeeper v1.0.0（全新起点）
 * ============================================================
 * 目标：国区上架的 IAP 商品，在登录外区 Apple ID 时也能正常购买。
 *       支付段（密码/面容确认、扣款、凭证、到账）完全不干预，
 *       系统弹窗按外区账号收外币，这是苹果原生行为。
 *
 * 原理（等价于手动流程的自动化）：
 *   手动：国区 ID 进游戏点金额(进程拿到国区 SKProduct)→不支付取消
 *         →切外区 ID→内存商品仍在→外区 ID 支付成功（已在 iOS 16.0.2 实证）
 *   插件：外区 ID 冷启动，在 SK1 商品请求出口注入国区 storefront，
 *         让苹果服务端直接返回真·国区 SKProduct，门当场打开；
 *         同时 hook SKStorefront getter，使 App 读到的账号归属区也是 CHN。
 *
 * 本版只做三件事：
 *   1. SK1 商品请求 storefront header 抓包 + 改写（中国区店面号 143465）
 *   2. 响应商品 / invalid 列表诊断（判决该 App 是否支持外币挡位）
 *   3. App 侧所有店面读取点记录（调用栈去重）并返回国区
 *
 * 明确不做：locale/price 展示伪造、商品缓存替换、支付替换、prefetch、
 *           越狱屏蔽、NSObject/libc 全局 hook、界面与配置。
 * ============================================================
 */

#import <StoreKit/StoreKit.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ===== 目标店面：中国区 =====
static NSString * const RCK_COUNTRY_CODE  = @"CHN";
static NSString * const RCK_STOREFRONT_ID = @"143465";
static NSString * const RCK_HEADER_NAME   = @"X-Apple-Store-Front";

// SKRequest 的私有请求构造方法（SK1 商品查询请求出口）
@interface SKRequest (RCKPrivate)
- (id)_urlRequest;
@end

// ============================================================
// 日志：NSLog + App 沙盒 Documents/rck_debug.log
// ============================================================

static NSMutableSet *g_logSeen = nil;   // 调用栈去重

static NSString *RCKLogPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        path = [docs stringByAppendingPathComponent:@"rck_debug.log"];
    });
    return path;
}

static void RCKLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@ [RCK] %@",
                      [NSDate date], body];
    NSLog(@"%@", line);

    @try {
        NSString *p = RCKLogPath();
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:p]) {
            [fm createFileAtPath:p contents:nil attributes:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        [fh seekToEndOfFile];
        [fh writeData:[[line stringByAppendingString:@"\n"]
                       dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (__unused NSException *e) {
        // 沙盒写失败时 NSLog 仍在
    }
}

// 调用栈（跳过本工具函数自身若干帧）
static NSString *RCKStack(NSUInteger skip, NSUInteger maxCount) {
    NSArray *syms = [NSThread callStackSymbols];
    NSUInteger start = MIN(skip, syms.count);
    NSUInteger len = MIN(maxCount, syms.count - start);
    if (len == 0) return @"(no stack)";
    return [[syms subarrayWithRange:NSMakeRange(start, len)]
            componentsJoinedByString:@"\n    "];
}

// 同一签名只输出一次完整调用栈，避免刷屏
static void RCKLogOnce(NSString *signature, NSString *fmt, ...) {
    BOOL first = NO;
    @synchronized (g_logSeen) {
        if (![g_logSeen containsObject:signature]) {
            [g_logSeen addObject:signature];
            first = YES;
        }
    }
    va_list args;
    va_start(args, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    if (first) {
        RCKLog(@"%@\n    %@", body, RCKStack(2, 10));
    } else {
        RCKLog(@"%@ (stack suppressed)", body);
    }
}

// ============================================================
// 注入门控：仅第三方 GUI App
// ============================================================

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

// 大小写不敏感取 header
static NSString *RCKHeaderValue(NSDictionary *headers, NSString *name) {
    for (NSString *k in headers) {
        if ([k caseInsensitiveCompare:name] == NSOrderedSame) {
            return headers[k];
        }
    }
    return nil;
}

// ============================================================
// 1. SK1 商品请求出口：抓真实 header，改写国区 storefront
//    hook 在父类 SKRequest，门控到 SKProductsRequest 实例
//    （_urlRequest 实现在父类时也能命中）
// ============================================================

%hook SKRequest

- (id)_urlRequest {
    id request = %orig;

    if (![self isKindOfClass:objc_getClass("SKProductsRequest")]) {
        return request;
    }

    @try {
        if (![request isKindOfClass:[NSURLRequest class]]) {
            RCKLog(@"_urlRequest unexpected class: %@", [request class]);
            return request;
        }

        NSURLRequest *r = (NSURLRequest *)request;
        NSDictionary *headers = r.allHTTPHeaderFields ?: @{};
        RCKLog(@"products request URL: %@", r.URL.absoluteString);
        RCKLog(@"products request ALL headers: %@", headers);

        NSMutableURLRequest *mutableReq = nil;
        if ([request isKindOfClass:[NSMutableURLRequest class]]) {
            mutableReq = (NSMutableURLRequest *)request;
        } else {
            mutableReq = [request mutableCopy];
            RCKLog(@"request was immutable, used mutableCopy");
        }

        NSString *origValue = RCKHeaderValue(headers, RCK_HEADER_NAME);
        NSString *newValue = nil;

        if (origValue.length > 0) {
            // 真实格式形如 "143441-1,29"：只替换前缀店面号，完整保留后缀标志位
            NSRange dash = [origValue rangeOfString:@"-"];
            if (dash.location != NSNotFound) {
                NSString *suffix = [origValue substringFromIndex:dash.location];
                newValue = [RCK_STOREFRONT_ID stringByAppendingString:suffix];
            } else {
                newValue = RCK_STOREFRONT_ID;
            }
        } else {
            // 原始请求没有该头（新系统可能移除）时的兜底
            newValue = [RCK_STOREFRONT_ID stringByAppendingString:@"-1,29"];
        }

        [mutableReq setValue:newValue forHTTPHeaderField:RCK_HEADER_NAME];
        RCKLog(@"storefront rewrite: '%@' -> '%@'", origValue, newValue);

        return mutableReq;
    } @catch (NSException *e) {
        RCKLog(@"_urlRequest hook EXCEPTION: %@", e);
        return request;
    }
}

%end

// ============================================================
// 2. 请求发起：确认 hook 链路触发 + 商品 id
// ============================================================

%hook SKProductsRequest

- (void)start {
    @try {
        RCKLog(@"SKProductsRequest -start productIdentifiers=%@",
               [self productIdentifiers]);
    } @catch (NSException *e) {
        RCKLog(@"start log EXCEPTION: %@", e);
    }
    %orig;
}

%end

// ============================================================
// 3. 响应诊断：真国区商品(CNY) 还是 invalid（A/B 类 App 判决点）
//    每个 response 对象只记一次
// ============================================================

%hook SKProductsResponse

- (NSArray *)products {
    NSArray *products = %orig;

    static char kRCKProductsLogged;
    if (!objc_getAssociatedObject(self, &kRCKProductsLogged)) {
        objc_setAssociatedObject(self, &kRCKProductsLogged, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try {
            RCKLog(@"response products count=%lu", (unsigned long)products.count);
            for (SKProduct *p in products) {
                RCKLog(@"  PRODUCT id=%@ price=%@ currency=%@ locale=%@",
                       p.productIdentifier,
                       p.price,
                       p.priceLocale.currencyCode,
                       p.priceLocale.localeIdentifier);
            }
        } @catch (NSException *e) {
            RCKLog(@"products log EXCEPTION: %@", e);
        }
    }
    return products;
}

- (NSArray *)invalidProductIdentifiers {
    NSArray *invalid = %orig;

    static char kRCKInvalidLogged;
    if (invalid.count > 0 &&
        !objc_getAssociatedObject(self, &kRCKInvalidLogged)) {
        objc_setAssociatedObject(self, &kRCKInvalidLogged, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        RCKLog(@"response INVALID product identifiers=%@ —— 该挡位在当前账号店面不可购(B类App信号)",
               invalid);
    }
    return invalid;
}

%end

// ============================================================
// 4. App 侧账号归属区读取：SKStorefront getter 返回国区
//    每次读取记录（调用栈去重），暴露 App 真实检测点
// ============================================================

%hook SKStorefront

- (NSString *)countryCode {
    NSString *orig = nil;
    @try { orig = %orig; } @catch (__unused NSException *e) {}
    RCKLogOnce(@"SKStorefront.countryCode",
               @"App READ SKStorefront.countryCode orig=%@ -> %@",
               orig, RCK_COUNTRY_CODE);
    return RCK_COUNTRY_CODE;
}

- (NSString *)identifier {
    NSString *orig = nil;
    @try { orig = %orig; } @catch (__unused NSException *e) {}
    RCKLogOnce(@"SKStorefront.identifier",
               @"App READ SKStorefront.identifier orig=%@ -> %@",
               orig, RCK_STOREFRONT_ID);
    return RCK_STOREFRONT_ID;
}

%end

// ============================================================
// 5. SKPaymentQueue：记录店面读取时机与支付提交（不干预支付）
// ============================================================

%hook SKPaymentQueue

- (SKStorefront *)storefront {
    SKStorefront *sf = %orig;
    @try {
        RCKLogOnce(@"SKPaymentQueue.storefront",
                   @"App READ paymentQueue.storefront -> orig code=%@ id=%@",
                   sf.countryCode, sf.identifier);
    } @catch (__unused NSException *e) {}
    return sf;
}

- (void)addPayment:(SKPayment *)payment {
    @try {
        RCKLog(@"addPayment SUBMIT id=%@ quantity=%ld applicationUsername=%@",
               payment.productIdentifier,
               (long)payment.quantity,
               payment.applicationUsername);
    } @catch (NSException *e) {
        RCKLog(@"addPayment log EXCEPTION: %@", e);
    }
    %orig;
}

%end

// ============================================================
// 注入入口
// ============================================================

%ctor {
    @autoreleasepool {
        if (!RCKIsThirdPartyApp()) return;

        g_logSeen = [NSMutableSet set];

        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"?";
        RCKLog(@"===== RCK v1.0.0 injected app=%@ ios=%@ =====",
               bid, [UIDevice currentDevice].systemVersion);

        // 启动 2 秒后记录一次真实账号店面（诊断基线）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                SKStorefront *sf = [SKPaymentQueue defaultQueue].storefront;
                RCKLog(@"baseline real account storefront: code=%@ id=%@",
                       sf.countryCode, sf.identifier);
            } @catch (NSException *e) {
                RCKLog(@"baseline storefront read EXCEPTION: %@", e);
            }
        });
    }
}
