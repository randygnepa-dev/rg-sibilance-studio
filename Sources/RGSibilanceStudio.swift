import Cocoa
import AVFoundation
import Foundation

let RGVersion = "0.2.18"
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
    var channels: Int = 0
    var duration: Double = 0
    var peak: Float = 0
    var rms: Float = 0
    var overviewMin: [Float] = []
    var overviewMax: [Float] = []

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
        var energy = 0.0
        for x in samples {
            p = max(p, abs(x))
            energy += Double(x * x)
        }
        peak = p
        rms = samples.isEmpty ? 0 : Float(sqrt(energy / Double(samples.count)))
        buildOverview(binCount: 32768)
    }

    private func buildOverview(binCount: Int) {
        guard !samples.isEmpty else { overviewMin = []; overviewMax = []; return }
        let count = min(binCount, samples.count)
        overviewMin = Array(repeating: 0, count: count)
        overviewMax = Array(repeating: 0, count: count)
        let samplesPerBin = Double(samples.count) / Double(count)

        for bin in 0..<count {
            let start = min(samples.count - 1, Int(Double(bin) * samplesPerBin))
            let end = min(samples.count, max(start + 1, Int(Double(bin + 1) * samplesPerBin)))
            var mn = samples[start]
            var mx = samples[start]
            for i in start..<end {
                let x = samples[i]
                mn = min(mn, x)
                mx = max(mx, x)
            }
            overviewMin[bin] = mn
            overviewMax[bin] = mx
        }
    }
}

final class SibilanceDetector {
    func detect(
        samples: [Float],
        sampleRate: Double,
        sensitivity: Double,
        progress: @escaping (Double) -> Void
    ) -> [SibilanceEvent] {
        guard samples.count > 4096 else { progress(1); return [] }
        let frame = 1024
        let hop = 512
        let totalFrames = max(1, (samples.count - frame) / hop)
        var values: [(time: Double, value: Double, rms: Double, ratio: Double)] = []
        var i = 0
        var frameIndex = 0
        var lastProgressBucket = -1

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

            frameIndex += 1
            let p = min(0.86, Double(frameIndex) / Double(totalFrames) * 0.86)
            let bucket = Int(p * 100)
            if bucket != lastProgressBucket {
                lastProgressBucket = bucket
                progress(p)
            }
            i += hop
        }

        guard values.count > 10 else { progress(1); return [] }
        progress(0.89)
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
        progress(0.95)

        var merged: [(Double, Double, Double)] = []
        for item in raw {
            if let last = merged.last, item.0 - last.1 < 0.045 {
                merged[merged.count - 1] = (last.0, item.1, max(last.2, item.2))
            } else {
                merged.append(item)
            }
        }

        let result = merged.prefix(300).map { item in
            let kind = (item.1 - item.0) < 0.065 ? "T" : "S"
            return SibilanceEvent(
                start: item.0,
                end: item.1,
                peakTime: (item.0 + item.1) * 0.5,
                score: item.2,
                kind: kind,
                userLabel: ""
            )
        }
        progress(1)
        return result
    }
}

final class TimelineView: NSView {
    var model: AudioModel? {
        didSet {
            resetView()
            if let m = model { fixedVerticalScale = CGFloat(0.92 / max(0.02, Double(m.peak))) }
            needsDisplay = true
        }
    }
    var events: [SibilanceEvent] = [] { didSet { needsDisplay = true } }
    var selectedIndex: Int? { didSet { needsDisplay = true } }
    var playhead: Double = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    var onScrub: ((Double, Bool) -> Void)?
    var onAudioDrop: ((URL) -> Void)?
    var onAddSibilance: ((Double) -> Void)?
    var onDeleteEvent: ((Int) -> Void)?

    private var zoom = 1.0
    private var viewStart = 0.0
    private var fixedVerticalScale: CGFloat = 1
    private var scrubbing = false
    private var panning = false
    private var lastDragX: CGFloat = 0
    private var dragActive = false
    private var contextTime: Double = 0
    private var contextEventIndex: Int?
    private var rulerDragging = false
    private var highlightedTime: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    private var plotRect: NSRect {
        NSRect(x: 54, y: 34, width: max(120, bounds.width - 76), height: max(90, bounds.height - 58))
    }

    private var rulerRect: NSRect {
        NSRect(x: plotRect.minX, y: 0, width: plotRect.width, height: 32)
    }

    private var visibleDuration: Double {
        guard let m = model else { return 1 }
        return max(0.08, m.duration / zoom)
    }

    private var viewEnd: Double { viewStart + visibleDuration }

    private func resetView() {
        zoom = 1
        viewStart = 0
        playhead = 0
    }

    private func clampViewStart() {
        guard let m = model else { return }
        viewStart = min(max(0, viewStart), max(0, m.duration - visibleDuration))
    }

    private func timeForX(_ x: CGFloat) -> Double {
        let f = min(1, max(0, (x - plotRect.minX) / plotRect.width))
        return viewStart + Double(f) * visibleDuration
    }

