import Cocoa
import AVFoundation
import Foundation

let RGVersion = "0.2.8"
let RGRepoRaw = "https://raw.githubusercontent.com/randygnepa-dev/rg-sibilance-studio/main"

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1.0) {
        self.init(calibratedRed: CGFloat((hex >> 16) & 0xff) / 255.0,
                  green: CGFloat((hex >> 8) & 0xff) / 255.0,
                  blue: CGFloat(hex & 0xff) / 255.0,
                  alpha: alpha)
    }
}

struct SibilanceEvent {
    var start: Double
    var end: Double
    var peakTime: Double
    var score: Double
    var kind: String
    var userLabel: String
}

final class AudioModel {
    var url: URL?
    var samples: [Float] = []
    var sampleRate: Double = 48000
    var channels: Int = 0
    var duration: Double = 0
    var peak: Float = 0
    var rms: Float = 0
    var spectralBins: [Float] = []

    func load(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw NSError(domain: "RG", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate audio buffer"])
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            throw NSError(domain: "RG", code: 2, userInfo: [NSLocalizedDescriptionKey: "Audio is not readable as Float PCM"])
        }

        self.url = url
        self.sampleRate = format.sampleRate
        self.channels = Int(format.channelCount)
        self.duration = Double(buffer.frameLength) / format.sampleRate
        let n = Int(buffer.frameLength)
        samples = Array(repeating: 0, count: n)

        if channels == 1 {
            for i in 0..<n { samples[i] = channelData[0][i] }
        } else {
            let c = max(1, channels)
            for i in 0..<n {
                var sum: Float = 0
                for ch in 0..<c { sum += channelData[ch][i] }
                samples[i] = sum / Float(c)
            }
        }

        var p: Float = 0
        var e: Double = 0
        for x in samples {
            p = max(p, abs(x))
            e += Double(x * x)
        }
        peak = p
        rms = samples.isEmpty ? 0 : Float(sqrt(e / Double(samples.count)))
        spectralBins = makeSpectralBins(count: 360)
    }

    private func makeSpectralBins(count: Int) -> [Float] {
        guard samples.count > 8 else { return [] }
        var out = Array(repeating: Float(0), count: count)
        let chunk = max(64, samples.count / count)
        for b in 0..<count {
            let start = b * chunk
            if start >= samples.count { break }
            let end = min(samples.count, start + chunk)
            var full: Double = 0
            var diff: Double = 0
            var prev = samples[start]
            for i in start..<end {
                let x = samples[i]
                full += Double(x * x)
                let d = x - prev
                diff += Double(d * d)
                prev = x
            }
            let ratio = sqrt(diff / max(full, 1e-12))
            out[b] = Float(min(1.0, ratio / 1.5))
        }
        return out
    }
}

