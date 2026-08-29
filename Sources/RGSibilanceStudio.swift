import Cocoa
import AVFoundation
import Foundation

let RGVersion = "0.2.12"
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
    var channels = 0
    var duration = 0.0
    var peak: Float = 0
    var rms: Float = 0

    func load(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw NSError(domain: "RG", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate audio buffer"])
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else {
            throw NSError(domain: "RG", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot read audio samples"])
        }

        self.url = url
        sampleRate = format.sampleRate
        channels = Int(format.channelCount)
        duration = Double(buffer.frameLength) / sampleRate
        let n = Int(buffer.frameLength)
        let c = max(1, channels)
        samples = Array(repeating: 0, count: n)

        for i in 0..<n {
            var sum: Float = 0
            for ch in 0..<c { sum += data[ch][i] }
            samples[i] = sum / Float(c)
        }

        var p: Float = 0
        var e = 0.0
        for x in samples {
            p = max(p, abs(x))
            e += Double(x * x)
        }
        peak = p
        rms = samples.isEmpty ? 0 : Float(sqrt(e / Double(samples.count)))
    }
}

final class SibilanceDetector {
    func detect(samples: [Float], sampleRate: Double, sensitivity: Double) -> [SibilanceEvent] {
        guard samples.count > 4096 else { return [] }
        let frame = 1024
        let hop = 512
        var values: [(time: Double, value: Double, rms: Double, ratio: Double)] = []
        var i = 0

        while i + frame < samples.count {
            var full = 0.0
            var diff = 0.0
            var prev = samples[i]
            var crossings = 0
            for j in i..<(i + frame) {
                let x = samples[j]
                full += Double(x * x)
                let d = x - prev
                diff += Double(d * d)
                if (x >= 0) != (prev >= 0) { crossings += 1 }
                prev = x
            }
            let frameRMS = sqrt(full / Double(frame))
            let ratio = sqrt(diff / max(full, 1e-12))
            let zcr = Double(crossings) / Double(frame)
            let gate = min(1.0, max(0.0, (frameRMS - 0.0015) / 0.025))
            let score = ratio * (0.55 + 2.5 * zcr) * (0.20 + 0.80 * gate)
            values.append((Double(i + frame / 2) / sampleRate, score, frameRMS, ratio))
            i += hop
        }

        guard values.count > 10 else { return [] }
        let sorted = values.map { $0.value }.sorted()
        let sens = min(1.0, max(0.0, sensitivity))
        let percentile = 0.90 - sens * 0.28
        let thresholdIndex = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * percentile)))
        let threshold = max(0.62, sorted[thresholdIndex])
        let frameDuration = Double(frame) / sampleRate
        var raw: [(Double, Double, Double)] = []
        var activeStart: Double?
        var bestScore = 0.0

        for metric in values {
            let active = metric.value >= threshold && metric.rms > 0.0015 && metric.ratio > 0.48
            if active {
                if activeStart == nil { activeStart = max(0, metric.time - frameDuration * 0.5) }
                bestScore = max(bestScore, metric.value)
            } else if let start = activeStart {
                let end = metric.time + frameDuration * 0.25
                if end - start >= 0.025 && end - start <= 0.55 { raw.append((start, end, bestScore)) }
                activeStart = nil
                bestScore = 0
            }
        }

        var merged: [(Double, Double, Double)] = []
        for item in raw {
            if let last = merged.last, item.0 - last.1 < 0.045 {
                merged[merged.count - 1] = (last.0, item.1, max(last.2, item.2))
            } else {
                merged.append(item)
            }
        }

        return merged.prefix(300).map { item in
            let kind = (item.1 - item.0) < 0.065 ? "T" : "S"
            return SibilanceEvent(start: item.0, end: item.1, peakTime: (item.0 + item.1) * 0.5, score: item.2, kind: kind, userLabel: "")
        }
    }
}

final class TimelineView: NSView {
    var model: AudioModel? { didSet { resetView(); needsDisplay = true } }
    var events: [SibilanceEvent] = [] { didSet { needsDisplay = true } }
    var selectedIndex: Int? { didSet { needsDisplay = true } }
    var playhead: Double = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    var onScrub: ((Double, Bool) -> Void)?
    var onAudioDrop: ((URL) -> Void)?

    private var zoom = 1.0
    private var viewStart = 0.0
    private var scrubbing = false
    private var panning = false
    private var lastDragX: CGFloat = 0
    private var dragActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var plotRect: NSRect {
        NSRect(x: 54, y: 28, width: max(120, bounds.width - 76), height: max(90, bounds.height - 48))
    }

