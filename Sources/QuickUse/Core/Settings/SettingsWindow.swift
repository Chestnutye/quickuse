import AppKit
import SwiftUI

/// 设置窗口左侧的一页。
struct SettingsPane: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let view: () -> AnyView

    init<V: View>(id: String, title: String, subtitle: String, icon: String, tint: Color,
                  @ViewBuilder view: @escaping () -> V) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.view = { AnyView(view()) }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: String?
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let navigation = SettingsNavigation()

    func show(pane: String?) {
        let panes = AppServices.shared.settingsPanes
        navigation.selection = pane ?? navigation.selection ?? panes.first?.id
        if window == nil {
            let host = NSHostingController(rootView: SettingsRootView(panes: panes, nav: navigation))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.title = "QuickUse 设置"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.setContentSize(NSSize(width: 780, height: 560))
            w.minSize = NSSize(width: 680, height: 460)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        // 菜单栏 App 默认不在程序坞显示；设置窗口打开期间临时显示，便于切换窗口。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// 系统设置风格的彩色圆角图标。
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
    }
}

struct SettingsRootView: View {
    let panes: [SettingsPane]
    @ObservedObject var nav: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.selection) {
                AppBadge()
                    .padding(.vertical, 8)
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                ForEach(panes) { pane in
                    HStack(spacing: 9) {
                        IconTile(symbol: pane.icon, tint: pane.tint)
                        Text(pane.title)
                    }
                    .padding(.vertical, 2)
                    .tag(pane.id)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            if let pane = panes.first(where: { $0.id == nav.selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        PaneHeader(pane: pane)
                            .padding(.horizontal, 28)
                            .padding(.top, 8)
                        pane.view()
                            .scrollDisabled(true)
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .id(pane.id)
            }
        }
    }
}

private struct AppBadge: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: StatusIcon.image())
                .renderingMode(.template)
                .resizable()
                .frame(width: 26, height: 26)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text("QuickUse").font(.headline)
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PaneHeader: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: pane.icon, tint: pane.tint, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.title).font(.title2.weight(.semibold))
                Text(pane.subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
