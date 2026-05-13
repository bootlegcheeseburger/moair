import Foundation
import CoreMotion
import Combine

@MainActor
final class HeadTracker: NSObject, ObservableObject {
    enum State: Equatable {
        case unsupported
        case idle
        case waitingForPermission
        case denied
        case streaming
        case stoppedByDisconnect
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var latest: HeadOrientation = .zero
    /// Full-shaped sample (dead-spot + jitter + sensitivity). Sent over OSC.
    @Published private(set) var displayed: HeadOrientation = .zero
    /// Same shaping as `displayed` but with the jitter step skipped, so the
    /// number stays still while the user is calibrating. The panel's YPR
    /// readout binds to this — the OSC stream still uses `displayed`.
    @Published private(set) var displayedStable: HeadOrientation = .zero
    @Published private(set) var effectiveHz: Double = 0
    @Published private(set) var lastSampleAge: TimeInterval = 0
    @Published private(set) var totalSamples: UInt64 = 0
    @Published private(set) var lastError: String?

    /// Per-axis post-processing applied between the calibrated orientation
    /// and what's published / sent over OSC. `dial` values are 0...1,
    /// scaled to the degree-domain constants below. The post-processing
    /// happens in-place in `recomputeDisplayed`, so settings changes feel
    /// instantaneous even when no fresh sample has arrived.
    struct PostProcessing: Equatable, Sendable {
        var jitter: Double = 0          // 0...1 → 0...maxJitterDegrees peak amplitude
        var deadSpotYaw: Double = 0     // 0...1 → 0...maxDeadSpotDegrees half-width
        var deadSpotPitch: Double = 0
        var deadSpotRoll: Double = 0

        /// User-facing slider value in [-1, +1] with 0 = unchanged.
        /// `multiplier` translates this into the actual gain applied to
        /// every shaped axis (and to the jitter on top of it):
        ///   sensitivity == -1 → 0×  (motion fully muted)
        ///   sensitivity ==  0 → 1×  (the default; samples pass through)
        ///   sensitivity == +1 → 2×  (motion doubled)
        var sensitivity: Double = 0

        var multiplier: Double { 1.0 + max(-1, min(1, sensitivity)) }

        static let maxJitterDegrees = 2.0
        static let maxDeadSpotDegrees = 12.0
    }

    var postProcessing: PostProcessing = .init() {
        didSet {
            guard postProcessing != oldValue else { return }
            recomputeDisplayed()
        }
    }

    // Recreated on each start() so a fresh permission grant takes effect
    // without an app relaunch, and so swapping headphones (e.g. switching
    // from AirPods Max to AirPods Pro mid-session) re-binds cleanly. The
    // existing instance can otherwise cache "denied" or stale device state.
    private var manager = CMHeadphoneMotionManager()
    private let queue = OperationQueue()
    private var referenceQuaternion: SIMDQuaternion = .identity

    private var sampleTimestamps: [TimeInterval] = []
    private let sampleWindow = 25

    private var fakeTimer: Timer?
    private var fakeStartTime: TimeInterval = 0
    private var diagnosticsTimer: Timer?

    var onSample: ((HeadOrientation) -> Void)?

    override init() {
        super.init()
        queue.name = "bootlegcheeseburger.moair.motion"
        queue.qualityOfService = .userInteractive
        queue.maxConcurrentOperationCount = 1
        manager.delegate = self
    }

