import Combine
import SwiftUI
import UIKit

enum PointerMode: String, CaseIterable, Identifiable {
    case touchpad = "Touchpad", aim = "Laser"
    var id: String { rawValue }
    var hint: String {
        switch self {
        case .touchpad: return "Drag on the pad like a laptop trackpad. Phone movement is ignored."
        case .aim: return "Like a laser pointer: the pointer goes where the phone points. Aim at the middle and tap Recenter first. Best for a fixed screen."
        }
    }
}

final class AppModel: ObservableObject {
    let link = TVLink()
    let motion = MotionPointer()
    let remote = TVRemote()
    private var subscriptions = Set<AnyCancellable>()

    @Published var mode: PointerMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "pointerMode"); applyMode() }
    }
    @Published var sensitivity: Double {
        didSet { UserDefaults.standard.set(sensitivity, forKey: "sensitivity"); motion.sensitivity = sensitivity }
    }

    init() {
        mode = PointerMode(rawValue: UserDefaults.standard.string(forKey: "pointerMode") ?? "") ?? .aim
        let s = UserDefaults.standard.double(forKey: "sensitivity")
        sensitivity = s == 0 ? 1.0 : s
        motion.sensitivity = sensitivity
        motion.onMove = { [link] dx, dy in link.move(dx: dx, dy: dy) }
        motion.onPosition = { [link] x, y in link.position(x: x, y: y) }
        applyMode()

        // Point the remote-control session at whichever TV the pointer link is using.
        link.$host.combineLatest(link.$selectedName)
            .receive(on: DispatchQueue.main)
            .sink { [remote] host, name in
                if let host, let name { remote.setHost(host, name: name) }
            }
            .store(in: &subscriptions)
        remote.$state
            .sink { [link] state in link.remoteReady = state == .ready }
            .store(in: &subscriptions)
        link.onKeyRequest = { [remote] key in remote.sendKey(key) }
    }

    /// Real remote key when paired (works in every app), accessibility action otherwise.
    func press(_ action: TVLink.Action) {
        let keys: [TVLink.Action: Int] = [.back: 4, .home: 3, .playPause: 85, .up: 19, .down: 20, .left: 21, .right: 22, .center: 23]
        if action == .rewind || action == .fastForward {
            // Media seek needs real keys; the accessibility fallback has no equivalent.
            remote.sendKey(action == .rewind ? 89 : 90)   // KEYCODE_MEDIA_REWIND / FAST_FORWARD
            return
        }
        if remote.isReady, let key = keys[action] {
            remote.sendKey(key)
        } else {
            link.action(action)
        }
    }

    func applyMode() {
        switch mode {
        case .aim: motion.mode = .aim
        case .touchpad: motion.mode = .off
        }
    }

    func start() {
        link.start()
        motion.start()
    }

    func stop() { motion.stop() }

    func recenter() {
        motion.recenter()
        link.action(.recenter)
    }

    // MARK: Pad input

    private var stepAccumulator = CGSize.zero
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    func pad(_ event: TrackpadView.Event) {
        switch event {
        case .began:
            motion.frozen = true
            stepAccumulator = .zero
            haptic.prepare()
        case .ended:
            // Brief hold-off so lifting the thumb doesn't jolt the pointer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.motion.frozen = false }
        case .move(let dx, let dy):
            // Trackpad acceleration: slow strokes are precise, quick flicks cross the screen.
            let speed = hypot(dx, dy)
            let gain = (2.7 + min(speed / 12, 1) * 4.4) * sensitivity
            if mode == .aim {
                motion.nudge(dx: Double(dx * gain), dy: Double(dy * gain))
            } else {
                link.move(dx: Float(dx * gain), dy: Float(dy * gain))
            }
        case .scroll(let dx, let dy):
            // Two-finger drags step like the D-pad, matching the scroll strips.
            step(dx, dy)
        case .tap:
            haptic.impactOccurred()
            link.tap()
        case .longPress:
            haptic.impactOccurred(intensity: 1)
            link.longPress()
        case .twoFingerTap:
            haptic.impactOccurred()
            press(.back)
        }
    }

    /// Scroll strips: drag steps the D-pad, tap selects.
    func strip(_ event: TrackpadView.Event, vertical: Bool) {
        switch event {
        case .began:
            stepAccumulator = .zero
            haptic.prepare()
            // D-pad navigation: hide the pointer so OK means "the highlighted item".
            motion.quietUntilMoved()
            link.action(.hidePointer)
        case .move(let dx, let dy), .scroll(let dx, let dy):
            step(vertical ? 0 : dx, vertical ? dy : 0)
        case .tap, .longPress:
            haptic.impactOccurred()
            press(.center)
        case .twoFingerTap:
            press(.back)
        case .ended: break
        }
    }

    private func step(_ dx: CGFloat, _ dy: CGFloat) {
        let distance: CGFloat = 32
        stepAccumulator.width += dx
        stepAccumulator.height += dy
        if abs(stepAccumulator.width) >= distance && abs(stepAccumulator.width) > abs(stepAccumulator.height) {
            press(stepAccumulator.width > 0 ? .right : .left)
            stepAccumulator = .zero
            haptic.impactOccurred()
        } else if abs(stepAccumulator.height) >= distance {
            press(stepAccumulator.height > 0 ? .down : .up)
            stepAccumulator = .zero
            haptic.impactOccurred()
        }
    }
}

