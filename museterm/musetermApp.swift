//
//  musetermApp.swift
//  museterm
//
//  Created by rocky on 2026/6/30.
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 所有窗口都关闭后（即最后一个标签被 Cmd+W 关掉、窗口随之关闭时）退出 App。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct musetermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
