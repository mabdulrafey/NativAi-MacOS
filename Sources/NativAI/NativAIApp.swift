/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI
import AppKit

/// Ensures the app becomes the frontmost, key window on launch. Without this,
/// apps launched via `open` (e.g. from our .pkg's postinstall script) or from
/// a background Terminal process can appear without ever receiving keyboard
/// focus — which looks exactly like "I can't type in the text field" even
/// though the TextField binding itself is fine.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    /// If the user has opted in (Settings > "Stop Ollama when NativAI
    /// quits"), stop the Ollama server before actually terminating — without
    /// this, Ollama (started as a Homebrew launchd service, or by our own
    /// startServerIfNeeded() fallback) keeps running in the background
    /// indefinitely after the app closes, along with whatever model is
    /// currently loaded into memory. Returning .terminateLater lets us
    /// finish the async stop call before the app actually exits, rather than
    /// racing a fire-and-forget Task against process termination.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState, appState.stopOllamaOnQuit else {
            return .terminateNow
        }
        Task {
            await OllamaManager.shared.stopServer()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct NativAIApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(appState.appearanceMode.colorScheme)
                .onAppear {
                    // AppDelegate is initialized independently from
                    // @StateObject appState, so it needs this explicit hand-
                    // off before applicationShouldTerminate can read
                    // stopOllamaOnQuit.
                    appDelegate.appState = appState
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)

        // Memory lives in its own Settings window (⌘,) rather than as a sidebar
        // destination.
        //
        // Rendered inside the main NavigationSplitView it reliably blanked the
        // whole window — sidebar included — and three attempts to pin down the
        // SwiftUI interaction by inspection were unsuccessful. A separate window
        // scene is its own render tree, so even if this view fails it cannot take
        // the chat UI down with it. The memory feature itself is verified
        // working; this is about limiting the blast radius of a UI bug rather
        // than continuing to guess at it.
        Settings {
            MemoryView(store: MemoryStore.shared)
                .environmentObject(appState)
                .frame(width: 520, height: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    NotificationCenter.default.post(name: Notification.Name("NativAISystemNewChat"), object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .importExport) {
                Button("Export Session...") {
                    NotificationCenter.default.post(name: Notification.Name("NativAISystemExportSession"), object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)
            }
        }
    }
}
