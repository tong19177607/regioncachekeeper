// SK2SwiftHook.swift
// RegionCacheKeeper v1.4 — StoreKit2 + NSLocale 增强 hook (Swift)
// 按无根外币模式: 用 Swift hook NSLocale 的更多方法, 同时覆盖 StoreKit2 路径

import Foundation
import StoreKit
import ObjectiveC

// 目标常量
private let TARGET_LOCALE_ID = "zh_CN@currency=CNY"
private let TARGET_LOCALE_STR = "zh_CN"

@objc public class SK2SwiftHook: NSObject {

    // 递归防护
    private static var inHook = false

    /// 安装所有 Swift 端 hook
    @objc public static func install() {
        hookNSLocaleInit()
        hookNSLocaleCanonicalLanguage()
        hookNSLocaleComponents()
        NSLog("[SK2Swift] hooks installed")
    }

    // MARK: - NSLocale init hook
    // 所有通过 initWithLocaleIdentifier: 创建的 locale 都返回 zh_CN
    private static func hookNSLocaleInit() {
        let cls: AnyClass = NSLocale.self
        let original = class_getInstanceMethod(cls, #selector(NSLocale.init(localeIdentifier:)))
        guard let original = original else { return }

        let originalImp = method_getImplementation(original)

        // block 签名: (id self, SEL _cmd, NSString *identifier) -> id
        let block: @convention(block) (AnyObject, Selector, NSString) -> AnyObject = { self, cmd, identifier in
            // 递归防护: 正在 hook 内部时直接调原始实现
            if SK2SwiftHook.inHook {
                let orig = unsafeBitCast(originalImp, to: (@convention(c) (AnyObject, Selector, NSString) -> AnyObject).self)
                return orig(self, cmd, identifier)
            }

            SK2SwiftHook.inHook = true
            defer { SK2SwiftHook.inHook = false }

            // 强制用 zh_CN 调原始实现 (不通过 Swift init 避免递归)
            let orig = unsafeBitCast(originalImp, to: (@convention(c) (AnyObject, Selector, NSString) -> AnyObject).self)
            let result = orig(self, cmd, TARGET_LOCALE_STR as NSString)
            return result
        }

        let newImp = imp_implementationWithBlock(block)
        method_setImplementation(original, newImp)
    }

    // MARK: - NSLocale.canonicalLanguageIdentifierFromString: hook
    private static func hookNSLocaleCanonicalLanguage() {
        let cls: AnyClass = NSLocale.self
        let original = class_getClassMethod(cls, #selector(NSLocale.canonicalLanguageIdentifier(from:)))
        guard let original = original else { return }

        let originalImp = method_getImplementation(original)

        let block: @convention(block) (AnyObject, Selector, NSString) -> NSString = { _, cmd, str in
            let orig = unsafeBitCast(originalImp, to: (@convention(c) (AnyObject, Selector, NSString) -> NSString).self)
            let result = orig(NSLocale.self, cmd, str)
            // 非 zh 开头强制返回 zh-Hans
            if !result.hasPrefix("zh") {
                return "zh-Hans" as NSString
            }
            return result
        }

        let newImp = imp_implementationWithBlock(block)
        method_setImplementation(original, newImp)
    }

    // MARK: - NSLocale.components(fromLocaleIdentifier:) hook
    private static func hookNSLocaleComponents() {
        let cls: AnyClass = NSLocale.self
        let original = class_getClassMethod(cls, #selector(NSLocale.components(fromLocaleIdentifier:)))
        guard let original = original else { return }

        let originalImp = method_getImplementation(original)

        let block: @convention(block) (AnyObject, Selector, NSString) -> NSDictionary = { _, cmd, _ in
            // 强制用 zh_CN@currency=CNY 解析
            let orig = unsafeBitCast(originalImp, to: (@convention(c) (AnyObject, Selector, NSString) -> NSDictionary).self)
            return orig(NSLocale.self, cmd, TARGET_LOCALE_ID as NSString)
        }

        let newImp = imp_implementationWithBlock(block)
        method_setImplementation(original, newImp)
    }
}
