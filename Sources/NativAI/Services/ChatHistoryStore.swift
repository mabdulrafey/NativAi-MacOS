/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Persists chat sessions locally as individual JSON files under
/// ~/Library/Application Support/NativAI/ChatHistory/. One file per session
/// (named by session id) so deleting a chat is a single, fast file removal —
/// no need to rewrite one giant history blob on every delete.
final class ChatHistoryStore {

    static let shared = ChatHistoryStore()

    private let directory: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = appSupport.appendingPathComponent("NativAI/ChatHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for sessionId: UUID) -> URL {
        directory.appendingPathComponent("\(sessionId.uuidString).json")
    }

    func save(_ session: ChatSession) {
        do {
            let data = try JSONEncoder().encode(session)
            try data.write(to: fileURL(for: session.id), options: .atomic)
        } catch {
            print("⚠️ Failed to save chat session \(session.id): \(error)")
        }
    }

    func delete(sessionId: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: sessionId))
    }

    func loadAll() -> [ChatSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }

        let sessions: [ChatSession] = files.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let session = try? JSONDecoder().decode(ChatSession.self, from: data)
            else { return nil }
            return session
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Total bytes used by all saved chat history JSON files (text + any
    /// embedded base64 image data from image-gen responses).
    func totalDiskUsageBytes() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        return files.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }
}
