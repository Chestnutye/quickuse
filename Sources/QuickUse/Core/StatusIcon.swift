import AppKit

/// 菜单栏图标：从 App 包里的 StatusIcon.svg 加载，设为模板图像以自动适配深浅色菜单栏。
enum StatusIcon {
    static func image() -> NSImage {
        if let url = Bundle.main.url(forResource: "StatusIcon", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        let fallback = NSImage(systemSymbolName: "wifi", accessibilityDescription: "QuickUse")!
        fallback.isTemplate = true
        return fallback
    }
}