    func start() {
        if FakeMode.enabled {
            startFake()
            return
        }

        // Recreate the manager so any pre-grant cached state is dropped.
        if manager.isDeviceMotionActive {
            print("[MoAir][HeadTracker] already active, skipping")
            return
        }
        // CoreMotion may still hold the old manager (queued operations,
        // pending delegate calls). Disconnect ours from it BEFORE
        // swapping — otherwise its didDisconnect or motion-error
        // callback can fire after the new manager is live, mutating
        // state under us and dropping the user into a fake "Headphones
        // Removed" state that only an app restart recovers from.
        manager.delegate = nil
        if manager.isDeviceMotionActive {
            manager.stopDeviceMotionUpdates()
        }
        manager = CMHeadphoneMotionManager()
        manager.delegate = self
        let activeManager = manager

        let avail = manager.isDeviceMotionAvailable
        print("[MoAir][HeadTracker] start() avail=\(avail) currentState=\(state)")

        if state == .denied { state = .idle }

        // Don't gate on isDeviceMotionAvailable: on macOS it can return false
        // until Motion permission is granted AND a supported headphone is
        // connected, which would prevent TCC from ever seeing our request.
        lastError = nil
        state = .waitingForPermission
        print("[MoAir][HeadTracker] -> .waitingForPermission, starting CM updates")
        scheduleDiagnostics()
        manager.startDeviceMotionUpdates(to: queue) { [weak self, weak activeManager] motion, error in
            guard let self, let activeManager else { return }
            if let error {
                let nsError = error as NSError
                let desc = "[\(nsError.domain) \(nsError.code)] \(error.localizedDescription)"
                print("[MoAir][HeadTracker] motion error: \(desc)")
                Task { @MainActor in
                    // Drop callbacks from a manager we've already swapped
                    // out — they'd corrupt the state of the new one.
                    guard activeManager === self.manager else { return }
                    self.lastError = desc
                    if nsError.code == CMErrorMotionActivityNotAuthorized.rawValue {
                        self.state = .denied
                    } else {
                        self.state = .stoppedByDisconnect
                    }
                }
                return
            }
            guard let motion else { return }
            let now = Date().timeIntervalSince1970
            let sample = HeadOrientation(motion, receivedAt: now)
            Task { @MainActor in
                guard activeManager === self.manager else { return }
                self.ingest(sample)
                // Emit the *calibrated* orientation (relative to the
                // referenceQuaternion captured by reZero), so OSC consumers
                // see the same reset-to-forward values that the panel does.
                self.onSample?(self.displayed)
            }
        }
    }

    func stop() {
        print("[MoAir][HeadTracker] stop() state=\(state) totalSamples=\(totalSamples)")
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
        if FakeMode.enabled {
            fakeTimer?.invalidate()
            fakeTimer = nil
            state = .idle
            return
        }
        if manager.isDeviceMotionActive {
            manager.stopDeviceMotionUpdates()
        }
        state = .idle
    }

