import SwiftUI

// 色值来源与许可证见 docs/terminal-skin-sources.md。
extension TerminalVisualSkin {
    // https://raw.githubusercontent.com/catppuccin/alacritty/f6cb5a5c2b404cdaceaff193b9c52317f62c62f7/catppuccin-latte.toml
    static let classicCatppuccinLatte = TerminalSkinSpec.classic(
        symbol: "sun.max", isDark: false,
        foreground: 0x4C4F69, background: 0xEFF1F5,
        caret: 0xDC8A78,
        ansi: [
            0xBCC0CC, 0xD20F39, 0x40A02B, 0xDF8E1D,
            0x1E66F5, 0xEA76CB, 0x179299, 0x5C5F77,
            0xACB0BE, 0xD20F39, 0x40A02B, 0xDF8E1D,
            0x1E66F5, 0xEA76CB, 0x179299, 0x6C6F85
        ]
    )

    // https://raw.githubusercontent.com/catppuccin/alacritty/f6cb5a5c2b404cdaceaff193b9c52317f62c62f7/catppuccin-frappe.toml
    static let classicCatppuccinFrappe = TerminalSkinSpec.classic(
        symbol: "moon.stars", isDark: true,
        foreground: 0xC6D0F5, background: 0x303446,
        caret: 0xF2D5CF,
        ansi: [
            0x51576D, 0xE78284, 0xA6D189, 0xE5C890,
            0x8CAAEE, 0xF4B8E4, 0x81C8BE, 0xB5BFE2,
            0x626880, 0xE78284, 0xA6D189, 0xE5C890,
            0x8CAAEE, 0xF4B8E4, 0x81C8BE, 0xA5ADCE
        ]
    )

    // https://raw.githubusercontent.com/catppuccin/alacritty/f6cb5a5c2b404cdaceaff193b9c52317f62c62f7/catppuccin-macchiato.toml
    static let classicCatppuccinMacchiato = TerminalSkinSpec.classic(
        symbol: "moon.stars", isDark: true,
        foreground: 0xCAD3F5, background: 0x24273A,
        caret: 0xF4DBD6,
        ansi: [
            0x494D64, 0xED8796, 0xA6DA95, 0xEED49F,
            0x8AADF4, 0xF5BDE6, 0x8BD5CA, 0xB8C0E0,
            0x5B6078, 0xED8796, 0xA6DA95, 0xEED49F,
            0x8AADF4, 0xF5BDE6, 0x8BD5CA, 0xA5ADCB
        ]
    )

    // https://raw.githubusercontent.com/catppuccin/alacritty/f6cb5a5c2b404cdaceaff193b9c52317f62c62f7/catppuccin-mocha.toml
    static let classicCatppuccinMocha = TerminalSkinSpec.classic(
        symbol: "moon.stars", isDark: true,
        foreground: 0xCDD6F4, background: 0x1E1E2E,
        caret: 0xF5E0DC,
        ansi: [
            0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF,
            0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
            0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF,
            0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8
        ]
    )

    // https://raw.githubusercontent.com/folke/tokyonight.nvim/cdc07ac78467a233fd62c493de29a17e0cf2b2b6/extras/alacritty/tokyonight_day.toml
    static let classicTokyoDay = TerminalSkinSpec.classic(
        symbol: "sun.max", isDark: false,
        foreground: 0x3760BF, background: 0xE1E2E7,
        caret: 0x3760BF,
        ansi: [
            0xB4B5B9, 0xF52A65, 0x587539, 0x8C6C3E,
            0x2E7DE9, 0x9854F1, 0x007197, 0x6172B0,
            0xA1A6C5, 0xFF4774, 0x5C8524, 0xA27629,
            0x358AFF, 0xA463FF, 0x007EA8, 0x3760BF
        ]
    )

    // https://raw.githubusercontent.com/folke/tokyonight.nvim/cdc07ac78467a233fd62c493de29a17e0cf2b2b6/extras/alacritty/tokyonight_night.toml
    static let classicTokyoNight = TerminalSkinSpec.classic(
        symbol: "moon.stars", isDark: true,
        foreground: 0xC0CAF5, background: 0x1A1B26,
        caret: 0xC0CAF5,
        ansi: [
            0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68,
            0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
            0x414868, 0xFF899D, 0x9FE044, 0xFABA4A,
            0x8DB0FF, 0xC7A9FF, 0xA4DAFF, 0xC0CAF5
        ]
    )

