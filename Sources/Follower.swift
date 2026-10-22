import AppKit

/// What the menu shows.
struct Snapshot {
    var model: String?
    var inputs: [UInt8] = []
    var pictureModes: PictureModes?
    var own: UInt8?
    var detectedOwn: UInt8?
    var current: UInt8?
    var handedOver = false
    var notResponding = false
    var severalMonitors = false
}

/// Follows the monitor's input: when it switches away from this Mac, the display leaves
/// macOS; when it switches back, the display returns. The monitor keeps every input alive,
/// so macOS alone would keep drawing on a screen nobody sees. All DDC traffic and state
/// live on one queue.
final class Follower {
    var onChange: ((Snapshot) -> Void)?

    private static let interval = 2.0
    // A switch from the menu takes the monitor a moment, and its old input read meanwhile must not undo it.
    private static let settle = 4.0
    private static let failuresBeforeWarning = 3
    // Match Built-in Display copies the built-in screen only this soon after the last input.
    private static let activeWindow = 30.0

    private let queue = DispatchQueue(label: "monitor-handoff.follower")
    private let ddc = DDC()
    private let defaults = UserDefaults.standard
    private var timer: DispatchSourceTimer?
    private var capabilities: Capabilities?
    private var capabilitiesRead = false
    private var identity: (vendor: UInt32, product: UInt32)?
    private var current: UInt8?
    private var failures = 0
    private var screensAsleep = false
    private var settleUntil = Date.distantPast
    private var severalMonitors = false

    /// The display removed from macOS. Kept across launches: a removed display is in no list.
    private var removed: CGDirectDisplayID? {
        get {
            let id = defaults.integer(forKey: "removedDisplay")
            return id == 0 ? nil : CGDirectDisplayID(id)
        }
        set { defaults.set(newValue.map(Int.init) ?? 0, forKey: "removedDisplay") }
    }

    /// Kept, as the framebuffer may not report it while the display is removed.
    private var downstream: String? {
        get { defaults.string(forKey: "downstream") }
        set { defaults.set(newValue, forKey: "downstream") }
    }

    private var own: UInt8? {
        Inputs.own(among: capabilities?.inputs ?? [], downstream: downstream)
    }

    /// The monitor's display while macOS has it: matched by EDID, so an iPad or another
    /// monitor is never touched.
    private var display: CGDirectDisplayID? {
        identity.flatMap { Displays.find(vendor: $0.vendor, product: $0.product) }
    }

