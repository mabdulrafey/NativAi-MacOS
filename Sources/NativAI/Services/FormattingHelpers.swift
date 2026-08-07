/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Formats a byte count into a human-readable size string, e.g. "986 MB" or
/// "4.9 GB". Uses ByteCountFormatter so it matches Finder's own conventions.
func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
/// Formats a raw bytes/sec value into a human-readable speed string, e.g.
/// "4.2 MB/s" or "812 KB/s" — used to show live download speed during model pulls.
func formatSpeed(bytesPerSecond: Double) -> String {
    guard bytesPerSecond > 0 else { return "" }
    let mbPerSecond = bytesPerSecond / 1_048_576.0
    if mbPerSecond >= 1.0 {
        return String(format: "%.1f MB/s", mbPerSecond)
    }
    let kbPerSecond = bytesPerSecond / 1024.0
    return String(format: "%.0f KB/s", kbPerSecond)
}
