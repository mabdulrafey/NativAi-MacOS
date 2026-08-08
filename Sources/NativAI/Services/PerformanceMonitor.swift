/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation
import Combine

/// Tracks live streaming performance (tokens/sec) and system RAM/VRAM memory usage.
final class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()

    @Published private(set) var tokensPerSecond: Double = 0.0
    @Published private(set) var tokenCount: Int = 0
    @Published private(set) var activeRAMUsageMB: Double = 0.0
    @Published private(set) var isStreaming: Bool = false

    private var startTime: Date?

    func startStream() {
        DispatchQueue.main.async {
            self.startTime = Date()
            self.tokenCount = 0
            self.tokensPerSecond = 0.0
            self.isStreaming = true
        }
    }

    func recordToken() {
        DispatchQueue.main.async {
            self.tokenCount += 1
            guard let start = self.startTime else { return }
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > 0.2 {
                self.tokensPerSecond = Double(self.tokenCount) / elapsed
            }
        }
    }

    func stopStream() {
        DispatchQueue.main.async {
            self.isStreaming = false
        }
    }

    func updateRAMUsage(bytes: Int64) {
        DispatchQueue.main.async {
            self.activeRAMUsageMB = Double(bytes) / (1024.0 * 1024.0)
        }
    }
}