final class SibilanceDetector {
    func detect(samples: [Float], sampleRate: Double, sensitivity: Double) -> [SibilanceEvent] {
        guard samples.count > 4096 else { return [] }
        let frame = 1024
        let hop = 512
        var metrics: [(time: Double, value: Double, rms: Double, ratio: Double)] = []
        var i = 0
        while i + frame < samples.count {
            var full: Double = 0
            var diff: Double = 0
            var prev = samples[i]
            var zc = 0
            for j in i..<(i + frame) {
                let x = samples[j]
                full += Double(x * x)
                if (x >= 0) != (prev >= 0) { zc += 1 }
                let d = x - prev
                diff += Double(d * d)
                prev = x
            }
            let r = sqrt(full / Double(frame))
            let ratio = sqrt(diff / max(full, 1e-12))
            let zcr = Double(zc) / Double(frame)
            let gate = min(1.0, max(0.0, (r - 0.0015) / 0.025))
            let value = ratio * (0.55 + 2.5 * zcr) * (0.20 + 0.80 * gate)
            let t = Double(i + frame / 2) / sampleRate
            metrics.append((t, value, r, ratio))
            i += hop
        }

        guard metrics.count > 10 else { return [] }
        let sorted = metrics.map { $0.value }.sorted()
        let sens = min(1.0, max(0.0, sensitivity))
        let percentile = 0.90 - sens * 0.28
        let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * percentile)))
        let threshold = max(0.62, sorted[idx])

        var raw: [(Double, Double, Double)] = []
        var activeStart: Double? = nil
        var bestScore = 0.0
        var bestTime = 0.0
        let frameDur = Double(frame) / sampleRate

        for m in metrics {
            let on = m.value >= threshold && m.rms > 0.0015 && m.ratio > 0.48
            if on {
                if activeStart == nil { activeStart = max(0, m.time - frameDur * 0.5) }
                if m.value > bestScore { bestScore = m.value; bestTime = m.time }
            } else if let s = activeStart {
                let e = m.time + frameDur * 0.25
                if e - s >= 0.025 && e - s <= 0.55 { raw.append((s, e, bestScore)) }
                activeStart = nil; bestScore = 0; bestTime = 0
            }
        }
        if let s = activeStart, let last = metrics.last {
            let e = last.time + frameDur * 0.5
            if e - s >= 0.025 && e - s <= 0.55 { raw.append((s, e, bestScore)) }
        }

        var merged: [(Double, Double, Double)] = []
        for r in raw {
            if let last = merged.last, r.0 - last.1 < 0.045 {
                merged[merged.count - 1] = (last.0, r.1, max(last.2, r.2))
            } else {
                merged.append(r)
            }
        }

        return merged.prefix(300).map { r in
            let dur = r.1 - r.0
            let kind = dur < 0.065 ? "T" : "S"
            return SibilanceEvent(start: r.0, end: r.1, peakTime: (r.0 + r.1) * 0.5, score: r.2, kind: kind, userLabel: "")
        }
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
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func audioURL(_ sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let url = urls.first else { return nil }
        return ["wav", "wave", "aif", "aiff"].contains(url.pathExtension.lowercased()) ? url : nil
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard audioURL(sender) != nil else { return [] }
        active = true; needsDisplay = true; return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { active = false; needsDisplay = true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { return audioURL(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = audioURL(sender) else { return false }
        active = false; needsDisplay = true; onAudioDrop?(url); return true
    }
    override func draw(_ dirtyRect: NSRect) {
        (active ? NSColor(hex: 0x0E2C4D) : NSColor(hex: 0x0E1B28)).setFill(); bounds.fill()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        border.lineWidth = active ? 2 : 1
        (active ? NSColor(hex: 0x2F8CFF) : NSColor(hex: 0x28445F)).setStroke(); border.stroke()
        let title = active ? "DROP AUDIO" : "DRAG & DROP WAV / AIFF"
        let sub = active ? "Release to load audio" : "Pretiahni audio priamo z Finderu"
        let a1: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 17), .foregroundColor: NSColor.white]
        let a2: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(hex: 0x8797A8)]
        let s1 = title.size(withAttributes: a1), s2 = sub.size(withAttributes: a2)
        title.draw(at: NSPoint(x: bounds.midX - s1.width/2, y: bounds.midY + 5), withAttributes: a1)
        sub.draw(at: NSPoint(x: bounds.midX - s2.width/2, y: bounds.midY - 24), withAttributes: a2)
    }
}

