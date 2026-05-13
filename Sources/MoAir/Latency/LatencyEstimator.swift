import Foundation
import CoreAudio
import Combine

@MainActor
final class LatencyEstimator: ObservableObject {
    struct AudioLatencyBreakdown: Equatable {
        var deviceFrames: UInt32
        var safetyOffsetFrames: UInt32
        var streamFrames: UInt32
        var bufferFrames: UInt32
        var sampleRate: Double

        var totalFrames: UInt32 { deviceFrames + safetyOffsetFrames + streamFrames + bufferFrames }

        var totalMilliseconds: Double {
            guard sampleRate > 0 else { return 0 }
            return Double(totalFrames) / sampleRate * 1000.0
        }

        var deviceMs: Double { sampleRate > 0 ? Double(deviceFrames) / sampleRate * 1000 : 0 }
        var safetyMs: Double { sampleRate > 0 ? Double(safetyOffsetFrames) / sampleRate * 1000 : 0 }
        var streamMs: Double { sampleRate > 0 ? Double(streamFrames) / sampleRate * 1000 : 0 }
        var bufferMs: Double { sampleRate > 0 ? Double(bufferFrames) / sampleRate * 1000 : 0 }
    }

    @Published private(set) var audio: AudioLatencyBreakdown?
    @Published private(set) var headTrackingEffectiveHz: Double = 0
    @Published private(set) var headTrackingPipelineMs: Double = 0
    @Published private(set) var oscSendIntervalMs: Double = 0

    private var pollTimer: Timer?
    private weak var audioController: AudioController?
    private weak var headTracker: HeadTracker?
    private weak var oscBridge: OSCBridge?

    func bind(audio: AudioController, head: HeadTracker, osc: OSCBridge) {
        self.audioController = audio
        self.headTracker = head
        self.oscBridge = osc
        recompute()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
    }

    deinit { pollTimer?.invalidate() }

    func recompute() {
        recomputeAudio()
        recomputeHeadTracking()
        recomputeOSC()
    }

    private func recomputeAudio() {
        guard let id = audioController?.deviceID else { audio = nil; return }
        let device = CoreAudioBridge.deviceLatency(id) ?? 0
        let safety = CoreAudioBridge.safetyOffset(id) ?? 0
        let stream = CoreAudioBridge.streamLatency(id)
        let buffer = CoreAudioBridge.bufferFrameSize(id) ?? 0
        let sr = audioController?.sampleRate ?? 0
        audio = AudioLatencyBreakdown(
            deviceFrames: device,
            safetyOffsetFrames: safety,
            streamFrames: stream,
            bufferFrames: buffer,
            sampleRate: sr
        )
    }

    private func recomputeHeadTracking() {
        let hz = headTracker?.effectiveHz ?? 0
        headTrackingEffectiveHz = hz
        let interSampleMs = hz > 0 ? (1000.0 / hz) : 0
        let appAge = (headTracker?.lastSampleAge ?? 0) * 1000.0
        headTrackingPipelineMs = interSampleMs + appAge
    }

    private func recomputeOSC() {
        oscSendIntervalMs = oscBridge?.measuredSendIntervalMs ?? 0
    }
}
