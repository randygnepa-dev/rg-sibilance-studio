from pathlib import Path

p = Path('Sources/RGSibilanceStudio.swift')
s = p.read_text()
s = s.replace('let RGVersion = "0.2.28"', 'let RGVersion = "0.2.29"', 1)
start = s.index('final class UpdateManager {')
end = s.index('\nfinal class AudioDropView:', start)
new = r'''final class UpdateManager {
    private var timer: Timer?
    private var busy = false
    var onStatus: ((String) -> Void)?

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.check() }
    }

    func forceRefresh() { check(force: true) }

    private func versionParts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } }
    private func newer(_ a: String, than b: String) -> Bool {
        let x = versionParts(a), y = versionParts(b), n = max(x.count, y.count)
        for i in 0..<n {
            let xv = i < x.count ? x[i] : 0, yv = i < y.count ? y[i] : 0
            if xv != yv { return xv > yv }
        }
        return false
    }

    private func check(force: Bool = false) {
        guard !busy, let url = URL(string: "\(RGRepoRaw)/dist/VERSION?t=\(Date().timeIntervalSince1970)") else { return }
        if force { DispatchQueue.main.async { self.onStatus?("REFRESH — checking prebuilt update…") } }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let remote = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty else {
                if force { DispatchQueue.main.async { self?.onStatus?("REFRESH FAILED — update channel unavailable") } }
                return
            }
            guard self.newer(remote, than: RGVersion) || force else { return }
            self.busy = true
            DispatchQueue.main.async { self.onStatus?("UPDATE \(remote) — downloading verified app…") }
            self.applyPrebuilt(remote)
        }.resume()
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func sha256(_ url: URL) throws -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        p.arguments = ["-a", "256", url.path]
        p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "RGUpdate", code: 20, userInfo: [NSLocalizedDescriptionKey: "SHA256 verification tool failed"]) }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: " ").first.map(String.init) ?? ""
    }

    private func applyPrebuilt(_ version: String) {
        let stamp = String(Int(Date().timeIntervalSince1970))
        guard let zipURL = URL(string: "\(RGRepoRaw)/dist/RG-Sibilance-Studio-\(version).zip?t=\(stamp)"),
              let shaURL = URL(string: "\(RGRepoRaw)/dist/SHA256?t=\(stamp)") else { busy = false; return }

        URLSession.shared.downloadTask(with: zipURL) { [weak self] tempURL, _, error in
            guard let self = self, let tempURL = tempURL, error == nil else {
                self?.busy = false
                DispatchQueue.main.async { self?.onStatus?("UPDATE FAILED — download error") }
                return
            }
            do {
                let expectedData = try Data(contentsOf: shaURL)
                let expected = (String(data: expectedData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let actual = try self.sha256(tempURL).lowercased()
                guard !expected.isEmpty, expected == actual else {
                    throw NSError(domain: "RGUpdate", code: 21, userInfo: [NSLocalizedDescriptionKey: "Downloaded app failed SHA256 verification"])
                }

                let fm = FileManager.default
                let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RG Sibilance Studio/Updates", isDirectory: true)
                try fm.createDirectory(at: base, withIntermediateDirectories: true)
                let work = base.appendingPathComponent("\(version)-\(stamp)", isDirectory: true)
                try? fm.removeItem(at: work); try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("update.zip")
                try fm.copyItem(at: tempURL, to: zip)

                let ditto = Process()
                ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                ditto.arguments = ["-x", "-k", zip.path, work.path]
                try ditto.run(); ditto.waitUntilExit()
                guard ditto.terminationStatus == 0 else { throw NSError(domain: "RGUpdate", code: 22, userInfo: [NSLocalizedDescriptionKey: "Cannot unpack update"] ) }

                let candidates = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                guard let app = candidates.first(where: { $0.pathExtension == "app" }) else { throw NSError(domain: "RGUpdate", code: 23, userInfo: [NSLocalizedDescriptionKey: "Update package does not contain app"] ) }

                // Prefer the canonical /Applications install. If it is not writable, install in ~/Applications.
                var target = URL(fileURLWithPath: "/Applications/RG Sibilance Studio.app", isDirectory: true)
                let appsDir = target.deletingLastPathComponent()
                if !fm.isWritableFile(atPath: appsDir.path) {
                    let userApps = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
                    try fm.createDirectory(at: userApps, withIntermediateDirectories: true)
                    target = userApps.appendingPathComponent("RG Sibilance Studio.app", isDirectory: true)
                }

                let backupDir = base.appendingPathComponent("Backups", isDirectory: true)
                try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
                let backup = backupDir.appendingPathComponent("RG Sibilance Studio-before-\(version)-\(stamp).app", isDirectory: true)
                let staged = target.deletingLastPathComponent().appendingPathComponent(".RG Sibilance Studio.update.app", isDirectory: true)
                try? fm.removeItem(at: staged)
                try fm.copyItem(at: app, to: staged)

                // A detached script waits for this process to exit, swaps bundles atomically enough for Finder-style installs,
                // preserves the previous app as rollback, then launches the verified build.
                let script = work.appendingPathComponent("install-update.sh")
                let targetQ = self.shellQuote(target.path), stagedQ = self.shellQuote(staged.path), backupQ = self.shellQuote(backup.path)
                let text = "#!/bin/sh\nsleep 1\nif [ -e \(targetQ) ]; then mv \(targetQ) \(backupQ) || exit 41; fi\nmv \(stagedQ) \(targetQ) || { [ -e \(backupQ) ] && mv \(backupQ) \(targetQ); exit 42; }\n/usr/bin/open \(targetQ)\n"
                try text.write(to: script, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

                DispatchQueue.main.async {
                    self.onStatus?("UPDATE \(version) VERIFIED — restarting…")
                    let installer = Process()
                    installer.executableURL = URL(fileURLWithPath: "/bin/sh")
                    installer.arguments = [script.path]
                    try? installer.run()
                    NSApp.terminate(nil)
                }
            } catch {
                self.busy = false
                DispatchQueue.main.async { self.onStatus?("UPDATE FAILED — \(error.localizedDescription)") }
            }
        }.resume()
    }
}
'''
s = s[:start] + new + s[end:]
p.write_text(s)
print('patched 0.2.29')
