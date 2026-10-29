import SwiftUI

/// 命令面板、AI 指令输入条这类「键盘浮层」是否正在接管键盘。
/// 浮层显示期间，终端必须让出第一响应者：SwiftUI 每次刷新都会重新聚焦当前窗格，
/// 若不拦截，用户敲进浮层的字符会越过浮层直接进入 shell。
private struct TerminalKeyboardOverlayActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var terminalKeyboardOverlayActive: Bool {
        get { self[TerminalKeyboardOverlayActiveKey.self] }
        set { self[TerminalKeyboardOverlayActiveKey.self] = newValue }
    }
}

nonisolated enum TerminalInputFocusPolicy {
    /// 终端只有在窗格可见、持有输入焦点、且没有键盘浮层时才可以自动聚焦。
    static func shouldAutoFocus(
        isActive: Bool,
        focusesInput: Bool,
        keyboardOverlayActive: Bool
    ) -> Bool {
        isActive && focusesInput && !keyboardOverlayActive
    }
}
