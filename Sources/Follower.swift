import AppKit

/// What the menu shows.
struct Snapshot {
    var model: String?
    var inputs: [UInt8] = []
    var own: UInt8?
    var detectedOwn: UInt8?
    var current: UInt8?
    var handedOver = false
    var notResponding = false
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
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Follower.interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func select(_ input: UInt8) {
        queue.async { [self] in
            guard ddc.write(0x60, UInt16(input)) else { return publish() }
            current = input
            settleUntil = Date() + Follower.settle
            follow(input)
            publish()
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
        // Once per launch: the cached string covers the time until the monitor answers.
        if !capabilitiesRead, let string = ddc.capabilities() {
            capabilities = Capabilities(string)
            defaults.set(string, forKey: "capabilities")
            capabilitiesRead = true
        }
        if identity == nil { identity = ddc.identity() }
        if let link = DDC.downstream() { downstream = link }
        guard let value = ddc.read(0x60) else {
            failures += 1
            return publish()
        }
        failures = 0
        // The low byte is the input: Dell puts something else into the high one.
        let input = UInt8(value & 0xFF)
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
            own: own,
            detectedOwn: Inputs.detectedOwn(among: inputs, downstream: downstream),
            current: current,
            handedOver: removed != nil,
            // Only a monitor showing this Mac must answer; a handed-over one may be asleep.
            notResponding: failures >= Follower.failuresBeforeWarning && display != nil)
        DispatchQueue.main.async { self.onChange?(snapshot) }
    }
}