    // https://raw.githubusercontent.com/folke/tokyonight.nvim/cdc07ac78467a233fd62c493de29a17e0cf2b2b6/extras/alacritty/tokyonight_storm.toml
    static let classicTokyoStorm = TerminalSkinSpec.classic(
        symbol: "moon.stars", isDark: true,
        foreground: 0xC0CAF5, background: 0x24283B,
        caret: 0xC0CAF5,
        ansi: [
            0x1D202F, 0xF7768E, 0x9ECE6A, 0xE0AF68,
            0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
            0x414868, 0xFF899D, 0x9FE044, 0xFABA4A,
            0x8DB0FF, 0xC7A9FF, 0xA4DAFF, 0xC0CAF5
        ]
    )

    // https://raw.githubusercontent.com/folke/tokyonight.nvim/cdc07ac78467a233fd62c493de29a17e0cf2b2b6/extras/alacritty/tokyonight_moon.toml
    static let classicTokyoMoon = TerminalSkinSpec.classic(
        symbol: "moon.stars", isDark: true,
        foreground: 0xC8D3F5, background: 0x222436,
        caret: 0xC8D3F5,
        ansi: [
            0x1B1D2B, 0xFF757F, 0xC3E88D, 0xFFC777,
            0x82AAFF, 0xC099FF, 0x86E1FC, 0x828BB8,
            0x444A73, 0xFF8D94, 0xC7FB6D, 0xFFD8AB,
            0x9AB8FF, 0xCAABFF, 0xB2EBFF, 0xC8D3F5
        ]
    )

    // https://raw.githubusercontent.com/rose-pine/alacritty/a6f7c8245e5bba639befe52e1e025f84ba8b3ee5/dist/rose-pine.toml
    static let classicRosePine = TerminalSkinSpec.classic(
        symbol: "moon.stars", isDark: true,
        foreground: 0xE0DEF4, background: 0x191724,
        caret: 0x524F67,
        ansi: [
            0x26233A, 0xEB6F92, 0x31748F, 0xF6C177,
            0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
            0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177,
            0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4
        ]
    )

    // https://raw.githubusercontent.com/rose-pine/alacritty/a6f7c8245e5bba639befe52e1e025f84ba8b3ee5/dist/rose-pine-moon.toml
    static let classicRoseMoon = TerminalSkinSpec.classic(
        symbol: "moon.stars", isDark: true,
        foreground: 0xE0DEF4, background: 0x232136,
        caret: 0x56526E,
        ansi: [
            0x393552, 0xEB6F92, 0x3E8FB0, 0xF6C177,
            0x9CCFD8, 0xC4A7E7, 0xEA9A97, 0xE0DEF4,
            0x6E6A86, 0xEB6F92, 0x3E8FB0, 0xF6C177,
            0x9CCFD8, 0xC4A7E7, 0xEA9A97, 0xE0DEF4
        ]
    )

    // https://raw.githubusercontent.com/rose-pine/alacritty/a6f7c8245e5bba639befe52e1e025f84ba8b3ee5/dist/rose-pine-dawn.toml
    static let classicRoseDawn = TerminalSkinSpec.classic(
        symbol: "sun.max", isDark: false,
        foreground: 0x575279, background: 0xFAF4ED,
        caret: 0xCECACD,
        ansi: [
            0xF2E9E1, 0xB4637A, 0x286983, 0xEA9D34,
            0x56949F, 0x907AA9, 0xD7827E, 0x575279,
            0x9893A5, 0xB4637A, 0x286983, 0xEA9D34,
            0x56949F, 0x907AA9, 0xD7827E, 0x575279
        ]
    )

    // https://raw.githubusercontent.com/alacritty/alacritty-theme/ab88d5a80d676b5dc6157e91aba8067f2078dc94/themes/gruvbox_dark.toml
    static let classicGruvboxDark = TerminalSkinSpec.classic(
        symbol: "moon.stars", isDark: true,
        foreground: 0xEBDBB2, background: 0x282828,
        caret: 0xEBDBB2,
        ansi: [
            0x282828, 0xCC241D, 0x98971A, 0xD79921,
            0x458588, 0xB16286, 0x689D6A, 0xA89984,
            0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F,
            0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2
        ]
    )

