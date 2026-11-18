import Foundation
import Network

/// Finds AirPoint TVs on the local network and sends them pointer packets over UDP.
/// Network work happens on `queue`; published state is updated on the main thread.
final class TVLink: ObservableObject {
    struct TV: Identifiable, Hashable {
        let name: String          // Bonjour instance name, e.g. "AirPoint Living Room TV"
        let endpoint: NWEndpoint
        var id: String { name }
        var displayName: String { name.hasPrefix("AirPoint ") ? String(name.dropFirst(9)) : name }
    }

    enum PacketType: UInt8 { case move = 1, tap = 2, longPress = 3, scroll = 4, action = 5, hello = 6, position = 7 }
    enum Action: UInt8 {
        case back = 1, home = 2, playPause = 3
        case up = 10, down = 11, left = 12, right = 13, center = 14
        case recenter = 20, hidePointer = 21
        case rewind = 200, fastForward = 201   // phone-only: sent as real remote keys
    }

    @Published private(set) var tvs: [TV] = []
    @Published private(set) var selectedName: String?
    @Published private(set) var connected = false
    @Published private(set) var status = "Searching for TVs…"
    /// Resolved address of the connected TV (used for the remote-control protocol).
    @Published private(set) var host: NWEndpoint.Host?
    /// Media is playing on the TV, or was within the last couple of minutes (so pausing keeps the controls).
    @Published private(set) var mediaActive = false
    private var lastPlaying = Date.distantPast

    /// Set from the main thread: whether a paired remote session is ready (advertised in HELLO).
    var remoteReady = false
    /// Called on the main thread when the TV asks for a real remote key.
    var onKeyRequest: ((Int) -> Void)?
    private var lastKeyRequestId: UInt32?

    private let queue = DispatchQueue(label: "airpoint.link")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var connectedName: String?
    private var knownTVs: [TV] = []          // queue-owned copy of `tvs`
    private var lastAttempt = Date.distantPast
    private var lastReply = Date.distantPast
    private var helloTimer: DispatchSourceTimer?
    private let session = UInt32.random(in: 1...UInt32.max)
    private var sequence: UInt32 = 0
    private static let lastTVKey = "lastTV"

