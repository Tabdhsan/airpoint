import CryptoKit
import Foundation
import Network
import Security

/// Client for the Android TV Remote v2 protocol (the one the Google TV app uses).
///
/// Pairing (TLS, port 6467) makes the TV trust this app's client certificate. The remote
/// session (TLS, port 6466) then accepts real key presses and keyboard text. Messages on both
/// ports are protobufs prefixed by a varint length; they are encoded by hand in `PB`.
final class TVRemote: ObservableObject {
    enum State: Equatable {
        case idle                 // no TV address yet
        case connecting
        case ready
        case needsPairing
        case awaitingCode         // TV is showing a code
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// A text field is focused on the TV; `imeText` is its current contents.
    @Published private(set) var imeActive = false
    @Published private(set) var imeText = ""

    var isReady: Bool { state == .ready }

    private let queue = DispatchQueue(label: "airpoint.remote")
    private var host: NWEndpoint.Host?
    private var hostKey = ""
    private var connection: NWConnection?
    private var pairing: NWConnection?
    private var buffer = Data()
    private var pairBuffer = Data()
    private var serverCertificate: SecCertificate?
    private var sessionStarted = false
    private var pendingKeys: [Int] = []
    private var imeCounter = 0
    private var fieldCounter = 0
    private var retryWork: DispatchWorkItem?

    private static let identity: SecIdentity? = loadIdentity()

    // MARK: Public API (any thread)

    /// Points the remote at a TV. Connects if that TV was paired before.
    func setHost(_ newHost: NWEndpoint.Host, name: String) {
        queue.async { [self] in
            guard hostKey != name || host != newHost else { return }
            host = newHost
            hostKey = name
            disconnect()
            // Try a session even if this phone never paired: the TV may already trust this identity.
            connect()
        }
    }

    func sendKey(_ keyCode: Int) {
        queue.async { [self] in
            if state == .ready, let connection {
                // remote_key_inject { key_code, direction = SHORT }
                send(PB.message(10, PB.int(1, keyCode) + PB.int(2, 3)), on: connection)
            } else if Self.pairedTVs.contains(hostKey) {
                pendingKeys.append(keyCode)
                if connection == nil { connect() }
            }
        }
    }

    /// Types `text` at the TV's cursor (the TV inserts; it does not replace the field).
    func type(_ text: String) {
        guard !text.isEmpty else { return }
        queue.async { [self] in
            if case .text(let pending)? = typing.last {
                typing[typing.count - 1] = .text(pending + text)   // coalesce keystrokes
            } else {
                typing.append(.text(text))
            }
            flushTyping()
        }
    }

    /// Deletes `count` characters before the TV's cursor.
    func deleteBackward(_ count: Int = 1) {
        guard count > 0 else { return }
        queue.async { [self] in
            if case .delete(let n)? = typing.last {
                typing[typing.count - 1] = .delete(n + count)
            } else {
                typing.append(.delete(count))
            }
            flushTyping()
        }
    }

    private enum TypingItem { case text(String), delete(Int) }
    private var typing: [TypingItem] = []
    private var typingInFlight = false
    private var typingTimeout: DispatchWorkItem?

    /// Sends the next typing item. Each edit changes the TV's field counter, and edits carrying a
    /// stale counter are dropped, so wait for the TV to echo the field before sending the next one.
    private func flushTyping() {
        guard !typingInFlight, !typing.isEmpty, state == .ready, let connection else { return }
        let item = typing.removeFirst()
        switch item {
        case .text(let text):
            if imeCounter == 0 {
                // No keyboard session from the TV yet: fall back to key presses for simple characters.
                for ch in text { if let key = Self.keyCode(for: ch) { sendKeyNow(key, on: connection) } }
                flushTyping()
                return
            }
            let count = text.utf16.count
            let object = PB.int(1, count) + PB.int(2, count) + PB.string(3, text)
            let edit = PB.int(1, 1) + PB.message(2, object)
            let batch = PB.int(1, imeCounter) + PB.int(2, fieldCounter) + PB.message(3, edit)
            send(PB.message(21, batch), on: connection)
        case .delete(let n):
            for _ in 0..<n { sendKeyNow(67, on: connection) }   // KEYCODE_DEL
        }
        typingInFlight = true
        typingTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.typingInFlight = false
            self?.flushTyping()
        }
        typingTimeout = work
        queue.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// The TV echoed the field: counters are fresh, send what's queued.
    private func typingAcknowledged() {
        typingTimeout?.cancel()
        typingInFlight = false
        flushTyping()
    }

    private func sendKeyNow(_ key: Int, on conn: NWConnection) {
        send(PB.message(10, PB.int(1, key) + PB.int(2, 3)), on: conn)
    }