    // https://raw.githubusercontent.com/alacritty/alacritty-theme/ab88d5a80d676b5dc6157e91aba8067f2078dc94/themes/gruvbox_light.toml
    static let classicGruvboxLight = TerminalSkinSpec.classic(
        symbol: "sun.max", isDark: false,
        foreground: 0x3C3836, background: 0xFBF1C7,
        caret: 0x3C3836,
        ansi: [
            0xFBF1C7, 0xCC241D, 0x98971A, 0xD79921,
            0x458588, 0xB16286, 0x689D6A, 0x7C6F64,
            0x928374, 0x9D0006, 0x79740E, 0xB57614,
            0x076678, 0x8F3F71, 0x427B58, 0x3C3836
        ]
    )

    // https://raw.githubusercontent.com/alacritty/alacritty-theme/ab88d5a80d676b5dc6157e91aba8067f2078dc94/themes/everforest_dark.toml
    static let classicEverforestDark = TerminalSkinSpec.classic(
        symbol: "moon.stars", isDark: true,
        foreground: 0xD3C6AA, background: 0x2D353B,
        caret: 0xD3C6AA,
        ansi: [
            0x475258, 0xE67E80, 0xA7C080, 0xDBBC7F,
            0x7FBBB3, 0xD699B6, 0x83C092, 0xD3C6AA,
            0x475258, 0xE67E80, 0xA7C080, 0xDBBC7F,
            0x7FBBB3, 0xD699B6, 0x83C092, 0xD3C6AA
        ]
    )

    // https://raw.githubusercontent.com/alacritty/alacritty-theme/ab88d5a80d676b5dc6157e91aba8067f2078dc94/themes/everforest_light.toml
    static let classicEverforestLight = TerminalSkinSpec.classic(
        symbol: "sun.max", isDark: false,
        foreground: 0x5C6A72, background: 0xFDF6E3,
        caret: 0x5C6A72,
        ansi: [
            0x5C6A72, 0xF85552, 0x8DA101, 0xDFA000,
            0x3A94C5, 0xDF69BA, 0x35A77C, 0xE0DCC7,
            0x5C6A72, 0xF85552, 0x8DA101, 0xDFA000,
            0x3A94C5, 0xDF69BA, 0x35A77C, 0xE0DCC7
        ]
    )

    // https://raw.githubusercontent.com/alacritty/alacritty-theme/ab88d5a80d676b5dc6157e91aba8067f2078dc94/themes/kanagawa_wave.toml
    static let classicKanagawaWave = TerminalSkinSpec.classic(
        symbol: "moon.stars", isDark: true,
        foreground: 0xDCD7BA, background: 0x1F1F28,
        caret: 0xDCD7BA,
        ansi: [
            0x090618, 0xC34043, 0x76946A, 0xC0A36E,
            0x7E9CD8, 0x957FB8, 0x6A9589, 0xC8C093,
            0x727169, 0xE82424, 0x98BB6C, 0xE6C384,
            0x7FB4CA, 0x938AA9, 0x7AA89F, 0xDCD7BA
        ]
    )

    // https://raw.githubusercontent.com/alacritty/alacritty-theme/ab88d5a80d676b5dc6157e91aba8067f2078dc94/themes/kanagawa_dragon.toml
    static let classicKanagawaDragon = TerminalSkinSpec.classic(
        symbol: "moon.stars", isDark: true,
        foreground: 0xC5C9C5, background: 0x181616,
        caret: 0xC5C9C5,
        ansi: [
            0x0D0C0C, 0xC4746E, 0x8A9A7B, 0xC4B28A,
            0x8BA4B0, 0xA292A3, 0x8EA4A2, 0xC8C093,
            0xA6A69C, 0xE46876, 0x87A987, 0xE6C384,
            0x7FB4CA, 0x938AA9, 0x7AA89F, 0xC5C9C5
        ]
    )

    // https://raw.githubusercontent.com/alacritty/alacritty-theme/ab88d5a80d676b5dc6157e91aba8067f2078dc94/themes/ayu_dark.toml
    static let classicAyuDark = TerminalSkinSpec.classic(
        symbol: "moon.stars", isDark: true,
        foreground: 0xB3B1AD, background: 0x0A0E14,
        caret: 0xB3B1AD,
        ansi: [
            0x01060E, 0xEA6C73, 0x91B362, 0xF9AF4F,
            0x53BDFA, 0xFAE994, 0x90E1C6, 0xC7C7C7,
            0x686868, 0xF07178, 0xC2D94C, 0xFFB454,
            0x59C2FF, 0xFFEE99, 0x95E6CB, 0xFFFFFF
        ]
    )

