import Cocoa
import AVFoundation
import Foundation

let RGVersion = "0.2.7"
let RGRepoRaw = "https://raw.githubusercontent.com/randygnepa-dev/rg-sibilance-studio/main"

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1.0) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255.0,
            green: CGFloat((hex >> 8) & 0xff) / 255.0,
            blue: CGFloat(hex & 0xff) / 255.0,
            alpha: alpha
        )
    }
}

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
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let url = urls.first else { return nil }
        return ["wav", "wave", "aif", "aiff"].contains(url.pathExtension.lowercased()) ? url : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard audioURL(sender) != nil else { return [] }
        active = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        active = false
        needsDisplay = true
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        audioURL(sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = audioURL(sender) else { return false }
        active = false
        needsDisplay = true
        onAudioDrop?(url)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = active ? NSColor(hex: 0x0E2C4D) : NSColor(hex: 0x0E1B28)
        bg.setFill()
        bounds.fill()

        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        border.lineWidth = active ? 2.0 : 1.0
        (active ? NSColor(hex: 0x2F8CFF) : NSColor(hex: 0x28445F)).setStroke()
        border.stroke()

        let title = active ? "DROP AUDIO" : "DRAG & DROP WAV / AIFF"
        let sub = active ? "Release to load audio" : "Pretiahni audio priamo z Finderu"
        let t1: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 17),
            .foregroundColor: NSColor.white
        ]
        let t2: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor(hex: 0x8797A8)
        ]
        let s1 = title.size(withAttributes: t1)
        let s2 = sub.size(withAttributes: t2)
        title.draw(at: NSPoint(x: bounds.midX - s1.width/2, y: bounds.midY + 5), withAttributes: t1)
        sub.draw(at: NSPoint(x: bounds.midX - s2.width/2, y: bounds.midY - 24), withAttributes: t2)
    }
}