    private func scheduleDiagnostics() {
        diagnosticsTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.totalSamples == 0 {
                    print("[MoAir][HeadTracker] 2s diag: active=\(self.manager.isDeviceMotionActive) avail=\(self.manager.isDeviceMotionAvailable) samples=0 — try playing audio; AirPods / Beats Fit Pro typically only stream motion while audio is flowing")
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        diagnosticsTimer = timer
    }

    private func startFake() {
        guard fakeTimer == nil else { return }
        fakeStartTime = Date().timeIntervalSince1970
        sampleTimestamps.removeAll()
        let timer = Timer(timeInterval: 1.0 / 25.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fakeTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fakeTimer = timer
    }

    private func fakeTick() {
        let now = Date().timeIntervalSince1970
        let t = now - fakeStartTime
        let yawDeg = 30 * sin(t * 0.6)
        let pitchDeg = 15 * sin(t * 0.9 + 1.0)
        let rollDeg = 10 * sin(t * 1.4 + 2.0)
        // Generated values are in OSC convention (positive yaw = head turns
        // right). The quaternion lives in CoreMotion's headphone frame where
        // positive yaw = left turn, so flip the sign before encoding.
        let q = quaternionFromYPR(yawDeg: -yawDeg, pitchDeg: pitchDeg, rollDeg: rollDeg)
        let sample = HeadOrientation(
            quaternion: q,
            yawDegrees: yawDeg,
            pitchDegrees: pitchDeg,
            rollDegrees: rollDeg,
            rotationRate: SIMDVector3(
                x: cos(t * 1.4 + 2.0) * 1.4,
                y: cos(t * 0.9 + 1.0) * 0.9,
                z: cos(t * 0.6) * 0.6
            ),
            gravity: SIMDVector3(x: 0, y: -1, z: 0),
            sourceTimestamp: now,
            receivedAt: now
        )
        ingest(sample)
        onSample?(displayed)
    }

    func reZero() {
        referenceQuaternion = latest.quaternion
        recomputeDisplayed()
    }

    private func ingest(_ sample: HeadOrientation) {
        latest = sample
        recomputeDisplayed()
        sampleTimestamps.append(sample.sourceTimestamp)
        if sampleTimestamps.count > sampleWindow {
            sampleTimestamps.removeFirst(sampleTimestamps.count - sampleWindow)
        }
        if sampleTimestamps.count >= 2 {
            let span = sampleTimestamps.last! - sampleTimestamps.first!
            if span > 0 {
                effectiveHz = Double(sampleTimestamps.count - 1) / span
            }
        }
        lastSampleAge = Date().timeIntervalSince1970 - sample.receivedAt
        totalSamples &+= 1
        if state != .streaming {
            print("[MoAir][HeadTracker] first sample received, -> .streaming")
            state = .streaming
        }
    }

    private func recomputeDisplayed() {
        let calibrated = latest.relative(to: referenceQuaternion)
        let pp = postProcessing
        let dsScale = PostProcessing.maxDeadSpotDegrees
        let jitterAmp = pp.jitter * PostProcessing.maxJitterDegrees
        let sens = pp.multiplier

        // Linear expander instead of a hard gate: subtract the dead-spot
        // threshold from the magnitude so the output starts at 0 right at
        // the edge of the dead zone and grows continuously outward.
        // Without this, the value would jump from 0 to ±threshold the
        // moment the head moves past the boundary — a perceptible click
        // in the rendered audio image.
        func deadSpotted(_ v: Double, dead: Double) -> Double {
            let threshold = dead * dsScale
            let sign: Double = v < 0 ? -1 : 1
            return max(0, abs(v) - threshold) * sign
        }

        func noise() -> Double {
            jitterAmp == 0 ? 0 : Double.random(in: -jitterAmp...jitterAmp)
        }

        let yDS = deadSpotted(calibrated.yawDegrees, dead: pp.deadSpotYaw)
        let pDS = deadSpotted(calibrated.pitchDegrees, dead: pp.deadSpotPitch)
        let rDS = deadSpotted(calibrated.rollDegrees, dead: pp.deadSpotRoll)

        // Sensitivity scales both versions identically — what differs is
        // only whether jitter is added before the multiply. That keeps the
        // panel's YPR display rock-steady (so the user can read calibration
        // numbers) while OSC consumers still receive the full noisy stream.
        displayedStable = HeadOrientation(
            quaternion: calibrated.quaternion,
            yawDegrees: yDS * sens,
            pitchDegrees: pDS * sens,
            rollDegrees: rDS * sens,
            rotationRate: calibrated.rotationRate,
            gravity: calibrated.gravity,
            sourceTimestamp: calibrated.sourceTimestamp,
            receivedAt: calibrated.receivedAt
        )
        displayed = HeadOrientation(
            quaternion: calibrated.quaternion,
            yawDegrees: (yDS + noise()) * sens,
            pitchDegrees: (pDS + noise()) * sens,
            rollDegrees: (rDS + noise()) * sens,
            rotationRate: calibrated.rotationRate,
            gravity: calibrated.gravity,
            sourceTimestamp: calibrated.sourceTimestamp,
            receivedAt: calibrated.receivedAt
        )
    }
}

extension HeadTracker: CMHeadphoneMotionManagerDelegate {
    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        print("[MoAir][HeadTracker] delegate: headphones connected")
        // Resume motion if we were running before the headphones went to
        // sleep (taken off head, transient BT blip). .idle means the user
        // deliberately stopped — leave those alone.
        Task { @MainActor [weak self, weak manager] in
            guard let self else { return }
            guard manager === self.manager else { return }
            if self.state == .stoppedByDisconnect {
                print("[MoAir][HeadTracker] auto-restart after reconnect")
                self.start()
            }
        }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        print("[MoAir][HeadTracker] delegate: headphones disconnected")
        Task { @MainActor [weak self, weak manager] in
            guard let self else { return }
            // Ignore disconnect notifications from a manager we've
            // already swapped out — only the currently-live manager
            // should be allowed to flip state.
            guard manager === self.manager else { return }
            if self.state == .streaming || self.state == .waitingForPermission {
                self.state = .stoppedByDisconnect
            }
        }
    }
}

// Build a quaternion from CoreMotion-frame YPR angles using the same
// Tait-Bryan Z-X-Y intrinsic order as `SIMDQuaternion.toEulerYPR()`, so the
// fake-mode samples round-trip cleanly through `relative()` and produce the
// same axis behaviour as live AirPods data.
private func quaternionFromYPR(yawDeg: Double, pitchDeg: Double, rollDeg: Double) -> SIMDQuaternion {
    let cy = cos(yawDeg * .pi / 360)
    let sy = sin(yawDeg * .pi / 360)
    let cp = cos(pitchDeg * .pi / 360)
    let sp = sin(pitchDeg * .pi / 360)
    let cr = cos(rollDeg * .pi / 360)
    let sr = sin(rollDeg * .pi / 360)
    return SIMDQuaternion(
        w: cy * cp * cr - sy * sp * sr,
        x: cy * sp * cr - sy * cp * sr,
        y: cy * cp * sr + sy * sp * cr,
        z: cy * sp * sr + sy * cp * cr
    )
}
