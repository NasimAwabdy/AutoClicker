import Cocoa

/// Checks GitHub Releases for a newer version and performs one-click updates.
@MainActor
final class UpdateManager: ObservableObject {

    static let shared = UpdateManager()
    private static let repo = "NasimAwabdy/AutoClicker"
    private static let installedApp = "/Applications/AutoClicker.app"

    @Published private(set) var latestVersion: String? // set only when newer than current
    @Published private(set) var isUpdating = false
    @Published private(set) var updateError: String?
    @Published var dismissed = false

    let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private var downloadURL: URL?

    var updateAvailable: Bool { latestVersion != nil && !dismissed }

    /// Queries the latest GitHub release; fails silently (offline, rate limit)
    /// and simply retries on the next launch.
    func checkForUpdates() {
        Task {
            guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = json["assets"] as? [[String: Any]] ?? []
            guard Self.isNewer(latest, than: currentVersion),
                  let zip = assets.first(where: { ($0["name"] as? String) == "AutoClicker.zip" }),
                  let urlString = zip["browser_download_url"] as? String,
                  let dl = URL(string: urlString)
            else { return }
            downloadURL = dl
            latestVersion = latest
        }
    }

    /// Downloads and stages the new version, then swaps it into /Applications
    /// from a detached shell — the swap can't happen from inside the bundle
    /// being replaced — and relaunches. The old app stays untouched unless the
    /// download and extraction fully succeed.
    func installUpdate() {
        guard let downloadURL, !isUpdating else { return }
        isUpdating = true
        updateError = nil
        Task {
            do {
                let fm = FileManager.default
                let tmp = fm.temporaryDirectory
                    .appendingPathComponent("AutoClickerUpdate-\(UUID().uuidString)")
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                let (zipData, _) = try await URLSession.shared.data(from: downloadURL)
                let zipPath = tmp.appendingPathComponent("AutoClicker.zip")
                try zipData.write(to: zipPath)
                try runProcess("/usr/bin/ditto", ["-x", "-k", zipPath.path, tmp.path])
                let staged = tmp.appendingPathComponent("AutoClicker.app")
                guard fm.fileExists(atPath: staged.path) else {
                    throw NSError(domain: "Update", code: 1, userInfo:
                        [NSLocalizedDescriptionKey: "Downloaded archive did not contain AutoClicker.app"])
                }
                // Quarantine strip + Accessibility reset mirror install.sh:
                // the ad-hoc signature changes every release, so the old TCC
                // grant would silently block clicks.
                let script = """
                sleep 1
                rm -rf '\(Self.installedApp)'
                ditto '\(staged.path)' '\(Self.installedApp)'
                xattr -dr com.apple.quarantine '\(Self.installedApp)' 2>/dev/null
                tccutil reset Accessibility local.autoclicker.app >/dev/null 2>&1
                open '\(Self.installedApp)'
                rm -rf '\(tmp.path)'
                """
                let swap = Process()
                swap.executableURL = URL(fileURLWithPath: "/bin/bash")
                swap.arguments = ["-c", script]
                try swap.run()
                NSApp.terminate(nil)
            } catch {
                updateError = error.localizedDescription
                isUpdating = false
            }
        }
    }

    private func runProcess(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "Update", code: Int(p.terminationStatus), userInfo:
                [NSLocalizedDescriptionKey: "\(path) failed (exit \(p.terminationStatus))"])
        }
    }

    /// True if a is a higher version than b, comparing numeric components.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