final class TimelineView: NSView {
    var hasAudio = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: 0x0B1219).setFill()
        bounds.fill()

        let waveformRect = NSRect(x: 145, y: bounds.height * 0.47, width: bounds.width - 185, height: bounds.height * 0.42)
        let spectroRect = NSRect(x: 145, y: 36, width: bounds.width - 185, height: bounds.height * 0.34)

        NSColor(hex: 0x101A24).setFill()
        waveformRect.fill()
        NSColor(hex: 0x11111A).setFill()
        spectroRect.fill()

        if hasAudio {
            drawWaveform(in: waveformRect)
            drawSpectrogram(in: spectroRect)
            drawEvents(in: waveformRect.union(spectroRect))
        } else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor(hex: 0x607080)
            ]
            let s = "Waveform + spectrogram sa zobrazia po vložení audia"
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: bounds.midX - sz.width/2, y: bounds.midY - 8), withAttributes: attrs)
        }

        drawMeters()
        drawScale()
    }

    private func drawWaveform(in rect: NSRect) {
        let path = NSBezierPath()
        let mid = rect.midY
        let n = 420
        for i in 0..<n {
            let x = rect.minX + CGFloat(i) / CGFloat(n - 1) * rect.width
            let a = sin(CGFloat(i) * 0.19) * 0.32 + sin(CGFloat(i) * 0.051) * 0.22 + sin(CGFloat(i) * 0.013) * 0.15
            let envelope = 0.35 + 0.55 * abs(sin(CGFloat(i) * 0.021))
            let y = mid + a * envelope * rect.height * 0.42
            if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
        }
        NSColor(hex: 0x2F8CFF).setStroke()
        path.lineWidth = 1.25
        path.stroke()

        let lower = NSBezierPath()
        for i in 0..<n {
            let x = rect.minX + CGFloat(i) / CGFloat(n - 1) * rect.width
            let a = sin(CGFloat(i) * 0.17 + 0.8) * 0.27 + sin(CGFloat(i) * 0.047) * 0.18
            let envelope = 0.32 + 0.55 * abs(sin(CGFloat(i) * 0.018 + 0.9))
            let y = mid - a * envelope * rect.height * 0.40
            if i == 0 { lower.move(to: NSPoint(x: x, y: y)) } else { lower.line(to: NSPoint(x: x, y: y)) }
        }
        NSColor(hex: 0x2272CE).setStroke()
        lower.lineWidth = 1.0
        lower.stroke()
    }

    private func drawSpectrogram(in rect: NSRect) {
        let ctx = NSGraphicsContext.current?.cgContext
        for i in 0..<120 {
            let x = rect.minX + CGFloat(i) / 120.0 * rect.width
            let strength = 0.18 + 0.75 * abs(sin(CGFloat(i) * 0.43))
            let w = max(2, rect.width / 180)
            let h1 = rect.height * (0.18 + 0.70 * abs(sin(CGFloat(i) * 0.27)))
            ctx?.setFillColor(NSColor(hex: 0x7027B8, alpha: strength * 0.45).cgColor)
            ctx?.fill(CGRect(x: x, y: rect.minY, width: w, height: h1))
            ctx?.setFillColor(NSColor(hex: 0xFF6A1A, alpha: strength * 0.38).cgColor)
            ctx?.fill(CGRect(x: x, y: rect.minY, width: w * 0.65, height: h1 * 0.42))
        }
    }

    private func drawEvents(in rect: NSRect) {
        let xs: [CGFloat] = [0.08,0.13,0.22,0.28,0.35,0.43,0.47,0.54,0.60,0.66,0.75,0.83,0.90]
        let labels = ["S","S","T","S","Z","S","S","S","S","C","S","T","S"]
        for (idx, p) in xs.enumerated() {
            let x = 145 + p * (bounds.width - 185)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: rect.minY))
            line.line(to: NSPoint(x: x, y: rect.maxY))
            let color = labels[idx] == "T" ? NSColor(hex: 0xF5A623) : NSColor(hex: 0xF23E55)
            color.setStroke()
            line.lineWidth = 1
            line.stroke()

            let badge = NSBezierPath(roundedRect: NSRect(x: x - 8, y: rect.maxY + 4, width: 16, height: 16), xRadius: 3, yRadius: 3)
            color.setFill()
            badge.fill()
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white]
            let s = labels[idx]
            let size = s.size(withAttributes: a)
            s.draw(at: NSPoint(x: x - size.width/2, y: rect.maxY + 5), withAttributes: a)
        }
    }

    private func drawMeters() {
        let baseX: CGFloat = 36
        let h = bounds.height - 98
        let barW: CGFloat = 8
        let y: CGFloat = 45
        let left = NSRect(x: baseX, y: y, width: barW, height: h)
        let right = NSRect(x: baseX + 28, y: y, width: barW, height: h)
        NSColor(hex: 0x1A2A35).setFill(); left.fill(); right.fill()
        NSColor(hex: 0x4DD36F).setFill()
        NSRect(x: left.minX, y: y, width: barW, height: h * 0.72).fill()
        NSRect(x: right.minX, y: y, width: barW, height: h * 0.69).fill()
        NSColor(hex: 0xE5BE2F).setFill()
        NSRect(x: left.minX, y: y + h * 0.64, width: barW, height: h * 0.08).fill()
        NSRect(x: right.minX, y: y + h * 0.61, width: barW, height: h * 0.08).fill()
    }

    private func drawScale() {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(hex: 0x6F7B87)]
        ["16k","8k","4k","2k","1k","500","250"].enumerated().forEach { i, s in
            let y = 42 + CGFloat(i) * 15
            s.draw(at: NSPoint(x: 100, y: y), withAttributes: attrs)
        }
    }
}

