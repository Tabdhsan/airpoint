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
    let fx = SkinFX()
    private var subscriptions = Set<AnyCancellable>()

    @Published var theme: ThemeID {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") }
    }

    @Published var mode: PointerMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "pointerMode"); applyMode() }
    }
    @Published var sensitivity: Double {
        didSet { UserDefaults.standard.set(sensitivity, forKey: "sensitivity"); motion.sensitivity = sensitivity }
    }

    init() {
        mode = PointerMode(rawValue: UserDefaults.standard.string(forKey: "pointerMode") ?? "") ?? .aim
        theme = ThemeID(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .toy
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
        link.$connected.removeDuplicates()
            .sink { [fx] on in fx.emit(.connected(on)) }
            .store(in: &subscriptions)
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
            fx.emit(.padDown)
        case .ended:
            fx.emit(.padUp)
            // Brief hold-off so lifting the thumb doesn't jolt the pointer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.motion.frozen = false }
        case .move(let dx, let dy):
            // Trackpad acceleration: slow strokes are precise, quick flicks cross the screen.
            fx.emit(.move(dx: dx, dy: dy))
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
            fx.emit(.click)
            link.tap()
        case .longPress:
            haptic.impactOccurred(intensity: 1)
            fx.emit(.longPress)
            link.longPress()
        case .twoFingerTap:
            haptic.impactOccurred()
            fx.emit(.button(id: "back"))
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
            fx.emit(.click)
            press(.center)
        case .twoFingerTap:
            fx.emit(.button(id: "back"))
            press(.back)
        case .ended:
            fx.emit(.stripUp)
        }
    }

    private func step(_ dx: CGFloat, _ dy: CGFloat) {
        let distance: CGFloat = 32
        stepAccumulator.width += dx
        stepAccumulator.height += dy
        if abs(stepAccumulator.width) >= distance && abs(stepAccumulator.width) > abs(stepAccumulator.height) {
            fx.emit(.step(dx: stepAccumulator.width > 0 ? 1 : -1, dy: 0))
            press(stepAccumulator.width > 0 ? .right : .left)
            stepAccumulator = .zero
            haptic.impactOccurred()
        } else if abs(stepAccumulator.height) >= distance {
            fx.emit(.step(dx: 0, dy: stepAccumulator.height > 0 ? 1 : -1))
            press(stepAccumulator.height > 0 ? .down : .up)
            stepAccumulator = .zero
            haptic.impactOccurred()
        }
    }
}

private struct SkinKey: EnvironmentKey { static let defaultValue: any RemoteSkin = PlainSkin() }
extension EnvironmentValues {
    var skin: any RemoteSkin {
        get { self[SkinKey.self] }
        set { self[SkinKey.self] = newValue }
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
    @State private var padState = PadState()
    @State private var vStrip = StripState()
    @State private var hStrip = StripState()

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        _link = ObservedObject(wrappedValue: model.link)
        _remote = ObservedObject(wrappedValue: model.remote)
    }

    private var skin: any RemoteSkin { model.theme.skin }