    private var visibleDuration: Double {
        guard let model = model else { return 1 }
        return max(0.1, model.duration / zoom)
    }

    private var viewEnd: Double { viewStart + visibleDuration }

    private func resetView() {
        zoom = 1.0
        viewStart = 0
        playhead = 0
    }

    private func clampViewStart() {
        guard let model = model else { return }
        let maxStart = max(0, model.duration - visibleDuration)
        viewStart = min(max(0, viewStart), maxStart)
    }

    private func timeForX(_ x: CGFloat) -> Double {
        let fraction = min(1, max(0, (x - plotRect.minX) / plotRect.width))
        return viewStart + Double(fraction) * visibleDuration
    }

    private func xForTime(_ time: Double) -> CGFloat {
        CGFloat((time - viewStart) / visibleDuration) * plotRect.width + plotRect.minX
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
        dragActive = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragActive = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = audioURL(sender) else { return false }
        dragActive = false
        needsDisplay = true
        onAudioDrop?(url)
        return true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let model = model, model.duration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard plotRect.contains(point) else { return }

        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            let anchorTime = timeForX(point.x)
            let oldVisible = visibleDuration
            let factor = exp(Double(event.scrollingDeltaY) * 0.045)
            zoom = min(80.0, max(1.0, zoom * factor))
            let newVisible = visibleDuration
            let anchorFraction = Double((point.x - plotRect.minX) / plotRect.width)
            viewStart = anchorTime - anchorFraction * newVisible
            clampViewStart()
            if abs(oldVisible - newVisible) > 0.0001 { needsDisplay = true }
        } else {
            viewStart += Double(event.scrollingDeltaX) / Double(max(1, plotRect.width)) * visibleDuration
            clampViewStart()
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let model = model, model.duration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard plotRect.contains(point) else { return }

        lastDragX = point.x
        panning = event.modifierFlags.contains(.option)
        scrubbing = !panning

        if scrubbing {
            let t = timeForX(point.x)
            playhead = t
            onScrub?(t, true)
            selectNearestEvent(at: t)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model = model, model.duration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        if panning {
            let dx = point.x - lastDragX
            viewStart -= Double(dx / max(1, plotRect.width)) * visibleDuration
            clampViewStart()
            lastDragX = point.x
            needsDisplay = true
        } else if scrubbing {
            let t = timeForX(point.x)
            playhead = t
            onScrub?(t, true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if scrubbing { onScrub?(playhead, false) }
        scrubbing = false
        panning = false
    }

    private func selectNearestEvent(at time: Double) {
        guard !events.isEmpty else { return }
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, item) in events.enumerated() {
            let distance = abs(item.peakTime - time)
            if distance < bestDistance { bestDistance = distance; bestIndex = index }
        }
        selectedIndex = bestIndex
        onSelect?(bestIndex)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: 0x0A1118).setFill()
        bounds.fill()

        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor(hex: 0x22303C).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        NSColor(hex: dragActive ? 0x102A42 : 0x0F1B25).setFill()
        plotRect.fill()

        guard let model = model, !model.samples.isEmpty else {
            let title = dragActive ? "DROP AUDIO" : "DRAG & DROP WAV / AIFF"
            let sub = "Import aj analyzovaný waveform sú v tomto jednom okne"
            let a1: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: NSColor.white]
            let a2: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(hex: 0x7E8D99)]
            let z1 = title.size(withAttributes: a1), z2 = sub.size(withAttributes: a2)
            title.draw(at: NSPoint(x: bounds.midX - z1.width / 2, y: bounds.midY + 2), withAttributes: a1)
            sub.draw(at: NSPoint(x: bounds.midX - z2.width / 2, y: bounds.midY - 28), withAttributes: a2)
            return
        }

