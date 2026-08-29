from pathlib import Path

p = Path('Sources/RGSibilanceStudio.swift')
s = p.read_text()

s = s.replace('let RGVersion = "0.2.16"', 'let RGVersion = "0.2.17"', 1)

old = '''    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.check() }
    }'''
new = '''    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.check() }
    }

    func forceRefresh() {
        check(force: true)
    }'''
if old not in s:
    raise SystemExit('UpdateManager start marker missing')
s = s.replace(old, new, 1)

old = '''    private func check() {
        guard !busy, let url = URL(string: "\\(RGRepoRaw)/VERSION?t=\\(Date().timeIntervalSince1970)") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let remote = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  self.newer(remote, than: RGVersion) else { return }
            self.busy = true
            DispatchQueue.main.async { self.onStatus?("UPDATE \\(remote) — applying…") }
            self.apply(remote)
        }.resume()
    }'''
new = '''    private func check(force: Bool = false) {
        guard !busy, let url = URL(string: "\\(RGRepoRaw)/VERSION?t=\\(Date().timeIntervalSince1970)") else { return }
        if force {
            DispatchQueue.main.async { self.onStatus?("REFRESH — checking latest interface…") }
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let remote = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                if force { DispatchQueue.main.async { self?.onStatus?("REFRESH FAILED — cannot reach update channel") } }
                return
            }
            let shouldApply = self.newer(remote, than: RGVersion) || force
            guard shouldApply else { return }
            self.busy = true
            DispatchQueue.main.async {
                self.onStatus?(force ? "REFRESHING LATEST INTERFACE — v\\(remote)…" : "UPDATE \\(remote) — applying…")
            }
            self.apply(remote)
        }.resume()
    }'''
if old not in s:
    raise SystemExit('UpdateManager check marker missing')
s = s.replace(old, new, 1)

old = '''        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 49 && !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                self.toggleTransport()
                return nil
            }
            return event
        }'''
new = '''        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 15 && event.modifierFlags.contains(.command) {
                self.updater.forceRefresh()
                return nil
            }
            if event.keyCode == 49 && !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                self.toggleTransport()
                return nil
            }
            return event
        }'''
if old not in s:
    raise SystemExit('keyboard transport marker missing')
s = s.replace(old, new, 1)

s = s.replace(
    '"Native engine   •   Auto update: ON   •   v\\(RGVersion)"',
    '"Native engine   •   Auto update: ON   •   ⌘R Refresh latest   •   v\\(RGVersion)"',
    1
)

p.write_text(s)