final class PanelView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: 0x111820).cgColor
        layer?.borderColor = NSColor(hex: 0x26313B).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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
            guard let self,
                  let data,
                  let remote = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  self.isNewer(remote, than: RGVersion) else { return }
            self.updating = true
            DispatchQueue.main.async { self.status?("UPDATE \(remote) — applying automatically…") }
            self.apply(remote)
        }.resume()
    }

    private func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }

    private func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b), n = max(x.count, y.count)
        for i in 0..<n {
            let xv = i < x.count ? x[i] : 0
            let yv = i < y.count ? y[i] : 0
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

                let sdkProc = Process()
                let sdkPipe = Pipe()
                sdkProc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                sdkProc.arguments = ["--sdk", "macosx", "--show-sdk-path"]
                sdkProc.standardOutput = sdkPipe
                try sdkProc.run()
                sdkProc.waitUntilExit()
                let sdkData = sdkPipe.fileHandleForReading.readDataToEndOfFile()
                guard let sdk = String(data: sdkData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !sdk.isEmpty else { self.updating = false; return }

                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                p.arguments = ["--sdk", "macosx", "swiftc", src.path, "-sdk", sdk, "-o", bin.path, "-framework", "Cocoa", "-framework", "AVFoundation"]
                try p.run()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else {
                    self.updating = false
                    DispatchQueue.main.async { self.status?("UPDATE FAILED — previous version kept") }
                    return
                }

                DispatchQueue.main.async {
                    self.status?("UPDATED TO \(version) — restarting…")
                    let launch = Process()
                    launch.executableURL = bin
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
    private var timeline: TimelineView!
    private var loadedURL: URL?
    private let updater = UpdateManager()
    private let accent = NSColor(hex: 0x2F8CFF)

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
        updater.status = { [weak self] s in self?.status.stringValue = s }
        updater.start()
    }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = NSColor(hex: 0xAAB4BF)) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    private func button(_ title: String, frame: NSRect, target: AnyObject?, action: Selector?, primary: Bool = false) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.frame = frame
        b.bezelStyle = .rounded
        if primary {
            b.contentTintColor = .white
            b.wantsLayer = true
            b.layer?.backgroundColor = accent.cgColor
            b.layer?.cornerRadius = 6
            b.isBordered = false
        }
        return b
    }

    private func slider(value: Double, min: Double = 0, max: Double = 100, frame: NSRect) -> NSSlider {
        let s = NSSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil)
        s.frame = frame
        return s
    }

    private func buildUI() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let sf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = 1180
        let h: CGFloat = 760
        window = NSWindow(
            contentRect: NSRect(x: sf.midX-w/2, y: sf.midY-h/2, width: w, height: h),
            styleMask: [.titled,.closable,.miniaturizable,.resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RG Sibilance Studio \(RGVersion) BETA"
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(hex: 0x0B1016)
        window.minSize = NSSize(width: 1000, height: 680)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(hex: 0x0B1016).cgColor
        window.contentView = root

        let title = label("RG Sibilance Studio", size: 28, weight: .bold, color: .white)
        title.frame = NSRect(x: 34, y: h-72, width: 430, height: 38)
        root.addSubview(title)

        let sub = label("Sibilance detection & repair   •   AUTO UPDATE BETA", size: 13, color: NSColor(hex: 0x8695A4))
        sub.frame = NSRect(x: 36, y: h-102, width: 480, height: 22)
        root.addSubview(sub)

        root.addSubview(button("Analyze", frame: NSRect(x: w-320, y: h-78, width: 130, height: 34), target: self, action: #selector(analyzeAudio), primary: true))
        root.addSubview(button("Open WAV", frame: NSRect(x: w-178, y: h-78, width: 130, height: 34), target: self, action: #selector(openWav)))

        let drop = DropAudioView(frame: NSRect(x: 34, y: h-245, width: w-68, height: 125))
        drop.onAudioDrop = { [weak self] url in self?.loadAudio(url) }
        root.addSubview(drop)

        fileInfo = label("No audio loaded", size: 12, weight: .medium, color: NSColor(hex: 0x95A2AE))
        fileInfo.frame = NSRect(x: 46, y: h-264, width: w-92, height: 20)
        root.addSubview(fileInfo)

        timeline = TimelineView(frame: NSRect(x: 34, y: 275, width: w-68, height: 225))
        timeline.wantsLayer = true
        timeline.layer?.borderColor = NSColor(hex: 0x26313B).cgColor
        timeline.layer?.borderWidth = 1
        timeline.layer?.cornerRadius = 8
        root.addSubview(timeline)

        let timelineHeader = label("00:00.000 / 00:00.000", size: 13, weight: .semibold, color: accent)
        timelineHeader.frame = NSRect(x: 48, y: 475, width: 250, height: 20)
        root.addSubview(timelineHeader)

        let detected = label("Detected: 0 events", size: 12, weight: .medium, color: NSColor(hex: 0x6AAEFF))
        detected.frame = NSRect(x: 48, y: 282, width: 220, height: 20)
        root.addSubview(detected)

        let sensitivityLabel = label("Sensitivity", size: 11, color: NSColor(hex: 0x9AA8B5))
        sensitivityLabel.frame = NSRect(x: w-300, y: 282, width: 80, height: 18)
        root.addSubview(sensitivityLabel)
        root.addSubview(slider(value: 75, frame: NSRect(x: w-218, y: 284, width: 120, height: 18)))
        let sensValue = label("75%", size: 11, color: NSColor(hex: 0xB7C2CD))
        sensValue.frame = NSRect(x: w-90, y: 282, width: 45, height: 18)
        root.addSubview(sensValue)

        buildBottomPanels(in: root, width: w)

        status = label("READY — drop WAV/AIFF", size: 12, weight: .bold, color: NSColor(hex: 0x58D978))
        status.frame = NSRect(x: 34, y: 20, width: 520, height: 22)
        root.addSubview(status)

        let engine = label("Engine: Native   •   48 kHz   •   24-bit", size: 11, color: NSColor(hex: 0x7D8995))
        engine.frame = NSRect(x: w/2-120, y: 20, width: 300, height: 22)
        root.addSubview(engine)

        let update = label("Auto update: ON   •   v\(RGVersion) BETA", size: 11, color: NSColor(hex: 0x58D978))
        update.frame = NSRect(x: w-270, y: 20, width: 240, height: 22)
        root.addSubview(update)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildBottomPanels(in root: NSView, width: CGFloat) {
        let y: CGFloat = 64
        let h: CGFloat = 190
        let gap: CGFloat = 12
        let leftW: CGFloat = 300
        let middleW: CGFloat = 390
        let rightW = width - 68 - leftW - middleW - gap*2

        let detection = PanelView(frame: NSRect(x: 34, y: y, width: leftW, height: h))
        root.addSubview(detection)
        addPanelTitle("DETECTION", to: detection)
        addControl("Sensitivity", value: "75%", y: 125, sliderValue: 75, to: detection)
        addControl("Min. Length", value: "20 ms", y: 90, sliderValue: 20, to: detection)
        addControl("Min. Frequency", value: "5.0 kHz", y: 55, sliderValue: 40, to: detection)
        addControl("Max. Frequency", value: "16.0 kHz", y: 20, sliderValue: 82, to: detection)

        let repair = PanelView(frame: NSRect(x: 34 + leftW + gap, y: y, width: middleW, height: h))
        root.addSubview(repair)
        addPanelTitle("REPAIR", to: repair)
        let tabs = label("GOOD      BAD      TARGET      NORMAL", size: 12, weight: .semibold, color: NSColor(hex: 0x9EABB7))
        tabs.frame = NSRect(x: 14, y: 138, width: 350, height: 22)
        repair.addSubview(tabs)
        let repairStrength = label("Repair Strength", size: 12, color: NSColor(hex: 0xAAB5BF))
        repairStrength.frame = NSRect(x: 14, y: 107, width: 120, height: 20)
        repair.addSubview(repairStrength)
        repair.addSubview(slider(value: 58, frame: NSRect(x: 128, y: 109, width: 180, height: 18)))
        let percent = label("58%", size: 11, color: NSColor(hex: 0xB7C2CD))
        percent.frame = NSRect(x: 318, y: 107, width: 48, height: 20)
        repair.addSubview(percent)

        repair.addSubview(button("Repair", frame: NSRect(x: 14, y: 61, width: 100, height: 30), target: self, action: #selector(modeRepair), primary: true))
        repair.addSubview(button("Reference Morph", frame: NSRect(x: 122, y: 61, width: 120, height: 30), target: self, action: #selector(modeMorph)))
        repair.addSubview(button("Reference Blend", frame: NSRect(x: 250, y: 61, width: 120, height: 30), target: self, action: #selector(modeBlend)))

        let preserve = NSButton(checkboxWithTitle: "Preserve Natural Tone", target: nil, action: nil)
        preserve.state = .on
        preserve.frame = NSRect(x: 14, y: 18, width: 220, height: 24)
        repair.addSubview(preserve)

        let xRight = 34 + leftW + middleW + gap*2
        let preview = PanelView(frame: NSRect(x: xRight, y: y + 96, width: rightW, height: 94))
        root.addSubview(preview)
        addPanelTitle("PREVIEW", to: preview)
        preview.addSubview(button("▶ Play", frame: NSRect(x: 14, y: 20, width: 100, height: 30), target: self, action: #selector(playPreview), primary: true))
        preview.addSubview(button("A/B", frame: NSRect(x: 122, y: 20, width: 86, height: 30), target: self, action: #selector(abPreview)))
        preview.addSubview(button("Loop", frame: NSRect(x: 216, y: 20, width: 86, height: 30), target: self, action: #selector(loopPreview)))

        let output = PanelView(frame: NSRect(x: xRight, y: y, width: rightW, height: 84))
        root.addSubview(output)
        addPanelTitle("OUTPUT", to: output)
        let dry = label("Dry / Wet", size: 11, color: NSColor(hex: 0xAAB5BF)); dry.frame = NSRect(x: 14, y: 37, width: 72, height: 18); output.addSubview(dry)
        output.addSubview(slider(value: 100, frame: NSRect(x: 88, y: 39, width: rightW-150, height: 18)))
        let wet = label("100%", size: 11); wet.frame = NSRect(x: rightW-52, y: 37, width: 40, height: 18); output.addSubview(wet)
        let gain = label("Output Gain", size: 11, color: NSColor(hex: 0xAAB5BF)); gain.frame = NSRect(x: 14, y: 14, width: 78, height: 18); output.addSubview(gain)
        output.addSubview(slider(value: 50, frame: NSRect(x: 88, y: 16, width: rightW-150, height: 18)))
        let db = label("0.0 dB", size: 11); db.frame = NSRect(x: rightW-58, y: 14, width: 48, height: 18); output.addSubview(db)
    }

    private func addPanelTitle(_ text: String, to panel: NSView) {
        let t = label(text, size: 11, weight: .bold, color: NSColor(hex: 0xD4DCE3))
        t.frame = NSRect(x: 14, y: panel.bounds.height-28, width: 180, height: 18)
        panel.addSubview(t)
    }

    private func addControl(_ name: String, value: String, y: CGFloat, sliderValue: Double, to panel: NSView) {
        let n = label(name, size: 11, color: NSColor(hex: 0xA7B2BC)); n.frame = NSRect(x: 14, y: y, width: 92, height: 18); panel.addSubview(n)
        panel.addSubview(slider(value: sliderValue, frame: NSRect(x: 103, y: y+2, width: 120, height: 16)))
        let v = label(value, size: 11, color: NSColor(hex: 0xBEC7CF)); v.frame = NSRect(x: 235, y: y, width: 55, height: 18); panel.addSubview(v)
    }

    @objc private func openWav() {
        let p = NSOpenPanel()
        p.allowedFileTypes = ["wav","wave","aif","aiff"]
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        if p.runModal() == .OK, let url = p.url { loadAudio(url) }
    }

    private func loadAudio(_ url: URL) {
        do {
            let f = try AVAudioFile(forReading: url)
            let format = f.processingFormat
            let duration = Double(f.length) / format.sampleRate
            loadedURL = url
            timeline.hasAudio = true
            fileInfo.stringValue = "\(url.lastPathComponent)   •   \(Int(format.sampleRate)) Hz   •   \(format.channelCount) ch   •   \(String(format: "%.2f", duration)) s"
            status.stringValue = "AUDIO LOADED — ready to Analyze"
        } catch {
            let a = NSAlert()
            a.messageText = "Audio sa nepodarilo načítať"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    @objc private func analyzeAudio() {
        guard let url = loadedURL else {
            status.stringValue = "DROP WAV/AIFF FIRST"
            return
        }
        status.stringValue = "ANALYZING — \(url.lastPathComponent)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.status.stringValue = "ANALYSIS READY — event engine next"
        }
    }

    @objc private func modeRepair() { status.stringValue = "REPAIR MODE" }
    @objc private func modeMorph() { status.stringValue = "REFERENCE MORPH MODE" }
    @objc private func modeBlend() { status.stringValue = "REFERENCE BLEND MODE" }
    @objc private func playPreview() { status.stringValue = loadedURL == nil ? "DROP WAV/AIFF FIRST" : "PREVIEW — playback engine next" }
    @objc private func abPreview() { status.stringValue = "A/B PREVIEW" }
    @objc private func loopPreview() { status.stringValue = "LOOP PREVIEW" }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
