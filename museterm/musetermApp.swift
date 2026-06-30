//
//  musetermApp.swift
//  museterm
//
//  Created by rocky on 2026/6/30.
//

import SwiftUI

@main
struct musetermApp: App {
    @StateObject private var preferences = TerminalPreferences()

    var body: some Scene {
        WindowGroup {
            ContentView(preferences: preferences)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            TerminalCommands()

            CommandGroup(replacing: .appSettings) {
                Button(L10n.string("menu.settings")) {
                    SettingsWindowOpener.open(preferences: preferences)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