    private static func keyCode(for ch: Character) -> Int? {
        let s = String(ch).lowercased()
        guard let scalar = s.unicodeScalars.first, s.unicodeScalars.count == 1 else { return nil }
        switch scalar {
        case "a"..."z": return 29 + Int(scalar.value - 97)       // KEYCODE_A = 29
        case "0"..."9": return 7 + Int(scalar.value - 48)        // KEYCODE_0 = 7
        case " ": return 62
        case ".": return 56
        case ",": return 55
        case "-": return 69
        case "@": return 77
        case "/": return 76
        default: return nil
        }
    }

    func startPairing() {
        queue.async { [self] in
            guard let host, let identity = Self.identity else {
                publish(.failed(Self.identity == nil ? "Missing client identity" : "No TV address yet"))
                return
            }
            pairing?.cancel()
            pairBuffer = Data()
            let conn = NWConnection(host: host, port: 6467, using: tlsParameters(identity))
            pairing = conn
            publish(.connecting)
            conn.stateUpdateHandler = { [weak self, weak conn] st in
                guard let self, let conn, self.pairing === conn else { return }
                switch st {
                case .ready:
                    // pairing_request { service_name, client_name }
                    self.send(Self.outer(PB.message(10, PB.string(1, "atvremote") + PB.string(2, "AirPoint"))), on: conn)
                    self.receivePairing(conn)
                case .failed(let e), .waiting(let e):
                    self.publish(.failed("Pairing connection: \(e.localizedDescription)"))
                    conn.cancel()
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    /// Finishes pairing with the 6-character code shown on the TV.
    func submitCode(_ raw: String) {
        queue.async { [self] in
            let code = raw.trimmingCharacters(in: .whitespaces).uppercased()
            guard code.count == 6, let codeBytes = Data(hex: String(code.dropFirst(2))),
                  let check = UInt8(code.prefix(2), radix: 16) else {
                publish(.failed("The code is 6 characters, 0–9 and A–F"))
                return
            }
            guard let pairing, let identity = Self.identity,
                  let client = Self.rsaNumbers(of: Self.certificate(of: identity)),
                  let serverCertificate, let server = Self.rsaNumbers(of: serverCertificate) else {
                publish(.failed("Pairing session expired; try again"))
                return
            }
            var hash = SHA256()
            for part in [client.modulus, client.exponent, server.modulus, server.exponent, codeBytes] { hash.update(data: part) }
            let digest = Data(hash.finalize())
            guard digest.first == check else {
                publish(.failed("That code doesn't match; check it and try again"))
                return
            }
            send(Self.outer(PB.message(40, PB.bytes(1, digest))), on: pairing)
        }
    }

    // MARK: Remote session (on queue)

    private func connect() {
        guard let host, let identity = Self.identity else { return }
        retryWork?.cancel()
        connection?.cancel()
        buffer = Data()
        sessionStarted = false
        let conn = NWConnection(host: host, port: 6466, using: tlsParameters(identity))
        connection = conn
        publish(.connecting)
        conn.stateUpdateHandler = { [weak self, weak conn] st in
            guard let self, let conn, self.connection === conn else { return }
            switch st {
            case .ready: self.receive(conn)
            case .failed, .waiting: self.dropped(conn)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func disconnect() {
        retryWork?.cancel()
        connection?.cancel()
        connection = nil
        pairing?.cancel()
        pairing = nil
        sessionStarted = false
        pendingKeys.removeAll()
        typing.removeAll()
        typingInFlight = false
        publishIME(active: false, text: "")
    }

    private func dropped(_ conn: NWConnection) {
        conn.cancel()
        connection = nil
        let wasStarted = sessionStarted
        sessionStarted = false
        publishIME(active: false, text: "")
        if !wasStarted && !Self.pairedTVs.contains(hostKey) {
            publish(.needsPairing)
            return
        }
        // Idle disconnects are normal; reconnect quietly, and on demand when a key is pressed.
        publish(.connecting)
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retryWork = work
        queue.asyncAfter(deadline: .now() + (wasStarted ? 1 : 4), execute: work)
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak conn] data, _, complete, error in
            guard let self, let conn, self.connection === conn else { return }
            if let data { self.buffer.append(data) }
            while let message = PB.nextFrame(&self.buffer) { self.handleRemote(message, on: conn) }
            if complete || error != nil { self.dropped(conn) } else { self.receive(conn) }
        }
    }

    private func handleRemote(_ data: Data, on conn: NWConnection) {
        let m = PB.parse(data)
        let features = 1 | 2 | 4 | 32 | 64 | 512   // ping, key, IME, power, volume, app link
        if let cfg = m.message(1) {                 // remote_configure
            let tvFeatures = cfg.int(1) ?? features
            let info = PB.string(1, "iPhone") + PB.string(2, "AirPoint") + PB.int(3, 1)
                + PB.string(4, "1") + PB.string(5, "atvremote") + PB.string(6, "1.0.0")
            send(PB.message(1, PB.int(1, features & tvFeatures) + PB.message(2, info)), on: conn)
        } else if m.message(2) != nil {             // remote_set_active
            send(PB.message(2, PB.int(1, features)), on: conn)
        } else if let ping = m.message(8) {         // remote_ping_request
            send(PB.message(9, PB.int(1, ping.int(1) ?? 0)), on: conn)
        } else if m.message(40) != nil {            // remote_start
            if !sessionStarted {
                sessionStarted = true
                Self.markPaired(hostKey)
                publish(.ready)
                // Give the TV a moment before the first key, as the protocol requires.
                queue.asyncAfter(deadline: .now() + 0.5) { [self] in
                    let keys = pendingKeys
                    pendingKeys.removeAll()
                    for k in keys { send(PB.message(10, PB.int(1, k) + PB.int(2, 3)), on: conn) }
                }
            }
        } else if let inject = m.message(20) {      // remote_ime_key_inject: focused field status
            if let app = inject.message(1), let c = app.int(1), c != 0 { imeCounter = c }
            if let field = inject.message(2) {
                if let c = field.int(1), c != 0 { fieldCounter = c }
                publishIME(active: true, text: field.string(2) ?? "")
            }
            typingAcknowledged()
        } else if let show = m.message(22) {        // remote_ime_show_request
            if let field = show.message(2) {
                if let c = field.int(1) { fieldCounter = c }
                publishIME(active: true, text: field.string(2) ?? imeTextSnapshot)
            }
            typingAcknowledged()
        } else if let batch = m.message(21) {       // remote_ime_batch_edit from the TV
            // Only a fallback: after our own edits the TV echoes placeholder counters (1, 1)
            // that must not replace the real ones from remote_ime_key_inject.
            if imeCounter == 0, let c = batch.int(1), c != 0 { imeCounter = c }
            if fieldCounter == 0, let c = batch.int(2), c != 0 { fieldCounter = c }
        }
    }

    private var imeTextSnapshot = ""

    // MARK: Pairing session (on queue)

    private func receivePairing(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak conn] data, _, complete, error in
            guard let self, let conn, self.pairing === conn else { return }
            if let data { self.pairBuffer.append(data) }
            while let message = PB.nextFrame(&self.pairBuffer) { self.handlePairing(message, on: conn) }
            if complete || error != nil {
                if self.state == .awaitingCode { self.publish(.failed("The TV closed the pairing request")) }
                self.pairing = nil
            } else {
                self.receivePairing(conn)
            }
        }
    }

    private func handlePairing(_ data: Data, on conn: NWConnection) {
        let m = PB.parse(data)
        guard m.int(2) == 200 else {
            publish(.failed(m.int(2) == 402 ? "Wrong code" : "The TV refused pairing (\(m.int(2) ?? 0))"))
            conn.cancel()
            return
        }
        let encoding = PB.int(1, 3) + PB.int(2, 6)            // hexadecimal, 6 symbols
        if m.message(11) != nil {                               // pairing_request_ack → options
            send(Self.outer(PB.message(20, PB.message(1, encoding) + PB.int(3, 1))), on: conn)
        } else if m.message(20) != nil {                        // options → configuration
            send(Self.outer(PB.message(30, PB.message(1, encoding) + PB.int(2, 1))), on: conn)
        } else if m.message(31) != nil {                        // configuration_ack: code is on screen
            publish(.awaitingCode)
        } else if m.message(41) != nil {                        // secret_ack: paired
            Self.markPaired(hostKey)
            conn.cancel()
            pairing = nil
            connect()
        }
    }

    // MARK: Helpers

    private func send(_ message: Data, on conn: NWConnection) {
        conn.send(content: PB.varint(UInt64(message.count)) + message, completion: .contentProcessed { _ in })
    }

    private static func outer(_ body: Data) -> Data {
        PB.int(1, 2) + PB.int(2, 200) + body       // protocol_version = 2, status = OK
    }

    private func tlsParameters(_ identity: SecIdentity) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        if let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(options, secIdentity)
        }
        // The TV uses a self-signed certificate; trust is established by pairing, not by a CA.
        sec_protocol_options_set_verify_block(options, { [weak self] _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            if let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let leaf = chain.first {
                self?.serverCertificate = leaf
            }
            complete(true)
        }, queue)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    private func publish(_ newState: State) {
        DispatchQueue.main.async { if self.state != newState { self.state = newState } }
    }

    private func publishIME(active: Bool, text: String) {
        imeTextSnapshot = text
        DispatchQueue.main.async {
            if self.imeActive != active { self.imeActive = active }
            if self.imeText != text { self.imeText = text }
        }
    }

    // MARK: Identity and pairing records

    private static var pairedTVs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "pairedTVs") ?? [])
    }

