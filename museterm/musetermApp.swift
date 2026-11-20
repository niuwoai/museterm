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
        do { try TerminalRuntimeWorkspaceLifecycle.shared.prepareForExit() }
        catch {
            let alert = NSAlert()
            alert.messageText = L10n.string("runtime.workspace.save_failed")
            alert.informativeText = L10n.string("runtime.workspace.exit_cancelled")
            alert.runModal()
            return .terminateCancel
        }
        TerminalWindowCloseState.isAppTerminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Closing a floating window during teardown must still detach its PTY.
        TerminalWindowCloseState.isAppTerminating = true
    }
}

@main
struct musetermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var preferences: TerminalPreferences

    init() {
        let preferences = TerminalPreferences()
        #if DEBUG
        TerminalToolAccessTestFixture.configure(preferences)
        #endif
        _preferences = StateObject(wrappedValue: preferences)
        SomeIMUpdateController.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(preferences: preferences)
        }
        // 隐藏标题文字由 WindowConfigurator 负责，保留系统标题栏的鼠标行为。
        .windowStyle(.titleBar)
        .commands {
            SomeIMUpdateCommands()

            TerminalCommands(preferences: preferences)

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