    private func xForTime(_ t: Double) -> CGFloat {
        plotRect.minX + CGFloat((t - viewStart) / visibleDuration) * plotRect.width
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
        guard let m = model, m.duration > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard plotRect.contains(p) else { return }

        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            let anchor = timeForX(p.x)
            let factor = exp(Double(event.scrollingDeltaY) * 0.10)
            zoom = min(160, max(1, zoom * factor))
            let fraction = Double((p.x - plotRect.minX) / plotRect.width)
            viewStart = anchor - fraction * visibleDuration
        } else {
            viewStart += Double(event.scrollingDeltaX) / Double(max(1, plotRect.width)) * visibleDuration * 1.7
        }
        clampViewStart()
        needsDisplay = true
    }

    private func eventIndexNear(x: CGFloat, tolerance: CGFloat = 11) -> Int? {
        var best: Int?
        var distance = CGFloat.greatestFiniteMagnitude
        for (i, e) in events.enumerated() where e.peakTime >= viewStart && e.peakTime <= viewEnd {
            let d = abs(xForTime(e.peakTime) - x)
            if d <= tolerance && d < distance {
                distance = d
                best = i
            }
        }
        return best
    }

    override func rightMouseDown(with event: NSEvent) {
        guard model != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard plotRect.contains(p) else { return }
        contextTime = timeForX(p.x)
        contextEventIndex = eventIndexNear(x: p.x)
        playhead = contextTime
        window?.makeFirstResponder(self)

        let menu = NSMenu()
        if let i = contextEventIndex {
            selectedIndex = i
            onSelect?(i)
            let item = NSMenuItem(title: "Delete Sibilance", action: #selector(contextDeleteSibilance), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "Add Sibilance", action: #selector(contextAddSibilance), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func contextAddSibilance() {
        onAddSibilance?(contextTime)
    }

    @objc private func contextDeleteSibilance() {
        guard let i = contextEventIndex else { return }
        onDeleteEvent?(i)
        contextEventIndex = nil
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 51 || event.keyCode == 117), let i = selectedIndex {
            onDeleteEvent?(i)
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard model != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)

        if rulerRect.contains(p) {
            rulerDragging = true
            lastDragX = p.x
            let t = timeForX(p.x)
            playhead = t
            highlightedTime = t
            needsDisplay = true
            return
        }

        guard plotRect.contains(p) else { return }
        lastDragX = p.x
        panning = event.modifierFlags.contains(.option)
        scrubbing = !panning
        if scrubbing {
            let t = timeForX(p.x)
            playhead = t
            highlightedTime = t
            onScrub?(t, true)
            selectNearestEvent(at: t)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if rulerDragging {
            let dx = p.x - lastDragX
            viewStart -= Double(dx / max(1, plotRect.width)) * visibleDuration
            clampViewStart()
            lastDragX = p.x
            let t = timeForX(min(max(p.x, plotRect.minX), plotRect.maxX))
            playhead = t
            highlightedTime = t
            needsDisplay = true
        } else if panning {
            let dx = p.x - lastDragX
            viewStart -= Double(dx / max(1, plotRect.width)) * visibleDuration
            clampViewStart()
            lastDragX = p.x
            needsDisplay = true
        } else if scrubbing {
            let t = timeForX(p.x)
            playhead = t
            highlightedTime = t
            onScrub?(t, true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if scrubbing { onScrub?(playhead, false) }
        scrubbing = false
        panning = false
        rulerDragging = false
        needsDisplay = true
    }

    func followPlayback(to time: Double) {
        playhead = time
        highlightedTime = time
        guard let m = model, m.duration > 0, zoom > 1.02 else { return }
        let leftEdge = viewStart + visibleDuration * 0.12
        let rightEdge = viewStart + visibleDuration * 0.78
        if time > rightEdge {
            viewStart = time - visibleDuration * 0.62
            clampViewStart()
        } else if time < leftEdge {
            viewStart = time - visibleDuration * 0.12
            clampViewStart()
        }
        needsDisplay = true
    }

    private func selectNearestEvent(at t: Double) {
        guard !events.isEmpty else { return }
        var best = 0
        var d = Double.greatestFiniteMagnitude
        for (i, e) in events.enumerated() {
            let nd = abs(e.peakTime - t)
            if nd < d { d = nd; best = i }
        }
        selectedIndex = best
        onSelect?(best)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: 0x091119).setFill()
        bounds.fill()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
        NSColor(hex: dragActive ? 0x347AB8 : 0x263846).setStroke()
        border.lineWidth = dragActive ? 2 : 1
        border.stroke()
        NSColor(hex: dragActive ? 0x102C43 : 0x0E1B25).setFill()
        plotRect.fill()

        guard let m = model, !m.samples.isEmpty else {
            let title = dragActive ? "DROP AUDIO" : "DRAG & DROP WAV / AIFF"
            let sub = "Waveform, analýza aj editácia ostávajú v tomto okne"
            drawCentered(title, y: bounds.midY + 4, size: 20, color: .white, bold: true)
            drawCentered(sub, y: bounds.midY - 27, size: 12, color: NSColor(hex: 0x778895), bold: false)
            return
        }

        drawWaveform(m)
        drawEvents(m)
        drawPlayhead()
        drawTimeScale(m)
        drawInstructions()
    }

    private func drawCentered(_ text: String, y: CGFloat, size: CGFloat, color: NSColor, bold: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
            .foregroundColor: color
        ]
        let s = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: bounds.midX - s.width / 2, y: y), withAttributes: attrs)
    }

    private func drawWaveform(_ m: AudioModel) {
        guard !m.overviewMin.isEmpty else { return }
        let nBins = m.overviewMin.count
        let total = max(0.0001, m.duration)
        let startBin = max(0, min(nBins - 1, Int(viewStart / total * Double(nBins))))
        let endBin = max(startBin + 1, min(nBins, Int(viewEnd / total * Double(nBins)) + 1))
        let visibleBins = max(1, endBin - startBin)
        let columns = max(140, Int(plotRect.width))
        let binsPerColumn = Double(visibleBins) / Double(columns)
        let path = NSBezierPath()

        for column in 0..<columns {
            let b0 = min(endBin - 1, startBin + Int(Double(column) * binsPerColumn))
            let b1 = min(endBin, max(b0 + 1, startBin + Int(Double(column + 1) * binsPerColumn)))
            var mn = m.overviewMin[b0]
            var mx = m.overviewMax[b0]
            if b0 + 1 < b1 {
                for b in (b0 + 1)..<b1 {
                    mn = min(mn, m.overviewMin[b])
                    mx = max(mx, m.overviewMax[b])
                }
            }
            let x = plotRect.minX + CGFloat(column) / CGFloat(max(1, columns - 1)) * plotRect.width
            path.move(to: NSPoint(x: x, y: plotRect.midY + CGFloat(mn) * plotRect.height * 0.48 * fixedVerticalScale))
            path.line(to: NSPoint(x: x, y: plotRect.midY + CGFloat(mx) * plotRect.height * 0.48 * fixedVerticalScale))
        }

        NSColor(hex: 0x2F95FF).setStroke()
        path.lineWidth = 1
        path.stroke()

        let zero = NSBezierPath()
        zero.move(to: NSPoint(x: plotRect.minX, y: plotRect.midY))
        zero.line(to: NSPoint(x: plotRect.maxX, y: plotRect.midY))
        NSColor(hex: 0x203646).setStroke()
        zero.lineWidth = 0.5
        zero.stroke()
    }

    private func drawEvents(_ m: AudioModel) {
        for (i, e) in events.enumerated() where e.peakTime >= viewStart && e.peakTime <= viewEnd {
            let x = xForTime(e.peakTime)
            let color: NSColor
            switch e.userLabel {
            case "GOOD": color = .systemGreen
            case "BAD": color = .systemRed
            case "TARGET": color = .systemBlue
            case "NORMAL": color = .systemGray
            default: color = e.kind == "T" ? .systemOrange : .systemPink
            }
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: plotRect.minY))
            line.line(to: NSPoint(x: x, y: plotRect.maxY))
            color.setStroke()
            line.lineWidth = i == selectedIndex ? 2.5 : 0.9
            line.stroke()

            let badge = NSBezierPath(roundedRect: NSRect(x: x - 8, y: plotRect.maxY - 18, width: 16, height: 16), xRadius: 3, yRadius: 3)
            color.setFill()
            badge.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 9), .foregroundColor: NSColor.white]
            let s = e.kind.size(withAttributes: attrs)
            e.kind.draw(at: NSPoint(x: x - s.width / 2, y: plotRect.maxY - 17), withAttributes: attrs)
        }
    }

    private func drawPlayhead() {
        guard playhead >= viewStart && playhead <= viewEnd else { return }
        let x = xForTime(playhead)
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x, y: plotRect.minY))
        line.line(to: NSPoint(x: x, y: plotRect.maxY))
        NSColor.white.withAlphaComponent(0.75).setStroke()
        line.lineWidth = 1
        line.stroke()
    }

    private func drawTimeScale(_ m: AudioModel) {
        NSColor(hex: 0x0A141D).setFill()
        rulerRect.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor(hex: 0x718493)]
        for i in 0...5 {
            let t = viewStart + visibleDuration * Double(i) / 5
            let min = Int(t) / 60
            let sec = Int(t) % 60
            let text = String(format: "%d:%02d", min, sec)
            let x = plotRect.minX + plotRect.width * CGFloat(i) / 5
            text.draw(at: NSPoint(x: x - 12, y: 9), withAttributes: attrs)
        }
        if let t = highlightedTime, t >= viewStart && t <= viewEnd {
            let x = xForTime(t)
            let text = String(format: "%d:%02d.%03d", Int(t) / 60, Int(t) % 60, Int((t - floor(t)) * 1000))
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: a)
            let box = NSRect(x: min(max(plotRect.minX, x - size.width / 2 - 7), plotRect.maxX - size.width - 14), y: 4, width: size.width + 14, height: 20)
            NSColor(hex: 0x176BC1).setFill()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
            text.draw(at: NSPoint(x: box.minX + 7, y: box.minY + 4), withAttributes: a)
        }
    }

    private func drawInstructions() {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(hex: 0x60717E)]
        "Scroll: zoom   •   drag waveform: scrub   •   drag time ruler: move timeline   •   ⌥ drag: pan   •   Space: play/stop".draw(
            at: NSPoint(x: plotRect.minX + 8, y: bounds.height - 18),
            withAttributes: attrs
        )
    }
}

