import Foundation
import CoreBluetooth
import Combine

@MainActor
final class ContinuityScanner: NSObject, ObservableObject {
    enum AuthState: Equatable {
        case unknown
        case authorized
        case denied
        case unsupported
    }

    @Published private(set) var auth: AuthState = .unknown
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var isCharging: Bool = false
    @Published private(set) var isInCase: Bool = false
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var lastSeenRSSI: Int?

    private var central: CBCentralManager!
    private let queue = DispatchQueue(label: "bootlegcheeseburger.moair.continuity", qos: .utility)
    private let appleCompanyID: UInt16 = 0x004C
    private let proximityPairingType: UInt8 = 0x07

    // Apple Continuity proximity-pairing model codes for headphones whose
    // IMU surfaces through CMHeadphoneMotionManager. Stored both byte-orders
    // because adverts from some firmware revisions swap them.
    private let supportedHeadphoneModelCodes: Set<UInt16> = [
        0x0A20, 0x200A, // AirPods Max
        0x0E20, 0x200E, // AirPods Pro (1st gen)
        0x1420, 0x2014, // AirPods Pro (2nd gen, Lightning)
        0x2420, 0x2024, // AirPods Pro (2nd gen, USB-C)
        0x1320, 0x2013, // AirPods (3rd gen)
        0x2724, 0x2427, // AirPods 4 (with ANC)
        0x1020, 0x2010, // Beats Fit Pro
    ]

    private var fakeTimer: Timer?

    override init() {
        super.init()
        if FakeMode.enabled {
            startFake()
            return
        }
        central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionShowPowerAlertKey: false
        ])
    }

    func startScan() {
        if FakeMode.enabled { return }
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
    }

    func stopScan() {
        if FakeMode.enabled { return }
        guard central.state == .poweredOn else { return }
        central.stopScan()
    }

    private func startFake() {
        auth = .authorized
        batteryPercent = 87
        isCharging = false
        isInCase = false
        lastSeenRSSI = -52
        lastUpdate = Date()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastUpdate = Date()
                self?.lastSeenRSSI = Int.random(in: -65 ... -45)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fakeTimer = timer
    }
}

extension ContinuityScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.auth = .authorized
                self.startScan()
            case .unauthorized:
                self.auth = .denied
            case .unsupported:
                self.auth = .unsupported
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber
    ) {
        guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        guard manufacturerData.count >= 4 else { return }

        let companyID = UInt16(manufacturerData[0]) | (UInt16(manufacturerData[1]) << 8)
        guard companyID == appleCompanyID else { return }

        let messageType = manufacturerData[2]
        guard messageType == proximityPairingType else { return }

        let payload = manufacturerData.dropFirst(3)
        guard payload.count >= 6 else { return }
        let bytes = Array(payload)

        let deviceClassHi = bytes[1]
        let deviceClassLo = bytes[2]
        let modelCode = (UInt16(deviceClassHi) << 8) | UInt16(deviceClassLo)
        guard supportedHeadphoneModelCodes.contains(modelCode) else { return }

        let statusByte = bytes[3]
        let batteryByte = bytes[4]
        let caseFlagsByte = bytes[5]

        let leftNibble = (batteryByte & 0xF0) >> 4
        let rightNibble = batteryByte & 0x0F
        let validNibbles = [leftNibble, rightNibble].filter { $0 != 0xF }
        let percent: Int? = validNibbles.isEmpty ? nil : Int(validNibbles.max() ?? 0) * 10

        let chargingFlags = caseFlagsByte & 0xF0
        let charging = (chargingFlags & 0x10) != 0 || (chargingFlags & 0x20) != 0

        let inCase = (statusByte & 0x40) != 0

        let rssiValue = RSSI.intValue

        Task { @MainActor in
            self.batteryPercent = percent
            self.isCharging = charging
            self.isInCase = inCase
            self.lastSeenRSSI = rssiValue
            self.lastUpdate = Date()
        }
    }
}
