//
//  ClipboardHistoryApp.swift
//  ClipboardHistory
//
//  Created by 宋斌 on 2026/1/14.
//

import SwiftUI
import AppKit

@main
struct ClipboardHistoryApp: App {
    @NSApplicationDelegateAdaptor(ClipboardHistoryAppDelegate.self) private var appDelegate
    @StateObject private var viewModel = ClipboardHistoryViewModel()
    @StateObject private var shortcutManager = KeyboardShortcutManager()
    @State private var isPanelVisible = false

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel,
                        isPanelVisible: $isPanelVisible)
            .frame(minWidth: 960)
            .onAppear {
                shortcutManager.configure(
                    onTogglePanel: { togglePanelVisible(source: "hotkey") }
                )
                shortcutManager.start()
            }
            .onReceive(NotificationCenter.default.publisher(for: .togglePanelRequested)) { _ in
                togglePanelVisible(source: "status_item")
            }
            .onReceive(NotificationCenter.default.publisher(for: .showSettingsRequested)) { _ in
                presentSettings(source: "status_item")
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("剪贴板历史") {
                Button("显示/隐藏面板 (Ctrl+~)") {
                    togglePanelVisible(source: "menu")
                }.keyboardShortcut("`", modifiers: [.control])
            }
        }
    }

    private func togglePanelVisible(source: String) {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        isPanelVisible.toggle()
        ClipLog.info("panel_toggle source=\(source) visible=\(isPanelVisible)")
        if isPanelVisible {
            NotificationCenter.default.post(name: .focusSearchField, object: nil)
        }
    }

    private func presentSettings(source: String) {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if !isPanelVisible {
            isPanelVisible = true
            ClipLog.info("panel_toggle source=\(source) visible=\(isPanelVisible)")
        }
        NotificationCenter.default.post(name: .presentSettingsSheet, object: nil)
        ClipLog.info("settings_open source=\(source)")
    }
}
