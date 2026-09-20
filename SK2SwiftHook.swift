// SK2SwiftHook.swift
// RegionCacheKeeper v1.4 — StoreKit2 + NSLocale 增强 hook (Swift)

import Foundation
import StoreKit
import ObjectiveC

private let TARGET_LOCALE_ID = "zh_CN@currency=CNY"
private let TARGET_LOCALE_STR = "zh_CN"

@objc public class SK2SwiftHook: NSObject {

    private static var inHook = false

    @objc public static func install() {
        hookNSLocaleInit()
        hookNSLocaleCanonicalLanguage()
        hookNSLocaleComponents()
        NSLog("[SK2Swift] hooks installed")
    }

    private static func hookNSLocaleInit() {
        let cls: AnyClass = NSLocale.self
        let original = class_getInstanceMethod(cls, #selector(NSLocale.init(localeIdentifier:)))
        guard let original = original else { return }
        let originalImp = method_getImplementation(original)

        let block: @convention(block) (AnyObject, Selector, NSString) -> AnyObject = { recv, sel, _ in
            if SK2SwiftHook.inHook {
                let orig = unsafeBitCast(originalImp, to: (@convention(c) (AnyObject, Selector, NSString) -> AnyObject).self)
                return orig(recv, sel, TARGET_LOCALE_STR as NSString)
            }
            SK2SwiftHook.inHook = true
            defer { SK2SwiftHook.inHook = false }
            let orig = unsafeBitCast(originalImp, to: (@convention(c) (AnyObject, Selector, NSString) -> AnyObject).self)
            return orig(recv, sel, TARGET_LOCALE_STR as NSString)
        }

        let newImp = imp_implementationWithBlock(block)
        method_setImplementation(original, newImp)
    }

    private static func hookNSLocaleCanonicalLanguage() {
        let cls: AnyClass = NSLocale.self
        let original = class_getClassMethod(cls, #selector(NSLocale.canonicalLanguageIdentifier(from:)))
        guard let original = original else { return }
        let originalImp = method_getImplementation(original)

        let block: @convention(block) (AnyObject, Selector, NSString) -> NSString = { recv, sel, str in
            let orig = unsafeBitCast(originalImp, to: (@convention(c) (AnyObject, Selector, NSString) -> NSString).self)
            let result = orig(recv, sel, str)
            if !result.hasPrefix("zh") {
                return "zh-Hans" as NSString
            }
            return result
        }

        let newImp = imp_implementationWithBlock(block)
        method_setImplementation(original, newImp)
    }

    private static func hookNSLocaleComponents() {
        let cls: AnyClass = NSLocale.self
        let original = class_getClassMethod(cls, #selector(NSLocale.components(fromLocaleIdentifier:)))
        guard let original = original else { return }
        let originalImp = method_getImplementation(original)

        let block: @convention(block) (AnyObject, Selector, NSString) -> NSDictionary = { recv, sel, _ in
            let orig = unsafeBitCast(originalImp, to: (@convention(c) (AnyObject, Selector, NSString) -> NSDictionary).self)
            return orig(recv, sel, TARGET_LOCALE_ID as NSString)
        }

        let newImp = imp_implementationWithBlock(block)
        method_setImplementation(original, newImp)
    }
}
