import Foundation

/// 选中即复制：鼠标松开时决定是否把当前选区写入剪贴板。
/// 只在本次鼠标手势确实改动了选区时复制，避免鼠标上报模式（tmux、vim）下
/// 普通点击把之前残留的选区再次写入、覆盖用户刚复制的其他内容。
enum TerminalCopyOnSelectPolicy {
    static func textToCopy(
        isEnabled: Bool,
        selectionChangedDuringGesture: Bool,
        selection: String?
    ) -> String? {
        guard isEnabled, selectionChangedDuringGesture, let selection else { return nil }
        // 双击空白处会选中一串空格，复制它只会白白覆盖剪贴板
        guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return selection
    }
}
