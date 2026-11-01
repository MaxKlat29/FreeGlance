import Combine
import Foundation

@MainActor
final class Settings: ObservableObject {
    private enum Key {
        static let switchDelayMs = "switchDelayMs"
        static let headTurnPercent = "headTurnPercent"
        static let sameScreenFocus = "sameScreenFocus"
        static let paneDelayMs = "paneDelayMs"
        static let waitWhileTyping = "waitWhileTyping"
        static let typingPauseSec = "typingPauseSec"
        static let showGazeDot = "showGazeDot"
        static let clickFallback = "clickFallback"
        static let learnFromClicks = "learnFromClicks"
        static let cameraUniqueID = "cameraUniqueID"
        static let launchAtLogin = "launchAtLogin"
    }

    private let defaults: UserDefaults

    @Published var switchDelayMs: Int { didSet { defaults.set(switchDelayMs, forKey: Key.switchDelayMs) } }
    @Published var headTurnPercent: Int { didSet { defaults.set(headTurnPercent, forKey: Key.headTurnPercent) } }
    @Published var sameScreenFocus: Bool { didSet { defaults.set(sameScreenFocus, forKey: Key.sameScreenFocus) } }
    @Published var paneDelayMs: Int { didSet { defaults.set(paneDelayMs, forKey: Key.paneDelayMs) } }
    @Published var waitWhileTyping: Bool { didSet { defaults.set(waitWhileTyping, forKey: Key.waitWhileTyping) } }
    @Published var typingPauseSec: Double { didSet { defaults.set(typingPauseSec, forKey: Key.typingPauseSec) } }
    @Published var showGazeDot: Bool { didSet { defaults.set(showGazeDot, forKey: Key.showGazeDot) } }
    @Published var clickFallback: Bool { didSet { defaults.set(clickFallback, forKey: Key.clickFallback) } }
    @Published var learnFromClicks: Bool { didSet { defaults.set(learnFromClicks, forKey: Key.learnFromClicks) } }
    @Published var cameraUniqueID: String? { didSet { defaults.set(cameraUniqueID, forKey: Key.cameraUniqueID) } }
    @Published var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.switchDelayMs: 300,
            Key.headTurnPercent: 50,
            Key.sameScreenFocus: true,
            Key.paneDelayMs: 300,
            Key.waitWhileTyping: true,
            Key.typingPauseSec: 2.0,
            Key.showGazeDot: false,
            Key.clickFallback: true,
            Key.learnFromClicks: true,
            Key.launchAtLogin: true,
        ])
        switchDelayMs = defaults.integer(forKey: Key.switchDelayMs)
        headTurnPercent = defaults.integer(forKey: Key.headTurnPercent)
        sameScreenFocus = defaults.bool(forKey: Key.sameScreenFocus)
        paneDelayMs = defaults.integer(forKey: Key.paneDelayMs)
        waitWhileTyping = defaults.bool(forKey: Key.waitWhileTyping)
        typingPauseSec = defaults.double(forKey: Key.typingPauseSec)
        showGazeDot = defaults.bool(forKey: Key.showGazeDot)
        clickFallback = defaults.bool(forKey: Key.clickFallback)
        learnFromClicks = defaults.bool(forKey: Key.learnFromClicks)
        cameraUniqueID = defaults.string(forKey: Key.cameraUniqueID)
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
    }

    var switchDelay: TimeInterval { Double(switchDelayMs) / 1000 }
    var paneDelay: TimeInterval { Double(paneDelayMs) / 1000 }
    var headTurnFraction: Double { Double(headTurnPercent) / 100 }
}
