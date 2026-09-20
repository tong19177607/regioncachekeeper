/**
 * RegionCacheKeeper v2.2
 * ============================================================
 * 100% 照抄无根外币(txwz.dylib 逆向确认的 6 个 hook), 纯 ObjC
 *
 * 用途: 国区 App 内购商品, 用美区(其他区) Apple ID 也能下单。
 *       页面价格不变, 系统支付弹窗按账号所在区收外币(如 ¥6 档 → $1),
 *       付款后商品正常到账。
 *
 * 无根外币同款 6 hook:
 *   SKProduct             -price          (页面原价, 不改)
 *   SKProduct             -priceLocale    → zh_CN locale
 *   _NSPlaceholderLocale  -initWithLocaleIdentifier: → zh_CN@currency=CNY
 *   NSLocale              -localeIdentifier
 *   NSLocale              +localeWithLocaleIdentifier:
 *   NSLocale              +canonicalLanguageIdentifierFromString:
 *
 * 不做(无根外币也没有): 请求头注入 / 商品缓存 / 支付替换 / storefront 伪装
 * ============================================================
 */

#import <StoreKit/StoreKit.h>

// ===== 目标 locale(和 App 商品所在区一致: 国区) =====
static NSString * const RCK_LOCALE_ID  = @"zh_CN@currency=CNY";
static NSString * const RCK_LOCALE_STR = @"zh_CN";

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

#pragma mark - SKProduct: price(原价) + priceLocale(zh_CN)

%hook SKProduct

// 价格数字保持原样(页面仍显示原价; 外币金额由苹果系统弹窗服务端给出)
- (NSDecimalNumber *)price {
    return %orig;
}

// 货币 locale 伪装成 zh_CN
- (NSLocale *)priceLocale {
    static NSLocale *fakeLocale = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fakeLocale = [NSLocale localeWithLocaleIdentifier:RCK_LOCALE_STR];
    });
    return fakeLocale;
}

%end

#pragma mark - _NSPlaceholderLocale(私有类, NSLocale init 真正实现)

%hook _NSPlaceholderLocale

- (id)initWithLocaleIdentifier:(NSString *)identifier {
    if ([identifier hasPrefix:@"zh"]) return %orig;
    return %orig(RCK_LOCALE_ID);
}

%end

#pragma mark - NSLocale 三个方法

%hook NSLocale

// 实例 localeIdentifier: 非 zh 一律 zh_CN@currency=CNY
- (NSString *)localeIdentifier {
    NSString *orig = %orig;
    if ([orig hasPrefix:@"zh"]) return orig;
    return RCK_LOCALE_ID;
}

// 类方法 localeWithLocaleIdentifier: 强制目标 locale
+ (NSLocale *)localeWithLocaleIdentifier:(NSString *)identifier {
    return %orig(RCK_LOCALE_ID);
}

// 类方法 canonicalLanguageIdentifierFromString: 非 zh → zh-Hans
+ (NSString *)canonicalLanguageIdentifierFromString:(NSString *)string {
    NSString *orig = %orig;
    if ([orig hasPrefix:@"zh"]) return orig;
    return @"zh-Hans";
}

%end

#pragma mark - 注入入口

%ctor {
    @autoreleasepool {
        if (!RCKIsThirdPartyApp()) return;
        NSLog(@"[RCK] v2.2 loaded in %@", [NSBundle mainBundle].bundleIdentifier ?: @"?");
    }
}
