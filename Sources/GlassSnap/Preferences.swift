import SwiftUI

final class Preferences: ObservableObject {
    static let shared = Preferences()
    @Published var enabled: Bool { didSet { save() } }
    @Published var gap: Double { didSet { save() } }
    @Published var animate: Bool { didSet { save() } }
    @Published var dividers: Bool { didSet { save() } }
    @Published var edgeDelay: Double { didSet { save() } }
    @Published var switcherEnabled: Bool { didSet { defaults.set(switcherEnabled, forKey: "switcherEnabled") } }
    var changed: (() -> Void)?
    private let defaults = UserDefaults.standard
    private init() {
        defaults.register(defaults: ["enabled": true, "gap": 8.0, "animate": true, "dividers": true, "edgeDelay": 0.12, "switcherEnabled": true])
        switcherEnabled = defaults.bool(forKey: "switcherEnabled")
        enabled = defaults.bool(forKey: "enabled")
        gap = defaults.double(forKey: "gap")
        animate = defaults.bool(forKey: "animate")
        dividers = defaults.bool(forKey: "dividers")
        edgeDelay = defaults.double(forKey: "edgeDelay")
    }
    private func save() {
        defaults.set(enabled, forKey: "enabled"); defaults.set(gap, forKey: "gap")
        defaults.set(animate, forKey: "animate"); defaults.set(dividers, forKey: "dividers")
        defaults.set(edgeDelay, forKey: "edgeDelay"); changed?()
    }
}
