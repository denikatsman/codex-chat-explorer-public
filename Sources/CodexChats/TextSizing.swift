import Foundation

enum TextSizing {
    static let preferenceKey = "contentMagnification"
    static let minimum = 0.75
    static let maximum = 2.5
    static let step = 1.15
    static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(maximum, max(minimum, value)) : 1
    }
    static func restored(from defaults: UserDefaults) -> Double {
        guard let value = defaults.object(forKey: preferenceKey) as? NSNumber else { return 1 }
        return clamp(value.doubleValue)
    }
}
