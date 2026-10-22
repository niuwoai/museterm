//
//  DetachedTerminalPanel.swift
//  museterm
//
//  “分离”功能：把一个正在运行的标签（TerminalSession）从主窗口摘出，放进一个无边框、
//  半透明、带毛玻璃、能融入桌面的悬浮面板里继续渲染——进程不断，top / tail -f 继续滚。
//  桌面融合效果参照 ~/Sites/FuturePanel 的窗口配方（borderless + 清空背景 +
//  NSVisualEffectView.behindWindow + underWindowBackground），此处不涉及其取数逻辑。
//

import AppKit
import Combine
import SwiftUI

// MARK: - Manager

/// 统一管理所有分离出来的悬浮终端面板：每个被分离的 session 对应一个玻璃窗。
@MainActor
final class DetachedTerminalPanelManager {
    static let shared = DetachedTerminalPanelManager()

    private var controllers: [TerminalSession.ID: DetachedTerminalPanelController] = [:]

    private init() {}

    var hasPanels: Bool { !controllers.isEmpty }

    @discardableResult
    func focus(_ id: TerminalSession.ID) -> Bool {
        guard let controller = controllers[id] else { return false }
        controller.bringToFront()
        return true
    }

    func isDetached(_ id: TerminalSession.ID) -> Bool {
        controllers[id] != nil
    }

    /// 分离：从工作区摘出 tab（不终止），在悬浮面板里继续渲染。
    func detach(_ tab: TerminalSession, workspace: TerminalWorkspace, preferences: TerminalPreferences) {
        if let existing = controllers[tab.id] {
            existing.bringToFront()
            return
        }
        guard workspace.detachTab(tab) != nil else { return }
        let controller = DetachedTerminalPanelController(
            session: tab,
            workspace: workspace,
            preferences: preferences,
            manager: self
        )
        controllers[tab.id] = controller
        controller.show()
    }

    /// 收回：面板 → 主窗口标签。session 不终止。
    func reattach(_ session: TerminalSession) {
        guard let controller = controllers[session.id] else { return }
        controllers[session.id] = nil
        controller.tearDownWindow()
        controller.workspace?.reattachTab(session)
    }

    /// 关闭：终止 session 并销毁面板。
    func closeAndTerminate(_ session: TerminalSession) {
        guard let controller = controllers[session.id] else { return }
        controllers[session.id] = nil
        controller.tearDownWindow()
        session.terminate()
    }

    /// 窗口已被系统/用户直接关掉后的回收（避免留下悬空引用）。
    fileprivate func forget(_ id: TerminalSession.ID) {
        controllers[id] = nil
    }
}

// MARK: - Chrome state

/// 驱动面板控制条的可观察状态：是否置顶、鼠标是否悬停。
@MainActor
final class DetachedPanelChromeState: ObservableObject {
    @Published var pinned: Bool
    @Published var isHovering: Bool = false

    init(pinned: Bool) {
        self.pinned = pinned
    }
}

// MARK: - Window

/// 无边框面板窗口。默认不可成为 key，这里放开以便终端接收键盘（top 里按 q、tail 里 Ctrl-C）。
final class DetachedTerminalPanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Controller

@MainActor
final class DetachedTerminalPanelController: NSObject, NSWindowDelegate {
    private let session: TerminalSession
    weak var workspace: TerminalWorkspace?
    private let preferences: TerminalPreferences
    private weak var manager: DetachedTerminalPanelManager?

    private let chrome: DetachedPanelChromeState
    private var window: DetachedTerminalPanelWindow?
    private var opacityCancellable: AnyCancellable?
    // 收回 / 主动终止时置位，避免 windowWillClose 再次把它当“用户关窗=终止”处理。
    private var isTearingDown = false

    init(
        session: TerminalSession,
        workspace: TerminalWorkspace,
        preferences: TerminalPreferences,
        manager: DetachedTerminalPanelManager
    ) {
        self.session = session
        self.workspace = workspace
        self.preferences = preferences
        self.manager = manager
        self.chrome = DetachedPanelChromeState(pinned: true)
        super.init()
    }

    func show() {
        let content = DetachedPanelContentView(
            session: session,
            preferences: preferences,
            chrome: chrome,
            onClose: { [weak self] in self?.requestClose() },
            onReattach: { [weak self] in self?.requestReattach() },
            onTogglePin: { [weak self] in self?.togglePin() }
        )
        let hosting = NSHostingController(rootView: content)
        let window = DetachedTerminalPanelWindow(contentViewController: hosting)
        window.styleMask = [.borderless, .fullSizeContentView, .resizable]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        // 监控面板贴桌面用：随手跨 Space 都能看到，且能浮在全屏 App 之上。
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = chrome.pinned ? .floating : .normal
        window.delegate = self
        window.setContentSize(NSSize(width: 560, height: 380))
        window.minSize = NSSize(width: 260, height: 160)
        // 圆角遮罩放在 contentView 图层层面：SwiftUI 的 .clipShape 裁不住嵌进来的 AppKit
        // 视图（玻璃层、终端 container），会在四角戳出直角灰块、右侧留下多余竖边；改由图层
        // masksToBounds 统一裁剪，连同所有子视图一起裁到同一个圆角矩形，边框也收成一条。
        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = Self.cornerRadius
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true
            contentView.layer?.borderWidth = 1
            contentView.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        }
        // 整窗不透明度（含文字），实现半透融入桌面；随设置滑杆实时变化。
        window.alphaValue = CGFloat(preferences.detachedPanelOpacity)
        opacityCancellable = preferences.$detachedPanelOpacity
            .receive(on: DispatchQueue.main)
            .sink { [weak window] value in
                window?.alphaValue = CGFloat(value)
            }
        positionInitially(window)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    static let cornerRadius: CGFloat = 12

