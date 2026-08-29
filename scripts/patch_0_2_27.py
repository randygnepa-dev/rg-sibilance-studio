from pathlib import Path

p = Path('Sources/RGSibilanceStudio.swift')
s = p.read_text()
s = s.replace('let RGVersion = "0.2.26"', 'let RGVersion = "0.2.27"')
old = '''let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()'''
new = '''@main
struct RGSibilanceStudioMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}'''
if old not in s:
    raise SystemExit('entry point not found')
s = s.replace(old, new)
p.write_text(s)

# CI must compile the @main source under its real filename; renaming it to main.swift
# would make Swift treat it as a top-level entry point and conflict with @main.
w = Path('.github/workflows/build-macos.yml')
t = w.read_text()
t = t.replace('          mv build-src/RGSibilanceStudio.swift build-src/main.swift\n', '')
t = t.replace('# trigger 0.2.26 functional learning/reference/spectral repair', '# trigger 0.2.27 updater entrypoint compatibility')
w.write_text(t)