    var body: some View {
        ZStack {
            skin.backdrop().ignoresSafeArea()
            ZStack {
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
                skin.effects()
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }
            .modifier(BarrelRoll())
        }
        .id(model.theme)   // fresh skin state (easter eggs, animations) when switching themes
        .environment(\.skin, skin)
        .environmentObject(model.fx)
        .tint(skin.tint)
        .preferredColorScheme(skin.colorScheme)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.start()
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(model: model, remote: remote)
                .presentationDetents([.medium])
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

    // MARK: Pad and strips

    private var pad: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack {
                        skin.pad(padState)
                        Trackpad(onEvent: { event in
                            trackPadState(event)
                            model.pad(event)
                        }, onLocation: { point in
                            padState.location = point
                        })
                    }
                    .onAppear { padState.size = geo.size }
                    .onChange(of: geo.size) { _, size in padState.size = size }
                }
                strip(vertical: true)
                    .frame(width: 58)
            }
            strip(vertical: false)
                .frame(height: 58)
                .padding(.trailing, 66)
        }
    }

    private func trackPadState(_ event: TrackpadView.Event) {
        switch event {
        case .began:
            padState.touching = true
            padState.holdProgress = 0
            withAnimation(.linear(duration: 0.55)) { padState.holdProgress = 1 }
        case .move, .scroll:
            if padState.holdProgress != 0 {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { padState.holdProgress = 0 }
            }
        case .ended:
            padState.touching = false
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { padState.holdProgress = 0 }
        default: break
        }
    }

    private func strip(vertical: Bool) -> some View {
        ZStack {
            skin.strip(vertical: vertical, vertical ? vStrip : hStrip)
            Trackpad { event in
                switch event {
                case .began: if vertical { vStrip.touching = true } else { hStrip.touching = true }
                case .ended: if vertical { vStrip.touching = false } else { hStrip.touching = false }
                case .move(let dx, let dy), .scroll(let dx, let dy):
                    if vertical { vStrip.travel += dy } else { hStrip.travel += dx }
                default: break
                }
                model.strip(event, vertical: vertical)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            skin.statusDot(connected: link.connected)
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
                        Text(selectedDisplayName).font(skin.titleFont).lineLimit(1).minimumScaleFactor(0.7)
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                    .foregroundStyle(skin.ink)
                }
                skin.subtitle(status: link.status)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                Haptics.tap(.light)
                model.fx.emit(.button(id: "gear"))
                showSettings = true
            } label: { EmptyView() }
            .buttonStyle(GearStyle(skin: skin))
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(skin.headerPanel())
    }

    // MARK: Buttons

    private func button(_ id: String, _ symbol: String, _ label: String, role: SkinButtonRole = .normal,
                        height: CGFloat = 64, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        ThemedButton(spec: SkinButton(id: id, symbol: symbol, label: label, role: role, enabled: enabled, height: height),
                     action: action)
    }

    /// Thumb-zone controls: the most used button (OK) is biggest and lowest.
    /// Media controls appear only while something is playing (or was recently paused).
    private var controls: some View {
        VStack(spacing: 8) {
            if link.mediaActive { mediaRow }
            HStack(spacing: 8) {
                button("back", "chevron.backward", "Back") { model.press(.back) }
                button("home", "house", "Home") { model.press(.home) }
                typeButton()
            }
            HStack(spacing: 8) {
                laserButton()
                recenterButton()
                okButton(height: 76).frame(minWidth: 160)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: link.mediaActive)
    }

    /// Regular phone (and the Duo folded): one column, buttons in the thumb zone.
    private var tallLayout: some View {
        VStack(spacing: 14) {
            header
            speedControl
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
                speedControl
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

    private func laserButton(height: CGFloat = 64) -> some View {
        button("laser", model.mode == .aim ? "light.beacon.max.fill" : "light.beacon.max",
               model.mode == .aim ? "Laser on" : "Laser off", role: .toggle(on: model.mode == .aim), height: height) {
            model.mode = model.mode == .aim ? .touchpad : .aim
        }
    }

    private func recenterButton(height: CGFloat = 64) -> some View {
        button("recenter", "scope", "Recenter", height: height, enabled: model.mode == .aim) { model.recenter() }
    }

    private func typeButton(height: CGFloat = 64) -> some View {
        button("type", "keyboard", "Type", height: height, enabled: remote.isReady) { showKeyboard = true }
    }

    private func okButton(height: CGFloat) -> some View {
        // The TV decides: click under the pointer if it's showing, else the remote's OK.
        button("ok", "circle.circle.fill", "OK", role: .ok, height: height) {
            model.fx.emit(.click)
            model.link.action(.center)
        }
    }

    private var mediaRow: some View {
        HStack(spacing: 8) {
            button("rewind", "gobackward", "Rewind", role: .media) { model.press(.rewind) }
            button("playpause", "playpause.fill", "Play/Pause", role: .media) { model.press(.playPause) }
            button("forward", "goforward", "Forward", role: .media) { model.press(.fastForward) }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Right-hand column for the wide layout: buttons fill the height, OK is biggest and lowest.
    private var sideControls: some View {
        VStack(spacing: 10) {
            if link.mediaActive { mediaRow }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                button("back", "chevron.backward", "Back", height: 78) { model.press(.back) }
                button("home", "house", "Home", height: 78) { model.press(.home) }
            }
            HStack(spacing: 10) {
                typeButton()
                laserButton()
            }
            recenterButton()
            okButton(height: 150)
        }
        .animation(.easeInOut(duration: 0.2), value: link.mediaActive)
    }

    private var speedControl: some View {
        skin.speedControl(value: $model.sensitivity, range: 0.4...2.5)
    }

    @ViewBuilder private var remoteBanner: some View {
        switch remote.state {
        case .needsPairing:
            Button {
                model.remote.startPairing()
            } label: {
                Label("Pair with this TV for OK and typing", systemImage: "link")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(skin.ink)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(skin.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        case .failed(let message):
            HStack {
                Text(message).font(.footnote).foregroundStyle(skin.inkSecondary)
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

/// A remote button whose face comes from the current skin.
struct ThemedButton: View {
    let spec: SkinButton
    let action: () -> Void
    @Environment(\.skin) private var skin
    @EnvironmentObject private var fx: SkinFX

    var body: some View {
        Button {
            Haptics.tap(spec.role == .ok ? .rigid : .medium)
            fx.emit(.button(id: spec.id))
            action()
        } label: { EmptyView() }
        .buttonStyle(SkinButtonStyle(skin: skin, spec: spec))
        .disabled(!spec.enabled)
        .accessibilityLabel(spec.label)
    }
}

struct GearStyle: ButtonStyle {
    let skin: any RemoteSkin
    func makeBody(configuration: Configuration) -> some View {
        skin.gear(pressed: configuration.isPressed).contentShape(Rectangle())
    }
}

struct SettingsSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var remote: TVRemote

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Theme").font(.headline)
            VStack(spacing: 8) {
                ForEach(ThemeID.allCases) { theme in
                    Button {
                        Haptics.tick()
                        withAnimation(.easeInOut(duration: 0.25)) { model.theme = theme }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: model.theme == theme ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.theme == theme ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(theme.title).font(.body.weight(.semibold))
                                Text(theme.blurb).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Remote control").font(.headline)
            HStack {
                Text(remoteStatus).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Pair again") { model.remote.startPairing() }
            }
            Spacer(minLength: 0)
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