    private func positionInitially(_ window: NSWindow) {
        guard let screen = NSScreen.main else {
            window.center()
            return
        }
        // 默认落在屏幕右上角一带，贴合“看日志/负载的监控角”的直觉。
        let visible = screen.visibleFrame
        let size = window.frame.size
        let margin: CGFloat = 24
        let origin = NSPoint(
            x: visible.maxX - size.width - margin,
            y: visible.maxY - size.height - margin
        )
        window.setFrameOrigin(origin)
    }

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
    }

    /// 只销毁窗口，不动 session（收回/终止的公共收尾）。
    func tearDownWindow() {
        guard !isTearingDown else { return }
        isTearingDown = true
        window?.delegate = nil
        window?.close()
        window = nil
    }

    private func togglePin() {
        chrome.pinned.toggle()
        window?.level = chrome.pinned ? .floating : .normal
    }

    private func requestReattach() {
        manager?.reattach(session)
    }

    private func requestClose() {
        // 与普通关标签共用同一「不再询问」开关，且只有进程仍在运行时才确认——
        // 进程已退出（如 top 已 q 掉）直接关，不再无谓打扰。
        let skipKey = SystemTerminalTabCloseConfirmer.skipRunningTabCloseConfirmationKey
        let defaults = UserDefaults.standard
        guard session.hasRunningProcess, defaults.bool(forKey: skipKey) == false, let window else {
            manager?.closeAndTerminate(session)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("detached_panel.close_confirm.title")
        alert.informativeText = L10n.format("detached_panel.close_confirm.message", session.tabTitle)
        alert.addButton(withTitle: L10n.string("detached_panel.close_confirm.confirm"))
        alert.addButton(withTitle: L10n.string("action.cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.string("tab.close_running.do_not_ask_again")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if alert.suppressionButton?.state == .on {
                defaults.set(true, forKey: skipKey)
            }
            if response == .alertFirstButtonReturn {
                self.manager?.closeAndTerminate(self.session)
            }
        }
    }

    // 用户/系统直接关窗（如 Cmd+W）：等同“关闭=终止 session”。收回或主动终止已置 isTearingDown。
    func windowWillClose(_ notification: Notification) {
        guard !isTearingDown else { return }
        isTearingDown = true
        window?.delegate = nil
        window = nil
        manager?.forget(session.id)
        session.terminate()
    }
}

// MARK: - Content view

/// 玻璃背景：behindWindow 混合 + underWindowBackground 材质，把桌面透进来（FuturePanel 同款）。
private struct DetachedGlassBackground: NSViewRepresentable {
    let opacity: Double

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        view.isEmphasized = true
        view.alphaValue = CGFloat(opacity)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.alphaValue = CGFloat(opacity)
    }
}

/// 顶部可拖拽区域：让无边框窗口能靠拖动这条窄带移动。
private struct DetachedDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            // 仅作为拖拽热区，鼠标事件到此为止（不穿透给终端）。
            super.hitTest(point)
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = DragView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct DetachedPanelContentView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var preferences: TerminalPreferences
    @ObservedObject var chrome: DetachedPanelChromeState
    let onClose: () -> Void
    let onReattach: () -> Void
    let onTogglePin: () -> Void

    var body: some View {
        // 圆角、边框、阴影都交给窗口 contentView 图层与 window.hasShadow 处理（见 controller）——
        // SwiftUI 裁剪管不住嵌入的 AppKit 视图，会在四角/右侧留下毛边。这里只铺内容。
        ZStack(alignment: .top) {
            DetachedGlassBackground(opacity: preferences.glassOpacity)

            TerminalHostView(session: session, preferences: preferences, isActive: true)

            TerminalAIControlMask(tab: session, skin: preferences.skin)

            // 顶部拖拽条（始终存在，透明），悬停时叠加控制按钮。
            topChrome
        }
        .onHover { hovering in
            chrome.isHovering = hovering
        }
        .ignoresSafeArea()
    }

    private var topChrome: some View {
        ZStack(alignment: .topTrailing) {
            DetachedDragArea()
                .frame(height: 30)
                .frame(maxWidth: .infinity)

            controlButtons
                .padding(.top, 6)
                .padding(.trailing, 8)
                .opacity(chrome.isHovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: chrome.isHovering)
                .allowsHitTesting(chrome.isHovering)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var controlButtons: some View {
        HStack(spacing: 6) {
            chromeButton(
                systemName: chrome.pinned ? "pin.fill" : "pin.slash",
                help: L10n.string(chrome.pinned ? "detached_panel.pin.on" : "detached_panel.pin.off"),
                action: onTogglePin
            )
            chromeButton(
                systemName: "arrow.down.right.and.arrow.up.left.rectangle",
                help: L10n.string("detached_panel.reattach"),
                action: onReattach
            )
            chromeButton(
                systemName: "xmark",
                help: L10n.string("detached_panel.close"),
                action: onClose
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }

    private func chromeButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}