struct ContentView: View {
    @StateObject private var model: AppModel
    @ObservedObject private var link: TVLink
    @ObservedObject private var remote: TVRemote
    @Environment(\.scenePhase) private var scenePhase
    @State private var showKeyboard = false
    @State private var showSettings = false
    @State private var code = ""

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        _link = ObservedObject(wrappedValue: model.link)
        _remote = ObservedObject(wrappedValue: model.remote)
    }

    var body: some View {
        GeometryReader { geo in
            // Unfolded iPhone Duo (626x890 pt, usually held sideways) or any landscape screen:
            // two-handed layout. The folded Duo (narrow cover screen) and regular phones get one column.
            if geo.size.width > 560 || geo.size.width / max(geo.size.height, 1) > 0.62 {
                wideLayout
            } else {
                tallLayout
            }
        }
        .padding()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.start()
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(model: model, remote: remote)
                .presentationDetents([.height(160)])
        }
        .sheet(isPresented: $showKeyboard) {
            KeyboardSheet(remote: remote)
                .presentationDetents([.height(240)])
        }
        .onChange(of: remote.imeActive) { _, active in
            // A text box was selected on the TV: bring up the phone keyboard.
            if active { showKeyboard = true }
        }
        .alert("Enter the code shown on the TV", isPresented: Binding(
            get: { remote.state == .awaitingCode },
            set: { _ in })) {
            TextField("6 characters", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Pair") { model.remote.submitCode(code); code = "" }
            Button("Cancel", role: .cancel) { code = "" }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.start() } else { model.stop() }
            UIApplication.shared.isIdleTimerDisabled = phase == .active
        }
    }

    private var pad: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                    VStack(spacing: 6) {
                        Image(systemName: "hand.point.up.left").font(.system(size: 34))
                        Text("Drag to move · tap to click · hold for long press\nTwo-finger tap for Back")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding()
                    .allowsHitTesting(false)
                    Trackpad { model.pad($0) }
                }
                ScrollStrip(symbol: "arrow.up.and.down", vertical: true) { model.strip($0, vertical: true) }
                    .frame(width: 58)
            }
            ScrollStrip(symbol: "arrow.left.and.right", vertical: false) { model.strip($0, vertical: false) }
                .frame(height: 58)
                .padding(.trailing, 66)
        }
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(link.connected ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Menu {
                    if link.tvs.isEmpty {
                        Text("No TVs found")
                    }
                    ForEach(link.tvs) { tv in
                        Button {
                            link.select(tv.name)
                        } label: {
                            if tv.name == link.selectedName {
                                Label(tv.displayName, systemImage: "checkmark")
                            } else {
                                Text(tv.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedDisplayName).font(.headline)
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                }
                Text(link.status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
    }

    /// Thumb-zone controls: the most used button (OK) is biggest and lowest.
    /// Media controls appear only while something is playing (or was recently paused).
    private var controls: some View {
        VStack(spacing: 8) {
            if link.mediaActive { mediaRow }
            HStack(spacing: 8) {
                RemoteButton(symbol: "chevron.backward", label: "Back") { model.press(.back) }
                RemoteButton(symbol: "house", label: "Home") { model.press(.home) }
                typeButton
            }
            HStack(spacing: 8) {
                laserButton
                recenterButton
                okButton.frame(minWidth: 160)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: link.mediaActive)
    }

    /// Regular phone (and the Duo folded): one column, buttons in the thumb zone.
    private var tallLayout: some View {
        VStack(spacing: 14) {
            header
            speedSlider
            remoteBanner
            pad
            controls
        }
    }

    /// Unfolded Duo: left thumb drives the pointer, right thumb gets every button.
    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 18) {
            // Left thumb: the pointer gets the full height.
            VStack(spacing: 12) {
                speedSlider
                pad
            }
            .frame(maxWidth: .infinity)
            // Right column: TV picker and status up top (rarely touched), buttons at the bottom.
            VStack(spacing: 10) {
                header
                remoteBanner
                sideControls
            }
            .frame(width: 260)
        }
    }

    private var laserButton: some View {
        RemoteButton(symbol: model.mode == .aim ? "light.beacon.max.fill" : "light.beacon.max",
                     label: model.mode == .aim ? "Laser on" : "Laser off",
                     highlighted: model.mode == .aim) {
            model.mode = model.mode == .aim ? .touchpad : .aim
        }
    }

    private var recenterButton: some View {
        RemoteButton(symbol: "scope", label: "Recenter") { model.recenter() }
            .disabled(model.mode != .aim)
            .opacity(model.mode == .aim ? 1 : 0.35)
    }

    private var typeButton: some View {
        RemoteButton(symbol: "keyboard", label: "Type") { showKeyboard = true }
            .disabled(!remote.isReady)
            .opacity(remote.isReady ? 1 : 0.35)
    }

    private var okButton: some View {
        // The TV decides: click under the pointer if it's showing, else the remote's OK.
        RemoteButton(symbol: "circle.circle.fill", label: "OK", prominent: true, height: 76) { model.link.action(.center) }
    }

    private var mediaRow: some View {
        HStack(spacing: 8) {
            RemoteButton(symbol: "gobackward", label: "Rewind") { model.press(.rewind) }
            RemoteButton(symbol: "playpause.fill", label: "Play/Pause", highlighted: true) { model.press(.playPause) }
            RemoteButton(symbol: "goforward", label: "Forward") { model.press(.fastForward) }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Right-hand column for the wide layout: buttons fill the height, OK is biggest and lowest.
    private var sideControls: some View {
        VStack(spacing: 10) {
            if link.mediaActive { mediaRow }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                RemoteButton(symbol: "chevron.backward", label: "Back", height: 78) { model.press(.back) }
                RemoteButton(symbol: "house", label: "Home", height: 78) { model.press(.home) }
            }
            HStack(spacing: 10) {
                typeButton
                laserButton
            }
            recenterButton
            RemoteButton(symbol: "circle.circle.fill", label: "OK", prominent: true, height: 150) { model.link.action(.center) }
        }
        .animation(.easeInOut(duration: 0.2), value: link.mediaActive)
    }

    private var speedSlider: some View {
        HStack(spacing: 10) {
            Image(systemName: "tortoise").foregroundStyle(.secondary)
            Slider(value: $model.sensitivity, in: 0.4...2.5)
            Image(systemName: "hare").foregroundStyle(.secondary)
        }
        .font(.footnote)
    }

    @ViewBuilder private var remoteBanner: some View {
        switch remote.state {
        case .needsPairing:
            Button {
                model.remote.startPairing()
            } label: {
                Label("Pair with this TV for OK and typing", systemImage: "link")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        case .failed(let message):
            HStack {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Pair again") { model.remote.startPairing() }.font(.footnote.weight(.semibold))
            }
        default:
            EmptyView()
        }
    }

    private var selectedDisplayName: String {
        link.tvs.first { $0.name == link.selectedName }?.displayName ?? "Choose TV"
    }
}

/// Narrow pad that steps the D-pad as you drag along it; tap selects.
struct ScrollStrip: View {
    let symbol: String
    let vertical: Bool
    let onEvent: (TrackpadView.Event) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(.separator)))
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            Trackpad(onEvent: onEvent)
        }
    }
}