    private static func markPaired(_ name: String) {
        var set = pairedTVs
        guard !name.isEmpty, !set.contains(name) else { return }
        set.insert(name)
        UserDefaults.standard.set(Array(set), forKey: "pairedTVs")
    }

    private static func loadIdentity() -> SecIdentity? {
        guard let url = Bundle.main.url(forResource: "identity", withExtension: "p12"),
              let data = try? Data(contentsOf: url) else { return nil }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: "airpoint"] as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else { return nil }
        return (identity as! SecIdentity)
    }

    private static func certificate(of identity: SecIdentity) -> SecCertificate? {
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        return cert
    }

    /// RSA modulus and exponent as minimal big-endian bytes (no leading zeros).
    private static func rsaNumbers(of certificate: SecCertificate?) -> (modulus: Data, exponent: Data)? {
        guard let certificate, let key = SecCertificateCopyKey(certificate),
              let der = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        // PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
        var reader = DERReader(Array(der))
        guard reader.enter(tag: 0x30), let n = reader.integer(), let e = reader.integer() else { return nil }
        return (Data(n.drop { $0 == 0 }), Data(e.drop { $0 == 0 }))
    }
}

/// Minimal DER reader for an RSA public key.
private struct DERReader {
    let bytes: [UInt8]
    var i = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    private mutating func length() -> Int? {
        guard i < bytes.count else { return nil }
        let first = Int(bytes[i]); i += 1
        if first < 0x80 { return first }
        let count = first & 0x7F
        guard count <= 4, i + count <= bytes.count else { return nil }
        var value = 0
        for _ in 0..<count { value = value << 8 | Int(bytes[i]); i += 1 }
        return value
    }

