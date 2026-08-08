/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import AppKit
import SwiftUI

/// Manages the macOS Status Item (Menu Bar icon) and global hotkey to show/hide the Quick Ask Spotlight panel.
final class QuickAskManager: NSObject {
    static let shared = QuickAskManager()

    private var statusItem: NSStatusItem?
    private var panel: QuickAskPanel?
    private var eventMonitor: Any?

    func setup(appState: AppState) {
        // Create Menu Bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "NativAI Quick Ask")
            button.target = self
            button.action = #selector(togglePanel)
        }

        // Create Panel View
        let quickView = QuickAskView().environmentObject(appState)
        let hostingView = NSHostingView(rootView: quickView)
        panel = QuickAskPanel(contentView: hostingView)

        // Register Global Key Monitor (Cmd + Shift + Space)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 49 { // 49 = Space
                DispatchQueue.main.async {
                    self?.togglePanel()
                }
            }
        }
    }

    @objc func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.centerOnScreen()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
