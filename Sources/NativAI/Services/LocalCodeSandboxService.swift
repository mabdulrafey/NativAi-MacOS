/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Safe, isolated local code execution sandbox for Python scripts & math evaluations.
enum LocalCodeSandboxService {

    struct ExecutionResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let executionTimeSeconds: Double
    }

    /// Evaluates Python code locally using `/usr/bin/sandbox-exec` profile isolation.
    static func executePython(code: String, timeoutSeconds: TimeInterval = 10.0) async -> ExecutionResult {
        let startTime = Date()

        let tempDir = FileManager.default.temporaryDirectory
        let scriptFile = tempDir.appendingPathComponent("nativai_sandbox_\(UUID().uuidString).py")

        do {
            try code.write(to: scriptFile, atomically: true, encoding: .utf8)
        } catch {
            return ExecutionResult(stdout: "", stderr: "Failed to write script: \(error.localizedDescription)", exitCode: -1, executionTimeSeconds: 0)
        }

        defer {
            try? FileManager.default.removeItem(at: scriptFile)
        }

        let process = Process()
        let profile = "(version 1) (allow default) (deny file-write* (subpath \"/\")) (allow file-write* (subpath \"\(tempDir.path)\"))"
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, "/usr/bin/python3", scriptFile.path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ExecutionResult(stdout: "", stderr: "Failed to launch Python sandbox: \(error.localizedDescription)", exitCode: -1, executionTimeSeconds: 0)
        }

        // Enforce execution timeout
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        if process.isRunning {
            process.terminate()
            return ExecutionResult(stdout: "", stderr: "Execution timed out after \(Int(timeoutSeconds)) seconds.", exitCode: -9, executionTimeSeconds: timeoutSeconds)
        }

        let stdoutData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let elapsed = Date().timeIntervalSince(startTime)

        return ExecutionResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus, executionTimeSeconds: elapsed)
    }
}