    mutating func enter(tag: UInt8) -> Bool {
        guard i < bytes.count, bytes[i] == tag else { return false }
        i += 1
        return length() != nil
    }

    mutating func integer() -> [UInt8]? {
        guard i < bytes.count, bytes[i] == 0x02 else { return nil }
        i += 1
        guard let len = length(), i + len <= bytes.count else { return nil }
        defer { i += len }
        return Array(bytes[i..<(i + len)])
    }
}

/// Hand-rolled protobuf encoding for the handful of messages the protocol needs.
enum PB {
    enum Value { case int(Int), bytes(Data) }

    static func varint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    static func int(_ field: Int, _ value: Int) -> Data {
        varint(UInt64(field << 3)) + varint(UInt64(bitPattern: Int64(value)))
    }

    static func bytes(_ field: Int, _ data: Data) -> Data {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(data.count)) + data
    }

    static func string(_ field: Int, _ s: String) -> Data { bytes(field, Data(s.utf8)) }
    static func message(_ field: Int, _ body: Data) -> Data { bytes(field, body) }

    private static func readVarint(_ d: [UInt8], _ i: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < d.count {
            let b = d[i]; i += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    /// Pops one varint-length-prefixed frame from the buffer, if complete.
    static func nextFrame(_ buffer: inout Data) -> Data? {
        let d = [UInt8](buffer)
        var i = 0
        guard let len = readVarint(d, &i), i + Int(len) <= d.count else { return nil }
        let frame = Data(d[i..<(i + Int(len))])
        buffer = Data(d[(i + Int(len))...])
        return frame
    }

    static func parse(_ data: Data) -> Fields {
        let d = [UInt8](data)
        var i = 0
        var fields: [Int: [Value]] = [:]
        while i < d.count {
            guard let key = readVarint(d, &i) else { break }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = readVarint(d, &i) else { return Fields(fields) }
                fields[field, default: []].append(.int(Int(truncatingIfNeeded: v)))
            case 2:
                guard let len = readVarint(d, &i), i + Int(len) <= d.count else { return Fields(fields) }
                fields[field, default: []].append(.bytes(Data(d[i..<(i + Int(len))])))
                i += Int(len)
            case 5: i += 4
            case 1: i += 8
            default: return Fields(fields)
            }
        }
        return Fields(fields)
    }

    struct Fields {
        let values: [Int: [Value]]
        init(_ values: [Int: [Value]]) { self.values = values }

        func int(_ field: Int) -> Int? {
            if case .int(let v)? = values[field]?.first { return v }
            return nil
        }
        func data(_ field: Int) -> Data? {
            if case .bytes(let d)? = values[field]?.first { return d }
            return nil
        }
        func string(_ field: Int) -> String? { data(field).map { String(decoding: $0, as: UTF8.self) } }
        func message(_ field: Int) -> Fields? { data(field).map { PB.parse($0) } }
    }
}

private extension Data {
    init?(hex: String) {
        var out = Data()
        var chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        while !chars.isEmpty {
            guard let b = UInt8(String(chars[0...1]), radix: 16) else { return nil }
            out.append(b)
            chars.removeFirst(2)
        }
        self = out
    }
}