    func start() {
        queue.async { [self] in
            guard browser == nil else { return }
            let browser = NWBrowser(for: .bonjour(type: "_airpoint._udp", domain: nil), using: .udp)
            self.browser = browser
            browser.browseResultsChangedHandler = { [weak self] results, _ in self?.updateResults(results) }
            browser.stateUpdateHandler = { [weak self] state in
                switch state {
                case .waiting(let error), .failed(let error):
                    self?.publish(status: "Local network access needed: \(error.localizedDescription)")
                default: break
                }
            }
            browser.start(queue: queue)

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0)
            timer.setEventHandler { [weak self] in self?.heartbeat() }
            timer.resume()
            helloTimer = timer
        }
    }

    func select(_ name: String) {
        UserDefaults.standard.set(name, forKey: Self.lastTVKey)
        queue.async { [self] in
            DispatchQueue.main.async { self.selectedName = name }
            connect(to: name)
        }
    }

    // MARK: Sending

    func move(dx: Float, dy: Float) { send(.move, floats: (dx, dy)) }
    func position(x: Float, y: Float) { send(.position, floats: (x, y)) }
    func scroll(dx: Float, dy: Float) { send(.scroll, floats: (dx, dy)) }
    func tap() { send(.tap, repeats: 3) }
    func longPress() { send(.longPress, repeats: 3) }
    func action(_ action: Action) { send(.action, byte: action.rawValue, repeats: 3) }

    private func send(_ type: PacketType, floats: (Float, Float)? = nil, byte: UInt8? = nil, repeats: Int = 1) {
        queue.async { [self] in
            guard let connection else { return }
            sequence &+= 1
            var data = Data([0x41, 0x50, 1, type.rawValue])
            data.appendLE(session)
            data.appendLE(sequence)
            if let floats {
                data.appendLE(floats.0.bitPattern)
                data.appendLE(floats.1.bitPattern)
            }
            if let byte { data.append(byte) }
            for i in 0..<repeats {
                queue.asyncAfter(deadline: .now() + .milliseconds(20 * i)) {
                    connection.send(content: data, completion: .idempotent)
                }
            }
        }
    }

    // MARK: Discovery and connection (on queue)

    private func updateResults(_ results: Set<NWBrowser.Result>) {
        var found: [TV] = []
        for result in results {
            if case let .service(name, _, _, _) = result.endpoint {
                found.append(TV(name: name, endpoint: result.endpoint))
            }
        }
        found.sort { $0.name < $1.name }
        knownTVs = found
        DispatchQueue.main.async { self.tvs = found }

        if connectedName == nil {
            let remembered = UserDefaults.standard.string(forKey: Self.lastTVKey)
            if let tv = found.first(where: { $0.name == remembered }) ?? (found.count == 1 ? found.first : nil) {
                DispatchQueue.main.async { self.selectedName = tv.name }
                connect(to: tv.name)
            } else if found.isEmpty {
                publish(status: "Searching for TVs…")
            } else {
                publish(status: "Choose a TV")
            }
        }
    }

    private func connect(to name: String) {
        guard let tv = knownTVs.first(where: { $0.name == name }) else { return }
        lastAttempt = Date()
        connection?.cancel()
        if connectedFlag {
            connectedFlag = false
            DispatchQueue.main.async { self.connected = false }
        }
        let connection = NWConnection(to: tv.endpoint, using: .udp)
        self.connection = connection
        connectedName = name
        lastReply = .distantPast
        publish(status: "Connecting to \(tv.displayName)…")
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            if case .ready = state {
                self.receive(on: connection)
                self.heartbeat()
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, self.connection === connection else { return }
            if let data, data.count >= 10, data[data.startIndex] == 0x41, data[data.startIndex + 3] == 0x81 {
                let b = [UInt8](data)
                let key = Int(b[4]) | Int(b[5]) << 8
                let id = UInt32(b[6]) | UInt32(b[7]) << 8 | UInt32(b[8]) << 16 | UInt32(b[9]) << 24
                if id != self.lastKeyRequestId {
                    self.lastKeyRequestId = id
                    DispatchQueue.main.async { self.onKeyRequest?(key) }
                }
            } else if let data, data.count >= 8, data[data.startIndex] == 0x41, data[data.startIndex + 3] == 0x80 {
                self.lastReply = Date()
                let playing = data.count >= 9 && data[data.startIndex + 8] & 1 != 0
                if playing { self.lastPlaying = Date() }
                let media = Date().timeIntervalSince(self.lastPlaying) < 120
                DispatchQueue.main.async { if self.mediaActive != media { self.mediaActive = media } }
                let name = String(decoding: data.dropFirst(9), as: UTF8.self)
                if !self.connectedFlag {
                    self.connectedFlag = true
                    let resolved: NWEndpoint.Host?
                    if case .hostPort(let h, _)? = connection.currentPath?.remoteEndpoint { resolved = h } else { resolved = nil }
                    DispatchQueue.main.async {
                        self.connected = true
                        if let resolved { self.host = resolved }
                    }
                }
                self.publish(status: "Connected to \(name)")
            }
            if error == nil { self.receive(on: connection) }
        }
    }

    private var connectedFlag = false

    private func heartbeat() {
        guard connection != nil else { return }
        let flags: UInt8 = remoteReady ? 1 : 0
        send(.hello, byte: flags)
        let silence = Date().timeIntervalSince(lastReply)
        if silence > 3, connectedFlag {
            connectedFlag = false
            DispatchQueue.main.async { self.connected = false }
            publish(status: "Lost the TV · retrying…")
        }
        // The TV may have changed address; rebuild the connection from the latest Bonjour result.
        if silence > 6, Date().timeIntervalSince(lastAttempt) > 6, let name = connectedName {
            connect(to: name)
        }
    }

    private func publish(status: String) {
        DispatchQueue.main.async { if self.status != status { self.status = status } }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
