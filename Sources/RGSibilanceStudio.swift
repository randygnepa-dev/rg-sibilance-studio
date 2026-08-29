import Cocoa
import AVFoundation
import Foundation

let RGVersion = "0.2.6"
let RGRepoRaw = "https://raw.githubusercontent.com/randygnepa-dev/rg-sibilance-studio/main"

final class DropAudioView: NSView {
    var onAudioDrop: ((URL) -> Void)?
    private var active = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    private func audioURL(_ sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let url = urls.first else { return nil }
        return ["wav", "wave", "aif", "aiff"].contains(url.pathExtension.lowercased()) ? url : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard audioURL(sender) != nil else { return [] }
        active = true; needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { active = false; needsDisplay = true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { audioURL(sender) != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = audioURL(sender) else { return false }
        active = false; needsDisplay = true
        onAudioDrop?(url)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        (active ? NSColor.controlAccentColor.withAlphaComponent(0.10) : NSColor(calibratedWhite: 0.96, alpha: 1)).setFill()
        bounds.fill()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        p.lineWidth = active ? 3 : 1.5
        (active ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke(); p.stroke()
        let title = active ? "DROP AUDIO" : "DRAG & DROP WAV / AIFF"
        let sub = active ? "Release to load audio" : "Pretiahni audio priamo z Finderu"
        let a1: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 17), .foregroundColor: active ? NSColor.controlAccentColor : NSColor.labelColor]
        let a2: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
        let s1 = title.size(withAttributes: a1), s2 = sub.size(withAttributes: a2)
        title.draw(at: NSPoint(x: bounds.midX - s1.width/2, y: bounds.midY + 5), withAttributes: a1)
        sub.draw(at: NSPoint(x: bounds.midX - s2.width/2, y: bounds.midY - 25), withAttributes: a2)
    }
}

final class UpdateManager {
    private var timer: Timer?
    private var updating = false
    var status: ((String) -> Void)?

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.check() }
    }

    private func check() {
        guard !updating, let url = URL(string: "\(RGRepoRaw)/VERSION?t=\(Date().timeIntervalSince1970)") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let remote = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), self.isNewer(remote, than: RGVersion) else { return }
            self.updating = true
            DispatchQueue.main.async { self.status?("UPDATE \(remote) — applying automatically…") }
            self.apply(remote)
        }.resume()
    }

    private func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
    private func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b), n = max(x.count, y.count)
        for i in 0..<n {
            let xv = i < x.count ? x[i] : 0, yv = i < y.count ? y[i] : 0
            if xv != yv { return xv > yv }
        }
        return false
    }

    private func apply(_ version: String) {
        guard let srcURL = URL(string: "\(RGRepoRaw)/Sources/RGSibilanceStudio.swift?t=\(Date().timeIntervalSince1970)") else { return }
        URLSession.shared.dataTask(with: srcURL) { [weak self] data, _, _ in
            guard let self, let data else { self?.updating = false; return }
            do {
                let fm = FileManager.default
                let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RG Sibilance Studio", isDirectory: true)
                try fm.createDirectory(at: base, withIntermediateDirectories: true)
                let src = base.appendingPathComponent("RGSibilanceStudio-\(version).swift")
                let bin = base.appendingPathComponent("RG Sibilance Studio-\(version)")
                try data.write(to: src, options: .atomic)

                let sdkProc = Process(); let sdkPipe = Pipe()
                sdkProc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                sdkProc.arguments = ["--sdk", "macosx", "--show-sdk-path"]
                sdkProc.standardOutput = sdkPipe
                try sdkProc.run(); sdkProc.waitUntilExit()
                let sdkData = sdkPipe.fileHandleForReading.readDataToEndOfFile()
                guard let sdk = String(data: sdkData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !sdk.isEmpty else { self.updating = false; return }

                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                p.arguments = ["--sdk", "macosx", "swiftc", src.path, "-sdk", sdk, "-o", bin.path, "-framework", "Cocoa", "-framework", "AVFoundation"]
                try p.run(); p.waitUntilExit()
                guard p.terminationStatus == 0 else { self.updating = false; DispatchQueue.main.async { self.status?("UPDATE FAILED") }; return }

                DispatchQueue.main.async {
                    self.status?("UPDATED TO \(version) — restarting…")
                    let launch = Process(); launch.executableURL = bin
                    try? launch.run()
                    NSApp.terminate(nil)
                }
            } catch {
                self.updating = false
                DispatchQueue.main.async { self.status?("UPDATE FAILED: \(error.localizedDescription)") }
            }
        }.resume()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var status: NSTextField!
    private var fileInfo: NSTextField!
    private var loadedURL: URL?
    private let updater = UpdateManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
        updater.status = { [weak self] s in self?.status.stringValue = s }
        updater.start()
    }

    private func buildUI() {
        let sf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        window = NSWindow(contentRect: NSRect(x: sf.midX-500, y: sf.midY-320, width: 1000, height: 640), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "RG Sibilance Studio \(RGVersion) BETA"
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x:0,y:0,width:1000,height:640)); window.contentView = root

        let title = NSTextField(labelWithString: "RG Sibilance Studio"); title.font = .boldSystemFont(ofSize: 28); title.frame = NSRect(x:28,y:565,width:470,height:42); root.addSubview(title)
        let sub = NSTextField(labelWithString: "Sibilance detection & repair  •  AUTO UPDATE BETA"); sub.font = .systemFont(ofSize:14); sub.textColor = .secondaryLabelColor; sub.frame = NSRect(x:30,y:535,width:520,height:24); root.addSubview(sub)

        let analyze = NSButton(title:"Analyze", target:self, action:#selector(analyzeAudio)); analyze.frame = NSRect(x:680,y:565,width:130,height:32); root.addSubview(analyze)
        let open = NSButton(title:"Open WAV", target:self, action:#selector(openWav)); open.frame = NSRect(x:820,y:565,width:130,height:32); root.addSubview(open)

        let drop = DropAudioView(frame:NSRect(x:30,y:250,width:920,height:255)); drop.onAudioDrop = { [weak self] url in self?.loadAudio(url) }; root.addSubview(drop)
        fileInfo = NSTextField(labelWithString:"No audio loaded"); fileInfo.font = .systemFont(ofSize:14, weight:.medium); fileInfo.frame = NSRect(x:30,y:205,width:920,height:28); root.addSubview(fileInfo)

        let labels = NSTextField(labelWithString:"GOOD     BAD     TARGET     NORMAL"); labels.font = .systemFont(ofSize:14, weight:.semibold); labels.textColor = .secondaryLabelColor; labels.frame = NSRect(x:30,y:145,width:500,height:25); root.addSubview(labels)
        let repair = NSTextField(labelWithString:"Repair:  LESS S   ←────────●────────→   MORE S"); repair.font = .systemFont(ofSize:14); repair.textColor = .secondaryLabelColor; repair.frame = NSRect(x:30,y:100,width:600,height:25); root.addSubview(repair)

        status = NSTextField(labelWithString:"READY — drop WAV/AIFF"); status.font = .boldSystemFont(ofSize:13); status.frame = NSRect(x:30,y:30,width:900,height:24); root.addSubview(status)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }

    @objc private func openWav() {
        let p = NSOpenPanel(); p.allowedFileTypes = ["wav","wave","aif","aiff"]; p.allowsMultipleSelection = false; p.canChooseDirectories = false
        if p.runModal() == .OK, let url = p.url { loadAudio(url) }
    }

    private func loadAudio(_ url: URL) {
        do {
            let f = try AVAudioFile(forReading:url); let format = f.processingFormat; let duration = Double(f.length)/format.sampleRate
            loadedURL = url
            fileInfo.stringValue = "\(url.lastPathComponent)   •   \(Int(format.sampleRate)) Hz   •   \(format.channelCount) ch   •   \(String(format:"%.2f",duration)) s"
            status.stringValue = "AUDIO LOADED — ready to Analyze"
        } catch {
            let a = NSAlert(); a.messageText = "Audio sa nepodarilo načítať"; a.informativeText = error.localizedDescription; a.runModal()
        }
    }

    @objc private func analyzeAudio() {
        guard let url = loadedURL else { status.stringValue = "DROP WAV/AIFF FIRST"; return }
        status.stringValue = "ANALYZING — \(url.lastPathComponent)"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