final class AnalysisProgressController {
    private var panel: NSPanel?
    private var indicator: NSProgressIndicator?
    private var percent: NSTextField?

    func show(over parent: NSWindow) {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 150),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        p.title = "Analyzing audio"
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 150))
        p.contentView = root

        let title = NSTextField(labelWithString: "Analyzujem sykavky…")
        title.font = NSFont.boldSystemFont(ofSize: 16)
        title.frame = NSRect(x: 24, y: 96, width: 340, height: 24)
        root.addSubview(title)

        let bar = NSProgressIndicator(frame: NSRect(x: 24, y: 59, width: 342, height: 18))
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        bar.doubleValue = 0
        root.addSubview(bar)

        let text = NSTextField(labelWithString: "0 %")
        text.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        text.alignment = .center
        text.frame = NSRect(x: 24, y: 29, width: 342, height: 22)
        root.addSubview(text)

        panel = p
        indicator = bar
        percent = text
        parent.beginSheet(p)
    }

    func update(_ value: Double) {
        let v = min(100, max(0, Int(value * 100)))
        indicator?.doubleValue = Double(v)
        percent?.stringValue = "\(v) %"
    }

    func close(parent: NSWindow) {
        if let p = panel { parent.endSheet(p) }
        panel = nil
        indicator = nil
        percent = nil
    }
}

