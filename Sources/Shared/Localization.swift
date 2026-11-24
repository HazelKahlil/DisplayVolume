import Foundation

enum L10n {
    static let isChinese: Bool = {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
    }()

    static func text(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }

    static var appName: String { text("桌面音量", "DisplayVolume") }
    static var mutedLabel: String { text("静音", "Muted") }
    static var micMutedLabel: String { text("已静音", "Muted") }
    static var micUnmutedLabel: String { text("麦克风已开启", "Mic On") }
    static var micMutedOSDLabel: String { text("麦克风已静音", "Mic Muted") }
    static var autoGainLabel: String { text("自动增益", "Auto Gain") }
    static var limitWord: String { text("上限", "Cap") }
    static var maxButton: String { text("上限", "Max") }
    static var maxVolumeTitle: String { text("安全上限", "Volume Ceiling") }
    static var activeControlBadge: String { text("软件控音", "Software Volume") }
    static var nativeControlBadge: String { text("系统原生", "Native Control") }
    static var virtualBadge: String { text("虚拟音频", "Virtual Audio") }
    static var pausedBadge: String { text("已暂停", "Paused") }
}
