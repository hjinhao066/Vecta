import Foundation
import Network
import Darwin

struct NativeWiFiListenerAddress: Equatable {
    let interfaceName: String
    let address: String
    let isUp: Bool
}

func nativeWiFiListenerCanBind(address: String, interfaceName: String, localAddresses: [NativeWiFiListenerAddress]) -> Bool {
    guard let ipv4 = IPv4Address(address), !interfaceName.isEmpty else { return false }
    let bytes = Array(ipv4.rawValue)
    guard bytes[0] != 0, bytes[0] != 127, bytes[0] < 224,
          !(bytes[0] == 169 && bytes[1] == 254) else { return false }
    // Ambiguous address ownership must not allow a listener on another interface.
    let owners = localAddresses.filter { $0.isUp && $0.address == address }
    return !owners.isEmpty && owners.allSatisfy { $0.interfaceName == interfaceName }
}

private func nativeWiFiListenerLocalAddresses() -> [NativeWiFiListenerAddress] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [] }
    defer { freeifaddrs(first) }
    var result: [NativeWiFiListenerAddress] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
        let value = entry.pointee
        cursor = value.ifa_next
        guard let address = value.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &ipv4, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
        result.append(NativeWiFiListenerAddress(interfaceName: String(cString: value.ifa_name),
                                              address: String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                                              isUp: value.ifa_flags & UInt32(IFF_UP) != 0))
    }
    return result
}

/// The recorder connects to this local server. No HTTP client or remote endpoint is used.
@MainActor final class NativeWiFiSocketServer {
    enum Failure: Error { case invalidAddress, unavailableInterface, alreadyStarted, disconnected, invalidMessage, notConnected }
    private let queue = DispatchQueue(label: "app.vecta.wifi-socket")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var stopped = false
    private var ready = false
    var onReady: (() -> Void)?
    var onConnected: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?

    func start(localAddress: String, interfaceName: String) async throws {
        guard IPv4Address(localAddress) != nil, localAddress != "0.0.0.0", localAddress != "127.0.0.1" else { throw Failure.invalidAddress }
        guard listener == nil, !stopped else { throw Failure.alreadyStarted }
        // Recorder APs have no Internet route. A generic NWPathMonitor may expose
        // no available interface even after CoreWLAN association and DHCP succeeded.
        guard if_nametoindex(interfaceName) != 0,
              nativeWiFiListenerCanBind(address: localAddress, interfaceName: interfaceName,
                                        localAddresses: nativeWiFiListenerLocalAddresses()) else { throw Failure.unavailableInterface }
        try Task.checkCancellation()
        guard !stopped else { throw Failure.disconnected }
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 16 * 1024 * 1024
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.requiredInterfaceType = .wifi
        parameters.requiredLocalEndpoint = .hostPort(host: .init(localAddress), port: 8081)
        let server = try NWListener(using: parameters)
        listener = server
        server.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                switch state {
                case .ready: self.onReady?()
                case .failed(let error): self.fail(error)
                default: break
                }
            }
        }
        server.newConnectionHandler = { [weak self] client in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, self.connection == nil else { client.cancel(); return }
                self.connection = client
                client.stateUpdateHandler = { [weak self, weak client = client] state in
                    Task { @MainActor [weak self, weak client = client] in
                        guard let self, !self.stopped, client === self.connection else { return }
                        switch state {
                        case .ready:
                            self.ready = true
                            self.onConnected?()
                            self.receive()
                        case .failed(let error): self.fail(error)
                        case .cancelled: self.fail(Failure.disconnected)
                        default: break
                        }
                    }
                }
                client.start(queue: self.queue)
            }
        }
        server.start(queue: queue)
    }
    func send(_ bytes: Data, completion: @escaping (Error?) -> Void) {
        guard !stopped, ready, let connection else { completion(Failure.notConnected); return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "vecta-wifi-pdu", metadata: [metadata])
        connection.send(content: bytes, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            Task { @MainActor in completion(error) }
        })
    }
    private func receive() {
        connection?.receiveMessage { [weak self] data, context, complete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                if let error { self.fail(error); return }
                guard complete, let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else { self.fail(Failure.invalidMessage); return }
                switch metadata.opcode {
                case .binary:
                    guard let data, !data.isEmpty, data.count <= 16 * 1024 * 1024 else { self.fail(Failure.invalidMessage); return }
                    // Authenticate/write before requesting another message; bounded buffering.
                    self.onMessage?(data)
                case .close: self.fail(Failure.disconnected); return
                case .ping, .pong: break
                default: self.fail(Failure.invalidMessage); return
                }
                guard !self.stopped else { return }
                self.receive()
            }
        }
    }
    private func fail(_ error: Error) {
        guard !stopped else { return }
        stopped = true; ready = false
        connection?.cancel(); listener?.cancel()
        onFailure?(error)
    }
    func stop() {
        stopped = true; ready = false
        connection?.cancel(); listener?.cancel()
        connection = nil; listener = nil
    }
}
