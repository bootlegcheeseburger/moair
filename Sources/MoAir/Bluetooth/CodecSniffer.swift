import Foundation
import Combine

@MainActor
final class CodecSniffer: ObservableObject {
    struct Snapshot: Equatable {
        var codec: String
        var bitrateKbps: Int?
        var sampleRateHz: Int?
        var rawLine: String
        var timestamp: Date
    }

    @Published private(set) var current: Snapshot?
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastError: String?

    func clearCurrent() {
        current = nil
    }

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var buffer = Data()

    func start() {
        if FakeMode.enabled {
            current = Snapshot(
                codec: "AAC-LC",
                bitrateKbps: 256,
                sampleRateHz: 48000,
                rawLine: "[fake] A2DP configured at 48 KHz. Codec: AAC-LC, VBR max: 256kbps",
                timestamp: Date()
            )
            isRunning = true
            return
        }
        guard !isRunning else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = [
            "stream",
            "--style", "compact",
            "--predicate", "subsystem == \"com.apple.bluetooth\" AND eventMessage CONTAINS \"Codec\"",
            "--info"
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in
                self?.handleChunk(chunk)
            }
        }

        do {
            try task.run()
            self.process = task
            self.stdoutPipe = pipe
            self.isRunning = true
            self.lastError = nil
        } catch {
            self.lastError = String(describing: error)
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        isRunning = false
    }

    deinit {
        // Reap the child `log stream` if the sniffer is dropped without
        // an explicit stop(). Process.terminate + handler-nil are safe
        // from a nonisolated deinit; we don't touch @Published state.
        process?.terminate()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
    }

    private func handleChunk(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let line = String(data: Data(lineData), encoding: .utf8) {
                parseLine(line)
            }
        }
    }

    private func parseLine(_ line: String) {
        guard let codecRange = line.range(of: #"Codec:\s*([A-Za-z0-9-]+)"#, options: .regularExpression) else { return }
        let codecMatch = String(line[codecRange])
        let codec = codecMatch
            .replacingOccurrences(of: "Codec:", with: "")
            .trimmingCharacters(in: .whitespaces)

        var bitrate: Int?
        if let r = line.range(of: #"max:?\s*(\d+)\s*kbps"#, options: .regularExpression) {
            let m = String(line[r])
            bitrate = m.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.last
        }

        var sampleRate: Int?
        if let r = line.range(of: #"(\d+(?:\.\d+)?)\s*K?Hz"#, options: .regularExpression) {
            let m = String(line[r])
            if let v = m.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap({ Double($0) }).first {
                sampleRate = Int(v >= 1000 ? v : v * 1000)
            }
        }

        current = Snapshot(
            codec: codec,
            bitrateKbps: bitrate,
            sampleRateHz: sampleRate,
            rawLine: line,
            timestamp: Date()
        )
    }
}