    func start() {
        if let cached = defaults.string(forKey: "capabilities") { capabilities = Capabilities(cached) }
        let center = NSWorkspace.shared.notificationCenter
        // A sleeping monitor does not answer; that is no reason to warn.
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.screensAsleep = true }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async {
                self?.screensAsleep = false
                self?.failures = 0
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.leave(sleeping: false) }
        }
        // Synchronous: the write has to reach the monitor before the Mac is asleep.
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.sync { self?.leave(sleeping: true) }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Follower.interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func select(_ input: UInt8) {
        queue.async { [self] in switchInput(to: input) }
    }

    private func switchInput(to input: UInt8) {
        guard ddc.write(0x60, UInt16(input)) else { return publish() }
        current = input
        settleUntil = Date() + Follower.settle
        follow(input)
        publish()
    }

    /// This Mac locked or is going to sleep: a monitor showing it goes to the input picked in
    /// Configure. Going to sleep, only the input is switched: the display leaves on the first tick
    /// after wake.
    private func leave(sleeping: Bool) {
        let target = UInt8(clamping: defaults.integer(forKey: "onLockInput"))
        guard target != 0, let own, current == own, target != own else { return }
        if sleeping {
            if ddc.write(0x60, UInt16(target)) { current = target }
        } else {
            switchInput(to: target)
        }
    }

    /// The monitor's brightness, read when the menu opens rather than on every tick.
    func readBrightness(_ completion: @escaping (_ value: Int, _ max: Int) -> Void) {
        queue.async { [self] in
            guard let brightness = ddc.read(0x10), brightness.max > 0 else { return }
            brightnessMax = Int(brightness.max)
            DispatchQueue.main.async { completion(Int(brightness.current), Int(brightness.max)) }
        }
    }

    /// The VCP values that tell which picture modes are on, read when the menu opens.
    func readPictureModes(_ codes: [UInt8], _ completion: @escaping ([UInt8: UInt16]) -> Void) {
        queue.async { [self] in
            var values: [UInt8: UInt16] = [:]
            for code in codes {
                // Dell reports the preset in E2 with something else in the high byte, like the input.
                if let value = ddc.read(code) { values[code] = value.current & 0xFF }
            }
            DispatchQueue.main.async { completion(values) }
        }
    }

    func setPictureMode(_ mode: PictureMode) {
        queue.async { [self] in _ = ddc.write(mode.set.code, mode.set.value) }
    }

    private var brightnessMax = 100
    private var lastMatchedBrightness: Int?

    /// Match Built-in Display: the monitor takes the built-in screen's brightness, which macOS sets
    /// by the light sensor. Not real auto-brightness: the sensor is silent while the built-in
    /// screen sleeps, so with the lid closed or the screen asleep the monitor keeps its last value.
    private func followBuiltinBrightness() {
        guard defaults.bool(forKey: "matchBuiltin"), let builtin = Displays.builtinBrightness() else { return }
        // An idle Mac dims its screen before it sleeps; copied, that dim would stick to the monitor
        // until the Mac wakes. A minute without input goes before any dimming.
        let anyInput = CGEventType(rawValue: ~0)!
        guard CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) < Follower.activeWindow else { return }
        let target = min(Int((builtin * Double(brightnessMax)).rounded()), brightnessMax)
        // Small steps are skipped: the sensor drifts, and each write is a DDC round.
        if let last = lastMatchedBrightness, abs(last - target) < 2 { return }
        if ddc.write(0x10, UInt16(target)) { lastMatchedBrightness = target }
    }

    // A dragged slider sends values faster than the monitor takes them: only the latest is written.
    private let brightnessLock = NSLock()
    private var pendingBrightness: Int?

    func setBrightness(_ value: Int) {
        brightnessLock.lock()
        let flushQueued = pendingBrightness != nil
        pendingBrightness = value
        brightnessLock.unlock()
        guard !flushQueued else { return }
        queue.async { [self] in
            brightnessLock.lock()
            let latest = pendingBrightness
            pendingBrightness = nil
            brightnessLock.unlock()
            guard let latest else { return }
            _ = ddc.write(0x10, UInt16(latest))
            usleep(50_000) // the monitor drops a write that follows the last one too closely
        }
    }

    /// A display removed with no app left to bring it back would stay dark until logout.
    func restore() {
        queue.sync {
            if let id = removed, Displays.setEnabled(id, true) { removed = nil }
        }
    }

    private func tick() {
        guard !screensAsleep else { return }
        // With two monitors, which channel answers and whose link type is read are guesses that
        // could remove the monitor showing this Mac: stand aside, with a removed display put back.
        severalMonitors = DDC.externalCount() > 1
        if severalMonitors {
            if let id = removed, Displays.setEnabled(id, true) { removed = nil }
            return publish()
        }
        // Once per launch: the cached string covers the time until the monitor answers.
        if !capabilitiesRead, let string = ddc.capabilities() {
            capabilities = Capabilities(string)
            defaults.set(string, forKey: "capabilities")
            capabilitiesRead = true
        }
        if identity == nil { identity = ddc.identity() }
        if let link = DDC.downstream() { downstream = link }
        followBuiltinBrightness()
        guard let value = ddc.read(0x60) else {
            failures += 1
            return publish()
        }
        failures = 0
        // The low byte is the input: Dell puts something else into the high one.
        let input = UInt8(value.current & 0xFF)
        if Date() >= settleUntil {
            current = input
            follow(input)
        }
        publish()
    }

    /// Puts macOS in line with the monitor: the display stays only while it shows this Mac.
    private func follow(_ input: UInt8) {
        guard let own else { return }
        if input == own {
            guard let id = removed else { return }
            // A failure means the id is stale: the cable was reconnected and the display is back under a new one.
            _ = Displays.setEnabled(id, true)
            removed = nil
        } else if let id = display {
            // Without another screen the Mac would be left with none: the lid is closed.
            guard Displays.active().contains(where: { $0 != id }) else { return }
            if Displays.setEnabled(id, false) { removed = id }
        }
    }

    private func publish() {
        let inputs = capabilities?.inputs ?? []
        let snapshot = Snapshot(
            model: capabilities?.model,
            inputs: inputs,
            pictureModes: capabilities.flatMap(PictureModes.init),
            own: own,
            detectedOwn: Inputs.detectedOwn(among: inputs, downstream: downstream),
            current: current,
            handedOver: removed != nil,
            // Only a monitor showing this Mac must answer; a handed-over one may be asleep.
            notResponding: failures >= Follower.failuresBeforeWarning && display != nil,
            severalMonitors: severalMonitors)
        DispatchQueue.main.async { self.onChange?(snapshot) }
    }
}