struct SettingsSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var remote: TVRemote

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Remote control").font(.headline)
            HStack {
                Text(remoteStatus).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Pair again") { model.remote.startPairing() }
            }
        }
        .padding(24)
    }

    private var remoteStatus: String {
        switch remote.state {
        case .ready: return "Paired · real OK and typing on"
        case .connecting: return "Connecting…"
        case .needsPairing: return "Not paired with this TV"
        case .awaitingCode: return "Enter the code on the TV"
        case .failed(let m): return m
        case .idle: return "Waiting for a TV"
        }
    }
}

/// Live keyboard: whatever is typed here replaces the focused TV text field.
struct KeyboardSheet: View {
    @ObservedObject var remote: TVRemote
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    /// Set when the Delete button already sent the key for a local edit.
    @State private var suppress = false

    /// The TV inserts text at its cursor, so send only what changed: Backspaces for removed
    /// characters, then the newly typed characters.
    private func sync(from old: String, to new: String) {
        if suppress { suppress = false; return }
        let common = zip(old, new).prefix { $0 == $1 }.count
        remote.deleteBackward(old.count - common)
        remote.type(String(new.dropFirst(common)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(remote.imeActive ? "Typing on the TV" : "Select a text box on the TV, then type")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Type here", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .submitLabel(.go)
                .onSubmit {
                    remote.sendKey(66)   // KEYCODE_ENTER
                    dismiss()
                }
                .onChange(of: text) { old, new in sync(from: old, to: new) }
            HStack {
                Button {
                    remote.deleteBackward()   // also clears text that was on the TV before
                    if !text.isEmpty { suppress = true; text.removeLast() }
                } label: {
                    Label("Delete", systemImage: "delete.left")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Done") {
                    remote.sendKey(66)   // KEYCODE_ENTER
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onAppear { focused = true }
    }
}

struct RemoteButton: View {
    let symbol: String
    let label: String
    var prominent = false
    var highlighted = false
    var height: CGFloat = 64
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(prominent ? .largeTitle : .title2)
                Text(label).font(prominent ? .caption.weight(.semibold) : .caption2)
            }
            .frame(maxWidth: .infinity, minHeight: height)
            .foregroundStyle(prominent ? Color.white : (highlighted ? Color.accentColor : Color.primary))
            .background(prominent ? Color.accentColor : (highlighted ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground)),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