        drawWaveform(model)
        drawEvents(model)
        drawPlayhead(model)
        drawTimeScale(model)
        drawInstructions()
    }

    private func drawWaveform(_ model: AudioModel) {
        let startSample = min(model.samples.count - 1, max(0, Int(viewStart * model.sampleRate)))
        let endSample = min(model.samples.count, max(startSample + 1, Int(viewEnd * model.sampleRate)))
        let visibleSamples = max(1, endSample - startSample)
        let columns = max(120, Int(plotRect.width))
        let step = max(1, visibleSamples / columns)

        var visiblePeak: Float = 0
        var scan = startSample
        while scan < endSample {
            visiblePeak = max(visiblePeak, abs(model.samples[scan]))
            scan += step
        }
        let scale = CGFloat(0.90 / max(0.02, Double(visiblePeak)))
        let waveform = NSBezierPath()

        for column in 0..<columns {
            let s = min(endSample - 1, startSample + column * step)
            let e = min(endSample, s + step)
            var mn = model.samples[s]
            var mx = mn
            if s < e {
                for i in s..<e {
                    mn = min(mn, model.samples[i])
                    mx = max(mx, model.samples[i])
                }
            }
            let x = plotRect.minX + CGFloat(column) / CGFloat(max(1, columns - 1)) * plotRect.width
            let y1 = plotRect.midY + CGFloat(mn) * plotRect.height * 0.48 * scale
            let y2 = plotRect.midY + CGFloat(mx) * plotRect.height * 0.48 * scale
            waveform.move(to: NSPoint(x: x, y: y1))
            waveform.line(to: NSPoint(x: x, y: y2))
        }

        NSColor(hex: 0x2F95FF).setStroke()
        waveform.lineWidth = 1
        waveform.stroke()

        let mid = NSBezierPath()
        mid.move(to: NSPoint(x: plotRect.minX, y: plotRect.midY))
        mid.line(to: NSPoint(x: plotRect.maxX, y: plotRect.midY))
        NSColor(hex: 0x203646).setStroke()
        mid.lineWidth = 0.5
        mid.stroke()
    }

    private func drawEvents(_ model: AudioModel) {
        for (index, item) in events.enumerated() where item.peakTime >= viewStart && item.peakTime <= viewEnd {
            let x = xForTime(item.peakTime)
            let color: NSColor
            switch item.userLabel {
            case "GOOD": color = .systemGreen
            case "BAD": color = .systemRed
            case "TARGET": color = .systemBlue
            case "NORMAL": color = .systemGray
            default: color = item.kind == "T" ? .systemOrange : .systemPink
            }
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: plotRect.minY))
            line.line(to: NSPoint(x: x, y: plotRect.maxY))
            color.setStroke()
            line.lineWidth = index == selectedIndex ? 2.5 : 1
            line.stroke()

            let badge = NSBezierPath(roundedRect: NSRect(x: x - 9, y: plotRect.maxY - 19, width: 18, height: 17), xRadius: 4, yRadius: 4)
            color.setFill(); badge.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white]
            let sz = item.kind.size(withAttributes: attrs)
            item.kind.draw(at: NSPoint(x: x - sz.width / 2, y: plotRect.maxY - 18), withAttributes: attrs)
        }
    }

    private func drawPlayhead(_ model: AudioModel) {
        guard playhead >= viewStart && playhead <= viewEnd else { return }
        let x = xForTime(playhead)
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x, y: plotRect.minY))
        line.line(to: NSPoint(x: x, y: plotRect.maxY))
        NSColor.white.withAlphaComponent(0.55).setStroke()
        line.lineWidth = 1
        line.stroke()
    }

    private func drawTimeScale(_ model: AudioModel) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor(hex: 0x748392)]
        for i in 0...5 {
            let t = viewStart + visibleDuration * Double(i) / 5.0
            let min = Int(t) / 60
            let sec = Int(t) % 60
            let text = String(format: "%d:%02d", min, sec)
            let x = plotRect.minX + plotRect.width * CGFloat(i) / 5.0
            text.draw(at: NSPoint(x: x - 12, y: 8), withAttributes: attrs)
        }
    }

    private func drawInstructions() {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(hex: 0x607383)]
        let text = "Wheel: zoom   •   drag: scrub/listen   •   ⌥ drag: pan   •   horizontal scroll: pan"
        text.draw(at: NSPoint(x: plotRect.minX, y: bounds.height - 18), withAttributes: attrs)
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
    private var repairSlider: NSSlider!

    private var player: AVAudioPlayer?
    private var stopTimer: Timer?
    private var scrubStopTimer: Timer?
    private var loopEnabled = false
    private var model = AudioModel()
    private var events: [SibilanceEvent] = []
    private let detector = SibilanceDetector()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
        showUpdateNotice()
    }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = NSColor(hex: 0xAAB5C0)) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func buildUI() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
        let width = min(CGFloat(1380), screen.width - 36)
        let height = min(CGFloat(860), screen.height - 36)

        window = NSWindow(
            contentRect: NSRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RG Sibilance Studio \(RGVersion) BETA"
        window.backgroundColor = NSColor(hex: 0x091016)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(hex: 0x091016).cgColor
        window.contentView = root

        let title = label("RG Sibilance Studio", size: 27, weight: .bold, color: .white)
        title.frame = NSRect(x: 30, y: height - 63, width: 450, height: 36)
        root.addSubview(title)

        let subtitle = label("Detect • inspect • teach • repair", size: 12, color: NSColor(hex: 0x748392))
        subtitle.frame = NSRect(x: 32, y: height - 87, width: 420, height: 18)
        root.addSubview(subtitle)

        let analyze = button("Analyze", action: #selector(analyzeAudio))
        analyze.frame = NSRect(x: width - 175, y: height - 66, width: 125, height: 32)
        root.addSubview(analyze)

        timeline = TimelineView(frame: NSRect(x: 30, y: height - 455, width: width - 60, height: 335))
        timeline.onAudioDrop = { [weak self] url in self?.loadAudio(url) }
        timeline.onSelect = { [weak self] index in self?.selectEvent(index) }
        timeline.onScrub = { [weak self] time, dragging in self?.scrub(to: time, dragging: dragging) }
        root.addSubview(timeline)

        fileInfo = label("Drop WAV/AIFF directly into the waveform area", size: 12, weight: .medium)
        fileInfo.frame = NSRect(x: 38, y: height - 479, width: width - 76, height: 19)
        root.addSubview(fileInfo)

        detectedLabel = label("Detected: 0 events", size: 12, weight: .semibold, color: .systemBlue)
        detectedLabel.frame = NSRect(x: 38, y: height - 505, width: 220, height: 19)
        root.addSubview(detectedLabel)

        eventInfo = label("Select an event or scrub the waveform", size: 12, color: NSColor(hex: 0x83909C))
        eventInfo.frame = NSRect(x: 250, y: height - 505, width: 700, height: 19)
        root.addSubview(eventInfo)

        let panelY: CGFloat = 58
        let panelH = max(CGFloat(190), height - 585)
        let gap: CGFloat = 12
        let panelW = (width - 60 - gap * 2) / 3

        let detectionPanel = makePanel(frame: NSRect(x: 30, y: panelY, width: panelW, height: panelH), root: root)
        let eventPanel = makePanel(frame: NSRect(x: 30 + panelW + gap, y: panelY, width: panelW, height: panelH), root: root)
        let previewPanel = makePanel(frame: NSRect(x: 30 + (panelW + gap) * 2, y: panelY, width: panelW, height: panelH), root: root)

        addPanelTitle("DETECTION", panel: detectionPanel, height: panelH)
        let sensitivityLabel = label("Sensitivity", size: 12)
        sensitivityLabel.frame = NSRect(x: 16, y: panelH - 67, width: 90, height: 18)
        detectionPanel.addSubview(sensitivityLabel)
        sensitivitySlider = NSSlider(value: 0.72, minValue: 0, maxValue: 1, target: self, action: #selector(sensitivityChanged))
        sensitivitySlider.frame = NSRect(x: 108, y: panelH - 71, width: panelW - 138, height: 22)
        detectionPanel.addSubview(sensitivitySlider)
        let addManual = button("+ Mark S at playhead", action: #selector(addManualEvent))
        addManual.frame = NSRect(x: 16, y: 18, width: 150, height: 30)
        detectionPanel.addSubview(addManual)

        addPanelTitle("EVENT / REPAIR", panel: eventPanel, height: panelH)
        let good = button("GOOD", action: #selector(markGood)); good.frame = NSRect(x: 16, y: panelH - 72, width: 72, height: 29)
        let bad = button("BAD", action: #selector(markBad)); bad.frame = NSRect(x: 93, y: panelH - 72, width: 72, height: 29)
        let target = button("TARGET", action: #selector(markTarget)); target.frame = NSRect(x: 170, y: panelH - 72, width: 80, height: 29)
        let normal = button("NORMAL", action: #selector(markNormal)); normal.frame = NSRect(x: 255, y: panelH - 72, width: 85, height: 29)
        [good, bad, target, normal].forEach { eventPanel.addSubview($0) }

        let repairLabel = label("LESS S", size: 11, color: NSColor(hex: 0x8997A5)); repairLabel.frame = NSRect(x: 16, y: panelH - 113, width: 50, height: 18); eventPanel.addSubview(repairLabel)
        repairSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: self, action: #selector(repairChanged))
        repairSlider.frame = NSRect(x: 68, y: panelH - 117, width: panelW - 136, height: 22)
        eventPanel.addSubview(repairSlider)
        let more = label("MORE S", size: 11, color: NSColor(hex: 0x8997A5)); more.alignment = .right; more.frame = NSRect(x: panelW - 66, y: panelH - 113, width: 50, height: 18); eventPanel.addSubview(more)
        let repairMode = label("Auto repair preview comes next; labels already persist in-session.", size: 10, color: NSColor(hex: 0x607383)); repairMode.frame = NSRect(x: 16, y: 18, width: panelW - 32, height: 18); eventPanel.addSubview(repairMode)

        addPanelTitle("PREVIEW / NAVIGATION", panel: previewPanel, height: panelH)
        playButton = button("▶ Play event", action: #selector(playSelected)); playButton.frame = NSRect(x: 16, y: panelH - 72, width: 115, height: 30); previewPanel.addSubview(playButton)
        loopButton = button("Loop OFF", action: #selector(toggleLoop)); loopButton.frame = NSRect(x: 138, y: panelH - 72, width: 95, height: 30); previewPanel.addSubview(loopButton)
        let prev = button("← Previous", action: #selector(previousEvent)); prev.frame = NSRect(x: 16, y: panelH - 112, width: 105, height: 29); previewPanel.addSubview(prev)
        let next = button("Next →", action: #selector(nextEvent)); next.frame = NSRect(x: 128, y: panelH - 112, width: 105, height: 29); previewPanel.addSubview(next)

        status = label("READY — drop WAV/AIFF into waveform", size: 11, weight: .bold, color: .systemGreen)
        status.frame = NSRect(x: 32, y: 18, width: width - 64, height: 18)
        root.addSubview(status)

        let version = label("Native engine   •   auto update ON   •   v\(RGVersion)", size: 10, color: NSColor(hex: 0x64727D))
        version.alignment = .right
        version.frame = NSRect(x: width - 420, y: 18, width: 380, height: 18)
        root.addSubview(version)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePanel(frame: NSRect, root: NSView) -> NSBox {
        let panel = NSBox(frame: frame)
        panel.boxType = .custom
        panel.fillColor = NSColor(hex: 0x101820)
        panel.borderColor = NSColor(hex: 0x22303C)
        panel.borderWidth = 1
        panel.cornerRadius = 8
        root.addSubview(panel)
        return panel
    }

    private func addPanelTitle(_ text: String, panel: NSView, height: CGFloat) {
        let title = label(text, size: 11, weight: .bold, color: .white)
        title.frame = NSRect(x: 16, y: height - 31, width: 180, height: 18)
        panel.addSubview(title)
    }

    private func showUpdateNotice() {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RG Sibilance Studio", isDirectory: true)
        let marker = base.appendingPathComponent("UPDATED_TO")
        if let value = try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), value == RGVersion {
            try? FileManager.default.removeItem(at: marker)
            status.stringValue = "AUTO UPDATE COMPLETE — v\(RGVersion)"
        }
    }

    private func loadAudio(_ url: URL) {
        status.stringValue = "LOADING AUDIO…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let newModel = AudioModel()
                try newModel.load(url)
                DispatchQueue.main.async {
                    self.model = newModel
                    self.events = []
                    self.timeline.model = newModel
                    self.timeline.events = []
                    self.timeline.selectedIndex = nil
                    self.fileInfo.stringValue = "\(url.lastPathComponent)   •   \(Int(newModel.sampleRate)) Hz   •   \(newModel.channels) ch   •   \(String(format: "%.2f", newModel.duration)) s"
                    self.detectedLabel.stringValue = "Detected: 0 events"
                    self.eventInfo.stringValue = "Audio loaded — press Analyze"
                    self.status.stringValue = "AUDIO LOADED — waveform fitted vertically"
                }
            } catch {
                DispatchQueue.main.async { self.status.stringValue = "LOAD FAILED — \(error.localizedDescription)" }
            }
        }
    }

    @objc private func analyzeAudio() {
        guard !model.samples.isEmpty else { status.stringValue = "DROP WAV/AIFF FIRST"; return }
        status.stringValue = "ANALYZING SIBILANCE…"
        let samples = model.samples
        let sr = model.sampleRate
        let sensitivity = sensitivitySlider.doubleValue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let found = self.detector.detect(samples: samples, sampleRate: sr, sensitivity: sensitivity)
            DispatchQueue.main.async {
                self.events = found
                self.timeline.events = found
                self.timeline.selectedIndex = found.isEmpty ? nil : 0
                self.detectedLabel.stringValue = "Detected: \(found.count) events"
                self.status.stringValue = found.isEmpty ? "ANALYSIS DONE — no events" : "ANALYSIS DONE — click or scrub to inspect"
                if !found.isEmpty { self.selectEvent(0) }
            }
        }
    }

    private func scrub(to time: Double, dragging: Bool) {
        timeline.playhead = time
        eventInfo.stringValue = String(format: "Playhead %.3f s", time)
        guard let url = model.url else { return }
        do {
            if player == nil || player?.url != url { player = try AVAudioPlayer(contentsOf: url) }
            guard let p = player else { return }
            p.currentTime = min(max(0, time), model.duration)
            if dragging {
                if !p.isPlaying { p.play() }
                scrubStopTimer?.invalidate()
                scrubStopTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in self?.player?.pause() }
            } else {
                scrubStopTimer?.invalidate()
                p.pause()
            }
        } catch { status.stringValue = "SCRUB FAILED" }
    }

    private func selectEvent(_ index: Int) {
        guard events.indices.contains(index) else { return }
        timeline.selectedIndex = index
        let item = events[index]
        timeline.playhead = item.peakTime
        eventInfo.stringValue = String(format: "#%03d   %@   %.3f–%.3f s   score %.2f   %@", index + 1, item.kind, item.start, item.end, item.score, item.userLabel.isEmpty ? "UNRATED" : item.userLabel)
    }

    private func mark(_ value: String) {
        guard let index = timeline.selectedIndex, events.indices.contains(index) else { status.stringValue = "SELECT AN EVENT FIRST"; return }
        events[index].userLabel = value
        timeline.events = events
        selectEvent(index)
        status.stringValue = "EVENT #\(index + 1) MARKED \(value)"
    }

    @objc private func markGood() { mark("GOOD") }
    @objc private func markBad() { mark("BAD") }
    @objc private func markTarget() { mark("TARGET") }
    @objc private func markNormal() { mark("NORMAL") }

    @objc private func addManualEvent() {
        guard !model.samples.isEmpty else { return }
        let center = timeline.playhead
        let start = max(0, center - 0.06)
        let end = min(model.duration, center + 0.08)
        let event = SibilanceEvent(start: start, end: end, peakTime: center, score: 1.0, kind: "S", userLabel: "TARGET")
        events.append(event)
        events.sort { $0.peakTime < $1.peakTime }
        timeline.events = events
        if let index = events.firstIndex(where: { abs($0.peakTime - center) < 0.0001 }) { selectEvent(index) }
        detectedLabel.stringValue = "Detected: \(events.count) events"
        status.stringValue = "MANUAL S ADDED"
    }

    @objc private func sensitivityChanged() {
        status.stringValue = "Sensitivity \(Int(sensitivitySlider.doubleValue * 100))% — press Analyze"
    }

    @objc private func repairChanged() {
        status.stringValue = "Repair strength \(Int(repairSlider.doubleValue * 100))% — processing engine next"
    }

    @objc private func previousEvent() {
        guard !events.isEmpty else { return }
        let current = timeline.selectedIndex ?? 0
        selectEvent(max(0, current - 1))
    }

    @objc private func nextEvent() {
        guard !events.isEmpty else { return }
        let current = timeline.selectedIndex ?? -1
        selectEvent(min(events.count - 1, current + 1))
    }

    @objc private func toggleLoop() {
        loopEnabled.toggle()
        loopButton.title = loopEnabled ? "Loop ON" : "Loop OFF"
    }

    @objc private func playSelected() {
        guard let url = model.url else { return }
        do {
            stopTimer?.invalidate()
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            player = p

            if let index = timeline.selectedIndex, events.indices.contains(index) {
                let item = events[index]
                let pre = max(0, item.start - 0.30)
                let post = min(model.duration, item.end + 0.40)
                p.currentTime = pre
                p.play()
                timeline.playhead = pre
                playButton.title = "■ Stop"
                stopTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, post - pre), repeats: false) { [weak self] _ in self?.finishPreview() }
            } else {
                p.currentTime = timeline.playhead
                p.play()
                playButton.title = "■ Stop"
            }
        } catch { status.stringValue = "PLAYBACK FAILED" }
    }

    private func finishPreview() {
        player?.stop()
        playButton.title = "▶ Play event"
        if loopEnabled { playSelected() } else { status.stringValue = "READY" }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playButton.title = "▶ Play event"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
