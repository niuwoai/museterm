enum SkinAppearanceFilter: String, CaseIterable, Identifiable {
    case all
    case light
    case dark

    var id: String { rawValue }

    func includes(_ skin: TerminalVisualSkin) -> Bool {
        switch self {
        case .all: true
        case .light: !skin.spec.isDark
        case .dark: skin.spec.isDark
        }
    }
}