final class UpdateManager {
    private var timer: Timer?
    private var busy = false
    var onStatus: ((String) -> Void)?

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.check() }
    }

    func forceRefresh() {
        check(force: true)
    }

    private func versionParts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } }

    private func newer(_ a: String, than b: String) -> Bool {
        let x = versionParts(a), y = versionParts(b), n = max(x.count, y.count)
        for i in 0..<n {
            let xv = i < x.count ? x[i] : 0
            let yv = i < y.count ? y[i] : 0
            if xv != yv { return xv > yv }
        }
        return false
    }

    private func check(force: Bool = false) {
        guard !busy, let url = URL(string: "\(RGRepoRaw)/VERSION?t=\(Date().timeIntervalSince1970)") else { return }
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
                self.onStatus?(force ? "REFRESHING LATEST INTERFACE — v\(remote)…" : "UPDATE \(remote) — applying…")
            }
            self.apply(remote)
        }.resume()
    }

    private func apply(_ version: String) {
        guard let sourceURL = URL(string: "\(RGRepoRaw)/Sources/RGSibilanceStudio.swift?t=\(Date().timeIntervalSince1970)") else { busy = false; return }
        URLSession.shared.dataTask(with: sourceURL) { [weak self] data, _, _ in
            guard let self = self, let data = data else { self?.busy = false; return }
            do {
                let fm = FileManager.default
                let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RG Sibilance Studio", isDirectory: true)
                try fm.createDirectory(at: base, withIntermediateDirectories: true)
                let source = base.appendingPathComponent("RGSibilanceStudio-\(version).swift")
                let binary = base.appendingPathComponent("RG Sibilance Studio-\(version)")
                let marker = base.appendingPathComponent("UPDATED_TO")
                try data.write(to: source, options: .atomic)

                let sdkProcess = Process()
                let sdkPipe = Pipe()
                sdkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                sdkProcess.arguments = ["--sdk", "macosx", "--show-sdk-path"]
                sdkProcess.standardOutput = sdkPipe
                try sdkProcess.run()
                sdkProcess.waitUntilExit()
                guard let sdk = String(data: sdkPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !sdk.isEmpty else { self.busy = false; return }

                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                p.arguments = ["--sdk", "macosx", "swiftc", source.path, "-sdk", sdk, "-o", binary.path, "-framework", "Cocoa", "-framework", "AVFoundation"]
                try p.run()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else {
                    self.busy = false
                    DispatchQueue.main.async { self.onStatus?("UPDATE FAILED — previous version kept") }
                    return
                }

                try version.write(to: marker, atomically: true, encoding: .utf8)
                DispatchQueue.main.async {
                    let launch = Process()
                    launch.executableURL = binary
                    try? launch.run()
                    NSApp.terminate(nil)
                }
            } catch {
                self.busy = false
                DispatchQueue.main.async { self.onStatus?("UPDATE FAILED — \(error.localizedDescription)") }
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
    private var repairSlider: NSSlider!
    private var analyzeButton: NSButton!
    private var playButton: NSButton!
    private var loopButton: NSButton!
    private var kindPopup: NSPopUpButton!
    private var typeTrimSlider: NSSlider!
    private var typeTrimValue: NSTextField!
    private var stopMode: NSSegmentedControl!

    private var model = AudioModel()
    private var events: [SibilanceEvent] = []
    private let detector = SibilanceDetector()
    private let progressUI = AnalysisProgressController()
    private let updater = UpdateManager()
    private var previewPlayer: AVAudioPlayer?
    private var scrubPlayer: AVAudioPlayer?
    private var stopTimer: Timer?
    private var loopEnabled = false
    private var keyMonitor: Any?
    private var transportTimer: Timer?
    private var transportPlaying = false
    private var transportStartTime: Double = 0
    private var typeTrims: [String: Double] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
        updater.onStatus = { [weak self] text in self?.status.stringValue = text }
        updater.start()
        showUpdateNoticeIfNeeded()
        installKeyboardTransport()
    }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = NSColor(hex: 0xAAB5C0)) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.systemFont(ofSize: size, weight: weight)
        f.textColor = color
        return f
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func buildUI() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(CGFloat(1400), screen.width - 36)
        let h = min(CGFloat(880), screen.height - 36)
        window = NSWindow(
            contentRect: NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RG Sibilance Studio \(RGVersion) BETA"
        window.backgroundColor = NSColor(hex: 0x0B1218)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(hex: 0x0B1218).cgColor
        window.contentView = root

        let title = label("RG Sibilance Studio", size: 27, weight: .bold, color: .white)
        title.frame = NSRect(x: 34, y: h - 67, width: 460, height: 36)
        root.addSubview(title)
        let subtitle = label("Sibilance detection & repair   •   AUTO UPDATE BETA", size: 12, color: NSColor(hex: 0x82919E))
        subtitle.frame = NSRect(x: 36, y: h - 93, width: 520, height: 20)
        root.addSubview(subtitle)

        analyzeButton = button("Analyze", action: #selector(analyzeAudio))
        analyzeButton.frame = NSRect(x: w - 323, y: h - 72, width: 125, height: 33)
        root.addSubview(analyzeButton)
        let open = button("Open WAV", action: #selector(openWav))
        open.frame = NSRect(x: w - 184, y: h - 72, width: 125, height: 33)
        root.addSubview(open)

        timeline = TimelineView(frame: NSRect(x: 34, y: h - 536, width: w - 68, height: 410))
        timeline.onAudioDrop = { [weak self] url in self?.loadAudio(url) }
        timeline.onSelect = { [weak self] i in self?.selectEvent(i) }
        timeline.onScrub = { [weak self] t, active in self?.scrub(to: t, active: active) }
        timeline.onAddSibilance = { [weak self] t in self?.addManualS(at: t) }
        timeline.onDeleteEvent = { [weak self] i in self?.deleteEvent(i) }
        root.addSubview(timeline)

        fileInfo = label("Drop WAV/AIFF directly into the waveform window", size: 11, color: NSColor(hex: 0x778895))
        fileInfo.frame = NSRect(x: 40, y: h - 560, width: w - 80, height: 19)
        root.addSubview(fileInfo)
        detectedLabel = label("Detected: 0 events", size: 11, weight: .semibold, color: .systemBlue)
        detectedLabel.frame = NSRect(x: 40, y: h - 583, width: 210, height: 18)
        root.addSubview(detectedLabel)
        eventInfo = label("Select an event or scrub the waveform", size: 11, color: NSColor(hex: 0x8696A3))
        eventInfo.frame = NSRect(x: 255, y: h - 583, width: 650, height: 18)
        root.addSubview(eventInfo)

        let panelY: CGFloat = 58
        let panelH = max(CGFloat(170), h - 650)
        let gap: CGFloat = 12
        let pw = (w - 68 - gap * 2) / 3
        let p1 = makePanel(NSRect(x: 34, y: panelY, width: pw, height: panelH))
        let p2 = makePanel(NSRect(x: 34 + pw + gap, y: panelY, width: pw, height: panelH))
        let p3 = makePanel(NSRect(x: 34 + (pw + gap) * 2, y: panelY, width: pw, height: panelH))
        root.addSubview(p1); root.addSubview(p2); root.addSubview(p3)

        addTitle("DETECTION", to: p1, y: panelH - 30)
        let sl = label("Sensitivity", size: 11)
        sl.frame = NSRect(x: 15, y: panelH - 69, width: 88, height: 18)
        p1.addSubview(sl)
        sensitivitySlider = NSSlider(value: 0.72, minValue: 0, maxValue: 1, target: self, action: #selector(sensitivityChanged))
        sensitivitySlider.frame = NSRect(x: 101, y: panelH - 72, width: pw - 132, height: 22)
        p1.addSubview(sensitivitySlider)
        let markS = button("+ Mark S at playhead", action: #selector(markManualS))
        markS.frame = NSRect(x: 15, y: 18, width: 155, height: 29)
        p1.addSubview(markS)

        addTitle("EVENT / REPAIR", to: p2, y: panelH - 30)
        let good = button("GOOD", action: #selector(markGood)); good.frame = NSRect(x: 15, y: panelH - 73, width: 74, height: 29)
        let bad = button("BAD", action: #selector(markBad)); bad.frame = NSRect(x: 94, y: panelH - 73, width: 72, height: 29)
        let target = button("TARGET", action: #selector(markTarget)); target.frame = NSRect(x: 171, y: panelH - 73, width: 82, height: 29)
        let normal = button("NORMAL", action: #selector(markNormal)); normal.frame = NSRect(x: 258, y: panelH - 73, width: 86, height: 29)
        p2.addSubview(good); p2.addSubview(bad); p2.addSubview(target); p2.addSubview(normal)
        let typeLabel = label("Detected type", size: 11)
        typeLabel.frame = NSRect(x: 15, y: panelH - 111, width: 90, height: 18)
        p2.addSubview(typeLabel)
        kindPopup = NSPopUpButton(frame: NSRect(x: 108, y: panelH - 116, width: 118, height: 25), pullsDown: false)
        kindPopup.addItems(withTitles: ["S", "Š", "Z", "C", "T", "D", "K", "P", "B", "F", "CH", "OTHER"])
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged)
        kindPopup.isEnabled = false
        p2.addSubview(kindPopup)

        let trimLabel = label("TYPE TRIM", size: 11)
        trimLabel.frame = NSRect(x: 15, y: panelH - 146, width: 88, height: 18)
        p2.addSubview(trimLabel)
        typeTrimSlider = NSSlider(value: 0, minValue: -12, maxValue: 0, target: self, action: #selector(typeTrimChanged))
        typeTrimSlider.frame = NSRect(x: 102, y: panelH - 149, width: pw - 185, height: 22)
        typeTrimSlider.isEnabled = false
        p2.addSubview(typeTrimSlider)
        typeTrimValue = label("0.0 dB", size: 10, weight: .semibold, color: NSColor(hex: 0x9DB4C5))
        typeTrimValue.alignment = .right
        typeTrimValue.frame = NSRect(x: pw - 79, y: panelH - 146, width: 62, height: 18)
        p2.addSubview(typeTrimValue)

        let rs = label("Repair Strength", size: 11); rs.frame = NSRect(x: 15, y: panelH - 178, width: 105, height: 18); p2.addSubview(rs)
        repairSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        repairSlider.frame = NSRect(x: 119, y: panelH - 181, width: pw - 150, height: 22)
        repairSlider.isEnabled = false
        p2.addSubview(repairSlider)
        let repairNote = label("TYPE TRIM applies to every event of the selected phoneme", size: 10, color: NSColor(hex: 0x667783))
        repairNote.frame = NSRect(x: 15, y: 18, width: pw - 30, height: 18)
        p2.addSubview(repairNote)

        addTitle("PREVIEW", to: p3, y: panelH - 30)
        playButton = button("▶ Play event", action: #selector(playSelected))
        playButton.frame = NSRect(x: 15, y: panelH - 73, width: 118, height: 30)
        p3.addSubview(playButton)
        loopButton = button("Loop OFF", action: #selector(toggleLoop))
        loopButton.frame = NSRect(x: 139, y: panelH - 73, width: 95, height: 30)
        p3.addSubview(loopButton)
        let stopLabel = label("SPACE stop", size: 10, color: NSColor(hex: 0x7F909D))
        stopLabel.frame = NSRect(x: 15, y: panelH - 112, width: 80, height: 18)
        p3.addSubview(stopLabel)
        stopMode = NSSegmentedControl(labels: ["CONTINUE", "RETURN"], trackingMode: .selectOne, target: self, action: nil)
        stopMode.selectedSegment = 0
        stopMode.frame = NSRect(x: 92, y: panelH - 117, width: 174, height: 27)
        p3.addSubview(stopMode)
        let prev = button("← Previous", action: #selector(previousEvent)); prev.frame = NSRect(x: 15, y: 18, width: 105, height: 29)
        let next = button("Next →", action: #selector(nextEvent)); next.frame = NSRect(x: 126, y: 18, width: 95, height: 29)
        p3.addSubview(prev); p3.addSubview(next)

        status = label("READY", size: 11, weight: .bold, color: .systemGreen)
        status.frame = NSRect(x: 36, y: 19, width: w - 72, height: 18)
        root.addSubview(status)
        let ver = label("Native engine   •   Auto update: ON   •   ⌘R Refresh latest   •   v\(RGVersion)", size: 10, color: NSColor(hex: 0x70808C))
        ver.alignment = .right
        ver.frame = NSRect(x: w - 420, y: 19, width: 380, height: 18)
        root.addSubview(ver)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePanel(_ frame: NSRect) -> NSBox {
        let p = NSBox(frame: frame)
        p.boxType = .custom
        p.borderColor = NSColor(hex: 0x263540)
        p.fillColor = NSColor(hex: 0x101820)
        p.cornerRadius = 8
        return p
    }

    private func addTitle(_ text: String, to view: NSView, y: CGFloat) {
        let l = label(text, size: 11, weight: .bold, color: .white)
        l.frame = NSRect(x: 15, y: y, width: 180, height: 18)
        view.addSubview(l)
    }

    private func showUpdateNoticeIfNeeded() {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RG Sibilance Studio", isDirectory: true)
        let marker = base.appendingPathComponent("UPDATED_TO")
        if let v = try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), v == RGVersion {
            try? FileManager.default.removeItem(at: marker)
            status.stringValue = "AUTO UPDATE COMPLETE — v\(RGVersion)"
        }
    }

    @objc private func openWav() {
        let p = NSOpenPanel()
        p.allowedFileTypes = ["wav", "wave", "aif", "aiff"]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url { loadAudio(url) }
    }

    private func loadAudio(_ url: URL) {
        status.stringValue = "LOADING AUDIO…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let m = AudioModel()
                try m.load(url)
                let scrub = try? AVAudioPlayer(contentsOf: url)
                DispatchQueue.main.async {
                    self.model = m
                    self.events = []
                    self.scrubPlayer = scrub
                    self.timeline.model = m
                    self.timeline.events = []
                    self.timeline.selectedIndex = nil
                    self.timeline.playhead = 0
                    self.fileInfo.stringValue = "\(url.lastPathComponent)   •   \(Int(m.sampleRate)) Hz   •   \(m.channels) ch   •   \(String(format: "%.2f", m.duration)) s"
                    self.detectedLabel.stringValue = "Detected: 0 events"
                    self.eventInfo.stringValue = "Audio loaded — analyzing automatically…"
                    self.status.stringValue = "AUDIO LOADED — starting automatic analysis…"
                    self.analyzeAudio()
                }
            } catch {
                DispatchQueue.main.async { self.status.stringValue = "LOAD FAILED — \(error.localizedDescription)" }
            }
        }
    }

    @objc private func analyzeAudio() {
        guard !model.samples.isEmpty else { status.stringValue = "DROP WAV/AIFF FIRST"; return }
        analyzeButton.isEnabled = false
        sensitivitySlider.isEnabled = false
        progressUI.show(over: window)
        let samples = model.samples
        let sr = model.sampleRate
        let sensitivity = sensitivitySlider.doubleValue

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let found = self.detector.detect(samples: samples, sampleRate: sr, sensitivity: sensitivity) { p in
                DispatchQueue.main.async { self.progressUI.update(p) }
            }
            DispatchQueue.main.async {
                self.events = found
                self.timeline.events = found
                self.timeline.selectedIndex = found.isEmpty ? nil : 0
                self.detectedLabel.stringValue = "Detected: \(found.count) events"
                if !found.isEmpty { self.selectEvent(0) }
                self.progressUI.close(parent: self.window)
                self.analyzeButton.isEnabled = true
                self.sensitivitySlider.isEnabled = true
                self.status.stringValue = found.isEmpty ? "ANALYSIS COMPLETE — no events" : "ANALYSIS COMPLETE"
            }
        }
    }

    @objc private func sensitivityChanged() {
        status.stringValue = "Sensitivity \(Int(sensitivitySlider.doubleValue * 100))% — press Analyze"
    }

    private func selectEvent(_ i: Int) {
        guard events.indices.contains(i) else { return }
        timeline.selectedIndex = i
        let e = events[i]
        kindPopup.isEnabled = true
        kindPopup.selectItem(withTitle: e.kind)
        typeTrimSlider.isEnabled = true
        let trim = typeTrims[e.kind] ?? 0
        typeTrimSlider.doubleValue = trim
        typeTrimValue.stringValue = String(format: "%.1f dB", trim)
        eventInfo.stringValue = String(format: "#%03d   %@   %.3f–%.3f s   score %.2f   %@   type trim %.1f dB", i + 1, e.kind, e.start, e.end, e.score, e.userLabel.isEmpty ? "UNRATED" : e.userLabel, trim)
    }

    @objc private func typeTrimChanged() {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { return }
        let kind = events[i].kind
        let value = typeTrimSlider.doubleValue
        typeTrims[kind] = value
        typeTrimValue.stringValue = String(format: "%.1f dB", value)
        selectEvent(i)
        let count = events.filter { $0.kind == kind }.count
        status.stringValue = String(format: "%@ TYPE TRIM %.1f dB — %d events", kind, value, count)
    }

    @objc private func kindChanged() {
        guard let i = timeline.selectedIndex, events.indices.contains(i), let title = kindPopup.selectedItem?.title else { return }
        events[i].kind = title
        timeline.events = events
        selectEvent(i)
        status.stringValue = "EVENT #\(i + 1) TYPE → \(title)"
    }

    private func mark(_ value: String) {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { status.stringValue = "SELECT AN EVENT FIRST"; return }
        events[i].userLabel = value
        timeline.events = events
        selectEvent(i)
        status.stringValue = "EVENT #\(i + 1) MARKED \(value)"
    }

    @objc private func markGood() { mark("GOOD") }
    @objc private func markBad() { mark("BAD") }
    @objc private func markTarget() { mark("TARGET") }
    @objc private func markNormal() { mark("NORMAL") }

    @objc private func markManualS() {
        addManualS(at: timeline.playhead)
    }

    private func addManualS(at t: Double) {
        guard model.duration > 0 else { return }
        let clamped = min(max(0, t), model.duration)
        let e = SibilanceEvent(start: max(0, clamped - 0.05), end: min(model.duration, clamped + 0.10), peakTime: clamped, score: 1, kind: "S", userLabel: "TARGET")
        events.append(e)
        events.sort { $0.peakTime < $1.peakTime }
        timeline.events = events
        timeline.playhead = clamped
        detectedLabel.stringValue = "Detected: \(events.count) events"
        if let i = events.firstIndex(where: { abs($0.peakTime - clamped) < 0.0001 }) { selectEvent(i) }
        status.stringValue = "MANUAL SIBILANCE ADDED"
    }

    private func deleteEvent(_ i: Int) {
        guard events.indices.contains(i) else { return }
        events.remove(at: i)
        timeline.events = events
        detectedLabel.stringValue = "Detected: \(events.count) events"
        if events.isEmpty {
            timeline.selectedIndex = nil
            kindPopup.isEnabled = false
            typeTrimSlider.isEnabled = false
            typeTrimValue.stringValue = "0.0 dB"
            eventInfo.stringValue = "No sibilance selected"
        } else {
            let next = min(i, events.count - 1)
            selectEvent(next)
            timeline.playhead = events[next].peakTime
        }
        status.stringValue = "SIBILANCE REMOVED"
    }

    @objc private func previousEvent() {
        guard !events.isEmpty else { return }
        let i = max(0, (timeline.selectedIndex ?? 0) - 1)
        selectEvent(i)
        timeline.playhead = events[i].peakTime
    }

    @objc private func nextEvent() {
        guard !events.isEmpty else { return }
        let i = min(events.count - 1, (timeline.selectedIndex ?? -1) + 1)
        selectEvent(i)
        timeline.playhead = events[i].peakTime
    }

    private func installKeyboardTransport() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
        }
    }

    private func toggleTransport() {
        transportPlaying ? stopTransport() : startTransport()
    }

    private func startTransport() {
        guard let p = scrubPlayer, model.duration > 0 else { return }
        previewPlayer?.stop()
        stopTimer?.invalidate()
        transportStartTime = min(max(0, timeline.playhead), max(0, p.duration - 0.01))
        p.currentTime = transportStartTime
        p.play()
        transportPlaying = true
        playButton.title = "■ Stop"
        status.stringValue = stopMode.selectedSegment == 1 ? "PLAYING — Space returns to start" : "PLAYING — Space continues from stop"
        transportTimer?.invalidate()
        transportTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.scrubPlayer else { return }
            self.timeline.followPlayback(to: player.currentTime)
            if !player.isPlaying && self.transportPlaying {
                self.transportPlaying = false
                self.transportTimer?.invalidate()
                self.playButton.title = "▶ Play event"
                self.status.stringValue = "PLAYBACK END"
            }
        }
    }

    private func stopTransport() {
        guard let p = scrubPlayer else { return }
        let stoppedAt = p.currentTime
        p.pause()
        transportPlaying = false
        transportTimer?.invalidate()
        transportTimer = nil
        if stopMode.selectedSegment == 1 {
            p.currentTime = transportStartTime
            timeline.followPlayback(to: transportStartTime)
            status.stringValue = "STOP — returned to start"
        } else {
            timeline.followPlayback(to: stoppedAt)
            status.stringValue = "STOP — locator stays at stop position"
        }
        playButton.title = "▶ Play event"
    }

    private func scrub(to time: Double, active: Bool) {
        guard let p = scrubPlayer else { return }
        if transportPlaying { stopTransport() }
        if active {
            p.currentTime = min(max(0, time), max(0, p.duration - 0.01))
            if !p.isPlaying { p.play() }
        } else {
            p.stop()
        }
    }

    @objc private func playSelected() {
        guard let url = model.url else { return }
        do {
            stopTimer?.invalidate()
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            previewPlayer = p
            if let i = timeline.selectedIndex, events.indices.contains(i) {
                let e = events[i]
                let pre = max(0, e.start - 0.30)
                let post = min(model.duration, e.end + 0.40)
                p.currentTime = pre
                p.play()
                playButton.title = "■ Stop"
                stopTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, post - pre), repeats: false) { [weak self] _ in self?.finishPreview() }
            } else {
                p.currentTime = timeline.playhead
                p.play()
            }
        } catch {
            status.stringValue = "PLAYBACK FAILED"
        }
    }

    @objc private func toggleLoop() {
        loopEnabled.toggle()
        loopButton.title = loopEnabled ? "Loop ON" : "Loop OFF"
    }

    private func finishPreview() {
        previewPlayer?.stop()
        playButton.title = "▶ Play event"
        if loopEnabled { playSelected() }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playButton.title = "▶ Play event"
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
