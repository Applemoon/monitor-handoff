import Foundation

/// Asks GitHub for the latest release at launch and once a day; a newer one than this build
/// shows in the menu, and installing it runs the same one-command install a user would.
final class Updates {
    private(set) var available: String?
    private var timer: Timer?

    private static let latest = URL(string: "https://api.github.com/repos/Applemoon/monitor-handoff/releases/latest")!
    private static let install = "curl -fsSL https://raw.githubusercontent.com/Applemoon/monitor-handoff/main/install.sh | bash"

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in self?.check() }
    }

    private func check() {
        URLSession.shared.dataTask(with: Updates.latest) { [weak self] data, _, _ in
            guard let data, let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = release["tag_name"] as? String else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let newer = latest.compare(current, options: .numeric) == .orderedDescending
            DispatchQueue.main.async { self?.available = newer ? latest : nil }
        }.resume()
    }

    /// The script quits this app, replaces it and starts the new one; it outlives this process.
    func installAvailable() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", Updates.install]
        try? task.run()
    }
}
