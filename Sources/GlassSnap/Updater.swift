import AppKit
import Security
import SnapGeometry

/// Updates run only when the person asks: no background checks, no telemetry.
/// A downloaded release replaces this bundle only if it satisfies the running
/// app's own designated requirement (same bundle ID and certificate), which is
/// what macOS uses to keep Accessibility and Screen Recording grants.
/// A copy built from source runs that checkout's ./Scripts/update.sh instead.
@MainActor
final class Updater {
    var onStatus: ((String) -> Void)?
    private var busy = false

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    private var repository: String? { Bundle.main.object(forInfoDictionaryKey: "GlassSnapUpdateRepository") as? String }
    private var sourceDirectory: String? { Bundle.main.object(forInfoDictionaryKey: "GlassSnapSourceDirectory") as? String }
    private var releasesPage: URL? { repository.flatMap { URL(string: "https://github.com/\($0)/releases/latest") } }

    nonisolated init() {}

    /// Called from menu and Settings actions, which AppKit runs on the main thread.
    nonisolated func check() { MainActor.assumeIsolated { begin() } }

    private func begin() {
        guard !busy else { return }
        if let sourceDirectory { updateFromSource(sourceDirectory); return }
        guard let repository, let api = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            alert("Updates aren’t available for this copy", "It doesn’t say where it was published.", openReleases: false); return
        }
        busy = true; onStatus?("Checking for updates…")
        Task {
            defer { busy = false }
            do {
                let release = try await Self.latest(api)
                guard let current = ReleaseVersion(Self.version), let available = ReleaseVersion(release.tagName) else {
                    throw UpdateError("The latest release has an unrecognized version.")
                }
                guard current < available else {
                    onStatus?("GlassSnap is up to date.")
                    alert("You’re up to date", "GlassSnap \(Self.version) is the latest version.", openReleases: false); return
                }
                guard let asset = release.assets.first(where: { $0.name == "GlassSnap.zip" }) else {
                    throw UpdateError("The latest release doesn’t include GlassSnap.zip yet.")
                }
                guard confirm(available, notes: release.htmlUrl) else { onStatus?("Update postponed."); return }
                onStatus?("Downloading GlassSnap \(available)…")
                let destination = Bundle.main.bundleURL
                try await Task.detached { try await Self.install(asset.browserDownloadUrl, version: available, over: destination) }.value
                relaunch(destination)
            } catch {
                onStatus?("Update didn’t finish.")
                alert("GlassSnap couldn’t update", (error as? UpdateError)?.message ?? error.localizedDescription, openReleases: true)
            }
        }
    }

    // MARK: Release download

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browserDownloadUrl: URL }
        let tagName: String
        let htmlUrl: URL
        let assets: [Asset]
    }
    private struct UpdateError: Error { let message: String; init(_ message: String) { self.message = message } }

    private nonisolated static func latest(_ api: URL) async throws -> Release {
        var request = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw UpdateError("No release has been published yet.") }
        guard status == 200 else { throw UpdateError("GitHub responded with status \(status). Try again later.") }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Release.self, from: data)
    }

    private nonisolated static func install(_ asset: URL, version: ReleaseVersion, over destination: URL) async throws {
        let files = FileManager.default
        let parent = destination.deletingLastPathComponent()
        guard !destination.path.contains("/AppTranslocation/"), files.isWritableFile(atPath: parent.path) else {
            throw UpdateError("Move GlassSnap to your Applications folder, open it from there, then check again.")
        }
        // Stage on the destination volume so the final swap is a rename.
        let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? files.removeItem(at: work) }
        let (download, response) = try await URLSession.shared.download(from: asset)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed. Try again later.") }
        let archive = work.appendingPathComponent("GlassSnap.zip"), expanded = work.appendingPathComponent("expanded")
        try files.moveItem(at: download, to: archive)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, expanded.path]
        try ditto.run(); ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError("The downloaded archive couldn’t be opened.") }
        let candidate = expanded.appendingPathComponent("GlassSnap.app")
        guard let bundle = Bundle(url: candidate), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let found = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(ReleaseVersion.init),
              found == version else {
            throw UpdateError("The download isn’t the expected GlassSnap \(version).")
        }
        try verifySameSigner(candidate)
        _ = try files.replaceItemAt(destination, withItemAt: candidate)
    }

    /// The update must satisfy this app's own designated requirement. An
    /// ad-hoc or differently signed copy is refused rather than installed with
    /// a new identity that would reset permissions.
    private nonisolated static func verifySameSigner(_ candidate: URL) throws {
        var running: SecCode?, installed: SecStaticCode?, requirement: SecRequirement?, code: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &installed) == errSecSuccess, let installed,
              SecCodeCopyDesignatedRequirement(installed, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(candidate as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("GlassSnap couldn’t check the update’s signature.")
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateError("The update isn’t signed by the same developer as this copy, so it wasn’t installed. Your current version is unchanged.")
        }
    }

    /// Duplicate detection makes a new instance quit while this one runs, so
    /// a detached shell waits for this process to exit before reopening.
    private func relaunch(_ app: URL) {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                            "sh", String(ProcessInfo.processInfo.processIdentifier), app.path]
        do { try helper.run() } catch {
            alert("Update installed", "Open GlassSnap again to finish.", openReleases: false); return
        }
        NSApp.terminate(nil)
    }

    // MARK: Source checkouts

    private func updateFromSource(_ directory: String) {
        guard FileManager.default.isExecutableFile(atPath: directory + "/Scripts/update.sh") else {
            alert("Source folder not found", "This copy was built from a checkout that has moved. Run ./Scripts/update.sh from your clone.", openReleases: false); return
        }
        let quoted = "'" + directory.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/bash\ncd \(quoted) || exit 1\ngit pull --ff-only || echo \"Couldn’t pull; updating from the current checkout.\"\n./Scripts/update.sh\nstatus=$?\necho\nread -n 1 -s -r -p \"Press any key to close.\"\nexit $status\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("GlassSnap Update.command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            alert("GlassSnap couldn’t start the update", error.localizedDescription, openReleases: false); return
        }
        onStatus?("Updating from source in Terminal…")
        NSWorkspace.shared.open(file)
    }

    // MARK: Alerts

    private func confirm(_ version: ReleaseVersion, notes: URL) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "GlassSnap \(version) is available"
        alert.informativeText = "You have \(Self.version). GlassSnap will download the update, check that it’s signed by the same developer, then reopen. Your permissions carry over."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release Notes")
        let choice = alert.runModal()
        if choice == .alertThirdButtonReturn { NSWorkspace.shared.open(notes) }
        return choice == .alertFirstButtonReturn
    }

    private func alert(_ title: String, _ message: String, openReleases: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if openReleases, releasesPage != nil { alert.addButton(withTitle: "Open Releases Page") }
        if alert.runModal() == .alertSecondButtonReturn, let releasesPage { NSWorkspace.shared.open(releasesPage) }
    }
}
