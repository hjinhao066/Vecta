import AppKit
import CoreBluetooth
import Foundation
import NotePinTransport
import NotePinAudio

/// Independent CoreBluetooth path. Ordinary synchronization never deletes recorder data.
/// Recovery is a separate explicit user action, never an automatic retry.
final class NativeBluetoothSession: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Configuration: Decodable {
        // Older research state may contain a CoreBluetooth UUID, but a fresh
        // macOS client starts without one. A verified cache is only a hint;
        // the authenticated recorder must still confirm its exact serial.
        let peripheralID: UUID?
        let platformDomain: String
        let accessToken: String
        let userID: String
        let serialNumber: String
        let deviceType: String
        var advertisedProtocolVersion: UInt16? = nil
        var handshakeToken: String? = nil
        var capturePrivateAdvertisements = false
        var explicitlyConfirmedRecovery = false
        var useVerifiedPeripheralCache = false
    }
    enum Stage: String { case idle, preparing, bluetooth, scanning, connecting, services, notifications, signature, rsa, owner, state, list, complete, download, downloaded, decoding, decoded, wifiStopping, wifiOpening, wifiReady, wifiDownload, resetting, failed }
    private(set) var stage = Stage.idle
    private(set) var authenticated = false
    private(set) var recorderState: ProtocolRecorderState?
    private(set) var recordings: [ProtocolRecordingFile] = []
    private(set) var supportsWiFi = false
    private var wifiFeatures = ProtocolWiFiFeatures()
    private var wifiReceivedSequence = ProtocolWiFiReceiveSequence()
    private var wifiActive = false
    private var wifiOpenCompletion: ((Result<ProtocolWiFiAccessPoint, Error>) -> Void)?
    var canUseWiFi: Bool { !stopped && authenticated && crypto != nil && supportsWiFi && !writeInProgress && writes.isEmpty && config.deviceType == "notepins" && config.serialNumber.hasPrefix("882") && protocolVersion == 20 && !wifiActive && stage == .download }
    var wifiOwnerToken: String { config.handshakeToken ?? config.userID }
    var isWiFiHandoverActive: Bool { wifiActive }
    private var lastTransferPublication:TimeInterval=0
    var onStatus: ((String) -> Void)?
    var onComplete: (([ProtocolRecordingFile]) -> Void)?
    var onIdentityPrepared: ((PreparedPartnerIdentity) throws -> Void)?
    var onTransferProgress: ((Int, Int) -> Void)?
    var onTransferValidated: (() -> Void)?
    var onDownloadComplete: ((URL) -> Void)?
    var onFailure: ((String) -> Void)?
    var onAuthenticatedCommandQueueIdle: (() -> Void)?
    var onFactoryResetAcknowledged: (() -> Void)?
    var onFactoryResetFinished: ((Bool) -> Void)?
    private var resetObservation = FactoryResetObservation()
    private var resetObservationTimer: Timer?
    private let config: Configuration
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var cachedConnection = false
    private var cacheDeadline: Timer?
    private var confirmedSerial = false
    var authenticatedPeripheralID: UUID? { authenticated && stage == .complete ? peripheral?.identifier : nil }
    private var command: CBCharacteristic?
    private var pendingServices = 0
    private var pendingNotifications = Set<String>()
    private var identity: PreparedPartnerIdentity?
    private var bootstrap = HandshakeChunks()
    private var crypto: SessionMaterial?
    private var sequence: UInt32 = 0
    private var receivedSequence: UInt32?
    private var protocolVersion: UInt16 = 0
    private var plaintextProfile: PlaudProtocolProfile?
    private var idleDeadline: Timer?
    var onBattery: ((Int, Bool) -> Void)?
    var onWiFiAvailabilityChanged: (() -> Void)?
    private var requestID: UInt32 = 0
    private var listCollector: ProtocolFileListCollector?
    private var listRetryPolicy = ProtocolListRetryPolicy()
    private let sessionReportID = UUID().uuidString
    private var listStartedAt = Date()
    private var downloadCollector: AudioDownloadCollector?
    private var downloadedRawURL: URL?
    private var downloadedMP3URL: URL?
    private(set) var downloadedHighlightSeconds: [Double]?
    private var preparationTask: Task<Void, Never>?
    private var decodingTask: Task<NativeAudioConversion, Error>?
    private var audioChannels = 1
    private var isOggAudio = false
    private var writes: [Data] = []
    private var writeInProgress = false
    private var deadline: Timer?
    private var lastDownloadActivity: TimeInterval = 0
    private var stopped = false
    private var maintainsConnection=false
    func setMaintainsConnection(_ value:Bool) {maintainsConnection=value;if value {idleDeadline?.invalidate();idleDeadline=nil}}
    private var events: [[String: Any]] = []
    private var observedAdvertisements: [[String: Any]] = []
    private var observedAdvertisementKeys = Set<String>()
    private let reportURL: URL

    init(config: Configuration, reportURL: URL, offlineIdentity: PreparedPartnerIdentity? = nil) {
        self.config = config; self.reportURL = reportURL; self.identity = offlineIdentity
        super.init()
    }
    func start() {
        guard stage == .idle else { return }
        if config.explicitlyConfirmedRecovery {
            guard config.deviceType == "notepins", config.serialNumber.hasPrefix("882"),
                  let version = config.advertisedProtocolVersion, (20...255).contains(version) else {
                fail("recovery-model-not-supported"); return
            }
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "dev.codex.plaudreceiver.a01a11651").isEmpty else {
            fail("sdk-recorder-still-running"); return
        }
        transition(.preparing, "Готовим защищённое подключение…")
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let version = config.advertisedProtocolVersion, version < 20 {
                    plaintextProfile = try PlaudProtocolProfile(version: version)
                    protocolVersion = version
                    guard !(config.handshakeToken ?? "").isEmpty else { fail("legacy-owner-token-required"); return }
                } else if identity == nil {
                let client = try PartnerPlatform(domain: config.platformDomain, accessToken: config.accessToken)
                let prepared = try await client.prepare(serialNumber: config.serialNumber, deviceType: config.deviceType) { [weak self] step in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.stopped, self.stage == .preparing else { return }
                        self.events.append(["preparationStep": step])
                        self.transition(.preparing, step == "partner-key" ? "Получаем ключ для защищённого подключения…" : "Подтверждаем авторизацию диктофона…")
                    }
                }
                guard !stopped else { return }
                identity = prepared
                do { try onIdentityPrepared?(prepared) }
                catch { fail("local-identity-save-failed"); return }
                events.append(["partnerIdentityPrepared": true])
                }
                // CoreBluetooth's initial authorization/state callback must be
                // started from the main dispatch queue, outside the async
                // preparation continuation (including launch-time sync).
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.events.append(["bluetoothAuthorization": CBManager.authorization.rawValue])
                    self.transition(.bluetooth, "Ожидаем готовность Bluetooth macOS…")
                    self.central = CBCentralManager(delegate: self, queue: .main,
                        options: [CBCentralManagerOptionShowPowerAlertKey: false])
                }
            } catch PartnerPlatformError.httpStatus(let status) { fail("partner-http-\(status)") }
            catch is CancellationError { return }
            catch let error as URLError { fail(error.code == .timedOut ? "partner-network-timeout" : "partner-network-unavailable") }
            catch { fail("partner-preparation-failed") }
        }
    }
    func stop() {
        onAuthenticatedCommandQueueIdle = nil
        resetObservation.cancel()
        resetObservationTimer?.invalidate(); resetObservationTimer = nil
        stopped = true; cacheDeadline?.invalidate(); preparationTask?.cancel(); preparationTask = nil; idleDeadline?.invalidate(); deadline?.invalidate(); central?.stopScan()
        writes.removeAll(); writeInProgress = false
        downloadCollector = nil
        decodingTask?.cancel(); decodingTask = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        crypto = nil; identity = nil
        let pendingWiFi = wifiOpenCompletion
        wifiActive = false; wifiOpenCompletion = nil
        pendingWiFi?(.failure(CancellationError()))
    }
    private func transition(_ value: Stage, _ message: String) {
        stage = value; onStatus?(message)
        events.append(["stage": value.rawValue, "time": Date().timeIntervalSince1970])
        deadline?.invalidate()
        // Decoding sets its own size-based deadline in decodeDownloadedAudio.
        if value != .complete && value != .downloaded && value != .decoding && value != .decoded && value != .wifiReady && value != .wifiDownload && value != .failed {
            deadline = Timer.scheduledTimer(withTimeInterval: value == .preparing ? 75 : value == .list ? max(0.1,min(12,45-Date().timeIntervalSince(listStartedAt))) : 45, repeats: false) { [weak self] _ in
                guard let self, !self.stopped else { return }
                if self.stage == .list { self.retryFileList() }
                else { self.fail("timeout-\(self.stage.rawValue)") }
            }
        }
        saveReport()
    }
    private func requestFileList() throws {
        // Every retry starts a fresh correlated snapshot; never combine pages
        // from different requests or accept a partial library as complete.
        requestID = requestID == .max ? 1 : requestID + 1
        listCollector = ProtocolFileListCollector(requestID: requestID)
        transition(.list, listRetryPolicy.retries == 0 ? "Получаем список записей…" : "Повторяем получение списка записей…")
        try send(ProtocolBootstrap.getFileList(requestID: requestID))
    }
    private func retryFileList() {
        guard Date().timeIntervalSince(listStartedAt) < 45, listRetryPolicy.takeRetry(authenticated: authenticated, connected: peripheral?.state == .connected,
              writePending: writeInProgress || !writes.isEmpty) else { fail("timeout-list"); return }
        events.append(["listRetry": listRetryPolicy.retries, "received": listCollector?.receivedCount ?? 0, "time": Date().timeIntervalSince1970])
        do { try requestFileList() } catch { fail("list-retry-failed") }
    }
    private func fail(_ reason: String) {
        guard !stopped else { return }
        events.append(["failure": reason]); transition(.failed, "Подключение остановлено: \(reason)")
        let pendingWiFi = wifiOpenCompletion; wifiOpenCompletion = nil
        saveReport(reason: reason); stop()
        pendingWiFi?(.failure(ProtocolWireError.invalidInput))
        onFailure?(reason)
    }
    private func saveReport(reason: String? = nil) {
        var value: [String: Any] = ["nativeMacOS": true, "sdkUsed": false,
            "stage": stage.rawValue, "authenticated": authenticated,
            "supportsWiFi": supportsWiFi, "wifiFeatureAnnouncementReceived": wifiFeatures.received,
            "wifiCipher": wifiFeatures.cipher == .aesGCM ? "aesGCM" : "chaChaPoly",
            "recordingCount": recordings.count, "fileDownloadVerified": downloadedRawURL != nil,
            "events": events, "recordings": recordings.map { ["sessionID": $0.sessionID, "byteSize": $0.byteSize, "scene": $0.scene, "attribute": $0.attribute] }]
        value["advertisements"] = observedAdvertisements
        value["audioChannels"] = audioChannels
        value["isOggAudio"] = isOggAudio
        if let downloadedRawURL { value["downloadedRawPath"] = downloadedRawURL.path }
        value["mp3ConversionVerified"] = downloadedMP3URL != nil
        value["playbackVerified"] = false
        if let downloadedMP3URL { value["downloadedMP3Path"] = downloadedMP3URL.path }
        if let reason { value["reason"] = reason }
        if let recorderState { value["recorderState"] = recorderState.state }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: reportURL, options: .atomic)
            if reason != nil {
                let history = reportURL.deletingLastPathComponent().appendingPathComponent("NativeSessionFailures", isDirectory: true)
                try? FileManager.default.createDirectory(at: history, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = history.appendingPathComponent(sessionReportID + ".json")
                try? data.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let old = (try? FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for file in old.filter({$0.pathExtension == "json"}).sorted(by: { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }).dropLast(20) { try? FileManager.default.removeItem(at: file) }
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !stopped else { return }
        switch central.state {
        case .poweredOn:
            guard stage == .bluetooth else { return }
            if config.useVerifiedPeripheralCache, let id = config.peripheralID,
               let target = central.retrievePeripherals(withIdentifiers: [id]).first {
                cachedConnection = true
                events.append(["connectionPath": "verified-cache"])
                connect(target)
                // Rotating recorder addresses can invalidate a cached UUID.
                // Discover concurrently so a fresh exact-serial frame wins
                // immediately rather than waiting for the cache timeout.
                central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                cacheDeadline = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
                    self?.fallbackFromCachedConnection()
                }
            } else { scanForSavedDevice() }
        case .unauthorized: fail("bluetooth-permission-denied")
        case .unsupported: fail("bluetooth-unsupported")
        case .poweredOff: fail("bluetooth-powered-off")
        default: break
        }
    }
    private func scanForSavedDevice() {
        guard !stopped else { return }
        transition(.scanning, "Ищем выбранное Bluetooth-устройство Plaud…")
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
    private func fallbackFromCachedConnection() {
        guard !stopped, cachedConnection, stage == .connecting else { return }
        cacheDeadline?.invalidate(); cachedConnection = false
        if let old = peripheral { peripheral = nil; central?.cancelPeripheralConnection(old) }
        events.append(["connectionPath": "cache-fallback-scan"])
        scanForSavedDevice()
    }
    private func connect(_ target: CBPeripheral) {
        central?.stopScan(); peripheral = target; target.delegate = self
        transition(.connecting, "Подключаем выбранное устройство Plaud…")
        central?.connect(target)
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !stopped, stage == .scanning || (stage == .connecting && cachedConnection) else { return }
        // Bounded private diagnostics distinguish no radio evidence from a
        // rejected vendor frame; they never relax target selection.
        if config.capturePrivateAdvertisements && observedAdvertisements.count < 500 {
            let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
            let decoded = manufacturer.flatMap { try? NativeAdvertisement.decodeManufacturerData($0) }
            var observation: [String: Any] = ["rssi": RSSI.intValue,
                "manufacturerBytes": manufacturer?.count ?? 0,
                "manufacturerPrefix": manufacturer.map { $0.prefix(11).map { String(format: "%02x", $0) }.joined() } ?? "",
                "connectable": (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true]
            if let decoded {
                observation["projectCode"] = decoded.projectCode
                observation["targetSerialMatches"] = decoded.serialNumber == config.serialNumber
            }
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
            let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
            let prefix = manufacturer.map { Array($0.prefix(2)) } ?? []
            let vendor = prefix.count == 2 && [UInt16(0x0046), 0x0059, 0x0131].contains(UInt16(prefix[0]) | UInt16(prefix[1]) << 8)
            let key = peripheral.identifier.uuidString + (manufacturer?.base64EncodedString() ?? "") + services.joined()
            let unique = observedAdvertisementKeys.insert(key).inserted
            observation["company"] = prefix.count == 2 ? Int(prefix[0]) | Int(prefix[1]) << 8 : -1
            if name.lowercased().contains("plaud") || name.lowercased().contains("notepin") || services.contains("1910") || vendor || decoded != nil {
                observation["name"] = name
                observation["services"] = services
                if let manufacturer { observation["manufacturerFrame"] = manufacturer.base64EncodedString() }
            }
            if unique { observedAdvertisements.append(observation); saveReport() }
        }
        // A name/Find My frame/service UUID alone never selects a recorder.
        // The normal PLAUD manufacturer frame carries the exact serial and
        // model code; only that authenticated target is allowed to connect.
        guard (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue != false,
              let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let found = try? NativeAdvertisement.decodeManufacturerData(manufacturerData),
              found.serialNumber == config.serialNumber,
              let model = PlaudModel.identify(project: found.projectCode, serial: found.serialNumber),
              model.partnerType == config.deviceType || model.rawValue == config.deviceType else { return }
        if let expected = config.advertisedProtocolVersion, let actual = found.protocolVersion, expected != actual {
            fail("protocol-advertisement-changed"); return
        }
        if cachedConnection {
            if peripheral === self.peripheral { return }
            cacheDeadline?.invalidate()
            if let old = self.peripheral { self.peripheral = nil; central.cancelPeripheralConnection(old) }
            cachedConnection = false
            events.append(["connectionPath": "fresh-advertisement-during-cache"])
        }
        connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !stopped, stage == .connecting, peripheral === self.peripheral else { central.cancelPeripheralConnection(peripheral); return }
        cacheDeadline?.invalidate()
        transition(.services, "Проверяем BLE-службы Plaud…")
        peripheral.discoverServices([CBUUID(string: "1910"), CBUUID(string: "180F")])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard !stopped, peripheral === self.peripheral else { return }
        if cachedConnection && stage == .connecting { fallbackFromCachedConnection() }
        else { fail("bluetooth-connect-failed") }
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        events.append(["disconnectCode": (error as NSError?)?.code ?? 0, "stageAtDisconnect": stage.rawValue])
        if !stopped, stage == .resetting, resetObservation.state == .delivered {
            finishFactoryReset(disconnected: true); return
        }
        if !stopped, wifiActive, wifiOpenCompletion == nil {
            events.append(["wifiExpectedBluetoothDisconnect": true]); saveReport(); return
        }
        if !stopped { fail("bluetooth-disconnected") }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !stopped else { return }
        guard error == nil, let services = peripheral.services, !services.isEmpty else { fail("service-discovery-failed"); return }
        pendingServices = services.count
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !stopped else { return }
        guard error == nil else { fail("characteristic-discovery-failed"); return }
        pendingServices -= 1
        guard pendingServices == 0 else { return }
        guard let control = peripheral.services?.first(where: { NotePinGATT.canonicalUUID($0.uuid.uuidString) == "1910" }),
              let chars = control.characteristics,
              let rx = chars.first(where: { NotePinGATT.canonicalUUID($0.uuid.uuidString) == "2BB1" && $0.properties.contains(.write) }),
              let tx = chars.first(where: { NotePinGATT.canonicalUUID($0.uuid.uuidString) == "2BB0" && !$0.properties.intersection([.notify, .indicate]).isEmpty }) else {
            fail("required-gatt-profile-absent"); return
        }
        command = rx; pendingNotifications = ["2BB0"]
        transition(.notifications, "Включаем защищённый обмен…")
        peripheral.setNotifyValue(true, for: tx)
        if let data = chars.first(where: { NotePinGATT.canonicalUUID($0.uuid.uuidString) == "B004" && !$0.properties.intersection([.notify, .indicate]).isEmpty }) {
            pendingNotifications.insert("B004"); peripheral.setNotifyValue(true, for: data)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard !stopped else { return }
        guard error == nil, characteristic.isNotifying else { fail("notification-subscription-failed"); return }
        pendingNotifications.remove(NotePinGATT.canonicalUUID(characteristic.uuid.uuidString))
        if pendingNotifications.isEmpty && stage == .notifications {
            if let profile = plaintextProfile {
                do {
                    transition(.owner, "Подтверждаем владельца Plaud…")
                    enqueue([try profile.ownerHandshake(token: config.handshakeToken!, checked: false)])
                } catch { fail("legacy-handshake-invalid") }
                return
            }
            guard let identity else { fail("partner-identity-missing"); return }
            do {
                transition(.signature, config.explicitlyConfirmedRecovery ? "Пробуем восстановить сопряжение NotePin S…" : "Проверяем подлинность диктофона…")
                let packets = config.explicitlyConfirmedRecovery
                    ? try ProtocolBootstrap.recoverySignaturePackets(identity.serialSignature, model: .notePinS,
                        protocolVersion: config.advertisedProtocolVersion!)
                    : try ProtocolBootstrap.signaturePackets(identity.serialSignature)
                enqueue(packets)
            }
            catch { fail("signature-packet-invalid") }
        }
    }
    private func enqueue(_ packets: [Data]) { writes += packets; pumpWrites() }
    private func notifyAuthenticatedCommandQueueIdle() {
        guard !stopped, authenticated, stage == .complete, !writeInProgress, writes.isEmpty else { return }
        let completion = onAuthenticatedCommandQueueIdle
        onAuthenticatedCommandQueueIdle = nil
        completion?()
    }
    private func pumpWrites() {
        if writes.isEmpty { onWiFiAvailabilityChanged?(); notifyAuthenticatedCommandQueueIdle(); return }
        guard !stopped, !writeInProgress, let peripheral, let command else { return }
        let packet = writes.removeFirst()
        events.append(["writeBytes": packet.count, "stageAtWrite": stage.rawValue])
        guard packet.count <= peripheral.maximumWriteValueLength(for: .withResponse) else { fail("packet-exceeds-gatt-mtu"); return }
        writeInProgress = true
        onWiFiAvailabilityChanged?()
        peripheral.writeValue(packet, for: command, type: .withResponse)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !stopped, peripheral === self.peripheral, characteristic === command, writeInProgress else { return }
        guard error == nil else { fail("gatt-write-failed"); return }
        events.append(["writeAcknowledged": true, "stageAtAck": stage.rawValue]); saveReport()
        writeInProgress = false
        if stage == .resetting {
            guard resetObservation.acknowledge() else { return }
            deadline?.invalidate()
            resetObservationTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
                self?.finishFactoryReset(disconnected: false)
            }
            onFactoryResetAcknowledged?()
            return
        }
        // Marker pacing is called out in ledger §2; ATT ACK does not imply
        // firmware has consumed the previous RSA/signature fragment.
        if stage == .signature || stage == .rsa {
            writeInProgress = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
                guard let self, !self.stopped else { return }; self.writeInProgress = false; self.pumpWrites()
            }
        } else { pumpWrites() }
    }
    #if VECTA_DEVELOPMENT
    func configureWiFiVerification(session: SessionMaterial, features: Data?, supportsWiFi: Bool, queued: Bool) throws {
        crypto = session; authenticated = true; protocolVersion = 20; stage = .download
        self.supportsWiFi = supportsWiFi; writeInProgress = queued
        if let features { try wifiFeatures.accept(features) }
    }
    #endif
    private func send(_ payload: Data) throws {
        if plaintextProfile != nil { enqueue([payload]); return }
        guard let crypto, sequence != .max else { throw ProtocolWireError.sequenceExhausted }
        sequence += 1
        enqueue([try crypto.sealPacket(sequence: sequence, payload: payload)])
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !stopped, error == nil, let data = characteristic.value else { if !stopped { fail("notification-read-failed") }; return }
        if crypto == nil {
            events.append(["bootstrapNotificationBytes": data.count, "characteristic": characteristic.uuid.uuidString,
                           "header": data.prefix(4).map { String(format: "%02x", $0) }.joined()]); saveReport()
        }
        // Pinned vendor's encrypted control/audio framing is established for
        // 2BB0 only. B004 is subscribed for GATT parity but never guessed to be
        // a control packet or written into an audio file.
        guard NotePinGATT.canonicalUUID(characteristic.uuid.uuidString) == "2BB0" else { return }
        do {
            if crypto == nil && plaintextProfile == nil {
                let bytes = Array(data)
                if stage == .signature, bytes.count >= 2, bytes[0] == 0x11, bytes[1] == 0xfe {
                    guard let identity else { fail("partner-identity-missing"); return }
                    transition(.rsa, "Проверяем ключ защищённого сеанса…")
                    enqueue(try ProtocolBootstrap.publicKeyPackets(identity.publicKeyPEM)); return
                }
                // The pre-handshake waiter accepts FE11 OR FE12 (ledger §4).
                // Reconnecting firmware can return its encrypted session
                // immediately; do not discard it while waiting for FE11.
                if stage == .signature || stage == .rsa, bytes.count >= 4, bytes[0] == 0x12, bytes[1] == 0xfe,
                   let encrypted = try bootstrap.accept(data), let identity {
                    crypto = try SessionMaterial.authenticate(rsaPlaintext: identity.privateKey.decryptBootstrap(encrypted))
                    transition(.owner, "Подтверждаем существующую привязку…")
                    try send(ProtocolBootstrap.ownerHandshake(token: config.handshakeToken ?? config.userID, checked: false))
                }
                return
            }
            let payload: Data
            if plaintextProfile != nil { payload = data }
            else {
                let packet = try crypto!.decodePacket(data)
                if let previous = receivedSequence, packet.sequence <= previous { return }
                receivedSequence = packet.sequence; payload = packet.payload
            }
            if Array(payload.prefix(3)) == [1, 0x8a, 0] {
                if try wifiFeatures.accept(payload) { try send(Data([1, 0x8a, 0, 0xff])) }
                onWiFiAvailabilityChanged?()
                saveReport()
                return
            }
            if stage == .wifiStopping, Array(payload.prefix(3)) == [1, 0x1e, 0] {
                guard payload.count == 3 || (payload.count == 4 && payload[3] == 0) else { throw ProtocolWireError.malformedResponse }
                downloadCollector = nil
                transition(.wifiOpening, "Включаем точку доступа PLAUD…")
                try send(Data([1, 0x0a, 0, 0])); return
            }
            if stage == .wifiOpening, Array(payload.prefix(3)) == [1, 0x0a, 0] {
                let access = try ProtocolWiFiAccessPoint(response: payload, serial: config.serialNumber)
                events.append(["wifiAccessPointHasPassword": !access.password.isEmpty, "wifiAccessPointPasswordEchoed": payload.count == 12])
                wifiFeatures.beginTransfer()
                transition(.wifiReady, "Точка доступа PLAUD готова…")
                let completion = wifiOpenCompletion; wifiOpenCompletion = nil
                completion?(.success(access)); return
            }
            if wifiActive, Array(payload.prefix(3)) == [1, 0x0d, 0] { return }
            if Array(payload.prefix(3)) == [1, 9, 0], payload.count >= 5 {
                let bytes = Array(payload)
                guard bytes[4] <= 100 else { throw ProtocolWireError.malformedResponse }
                onBattery?(Int(bytes[4]), bytes[3] == 1); return
            }
            // A recording can contain thousands of data packets. Store only
            // control metadata; never accumulate a per-packet audio log.
            if payload.first != 3 && payload.first != 2 {
                events.append(["notificationBytes": data.count, "payloadType": payload.first ?? 0,
                    "command": payload.count >= 3 && payload.first == 1 ? Int(payload[1]) | Int(payload[2]) << 8 : -1])
            }
            if stage == .owner {
                guard payload.count >= 3, payload[0] == 1, [1, 2].contains(payload[1]), payload[2] == 0 else { return }
                switch try ProtocolOwnerResponse.decode(payload) {
                case .serialNumber(let serial):
                    guard serial == config.serialNumber else { fail("recorder-serial-mismatch"); return }
                    confirmedSerial = true
                    if let profile = plaintextProfile {
                        try send(profile.ownerHandshake(token: config.handshakeToken!, checked: true))
                    } else { try send(ProtocolBootstrap.ownerConfirmation(token: config.handshakeToken ?? config.userID)) }
                case .status(let status):
                    guard !cachedConnection || confirmedSerial else { fail("cached-recorder-identity-unconfirmed"); return }
                    guard status.accepted else { fail("owner-handshake-rejected-\(status.status)"); return }
                    guard status.protocolVersion > 0,
                          (plaintextProfile == nil ? status.protocolVersion >= 20 : status.protocolVersion < 20) else {
                        fail("handshake-protocol-mismatch"); return
                    }
                    authenticated = true; protocolVersion = status.protocolVersion
                    if let expected = config.advertisedProtocolVersion, expected != protocolVersion { fail("handshake-protocol-mismatch"); return }
                    audioChannels = Int(status.audioChannels ?? 1)
                    isOggAudio = status.isOggAudio ?? false
                    supportsWiFi = status.supportsWiFi == true
                    onWiFiAvailabilityChanged?()
                    transition(.state, "Диктофон подключён. Читаем состояние…")
                    try send(ProtocolBootstrap.getState())
                    if protocolVersion >= 5 { try send(Data([1, 9, 0])) }
                }
            } else if stage == .state {
                guard Array(payload.prefix(3)) == [1, 3, 0] else { return }
                recorderState = try ProtocolRecorderState.decode(payload)
                listStartedAt = Date()
                listRetryPolicy = ProtocolListRetryPolicy()
                try requestFileList()
            } else if stage == .list {
                guard Array(payload.prefix(3)) == [1, 0x1a, 0] else { return }
                let page = try ProtocolFileListPage.decode(payload, protocolVersion: protocolVersion)
                guard page.requestID == requestID else {
                    events.append(["ignoredStaleListPage": true]); saveReport(); return
                }
                let before = listCollector?.receivedCount ?? 0
                let completed = try listCollector?.accept(page)
                events.append(["listPage": true, "total": page.total, "startIndex": page.startIndex, "entries": page.files.count, "received": listCollector?.receivedCount ?? 0, "retry": listRetryPolicy.retries])
                if completed == nil, (listCollector?.receivedCount ?? 0) > before { transition(.list, "Получаем список записей…") }
                else { saveReport() }
                if let files = completed {
                    recordings = files
                    transition(.complete, "Подключено. Записей: \(files.count)")
                    idleDeadline?.invalidate()
                    if !maintainsConnection {
                    idleDeadline = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                        guard let self, self.stage == .complete || self.stage == .decoded else { return }
                        self.stop(); self.onStatus?("Данные получены. Bluetooth-соединение освобождено.")
                    }
                    }
                    onComplete?(files)
                    notifyAuthenticatedCommandQueueIdle()
                }
            } else if stage == .download {
                guard let packet = try AudioDownloadPacket.parseTransfer(payload, protocolVersion: protocolVersion, expectedSession: downloadCollector?.session) else { return }
                guard let collector = downloadCollector else { fail("download-collector-missing"); return }
                if case .tail(_, let expectedCRC) = packet { events.append(["tailCRC": Int(expectedCRC), "computedCRC": Int(collector.computedCRC), "receivedBytes": collector.receivedByteCount, "expectedBytes": collector.expectedByteSize]) }
                if let rawURL = try collector.accept(packet) {
                    onTransferValidated?()
                    downloadedRawURL = rawURL
                    downloadCollector = nil
                    transition(.downloaded, "Файл передан и проверен: \(rawURL.lastPathComponent)")
                    decodeDownloadedAudio(rawURL)
                } else if case .data = packet {
                    lastDownloadActivity=ProcessInfo.processInfo.systemUptime
                    if lastDownloadActivity-lastTransferPublication>=0.2 {
                        lastTransferPublication=lastDownloadActivity
                        onTransferProgress?(Int(collector.receivedByteCount), Int(collector.expectedByteSize))
                        onStatus?("Передаём запись: \(collector.receivedByteCount) / \(collector.expectedByteSize) байт")
                    }
                }
            }
        } catch {
            events.append(["protocolError": String(describing: error), "notificationBytes": data.count])
            fail("invalid-protocol-response-\(stage.rawValue)")
        }
    }

    /// Starts one complete, non-resumable transfer after the authenticated
    /// session has produced its recording list.
    func download(recording: ProtocolRecordingFile, to stagingURL: URL) {
        guard !stopped, [.complete, .decoded].contains(stage), (crypto != nil || plaintextProfile != nil),
              peripheral?.state == .connected else { onFailure?("download-not-ready"); return }
        guard recordings.contains(recording) else { onFailure?("download-not-in-recording-list"); return }
        guard !FileManager.default.fileExists(atPath: stagingURL.path) else { onFailure?("download-destination-exists"); return }
        idleDeadline?.invalidate()
        do {
            downloadCollector = try AudioDownloadCollector(session: recording.sessionID,
                                                           expectedByteSize: recording.byteSize,
                                                           stagingURL: stagingURL, crcInitial: 0xffff, authenticatedPackets: crypto != nil)
            transition(.download, "Передаём запись (\(recording.byteSize) байт)…")
            // Bluetooth moves ~19 KB/s, so a fixed 300 s limit restarted every recording over ~5 MB
            // from zero forever. Fail only when the recorder stops sending data for a minute.
            deadline?.invalidate()
            lastDownloadActivity = ProcessInfo.processInfo.systemUptime
            deadline = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                guard let self, self.stage == .download else { return }
                if ProcessInfo.processInfo.systemUptime - self.lastDownloadActivity > 60 { self.fail("timeout-download") }
            }
            try send(AudioDownloadPacket.fullRequest(session: recording.sessionID, end: recording.byteSize))
        } catch { fail("download-start-failed") }
    }

    /// Preflight has no device effect. Only the confirmed UI action may request reset.
    func validateFactoryReset(confirmedSerial: String) throws {
        guard !stopped, stage == .complete, authenticated, confirmedSerial == config.serialNumber,
              config.deviceType == "notepins", protocolVersion == 20, config.serialNumber.hasPrefix("882"),
              crypto != nil, !wifiActive, peripheral?.state == .connected,
              !writeInProgress, writes.isEmpty, resetObservation.state == .ready else { throw ProtocolWireError.invalidInput }
        _ = try ProtocolFactoryReset.payload(serial: config.serialNumber, confirmedSerial: confirmedSerial,
                                             model: .notePinS, protocolVersion: protocolVersion)
    }
    func requestFactoryReset(confirmedSerial: String) throws {
        try validateFactoryReset(confirmedSerial: confirmedSerial)
        let payload = try ProtocolFactoryReset.payload(serial: config.serialNumber, confirmedSerial: confirmedSerial,
                                                       model: .notePinS, protocolVersion: protocolVersion)
        try resetObservation.request()
        idleDeadline?.invalidate()
        transition(.resetting, "Отправляем подтверждённый заводской сброс…")
        try send(payload)
    }
    private func finishFactoryReset(disconnected: Bool) {
        guard !stopped, stage == .resetting, resetObservation.finish(disconnected: disconnected) else { return }
        let completion = onFactoryResetFinished
        stop()
        completion?(disconnected)
    }

    func refreshRecordings() {
        idleDeadline?.invalidate()
        guard !stopped, [.complete, .decoded].contains(stage), (crypto != nil || plaintextProfile != nil),
              peripheral?.state == .connected else { onFailure?("refresh-not-ready"); return }
        do {
            transition(.state, "Обновляем список записей…")
            try send(ProtocolBootstrap.getState())
        } catch { fail("refresh-failed") }
    }

    func openWiFiForTransfer(completion: @escaping (Result<ProtocolWiFiAccessPoint, Error>) -> Void) {
        guard !stopped, canUseWiFi, peripheral?.state == .connected, !writeInProgress, writes.isEmpty else {
            completion(.failure(ProtocolWireError.invalidInput)); return
        }
        wifiActive = true; wifiOpenCompletion = completion
        idleDeadline?.invalidate()
        do {
            transition(.wifiStopping, "Останавливаем Bluetooth-передачу перед Fast transfer…")
            try send(Data([1, 0x1d, 0]))
        } catch { fail("wifi-stop-send-failed") }
    }
    func sealWiFiPDU(_ payload: Data) throws -> Data {
        guard !stopped, authenticated, wifiActive, let crypto, sequence != .max else { throw ProtocolWireError.invalidInput }
        sequence += 1
        return try crypto.sealWiFiPacket(sequence: sequence, payload: payload, cipher: wifiFeatures.cipher)
    }
    func openWiFiPDU(_ bytes: Data) throws -> Data {
        guard !stopped, authenticated, wifiActive, let crypto else { throw ProtocolWireError.invalidInput }
        let packet = try crypto.decodeWiFiPacket(bytes, cipher: wifiFeatures.cipher)
        // The recorder's WiFi counter starts independently of the preceding BLE stream.
        try wifiReceivedSequence.accept(packet.sequence)
        return packet.payload
    }
    func beginWiFiRecording(_ recording: ProtocolRecordingFile) throws {
        guard !stopped, authenticated, wifiActive, [.wifiReady, .decoded].contains(stage), recordings.contains(recording) else { throw ProtocolWireError.invalidInput }
        transition(.wifiDownload, "Передаём запись по Wi‑Fi…")
    }
    func finishWiFiRecording(_ rawURL: URL) throws {
        guard !stopped, wifiActive, stage == .wifiDownload else { throw ProtocolWireError.invalidInput }
        downloadedRawURL = rawURL
        onTransferValidated?()
        decodeDownloadedAudio(rawURL)
    }
    /// Best effort only; no automatic reconnect or claim of AP-close acknowledgment.
    func closeWiFiAccessPoint() {
        guard !stopped, wifiActive, peripheral?.state == .connected else { return }
        try? send(Data([1, 0x0d, 0]))
    }

    private func decodeDownloadedAudio(_ rawURL: URL) {

        transition(.decoding, "Готовим MP3…")
        // The generic 45 s stage limit discarded every recording longer than about an hour after a
        // verified Wi-Fi delivery. Allow 60 s plus 1 s per 100 KB (a 35 MB / 2.4 h file gets ~7 min).
        let rawBytes = (try? rawURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        deadline?.invalidate()
        deadline = Timer.scheduledTimer(withTimeInterval: 60 + Double(rawBytes) / 100_000, repeats: false) { [weak self] _ in
            guard let self, !self.stopped, self.stage == .decoding else { return }
            self.fail("timeout-decoding")
        }
        let privateKey = identity?.privateKey
        let defaultChannels = audioChannels
        let readsHighlights = config.deviceType == "notepins" && protocolVersion == 20
        let outputURL = rawURL.deletingPathExtension().appendingPathExtension("mp3")
        let task = Task.detached(priority: .userInitiated) {
            let input = try FileHandle(forReadingFrom: rawURL)
            let prefix = try input.read(upToCount: EncryptedAudioHeader.size) ?? Data()
            try input.close()
            let header = EncryptedAudioHeader.isEncrypted(prefix) ? try EncryptedAudioHeader(data: prefix) : nil
            let channels = header.map { Int($0.channels) } ?? defaultChannels
            let duration = header.map { Double($0.durationSeconds) }
            return try NativeAudioConverter.convert(rawURL: rawURL, outputURL: outputURL,
                channels: channels, expectedDuration: duration, privateKey: privateKey,
                recoverDamagedRecorderPackets: true, readRecorderHighlights: readsHighlights)
        }
        decodingTask = task
        Task { @MainActor [weak self] in
            do {
                let conversion = try await task.value
                guard let self, !self.stopped else { return }
                self.decodingTask = nil
                self.downloadedMP3URL = conversion.outputURL
                self.downloadedHighlightSeconds = conversion.recorderHighlightSeconds
                self.events.append(["decodedSamples": conversion.decodedSamples,
                                    "duration": conversion.duration, "sampleRate": conversion.sampleRate,
                                    "concealedPackets": conversion.concealedPackets,
                                    "concealedDuration": Double(conversion.concealedPackets) * 0.02])
                self.transition(.decoded, "Запись передана: \(conversion.outputURL.lastPathComponent)")
                self.onDownloadComplete?(conversion.outputURL)
            } catch {
                guard let self, !self.stopped else { return }
                self.events.append(["audioDecodingError": String(describing: error)])
                self.fail("native-audio-decoding-failed")
            }
        }
    }
}