    // https://raw.githubusercontent.com/alacritty/alacritty-theme/ab88d5a80d676b5dc6157e91aba8067f2078dc94/themes/ayu_light.toml
    static let classicAyuLight = TerminalSkinSpec.classic(
        symbol: "sun.max", isDark: false,
        foreground: 0x5C6166, background: 0xFCFCFC,
        caret: 0x5C6166,
        ansi: [
            0x010101, 0xE7666A, 0x80AB24, 0xEBA54D,
            0x4196DF, 0x9870C3, 0x51B891, 0xC1C1C1,
            0x343434, 0xEE9295, 0x9FD32F, 0xF0BC7B,
            0x6DAEE6, 0xB294D2, 0x75C7A8, 0xDBDBDB
        ]
    )

    // https://raw.githubusercontent.com/alacritty/alacritty-theme/ab88d5a80d676b5dc6157e91aba8067f2078dc94/themes/ayu_mirage.toml
    static let classicAyuMirage = TerminalSkinSpec.classic(
        symbol: "moon.stars", isDark: true,
        foreground: 0xCBCCC6, background: 0x1F2430,
        caret: 0xCBCCC6,
        ansi: [
            0x212733, 0xF08778, 0x53BF97, 0xFDCC60,
            0x60B8D6, 0xEC7171, 0x98E6CA, 0xFAFAFA,
            0x686868, 0xF58C7D, 0x58C49C, 0xFFD165,
            0x65BDDB, 0xF17676, 0x9DEBCF, 0xFFFFFF
        ]
    )

    // https://raw.githubusercontent.com/alacritty/alacritty-theme/ab88d5a80d676b5dc6157e91aba8067f2078dc94/themes/monokai.toml
    static let classicMonokai = TerminalSkinSpec.classic(
        symbol: "moon.stars", isDark: true,
        foreground: 0xF8F8F2, background: 0x272822,
        caret: 0xF8F8F2,
        ansi: [
            0x272822, 0xF92672, 0xA6E22E, 0xF4BF75,
            0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF8F8F2,
            0x75715E, 0xF92672, 0xA6E22E, 0xF4BF75,
            0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF9F8F5
        ]
    )

    // https://raw.githubusercontent.com/alacritty/alacritty-theme/ab88d5a80d676b5dc6157e91aba8067f2078dc94/themes/solarized_dark.toml
    static let classicSolarizedDark = TerminalSkinSpec.classic(
        symbol: "moon.stars", isDark: true,
        foreground: 0x839496, background: 0x002B36,
        caret: 0x839496,
        ansi: [
            0x073642, 0xDC322F, 0x859900, 0xB58900,
            0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
            0x002B36, 0xCB4B16, 0x586E75, 0x657B83,
            0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3
        ]
    )

    // https://raw.githubusercontent.com/alacritty/alacritty-theme/ab88d5a80d676b5dc6157e91aba8067f2078dc94/themes/tomorrow.toml
    static let classicTomorrow = TerminalSkinSpec.classic(
        symbol: "sun.max", isDark: false,
        foreground: 0x4D4D4C, background: 0xFFFFFF,
        caret: 0xD6D6D6,
        ansi: [
            0x1D1F21, 0xC82829, 0x718C00, 0xF5871F,
            0x4271AE, 0x8959A8, 0x3E999F, 0xD6D6D6,
            0x8E908C, 0xFF3334, 0x89AA00, 0xEAB700,
            0x5795E6, 0xB777E0, 0x66BDC3, 0xEFEFEF
        ]
    )

    // https://raw.githubusercontent.com/alacritty/alacritty-theme/ab88d5a80d676b5dc6157e91aba8067f2078dc94/themes/tomorrow_night.toml
    static let classicTomorrowNight = TerminalSkinSpec.classic(
        symbol: "moon.stars", isDark: true,
        foreground: 0xC5C8C6, background: 0x1D1F21,
        caret: 0xFFFFFF,
        ansi: [
            0x1D1F21, 0xCC6666, 0xB5BD68, 0xE6C547,
            0x81A2BE, 0xB294BB, 0x70C0BA, 0x373B41,
            0x666666, 0xFF3334, 0x9EC400, 0xF0C674,
            0x81A2BE, 0xB77EE0, 0x54CED6, 0x282A2E
        ]
    )
}
