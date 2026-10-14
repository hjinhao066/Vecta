import CoreBluetooth
import Foundation
import NotePinTransport

/// Passive bounded scan, no authentication, writes or automatic selection.
public final class NativePlaudDiscovery: NSObject, CBCentralManagerDelegate {
    public var onCandidates: (([PlaudCandidate]) -> Void)?
    public var onState: ((String) -> Void)?
    public var onFinished: (() -> Void)?
    public var onDiagnostics: (([String: Int]) -> Void)?
    private var diagnostics: [String: Int] = [:]
    private var central: CBCentralManager?
    private var timer: Timer?
    private var stopped = false
    private var candidates: [UUID: PlaudCandidate] = [:]
    public func start() {
        stopped = false; candidates.removeAll(); diagnostics = [:]; onCandidates?([])
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
    public func stop() { stopped = true; timer?.invalidate(); central?.stopScan(); central?.delegate = nil; central = nil; onDiagnostics?(diagnostics); onFinished?() }
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !stopped else { return }
        switch central.state {
        case .poweredOn:
            for peripheral in central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "1910")]) {
                candidates[peripheral.identifier] = PlaudCandidate(id: peripheral.identifier, advertisement: nil, rssi: 0, isConnectable: false)
                diagnostics["alreadyConnected", default: 0] += 1
            }
            onCandidates?(Array(candidates.values))
            onState?("Ищем Plaud рядом с Mac…")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
                self?.stop(); self?.onState?("Поиск завершён. Выберите устройство или повторите поиск.")
            }
        case .unauthorized: onState?("Разрешите Bluetooth для Vecta в настройках macOS."); stop()
        case .poweredOff: onState?("Bluetooth выключен."); stop()
        case .unsupported: onState?("Bluetooth не поддерживается."); stop()
        default: break
        }
    }
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !stopped, candidates.count < 100 || candidates[peripheral.identifier] != nil else { return }
        diagnostics["advertisements", default: 0] += 1
        if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 2 {
            let company = UInt16(data[0]) | UInt16(data[1]) << 8
            diagnostics["company-\(company)", default: 0] += 1
            if (try? NativeAdvertisement.decodeManufacturerData(data)) != nil { diagnostics["validPlaud", default: 0] += 1 }
        }
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
        guard let candidate = PlaudCandidate.observe(id: peripheral.identifier,
            manufacturer: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
            name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name,
            services: services, rssi: RSSI.intValue,
            connectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true) else { return }
        // Retain stronger identity when a later scan response only supplies name.
        if candidate.advertisement != nil || candidates[candidate.id]?.advertisement == nil { candidates[candidate.id] = candidate }
        onCandidates?(candidates.values.sorted { $0.rssi > $1.rssi })
    }
    deinit { timer?.invalidate(); central?.stopScan() }
}
