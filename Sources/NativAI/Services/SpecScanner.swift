/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Scans the local machine's hardware and produces a `DeviceSpecs` snapshot.
/// Uses sysctl for fast, reliable RAM/CPU info, and `system_profiler` for
/// chip/GPU names (slower, so it's only called once at first launch and cached).
enum SpecScanner {

    static func scan() -> DeviceSpecs {
        let totalRAMBytes = sysctlInt64("hw.memsize") ?? 0
        let totalRAMGB = Double(totalRAMBytes) / 1_073_741_824.0
        let cpuCores = Int(sysctlInt64("hw.ncpu") ?? 0)
        let isAppleSilicon = isRunningAppleSilicon()

        let (chipName, gpuName) = readChipAndGPUNames()

        // On Apple Silicon, GPU and CPU share unified memory, so we treat
        // the full RAM pool as the "VRAM" ceiling for model-fit calculations.
        // On Intel Macs with discrete GPUs we don't have a reliable local API
        // for VRAM size, so we conservatively fall back to 0 (forces RAM-only tiering).
        let vramGB = isAppleSilicon ? totalRAMGB : 0

        return DeviceSpecs(
            totalRAMGB: totalRAMGB,
            cpuCores: cpuCores,
            isAppleSilicon: isAppleSilicon,
            chipName: chipName,
            gpuName: gpuName,
            vramGB: vramGB
        )
    }

    // MARK: - sysctl helpers

    private static func sysctlInt64(_ name: String) -> Int64? {
        var size: size_t = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var value: Int64 = 0
        let result = sysctlbyname(name, &value, &size, nil, 0)
        return result == 0 ? value : nil
    }

    private static func isRunningAppleSilicon() -> Bool {
        var size: size_t = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        var value: Int32 = 0
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }

    // MARK: - system_profiler (chip + GPU display names)

    private static func readChipAndGPUNames() -> (chip: String, gpu: String) {
        let output = runProcess("/usr/sbin/sysctl", args: ["-n", "machdep.cpu.brand_string"])
        var chip = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"

        // On Apple Silicon, machdep.cpu.brand_string is often empty/unreliable;
        // fall back to system_profiler for a friendly chip name.
        if chip.isEmpty || chip == "Unknown" {
            if let profilerOutput = runProcess(
                "/usr/sbin/system_profiler", args: ["SPHardwareDataType"]
            ) {
                chip = extractLine(containing: "Chip:", in: profilerOutput)
                    ?? extractLine(containing: "Processor Name:", in: profilerOutput)
                    ?? "Unknown"
            }
        }

        var gpu = "Unknown"
        if let displayOutput = runProcess(
            "/usr/sbin/system_profiler", args: ["SPDisplaysDataType"]
        ) {
            gpu = extractLine(containing: "Chipset Model:", in: displayOutput) ?? "Unknown"
        }

        return (chip, gpu)
    }

    private static func extractLine(containing marker: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            if line.contains(marker) {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    private static func runProcess(_ path: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