final class TimelineView: NSView {
    var model: AudioModel? { didSet { needsDisplay = true } }
    var events: [SibilanceEvent] = [] { didSet { needsDisplay = true } }
    var selectedIndex: Int? { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?

    private var plotRect: NSRect { NSRect(x: 112, y: 32, width: max(100, bounds.width - 138), height: max(80, bounds.height - 54)) }

    override func mouseDown(with event: NSEvent) {
        guard let model = model, model.duration > 0, !events.isEmpty else { return }
        let p = convert(event.locationInWindow, from: nil)
        let rect = plotRect
        guard rect.contains(p) else { return }
        let t = Double((p.x - rect.minX) / rect.width) * model.duration
        var best = 0
        var bestD = Double.greatestFiniteMagnitude
        for (i, ev) in events.enumerated() {
            let d = abs(ev.peakTime - t)
            if d < bestD { bestD = d; best = i }
        }
        selectedIndex = best
        onSelect?(best)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: 0x0B1219).setFill(); bounds.fill()
        let rect = plotRect
        NSColor(hex: 0x101A24).setFill(); rect.fill()
        guard let model = model, !model.samples.isEmpty else {
            drawCentered("Waveform sa zobrazí po vložení audia")
            return
        }
        drawWaveform(model, in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height * 0.46))
        drawSpectral(model, in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.42))
        drawEvents(model, in: rect)
        drawMeters(model)
        drawTimeScale(model, rect: rect)
    }

    private func drawCentered(_ text: String) {
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor(hex: 0x607080)]
        let sz = text.size(withAttributes: a)
        text.draw(at: NSPoint(x: bounds.midX - sz.width/2, y: bounds.midY - 8), withAttributes: a)
    }

    private func drawWaveform(_ model: AudioModel, in rect: NSRect) {
        let n = model.samples.count
        let columns = max(100, Int(rect.width))
        let step = max(1, n / columns)
        let path = NSBezierPath()
        for xIndex in 0..<columns {
            let start = min(n - 1, xIndex * step)
            let end = min(n, start + step)
            var mn: Float = 0, mx: Float = 0
            if start < end {
                mn = model.samples[start]; mx = mn
                for i in start..<end { mn = min(mn, model.samples[i]); mx = max(mx, model.samples[i]) }
            }
            let x = rect.minX + CGFloat(xIndex) / CGFloat(max(1, columns - 1)) * rect.width
            let y1 = rect.midY + CGFloat(mn) * rect.height * 0.48
            let y2 = rect.midY + CGFloat(mx) * rect.height * 0.48
            path.move(to: NSPoint(x: x, y: y1)); path.line(to: NSPoint(x: x, y: y2))
        }
        NSColor(hex: 0x2F8CFF).setStroke(); path.lineWidth = 1; path.stroke()
        let mid = NSBezierPath(); mid.move(to: NSPoint(x: rect.minX, y: rect.midY)); mid.line(to: NSPoint(x: rect.maxX, y: rect.midY))
        NSColor(hex: 0x24384B).setStroke(); mid.lineWidth = 0.5; mid.stroke()
    }

    private func drawSpectral(_ model: AudioModel, in rect: NSRect) {
        guard !model.spectralBins.isEmpty else { return }
        let w = rect.width / CGFloat(model.spectralBins.count)
        for (i, v) in model.spectralBins.enumerated() {
            let x = rect.minX + CGFloat(i) * w
            let h = rect.height * CGFloat(0.15 + 0.85 * v)
            NSColor(hex: 0x6C32B9, alpha: 0.22 + CGFloat(v) * 0.42).setFill()
            NSRect(x: x, y: rect.minY, width: max(1, w), height: h).fill()
            if v > 0.52 {
                NSColor(hex: 0xFF6A1A, alpha: CGFloat(v) * 0.34).setFill()
                NSRect(x: x, y: rect.minY, width: max(1, w * 0.7), height: h * 0.38).fill()
            }
        }
    }

    private func drawEvents(_ model: AudioModel, in rect: NSRect) {
        guard model.duration > 0 else { return }
        for (i, ev) in events.enumerated() {
            let x = rect.minX + CGFloat(ev.peakTime / model.duration) * rect.width
            let selected = i == selectedIndex
            let color: NSColor
            if ev.userLabel == "GOOD" { color = NSColor(hex: 0x45C978) }
            else if ev.userLabel == "BAD" { color = NSColor(hex: 0xFF375F) }
            else if ev.userLabel == "TARGET" { color = NSColor(hex: 0x2F8CFF) }
            else if ev.userLabel == "NORMAL" { color = NSColor(hex: 0xA0A7AE) }
            else { color = ev.kind == "T" ? NSColor(hex: 0xF5A623) : NSColor(hex: 0xF23E55) }
            let line = NSBezierPath(); line.move(to: NSPoint(x: x, y: rect.minY)); line.line(to: NSPoint(x: x, y: rect.maxY))
            color.setStroke(); line.lineWidth = selected ? 2.5 : 1; line.stroke()
            let badge = NSBezierPath(roundedRect: NSRect(x: x - 8, y: rect.maxY - 17, width: 16, height: 16), xRadius: 3, yRadius: 3)
            color.setFill(); badge.fill()
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white]
            let s = ev.kind; let z = s.size(withAttributes: a)
            s.draw(at: NSPoint(x: x - z.width/2, y: rect.maxY - 16), withAttributes: a)
        }
    }

    private func drawMeters(_ model: AudioModel) {
        let h = max(60, bounds.height - 82), y: CGFloat = 32
        let peakNorm = CGFloat(min(1, max(0.04, model.peak)))
        let rmsNorm = CGFloat(min(1, max(0.03, model.rms * 4)))
        let left = NSRect(x: 34, y: y, width: 9, height: h), right = NSRect(x: 62, y: y, width: 9, height: h)
        NSColor(hex: 0x1A2A35).setFill(); left.fill(); right.fill()
        NSColor(hex: 0x4DD36F).setFill()
        NSRect(x: left.minX, y: y, width: 9, height: h * max(rmsNorm, peakNorm * 0.75)).fill()
        NSRect(x: right.minX, y: y, width: 9, height: h * max(rmsNorm * 0.96, peakNorm * 0.72)).fill()
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(hex: 0x71808E)]
        "IN".draw(at: NSPoint(x: 30, y: y + h + 6), withAttributes: a)
    }

    private func drawTimeScale(_ model: AudioModel, rect: NSRect) {
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(hex: 0x71808E)]
        for i in 0...4 {
            let t = model.duration * Double(i) / 4.0
            let m = Int(t) / 60, s = Int(t) % 60
            let text = String(format: "%d:%02d", m, s)
            let x = rect.minX + rect.width * CGFloat(i) / 4.0
            text.draw(at: NSPoint(x: x - 12, y: 9), withAttributes: a)
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
            guard let self = self, let data = data, let remote = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), self.isNewer(remote, than: RGVersion) else { return }
            self.updating = true
            DispatchQueue.main.async { self.status?("UPDATE \(remote) — applying automatically…") }
            self.apply(remote)
        }.resume()
    }
    private func parts(_ s: String) -> [Int] { return s.split(separator: ".").map { Int($0) ?? 0 } }
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
            guard let self = self, let data = data else { self?.updating = false; return }
            do {
                let fm = FileManager.default
                let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RG Sibilance Studio", isDirectory: true)
                try fm.createDirectory(at: base, withIntermediateDirectories: true)
                let src = base.appendingPathComponent("RGSibilanceStudio-\(version).swift")
                let bin = base.appendingPathComponent("RG Sibilance Studio-\(version)")
                try data.write(to: src, options: .atomic)
                let sdkProc = Process(), sdkPipe = Pipe()
                sdkProc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                sdkProc.arguments = ["--sdk", "macosx", "--show-sdk-path"]
                sdkProc.standardOutput = sdkPipe
                try sdkProc.run(); sdkProc.waitUntilExit()
                let sdkData = sdkPipe.fileHandleForReading.readDataToEndOfFile()
                guard let sdk = String(data: sdkData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !sdk.isEmpty else { self.updating = false; return }
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                p.arguments = ["--sdk", "macosx", "swiftc", src.path, "-sdk", sdk, "-o", bin.path, "-framework", "Cocoa", "-framework", "AVFoundation"]
                try p.run(); p.waitUntilExit()
                guard p.terminationStatus == 0 else {
                    self.updating = false
                    DispatchQueue.main.async { self.status?("UPDATE FAILED — previous version kept") }
                    return
                }
                DispatchQueue.main.async {
                    self.status?("UPDATED TO \(version) — restarting…")
                    let launch = Process(); launch.executableURL = bin; try? launch.run(); NSApp.terminate(nil)
                }
            } catch {
                self.updating = false
                DispatchQueue.main.async { self.status?("UPDATE FAILED: \(error.localizedDescription)") }
            }
        }.resume()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, AVAudioPlayerDelegate {
    private var window: NSWindow!
    private var status: NSTextField!
    private var fileInfo: NSTextField!
    private var eventInfo: NSTextField!
    private var detectedLabel: NSTextField!
    private var timeline: TimelineView!
    private var sensitivitySlider: NSSlider!
    private var playButton: NSButton!
    private var loopButton: NSButton!
    private var player: AVAudioPlayer?
    private var stopTimer: Timer?
    private var loopEnabled = false
    private var model = AudioModel()
    private var events: [SibilanceEvent] = []
    private let detector = SibilanceDetector()
    private let updater = UpdateManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
        updater.status = { [weak self] s in self?.status.stringValue = s }
        updater.start()
    }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = NSColor(hex: 0xAAB5C0)) -> NSTextField {
        let l = NSTextField(labelWithString: text); l.font = NSFont.systemFont(ofSize: size, weight: weight); l.textColor = color; return l
    }
    private func button(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b
    }
    private func addPanelTitle(_ text: String, to panel: NSView, x: CGFloat, y: CGFloat) {
        let l = label(text, size: 12, weight: .bold, color: NSColor(hex: 0xD5DEE7)); l.frame = NSRect(x: x, y: y, width: 180, height: 20); panel.addSubview(l)
    }

    private func buildUI() {
        let sf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1500, height: 980)
        let w: CGFloat = min(1440, sf.width - 40), h: CGFloat = min(900, sf.height - 40)
        window = NSWindow(contentRect: NSRect(x: sf.midX - w/2, y: sf.midY - h/2, width: w, height: h), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "RG Sibilance Studio \(RGVersion) BETA"
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(hex: 0x0C1218)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h)); root.wantsLayer = true; root.layer?.backgroundColor = NSColor(hex: 0x0C1218).cgColor; window.contentView = root

        let title = label("RG Sibilance Studio", size: 28, weight: .bold, color: .white); title.frame = NSRect(x: 34, y: h-70, width: 480, height: 38); root.addSubview(title)
        let sub = label("Sibilance detection & repair   •   AUTO UPDATE BETA", size: 13, color: NSColor(hex: 0x8896A4)); sub.frame = NSRect(x: 36, y: h-98, width: 560, height: 22); root.addSubview(sub)
        let analyze = button("Analyze", action: #selector(analyzeAudio)); analyze.frame = NSRect(x: w-330, y: h-75, width: 130, height: 34); root.addSubview(analyze)
        let open = button("Open WAV", action: #selector(openWav)); open.frame = NSRect(x: w-185, y: h-75, width: 130, height: 34); root.addSubview(open)

        let drop = DropAudioView(frame: NSRect(x: 34, y: h-232, width: w-68, height: 112)); drop.onAudioDrop = { [weak self] url in self?.loadAudio(url) }; root.addSubview(drop)
        fileInfo = label("No audio loaded", size: 12, weight: .medium); fileInfo.frame = NSRect(x: 40, y: h-255, width: w-80, height: 20); root.addSubview(fileInfo)

        timeline = TimelineView(frame: NSRect(x: 34, y: h-585, width: w-68, height: 300)); timeline.wantsLayer = true; timeline.layer?.borderColor = NSColor(hex: 0x26313B).cgColor; timeline.layer?.borderWidth = 1; timeline.layer?.cornerRadius = 8
        timeline.onSelect = { [weak self] i in self?.selectEvent(i) }; root.addSubview(timeline)
        detectedLabel = label("Detected: 0 events", size: 12, weight: .semibold, color: NSColor(hex: 0x2F8CFF)); detectedLabel.frame = NSRect(x: 52, y: h-610, width: 230, height: 20); root.addSubview(detectedLabel)
        eventInfo = label("Select an event on the timeline", size: 12, color: NSColor(hex: 0x8997A5)); eventInfo.frame = NSRect(x: 280, y: h-610, width: 600, height: 20); root.addSubview(eventInfo)

        let panelY: CGFloat = 62, panelH: CGFloat = max(185, h-665)
        let gap: CGFloat = 14
        let leftW = (w - 68 - gap*2) * 0.28, midW = (w - 68 - gap*2) * 0.42, rightW = (w - 68 - gap*2) * 0.30
        let p1 = PanelView(frame: NSRect(x: 34, y: panelY, width: leftW, height: panelH)); root.addSubview(p1)
        let p2 = PanelView(frame: NSRect(x: 34+leftW+gap, y: panelY, width: midW, height: panelH)); root.addSubview(p2)
        let p3 = PanelView(frame: NSRect(x: 34+leftW+gap+midW+gap, y: panelY, width: rightW, height: panelH)); root.addSubview(p3)

        addPanelTitle("DETECTION", to: p1, x: 16, y: panelH-30)
        let sensL = label("Sensitivity", size: 12); sensL.frame = NSRect(x: 16, y: panelH-68, width: 100, height: 20); p1.addSubview(sensL)
        sensitivitySlider = NSSlider(value: 0.72, minValue: 0, maxValue: 1, target: self, action: #selector(sensitivityChanged)); sensitivitySlider.frame = NSRect(x: 105, y: panelH-72, width: leftW-145, height: 24); p1.addSubview(sensitivitySlider)
        let note = label("Higher = more detected events", size: 11, color: NSColor(hex: 0x6F7D89)); note.frame = NSRect(x: 16, y: panelH-96, width: leftW-32, height: 18); p1.addSubview(note)
        let worst = button("Analyze", action: #selector(analyzeAudio)); worst.frame = NSRect(x: 16, y: 18, width: 110, height: 30); p1.addSubview(worst)

        addPanelTitle("EVENT / REPAIR", to: p2, x: 16, y: panelH-30)
        let good = button("GOOD", action: #selector(markGood)); good.frame = NSRect(x: 16, y: panelH-73, width: 82, height: 30); p2.addSubview(good)
        let bad = button("BAD", action: #selector(markBad)); bad.frame = NSRect(x: 104, y: panelH-73, width: 82, height: 30); p2.addSubview(bad)
        let target = button("TARGET", action: #selector(markTarget)); target.frame = NSRect(x: 192, y: panelH-73, width: 92, height: 30); p2.addSubview(target)
        let normal = button("NORMAL", action: #selector(markNormal)); normal.frame = NSRect(x: 290, y: panelH-73, width: 92, height: 30); p2.addSubview(normal)
        let repairTitle = label("Repair Strength", size: 12); repairTitle.frame = NSRect(x: 16, y: panelH-112, width: 120, height: 20); p2.addSubview(repairTitle)
        let repairSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil); repairSlider.frame = NSRect(x: 128, y: panelH-116, width: midW-162, height: 24); repairSlider.isEnabled = false; p2.addSubview(repairSlider)
        let coming = label("Repair engine: next build — first validate detection", size: 11, color: NSColor(hex: 0x6F7D89)); coming.frame = NSRect(x: 16, y: 18, width: midW-32, height: 20); p2.addSubview(coming)

        addPanelTitle("PREVIEW", to: p3, x: 16, y: panelH-30)
        playButton = button("▶ Play event", action: #selector(playSelected)); playButton.frame = NSRect(x: 16, y: panelH-75, width: 120, height: 32); p3.addSubview(playButton)
        loopButton = button("Loop OFF", action: #selector(toggleLoop)); loopButton.frame = NSRect(x: 145, y: panelH-75, width: 100, height: 32); p3.addSubview(loopButton)
        let ab = button("A/B — soon", action: #selector(abSoon)); ab.frame = NSRect(x: 16, y: panelH-116, width: 120, height: 30); ab.isEnabled = false; p3.addSubview(ab)

        status = label("READY — drop WAV/AIFF", size: 12, weight: .bold, color: NSColor(hex: 0x55D875)); status.frame = NSRect(x: 36, y: 20, width: w-72, height: 20); root.addSubview(status)
        let ver = label("Engine: Native   •   Auto update: ON   •   v\(RGVersion) BETA", size: 11, color: NSColor(hex: 0x75828E)); ver.alignment = .right; ver.frame = NSRect(x: w-470, y: 20, width: 430, height: 20); root.addSubview(ver)

        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openWav() {
        let p = NSOpenPanel(); p.allowedFileTypes = ["wav","wave","aif","aiff"]; p.allowsMultipleSelection = false; p.canChooseDirectories = false
        if p.runModal() == .OK, let u = p.url { loadAudio(u) }
    }

    private func loadAudio(_ url: URL) {
        status.stringValue = "LOADING AUDIO…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let m = AudioModel(); try m.load(url)
                DispatchQueue.main.async {
                    self.model = m; self.events = []; self.timeline.model = m; self.timeline.events = []; self.timeline.selectedIndex = nil
                    self.fileInfo.stringValue = "\(url.lastPathComponent)   •   \(Int(m.sampleRate)) Hz   •   \(m.channels) ch   •   \(String(format: "%.2f", m.duration)) s"
                    self.detectedLabel.stringValue = "Detected: 0 events"
                    self.eventInfo.stringValue = "Audio loaded — press Analyze"
                    self.status.stringValue = "AUDIO LOADED — ready to Analyze"
                }
            } catch {
                DispatchQueue.main.async { self.status.stringValue = "LOAD FAILED — \(error.localizedDescription)" }
            }
        }
    }

    @objc private func analyzeAudio() {
        guard !model.samples.isEmpty else { status.stringValue = "DROP WAV/AIFF FIRST"; return }
        status.stringValue = "ANALYZING SIBILANCE…"
        let samples = model.samples, sr = model.sampleRate, sens = sensitivitySlider.doubleValue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let found = self.detector.detect(samples: samples, sampleRate: sr, sensitivity: sens)
            DispatchQueue.main.async {
                self.events = found; self.timeline.events = found; self.timeline.selectedIndex = found.isEmpty ? nil : 0
                self.detectedLabel.stringValue = "Detected: \(found.count) events"
                self.status.stringValue = found.isEmpty ? "ANALYSIS DONE — no events detected" : "ANALYSIS DONE — click an event to inspect"
                if !found.isEmpty { self.selectEvent(0) }
            }
        }
    }

    @objc private func sensitivityChanged() { status.stringValue = "Sensitivity \(Int(sensitivitySlider.doubleValue * 100))% — press Analyze" }

    private func selectEvent(_ index: Int) {
        guard events.indices.contains(index) else { return }
        timeline.selectedIndex = index
        let e = events[index]
        eventInfo.stringValue = String(format: "#%03d   %@   %.3f–%.3f s   score %.2f   %@", index+1, e.kind, e.start, e.end, e.score, e.userLabel.isEmpty ? "UNRATED" : e.userLabel)
    }

    private func mark(_ value: String) {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { status.stringValue = "SELECT AN EVENT FIRST"; return }
        events[i].userLabel = value; timeline.events = events; selectEvent(i); status.stringValue = "EVENT #\(i+1) MARKED \(value)"
    }
    @objc private func markGood() { mark("GOOD") }
    @objc private func markBad() { mark("BAD") }
    @objc private func markTarget() { mark("TARGET") }
    @objc private func markNormal() { mark("NORMAL") }

    @objc private func toggleLoop() {
        loopEnabled.toggle(); loopButton.title = loopEnabled ? "Loop ON" : "Loop OFF"
    }

    @objc private func playSelected() {
        guard let url = model.url else { status.stringValue = "LOAD AUDIO FIRST"; return }
        do {
            stopTimer?.invalidate()
            let p = try AVAudioPlayer(contentsOf: url); p.delegate = self; player = p
            if let i = timeline.selectedIndex, events.indices.contains(i) {
                let e = events[i], pre = max(0, e.start - 0.30), post = min(model.duration, e.end + 0.40)
                p.currentTime = pre; p.play(); playButton.title = "■ Stop"
                let length = max(0.1, post - pre)
                stopTimer = Timer.scheduledTimer(withTimeInterval: length, repeats: false) { [weak self] _ in self?.finishPreview() }
                status.stringValue = String(format: "PLAYING EVENT #%d   %.3f–%.3f", i+1, e.start, e.end)
            } else {
                p.play(); playButton.title = "■ Stop"; status.stringValue = "PLAYING AUDIO"
            }
        } catch { status.stringValue = "PLAYBACK FAILED — \(error.localizedDescription)" }
    }

    private func finishPreview() {
        player?.stop(); playButton.title = "▶ Play event"
        if loopEnabled { playSelected() } else { status.stringValue = "READY" }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { playButton.title = "▶ Play event" }
    @objc private func abSoon() {}

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { return true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
