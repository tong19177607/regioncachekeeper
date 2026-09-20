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

    /// 安装所有 Swift 端 hook
    @objc public static func install() {
        hookNSLocaleInit()
        hookNSLocaleCanonicalLanguage()
        hookNSLocaleComponents()
        NSLog("[SK2Swift] hooks installed")
    }

    // MARK: - NSLocale init hook (覆盖 localeWithLocaleIdentifier:)
    // 无根外币核心: 所有通过 initWithLocaleIdentifier: 创建的 locale 都返回 zh_CN
    private static func hookNSLocaleInit() {
        let cls: AnyClass = NSLocale.self
        let original = class_getInstanceMethod(cls, #selector(NSLocale.init(localeIdentifier:)))
        guard let original = original else { return }

        let originalImp = method_getImplementation(original)

        let block: @convention(block) (NSLocale, Selector, String) -> NSLocale = { _, _, identifier in
            // 如果传入的不是 zh 系列, 强制改成 zh_CN
            if !identifier.hasPrefix("zh") {
                return NSLocale(localeIdentifier: TARGET_LOCALE_STR)
            }
            // 调原始实现
            let orig = unsafeBitCast(originalImp, to: (@convention(c) (AnyObject, Selector, String) -> NSLocale).self)
            return orig(self, #selector(NSLocale.init(localeIdentifier:)), TARGET_LOCALE_STR)
        }

        let newImp = imp_implementationWithBlock(block)
        method_setImplementation(original, newImp)
    }

    // MARK: - NSLocale.canonicalLanguageIdentifierFromString: hook
    // 防止 App 通过语言标识检测真实地区
    private static func hookNSLocaleCanonicalLanguage() {
        let cls: AnyClass = NSLocale.self
        let original = class_getClassMethod(cls, #selector(NSLocale.canonicalLanguageIdentifier(from:)))
        guard let original = original else { return }

        let originalImp = method_getImplementation(original)

        let block: @convention(block) (AnyObject, Selector, String) -> String = { _, _, str in
            let orig = unsafeBitCast(originalImp, to: (@convention(c) (AnyObject, Selector, String) -> String).self)
            let result = orig(NSLocale.self, #selector(NSLocale.canonicalLanguageIdentifier(from:)), str)
            // 如果结果不是 zh 开头, 强制返回 zh-Hans
            if !result.hasPrefix("zh") {
                return "zh-Hans"
            }
            return result
        }

        let newImp = imp_implementationWithBlock(block)
        method_setImplementation(original, newImp)
    }

    // MARK: - NSLocale.components(fromLocaleIdentifier:) hook
    // 防止 App 解析 locale identifier 拿到真实地区代码
    private static func hookNSLocaleComponents() {
        let cls: AnyClass = NSLocale.self
        let original = class_getClassMethod(cls, #selector(NSLocale.components(fromLocaleIdentifier:)))
        guard let original = original else { return }

        let originalImp = method_getImplementation(original)

        let block: @convention(block) (AnyObject, Selector, String) -> [String: String] = { _, _, identifier in
            // 强制用 zh_CN@currency=CNY 解析
            let orig = unsafeBitCast(originalImp, to: (@convention(c) (AnyObject, Selector, String) -> [String: String]).self)
            return orig(NSLocale.self, #selector(NSLocale.components(fromLocaleIdentifier:)), TARGET_LOCALE_ID)
        }

        let newImp = imp_implementationWithBlock(block)
        method_setImplementation(original, newImp)
    }
}
