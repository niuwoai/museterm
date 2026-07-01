//
//  musetermApp.swift
//  museterm
//
//  Created by rocky on 2026/6/30.
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 用户明确关闭所有窗口后退出 App；Cmd+W 在终端窗口内只关闭当前标签。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TerminalWindowCloseState.isAppTerminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        TerminalWindowCloseState.isAppTerminating = false
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

            CommandGroup(replacing: .appInfo) {
                Button(L10n.string("menu.about")) {
                    AboutWindowOpener.open(preferences: preferences)
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button(L10n.string("menu.settings")) {
                    SettingsWindowOpener.open(preferences: preferences)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
