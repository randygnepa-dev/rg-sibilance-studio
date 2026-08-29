import Cocoa
import AVFoundation
import Foundation

let RGVersion = "0.2.23"
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

struct SibilanceEvent: Codable {
    var start: Double
    var end: Double
    var peakTime: Double
    var score: Double
    var kind: String
    var userLabel: String
    var gainDB: Double = 0
    var fadeIn: Double = 0.012
    var fadeOut: Double = 0.012
}

struct FileSession: Codable {
    var path: String
    var fileSize: UInt64
    var modificationTime: Double
    var duration: Double
    var sampleRate: Double
    var events: [SibilanceEvent]
    var typeTrims: [String: Double]
    var sensitivity: Double?
    var playhead: Double?
    var selectedIndex: Int?
    var auditionMode: Int?
}

final class SessionStore {
    private let fm = FileManager.default

    private var directory: URL {
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RG Sibilance Studio/Sessions", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func stableHash(_ text: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for b in text.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        return String(format: "%016llx", hash)
    }

    private func sessionURL(for url: URL) -> URL {
        directory.appendingPathComponent(stableHash(url.standardizedFileURL.path) + ".json")
    }

    private func signature(_ url: URL) -> (UInt64, Double)? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              let date = attrs[.modificationDate] as? Date else { return nil }
        return (size.uint64Value, date.timeIntervalSince1970)
    }

    func load(for url: URL, duration: Double, sampleRate: Double) -> FileSession? {
        guard let sig = signature(url),
              let data = try? Data(contentsOf: sessionURL(for: url)),
              let session = try? JSONDecoder().decode(FileSession.self, from: data) else { return nil }
        guard session.path == url.standardizedFileURL.path,
              session.fileSize == sig.0,
              abs(session.modificationTime - sig.1) < 0.001,
              abs(session.duration - duration) < 0.001,
              abs(session.sampleRate - sampleRate) < 0.5 else { return nil }
        return session
    }

    func save(for url: URL, duration: Double, sampleRate: Double, events: [SibilanceEvent], typeTrims: [String: Double], sensitivity: Double, playhead: Double, selectedIndex: Int?, auditionMode: Int) {
        guard let sig = signature(url) else { return }
        let session = FileSession(path: url.standardizedFileURL.path, fileSize: sig.0, modificationTime: sig.1, duration: duration, sampleRate: sampleRate, events: events, typeTrims: typeTrims, sensitivity: sensitivity, playhead: playhead, selectedIndex: selectedIndex, auditionMode: auditionMode)
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: sessionURL(for: url), options: .atomic)
    }
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
    var spectralBands = RGSpectralBands(hopSamples: 512, sampleRate: 48000, values: [])

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
        buildOverview(binCount: 131072)
        spectralBands = RGSpectralAnalyzer.makeBands(samples: samples, sampleRate: sampleRate, hopSamples: 512)
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
    var onEventBoundsChanged: ((Int, Double, Double) -> Void)?
    var onPlayEvent: ((Int) -> Void)?
    var onEventGainChanged: ((Int, Double) -> Void)?
    var onEventFadesChanged: ((Int, Double, Double) -> Void)?
    var onCreateEventRegion: ((Double, Double) -> Void)?

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
    private var boundaryDrag: Int = 0
    private var gainDragIndex: Int?
    private var fadeDragIndex: Int?
    private var fadeDragSide: Int = 0
    private var selectingRegion = false
    private var selectionAnchor: Double?
    private var selectionCurrent: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    private var plotRect: NSRect {
        NSRect(x: 58, y: 48, width: max(120, bounds.width - 82), height: max(90, bounds.height - 72))
    }

    private var rulerRect: NSRect {
        NSRect(x: plotRect.minX, y: 0, width: plotRect.width, height: 44)
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
            zoom = min(640, max(1, zoom * factor))
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

        if event.modifierFlags.contains(.shift) {
            selectingRegion = true
            let t = timeForX(p.x)
            selectionAnchor = t
            selectionCurrent = t
            playhead = t
            highlightedTime = t
            needsDisplay = true
            return
        }

        if let i = eventIndexAtBadge(p) {
            selectedIndex = i
            onSelect?(i)
            playhead = events[i].start
            highlightedTime = events[i].start
            onPlayEvent?(i)
            needsDisplay = true
            return
        }

        if let i = selectedIndex, events.indices.contains(i), gainFaderRect(for: i).contains(p) {
            gainDragIndex = i
            updateGainDrag(i, y: p.y)
            return
        }

        if let i = selectedIndex, events.indices.contains(i) {
            let e = events[i]
            let inX = xForTime(min(e.end, e.start + e.fadeIn))
            let outX = xForTime(max(e.start, e.end - e.fadeOut))
            if abs(p.x - inX) <= 9 && abs(p.y - plotRect.midY) <= 42 {
                fadeDragIndex = i
                fadeDragSide = -1
                return
            }
            if abs(p.x - outX) <= 9 && abs(p.y - plotRect.midY) <= 42 {
                fadeDragIndex = i
                fadeDragSide = 1
                return
            }
        }

        if let i = selectedIndex, events.indices.contains(i) {
            let selected = events[i]
            let startX = xForTime(selected.start)
            let endX = xForTime(selected.end)
            if abs(p.x - startX) <= 9 {
                boundaryDrag = -1
                playhead = selected.start
                highlightedTime = selected.start
                needsDisplay = true
                return
            }
            if abs(p.x - endX) <= 9 {
                boundaryDrag = 1
                playhead = selected.end
                highlightedTime = selected.end
                needsDisplay = true
                return
            }
        }

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
        if selectingRegion {
            let t = timeForX(min(max(p.x, plotRect.minX), plotRect.maxX))
            selectionCurrent = t
            playhead = t
            highlightedTime = t
            needsDisplay = true
        } else if let i = gainDragIndex, events.indices.contains(i) {
            updateGainDrag(i, y: p.y)
        } else if let i = fadeDragIndex, events.indices.contains(i) {
            updateFadeDrag(i, side: fadeDragSide, x: p.x)
        } else if boundaryDrag != 0, let i = selectedIndex, events.indices.contains(i), let m = model {
            var e = events[i]
            let t = min(max(0, timeForX(min(max(p.x, plotRect.minX), plotRect.maxX))), m.duration)
            let minimumLength = 0.015
            if boundaryDrag < 0 {
                e.start = min(t, e.end - minimumLength)
            } else {
                e.end = max(t, e.start + minimumLength)
            }
            e.peakTime = (e.start + e.end) * 0.5
            events[i] = e
            playhead = boundaryDrag < 0 ? e.start : e.end
            highlightedTime = playhead
            onEventBoundsChanged?(i, e.start, e.end)
            needsDisplay = true
        } else if rulerDragging {
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
        if selectingRegion, let a = selectionAnchor, let b = selectionCurrent {
            let start = min(a, b)
            let end = max(a, b)
            selectingRegion = false
            selectionAnchor = nil
            selectionCurrent = nil
            if end - start >= 0.015 { onCreateEventRegion?(start, end) }
        }
        if scrubbing { onScrub?(playhead, false) }
        scrubbing = false
        panning = false
        rulerDragging = false
        boundaryDrag = 0
        gainDragIndex = nil
        fadeDragIndex = nil
        fadeDragSide = 0
        needsDisplay = true
    }

    private func eventIndexAtBadge(_ point: NSPoint) -> Int? {
        for (i, e) in events.enumerated() where e.end >= viewStart && e.start <= viewEnd {
            let centerX = xForTime(e.peakTime)
            let selected = i == selectedIndex
            let width: CGFloat = selected ? 48 : 30
            let height: CGFloat = selected ? 28 : 20
            let rect = NSRect(x: centerX - width / 2, y: plotRect.maxY - height - 4, width: width, height: height)
            if rect.contains(point) { return i }
        }
        return nil
    }

    private func gainFaderRect(for i: Int) -> NSRect {
        guard events.indices.contains(i) else { return .zero }
        let centerX = xForTime(events[i].peakTime)
        return NSRect(x: centerX - 28, y: plotRect.midY - 54, width: 56, height: 108)
    }

    private func updateGainDrag(_ i: Int, y: CGFloat) {
        guard events.indices.contains(i) else { return }
        let range: CGFloat = 48
        let clampedY = min(plotRect.midY + range, max(plotRect.midY - range, y))
        let normalized = Double((clampedY - (plotRect.midY - range)) / (range * 2))
        let value = -18.0 + normalized * 18.0
        events[i].gainDB = min(0, max(-18, value))
        onEventGainChanged?(i, events[i].gainDB)
        needsDisplay = true
    }

    private func updateFadeDrag(_ i: Int, side: Int, x: CGFloat) {
        guard events.indices.contains(i) else { return }
        var e = events[i]
        let t = timeForX(min(max(x, plotRect.minX), plotRect.maxX))
        let maxFade = max(0, (e.end - e.start) * 0.48)
        if side < 0 {
            e.fadeIn = min(maxFade, max(0, t - e.start))
        } else {
            e.fadeOut = min(maxFade, max(0, e.end - t))
        }
        events[i] = e
        onEventFadesChanged?(i, e.fadeIn, e.fadeOut)
        needsDisplay = true
    }

    private func visualGain(at time: Double) -> Double {
        guard let e = events.first(where: { time >= $0.start && time <= $0.end }) else { return 1.0 }
        let target = pow(10.0, e.gainDB / 20.0)
        if e.fadeIn > 0, time < e.start + e.fadeIn {
            let x = min(1, max(0, (time - e.start) / e.fadeIn))
            return 1.0 + (target - 1.0) * x
        }
        if e.fadeOut > 0, time > e.end - e.fadeOut {
            let x = min(1, max(0, (e.end - time) / e.fadeOut))
            return 1.0 + (target - 1.0) * x
        }
        return target
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

        drawSpectralOverlay(m)
        drawWaveform(m)
        drawSelectionRegion()
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

    private func drawSpectralOverlay(_ m: AudioModel) {
        let spec = m.spectralBands
        guard !spec.values.isEmpty else { return }
        let labels = ["2–4k", "4–7k", "7–10k", "10–14k", "14–20k"]
        let laneH = plotRect.height / 5.0
        let columns = max(160, Int(plotRect.width / 2))
        for c in 0..<columns {
            let t = viewStart + Double(c) / Double(max(1, columns - 1)) * visibleDuration
            let frame = min(spec.values.count - 1, max(0, Int(t * spec.sampleRate / Double(spec.hopSamples))))
            let x0 = plotRect.minX + CGFloat(c) / CGFloat(columns) * plotRect.width
            let x1 = plotRect.minX + CGFloat(c + 1) / CGFloat(columns) * plotRect.width
            for b in 0..<5 {
                let v = CGFloat(spec.values[frame][b])
                if v < 0.08 { continue }
                let y = plotRect.minY + CGFloat(b) * laneH
                let color: NSColor
                switch b {
                case 0: color = NSColor.systemBlue
                case 1: color = NSColor.systemCyan
                case 2: color = NSColor.systemTeal
                case 3: color = NSColor.systemPurple
                default: color = NSColor.systemPink
                }
                color.withAlphaComponent(0.025 + v * 0.19).setFill()
                NSRect(x: x0, y: y, width: max(1, x1 - x0 + 0.5), height: laneH).fill()
            }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.38)]
        for b in 0..<5 {
            labels[b].draw(at: NSPoint(x: 7, y: plotRect.minY + CGFloat(b) * laneH + laneH * 0.5 - 5), withAttributes: attrs)
        }
    }

    private func drawWaveform(_ m: AudioModel) {
        guard !m.samples.isEmpty else { return }
        let columns = max(180, Int(plotRect.width * 1.15))
        let startSample = max(0, min(m.samples.count - 1, Int(viewStart * m.sampleRate)))
        let endSample = max(startSample + 1, min(m.samples.count, Int(viewEnd * m.sampleRate) + 1))
        let visibleSamples = max(1, endSample - startSample)
        let spp = Double(visibleSamples) / Double(columns)
        let path = NSBezierPath()

        if spp <= 2048 {
            for column in 0..<columns {
                let s0 = min(endSample - 1, startSample + Int(Double(column) * spp))
                let s1 = min(endSample, max(s0 + 1, startSample + Int(Double(column + 1) * spp)))
                var mn = m.samples[s0]
                var mx = m.samples[s0]
                if s1 > s0 + 1 {
                    for i in (s0 + 1)..<s1 { mn = min(mn, m.samples[i]); mx = max(mx, m.samples[i]) }
                }
                let x = plotRect.minX + CGFloat(column) / CGFloat(max(1, columns - 1)) * plotRect.width
                let time = Double(s0) / m.sampleRate
                let gain = CGFloat(visualGain(at: time))
                path.move(to: NSPoint(x: x, y: plotRect.midY + CGFloat(mn) * gain * plotRect.height * 0.47 * fixedVerticalScale))
                path.line(to: NSPoint(x: x, y: plotRect.midY + CGFloat(mx) * gain * plotRect.height * 0.47 * fixedVerticalScale))
            }
        } else {
            let nBins = m.overviewMin.count
            let total = max(0.0001, m.duration)
            let startBin = max(0, min(nBins - 1, Int(viewStart / total * Double(nBins))))
            let endBin = max(startBin + 1, min(nBins, Int(viewEnd / total * Double(nBins)) + 1))
            let binsPerColumn = Double(max(1, endBin - startBin)) / Double(columns)
            for column in 0..<columns {
                let b0 = min(endBin - 1, startBin + Int(Double(column) * binsPerColumn))
                let b1 = min(endBin, max(b0 + 1, startBin + Int(Double(column + 1) * binsPerColumn)))
                var mn = m.overviewMin[b0]
                var mx = m.overviewMax[b0]
                if b1 > b0 + 1 { for b in (b0 + 1)..<b1 { mn = min(mn, m.overviewMin[b]); mx = max(mx, m.overviewMax[b]) } }
                let x = plotRect.minX + CGFloat(column) / CGFloat(max(1, columns - 1)) * plotRect.width
                let time = viewStart + Double(column) / Double(max(1, columns - 1)) * visibleDuration
                let gain = CGFloat(visualGain(at: time))
                path.move(to: NSPoint(x: x, y: plotRect.midY + CGFloat(mn) * gain * plotRect.height * 0.47 * fixedVerticalScale))
                path.line(to: NSPoint(x: x, y: plotRect.midY + CGFloat(mx) * gain * plotRect.height * 0.47 * fixedVerticalScale))
            }
        }
        NSColor(hex: 0x38A9FF).setStroke()
        path.lineWidth = spp < 80 ? 1.15 : 0.9
        path.stroke()
        let zero = NSBezierPath()
        zero.move(to: NSPoint(x: plotRect.minX, y: plotRect.midY))
        zero.line(to: NSPoint(x: plotRect.maxX, y: plotRect.midY))
        NSColor.white.withAlphaComponent(0.10).setStroke()
        zero.lineWidth = 0.5
        zero.stroke()
    }

    private func drawSelectionRegion() {
        guard let a = selectionAnchor, let b = selectionCurrent else { return }
        let x1 = xForTime(min(a, b))
        let x2 = xForTime(max(a, b))
        let r = NSRect(x: min(x1, x2), y: plotRect.minY, width: max(2, abs(x2 - x1)), height: plotRect.height)
        NSColor.systemCyan.withAlphaComponent(0.16).setFill()
        r.fill()
        NSColor.systemCyan.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: r)
        border.lineWidth = 1.5
        border.stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white]
        "NEW EVENT REGION".draw(at: NSPoint(x: r.minX + 6, y: r.maxY - 18), withAttributes: attrs)
    }

    private func drawEvents(_ m: AudioModel) {
        for (i, e) in events.enumerated() where e.end >= viewStart && e.start <= viewEnd {
            let startX = xForTime(max(e.start, viewStart))
            let endX = xForTime(min(e.end, viewEnd))
            let centerX = xForTime(e.peakTime)
            let color: NSColor
            switch e.userLabel {
            case "GOOD": color = .systemGreen
            case "BAD": color = .systemRed
            case "TARGET": color = .systemBlue
            case "NORMAL": color = .systemGray
            default:
                if ["T", "Ť", "D", "K", "P", "B"].contains(e.kind) {
                    color = .systemOrange
                } else if ["Č", "CH"].contains(e.kind) {
                    color = .systemPurple
                } else {
                    color = .systemPink
                }
            }

            let selected = i == selectedIndex
            let region = NSRect(
                x: min(startX, endX),
                y: plotRect.minY,
                width: max(2, abs(endX - startX)),
                height: plotRect.height
            )
            color.withAlphaComponent(selected ? 0.20 : 0.065).setFill()
            region.fill()

            let left = NSBezierPath()
            left.move(to: NSPoint(x: startX, y: plotRect.minY))
            left.line(to: NSPoint(x: startX, y: plotRect.maxY))
            color.withAlphaComponent(selected ? 0.95 : 0.38).setStroke()
            left.lineWidth = selected ? 2.0 : 0.7
            left.stroke()

            let right = NSBezierPath()
            right.move(to: NSPoint(x: endX, y: plotRect.minY))
            right.line(to: NSPoint(x: endX, y: plotRect.maxY))
            color.withAlphaComponent(selected ? 0.95 : 0.38).setStroke()
            right.lineWidth = selected ? 2.0 : 0.7
            right.stroke()

            if selected {
                for x in [startX, endX] {
                    let handle = NSBezierPath(roundedRect: NSRect(x: x - 5, y: plotRect.midY - 18, width: 10, height: 36), xRadius: 4, yRadius: 4)
                    color.setFill()
                    handle.fill()
                    NSColor.white.withAlphaComponent(0.9).setStroke()
                    handle.lineWidth = 1
                    handle.stroke()
                }
            }

            let badgeText = e.kind
            let badgeFont = selected ? NSFont.boldSystemFont(ofSize: 14) : NSFont.boldSystemFont(ofSize: 9)
            let attrs: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: NSColor.white]
            let textSize = badgeText.size(withAttributes: attrs)
            let badgeW = selected ? max(34, textSize.width + 18) : max(18, textSize.width + 8)
            let badgeH: CGFloat = selected ? 26 : 17
            let badgeY = plotRect.maxY - badgeH - 5
            let badge = NSBezierPath(roundedRect: NSRect(x: centerX - badgeW / 2, y: badgeY, width: badgeW, height: badgeH), xRadius: 5, yRadius: 5)
            color.setFill()
            badge.fill()
            if selected {
                NSColor.white.withAlphaComponent(0.65).setStroke()
                badge.lineWidth = 1.2
                badge.stroke()
            }
            badgeText.draw(at: NSPoint(x: centerX - textSize.width / 2, y: badgeY + (badgeH - textSize.height) / 2), withAttributes: attrs)

            if selected {
                let fader = gainFaderRect(for: i)
                let centerX = fader.midX
                let range: CGFloat = 48
                let rail = NSBezierPath()
                rail.move(to: NSPoint(x: centerX, y: plotRect.midY - range))
                rail.line(to: NSPoint(x: centerX, y: plotRect.midY + range))
                NSColor.white.withAlphaComponent(0.24).setStroke()
                rail.lineWidth = 1
                rail.stroke()
                let norm = CGFloat((min(0, max(-18, e.gainDB)) + 18) / 18)
                let knobY = plotRect.midY - range + norm * range * 2
                let knob = NSBezierPath(roundedRect: NSRect(x: centerX - 18, y: knobY - 9, width: 36, height: 18), xRadius: 9, yRadius: 9)
                NSColor.white.setFill()
                knob.fill()
                let gattrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.9)]
                let gainText = String(format: "%.1f dB", e.gainDB)
                let gainSize = gainText.size(withAttributes: gattrs)
                gainText.draw(at: NSPoint(x: centerX - gainSize.width / 2, y: knobY - 4), withAttributes: gattrs)

                let inX = xForTime(min(e.end, e.start + e.fadeIn))
                let outX = xForTime(max(e.start, e.end - e.fadeOut))
                let fadeTop = plotRect.midY + 34
                let fadeBottom = plotRect.midY - 34
                let fadeInPath = NSBezierPath()
                fadeInPath.move(to: NSPoint(x: startX, y: fadeTop))
                fadeInPath.line(to: NSPoint(x: inX, y: fadeBottom))
                color.withAlphaComponent(0.9).setStroke()
                fadeInPath.lineWidth = 1.4
                fadeInPath.stroke()
                let fadeOutPath = NSBezierPath()
                fadeOutPath.move(to: NSPoint(x: outX, y: fadeBottom))
                fadeOutPath.line(to: NSPoint(x: endX, y: fadeTop))
                fadeOutPath.lineWidth = 1.4
                fadeOutPath.stroke()
                for x in [inX, outX] {
                    let h = NSBezierPath(roundedRect: NSRect(x: x - 5, y: plotRect.midY - 5, width: 10, height: 10), xRadius: 3, yRadius: 3)
                    color.setFill()
                    h.fill()
                    NSColor.white.setStroke()
                    h.lineWidth = 1
                    h.stroke()
                }
                let fattrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.72)]
                String(format: "IN %.0f ms", e.fadeIn * 1000).draw(at: NSPoint(x: startX + 4, y: fadeTop + 5), withAttributes: fattrs)
                String(format: "OUT %.0f ms", e.fadeOut * 1000).draw(at: NSPoint(x: max(startX, endX - 58), y: fadeTop + 5), withAttributes: fattrs)
            }
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
        NSColor(hex: 0x08131D).setFill()
        rulerRect.fill()
        let major: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor(hex: 0xA3B2BD)]
        let tick = NSBezierPath()
        for i in 0...8 {
            let t = viewStart + visibleDuration * Double(i) / 8.0
            let x = plotRect.minX + plotRect.width * CGFloat(i) / 8.0
            tick.move(to: NSPoint(x: x, y: 31))
            tick.line(to: NSPoint(x: x, y: 42))
            let min = Int(t) / 60
            let sec = Int(t) % 60
            let ms = Int((t - floor(t)) * 1000)
            let text = visibleDuration < 12 ? String(format: "%d:%02d.%03d", min, sec, ms) : String(format: "%d:%02d", min, sec)
            text.draw(at: NSPoint(x: x - 22, y: 8), withAttributes: major)
        }
        NSColor.white.withAlphaComponent(0.18).setStroke()
        tick.lineWidth = 1
        tick.stroke()
        if let t = highlightedTime, t >= viewStart && t <= viewEnd {
            let x = xForTime(t)
            let text = String(format: "%02d:%02d.%03d", Int(t) / 60, Int(t) % 60, Int((t - floor(t)) * 1000))
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: a)
            let box = NSRect(x: min(max(plotRect.minX, x - size.width / 2 - 10), plotRect.maxX - size.width - 20), y: 5, width: size.width + 20, height: 28)
            NSColor(hex: 0x1577D2).setFill()
            NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
            text.draw(at: NSPoint(x: box.minX + 10, y: box.minY + 6), withAttributes: a)
        }
    }

    private func drawInstructions() {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(hex: 0x60717E)]
        "Scroll: zoom   •   ⇧ drag: new event   •   center handle: gain   •   edge diamonds: fades   •   Space: play/stop".draw(
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
    private var fadeInSlider: NSSlider!
    private var fadeOutSlider: NSSlider!
    private var fadeInValue: NSTextField!
    private var fadeOutValue: NSTextField!
    private var exportButton: NSButton!
    private var autoRepairButton: NSButton!
    private var applySimilarButton: NSButton!
    private var auditionMode: NSSegmentedControl!

    private var model = AudioModel()
    private var events: [SibilanceEvent] = []
    private let detector = SibilanceDetector()
    private let progressUI = AnalysisProgressController()
    private let updater = UpdateManager()
    private let sessionStore = SessionStore()
    private var previewPlayer: AVAudioPlayer?
    private var scrubPlayer: AVAudioPlayer?
    private var stopTimer: Timer?
    private var fadeTimer: Timer?
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
        analyzeButton.frame = NSRect(x: w - 430, y: h - 72, width: 112, height: 33)
        root.addSubview(analyzeButton)
        let open = button("Open WAV", action: #selector(openWav))
        open.frame = NSRect(x: w - 309, y: h - 72, width: 112, height: 33)
        root.addSubview(open)
        exportButton = button("Export RG-SIB", action: #selector(exportAudio))
        exportButton.frame = NSRect(x: w - 188, y: h - 72, width: 129, height: 33)
        exportButton.isEnabled = false
        root.addSubview(exportButton)

        timeline = TimelineView(frame: NSRect(x: 34, y: h - 536, width: w - 68, height: 410))
        timeline.onAudioDrop = { [weak self] url in self?.loadAudio(url) }
        timeline.onSelect = { [weak self] i in self?.selectEvent(i) }
        timeline.onScrub = { [weak self] t, active in self?.scrub(to: t, active: active) }
        timeline.onAddSibilance = { [weak self] t in self?.addManualS(at: t) }
        timeline.onDeleteEvent = { [weak self] i in self?.deleteEvent(i) }
        timeline.onEventBoundsChanged = { [weak self] i, start, end in self?.eventBoundsChanged(i, start: start, end: end) }
        timeline.onPlayEvent = { [weak self] i in self?.playRegionOnly(i) }
        timeline.onEventGainChanged = { [weak self] i, gain in self?.eventGainChanged(i, gain: gain) }
        timeline.onEventFadesChanged = { [weak self] i, fadeIn, fadeOut in self?.eventFadesChanged(i, fadeIn: fadeIn, fadeOut: fadeOut) }
        timeline.onCreateEventRegion = { [weak self] start, end in self?.createEventFromSelection(start: start, end: end) }
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
        kindPopup.addItems(withTitles: ["S", "Š", "Z", "C", "Č", "T", "Ť", "D", "K", "P", "B", "F", "CH", "OTHER"])
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

        let fi = label("Fade In", size: 10); fi.frame = NSRect(x: 15, y: panelH - 178, width: 48, height: 18); p2.addSubview(fi)
        fadeInSlider = NSSlider(value: 12, minValue: 0, maxValue: 120, target: self, action: #selector(fadeChanged))
        fadeInSlider.frame = NSRect(x: 63, y: panelH - 181, width: 94, height: 22)
        fadeInSlider.isEnabled = false
        p2.addSubview(fadeInSlider)
        fadeInValue = label("12 ms", size: 9, weight: .semibold, color: NSColor(hex: 0x9DB4C5))
        fadeInValue.frame = NSRect(x: 158, y: panelH - 178, width: 42, height: 18)
        p2.addSubview(fadeInValue)

        let fo = label("Fade Out", size: 10); fo.frame = NSRect(x: 211, y: panelH - 178, width: 54, height: 18); p2.addSubview(fo)
        fadeOutSlider = NSSlider(value: 12, minValue: 0, maxValue: 120, target: self, action: #selector(fadeChanged))
        fadeOutSlider.frame = NSRect(x: 265, y: panelH - 181, width: max(70, pw - 330), height: 22)
        fadeOutSlider.isEnabled = false
        p2.addSubview(fadeOutSlider)
        fadeOutValue = label("12 ms", size: 9, weight: .semibold, color: NSColor(hex: 0x9DB4C5))
        fadeOutValue.frame = NSRect(x: pw - 55, y: panelH - 178, width: 42, height: 18)
        p2.addSubview(fadeOutValue)

        autoRepairButton = button("AUTO SAFE", action: #selector(autoRepairSelected))
        autoRepairButton.frame = NSRect(x: 15, y: 16, width: 105, height: 29)
        autoRepairButton.isEnabled = false
        p2.addSubview(autoRepairButton)
        applySimilarButton = button("APPLY SIMILAR", action: #selector(applySimilar))
        applySimilarButton.frame = NSRect(x: 126, y: 16, width: 122, height: 29)
        applySimilarButton.isEnabled = false
        p2.addSubview(applySimilarButton)

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
        auditionMode = NSSegmentedControl(labels: ["ORIGINAL", "REPAIR"], trackingMode: .selectOne, target: self, action: #selector(auditionModeChanged))
        auditionMode.selectedSegment = 1
        auditionMode.frame = NSRect(x: 15, y: 53, width: 205, height: 27)
        p3.addSubview(auditionMode)
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
                    if let session = self.sessionStore.load(for: url, duration: m.duration, sampleRate: m.sampleRate) {
                        self.events = session.events
                        self.typeTrims = session.typeTrims
                        self.timeline.events = session.events
                        let restoredIndex = min(max(0, session.selectedIndex ?? 0), max(0, session.events.count - 1))
                        self.timeline.selectedIndex = session.events.isEmpty ? nil : restoredIndex
                        self.timeline.playhead = min(m.duration, max(0, session.playhead ?? 0))
                        self.sensitivitySlider.doubleValue = min(1, max(0, session.sensitivity ?? self.sensitivitySlider.doubleValue))
                        self.auditionMode.selectedSegment = min(1, max(0, session.auditionMode ?? 1))
                        self.exportButton.isEnabled = true
                        self.detectedLabel.stringValue = "Restored: \(session.events.count) events"
                        self.eventInfo.stringValue = session.events.isEmpty ? "Saved session restored" : "Saved session restored — last stage"
                        if !session.events.isEmpty { self.selectEvent(restoredIndex) }
                        self.status.stringValue = "SESSION RESTORED — LAST EDITED STAGE"
                    } else {
                        self.eventInfo.stringValue = "Audio loaded — analyzing automatically…"
                        self.exportButton.isEnabled = true
                        self.status.stringValue = "AUDIO LOADED — starting automatic analysis…"
                        self.analyzeAudio()
                    }
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
                self.saveCurrentSession()
                self.status.stringValue = found.isEmpty ? "ANALYSIS COMPLETE — no events" : "ANALYSIS COMPLETE"
            }
        }
    }

    private func saveCurrentSession() {
        guard let url = model.url else { return }
        sessionStore.save(for: url, duration: model.duration, sampleRate: model.sampleRate, events: events, typeTrims: typeTrims, sensitivity: sensitivitySlider.doubleValue, playhead: timeline.playhead, selectedIndex: timeline.selectedIndex, auditionMode: auditionMode?.selectedSegment ?? 1)
    }

    private func createEventFromSelection(start: Double, end: Double) {
        guard end - start >= 0.015 else { return }
        let menu = NSMenu()
        for kind in ["S", "Š", "Z", "C", "Č", "T", "Ť", "D", "K", "P", "B", "F", "CH", "OTHER"] {
            let item = NSMenuItem(title: kind, action: #selector(createSelectedRegionEvent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["start": start, "end": end, "kind": kind] as [String : Any]
            menu.addItem(item)
        }
        let p = NSEvent.mouseLocation
        if let screen = NSScreen.main {
            let local = NSPoint(x: p.x - screen.frame.minX, y: p.y - screen.frame.minY)
            menu.popUp(positioning: nil, at: local, in: nil)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 200, y: 200), in: nil)
        }
    }

    @objc private func createSelectedRegionEvent(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? [String: Any],
              let start = d["start"] as? Double, let end = d["end"] as? Double, let kind = d["kind"] as? String else { return }
        let e = SibilanceEvent(start: start, end: end, peakTime: (start + end) * 0.5, score: 1, kind: kind, userLabel: "TARGET")
        events.append(e)
        events.sort { $0.peakTime < $1.peakTime }
        timeline.events = events
        detectedLabel.stringValue = "Detected: \(events.count) events"
        if let i = events.firstIndex(where: { abs($0.start - start) < 0.000001 && abs($0.end - end) < 0.000001 && $0.kind == kind }) {
            selectEvent(i)
            timeline.playhead = events[i].start
        }
        saveCurrentSession()
        status.stringValue = "NEW [\(kind)] EVENT — \(String(format: "%.3f", start))–\(String(format: "%.3f", end)) s"
    }

    @objc private func sensitivityChanged() {
        saveCurrentSession()
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
        fadeInSlider.isEnabled = true
        fadeOutSlider.isEnabled = true
        fadeInSlider.doubleValue = e.fadeIn * 1000
        fadeOutSlider.doubleValue = e.fadeOut * 1000
        fadeInValue.stringValue = String(format: "%.0f ms", e.fadeIn * 1000)
        fadeOutValue.stringValue = String(format: "%.0f ms", e.fadeOut * 1000)
        autoRepairButton.isEnabled = true
        applySimilarButton.isEnabled = true
        eventInfo.stringValue = String(format: "#%03d [%@]  %.3f–%.3f s  %.0f ms  GAIN %.1f dB  IN %.0f / OUT %.0f ms  %@  •  %@", i + 1, e.kind, e.start, e.end, (e.end - e.start) * 1000, e.gainDB, e.fadeIn * 1000, e.fadeOut * 1000, e.userLabel.isEmpty ? "UNRATED" : e.userLabel, RGRepairAdvisor.qualityText(for: e))
    }

    private func eventBoundsChanged(_ i: Int, start: Double, end: Double) {
        guard events.indices.contains(i) else { return }
        events[i].start = start
        events[i].end = end
        events[i].peakTime = (start + end) * 0.5
        timeline.events = events
        selectEvent(i)
        saveCurrentSession()
        status.stringValue = String(format: "EVENT #%d REGION → %.3f–%.3f s", i + 1, start, end)
    }

    @objc private func fadeChanged() {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { return }
        let maxFade = max(0, (events[i].end - events[i].start) * 0.48)
        events[i].fadeIn = min(fadeInSlider.doubleValue / 1000.0, maxFade)
        events[i].fadeOut = min(fadeOutSlider.doubleValue / 1000.0, maxFade)
        fadeInSlider.doubleValue = events[i].fadeIn * 1000
        fadeOutSlider.doubleValue = events[i].fadeOut * 1000
        timeline.events = events
        selectEvent(i)
        saveCurrentSession()
        status.stringValue = String(format: "EVENT #%d CROSSFADES — IN %.0f ms / OUT %.0f ms", i + 1, events[i].fadeIn * 1000, events[i].fadeOut * 1000)
    }

    private func eventGainChanged(_ i: Int, gain: Double) {
        guard events.indices.contains(i) else { return }
        events[i].gainDB = min(0, max(-18, gain))
        selectEvent(i)
        saveCurrentSession()
        status.stringValue = String(format: "EVENT #%d GAIN %.1f dB", i + 1, events[i].gainDB)
    }

    private func eventFadesChanged(_ i: Int, fadeIn: Double, fadeOut: Double) {
        guard events.indices.contains(i) else { return }
        events[i].fadeIn = fadeIn
        events[i].fadeOut = fadeOut
        fadeInSlider.doubleValue = fadeIn * 1000
        fadeOutSlider.doubleValue = fadeOut * 1000
        fadeInValue.stringValue = String(format: "%.0f ms", fadeIn * 1000)
        fadeOutValue.stringValue = String(format: "%.0f ms", fadeOut * 1000)
        timeline.events = events
        selectEvent(i)
        saveCurrentSession()
        status.stringValue = String(format: "EVENT #%d CROSSFADES — IN %.0f ms / OUT %.0f ms", i + 1, fadeIn * 1000, fadeOut * 1000)
    }

    @objc private func typeTrimChanged() {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { return }
        let kind = events[i].kind
        let value = typeTrimSlider.doubleValue
        typeTrims[kind] = value
        typeTrimValue.stringValue = String(format: "%.1f dB", value)
        selectEvent(i)
        let count = events.filter { $0.kind == kind }.count
        saveCurrentSession()
        status.stringValue = String(format: "%@ TYPE TRIM %.1f dB — %d events", kind, value, count)
    }

    @objc private func kindChanged() {
        guard let i = timeline.selectedIndex, events.indices.contains(i), let title = kindPopup.selectedItem?.title else { return }
        events[i].kind = title
        timeline.events = events
        selectEvent(i)
        saveCurrentSession()
        status.stringValue = "EVENT #\(i + 1) TYPE → \(title)"
    }

    private func mark(_ value: String) {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { status.stringValue = "SELECT AN EVENT FIRST"; return }
        events[i].userLabel = value
        timeline.events = events
        selectEvent(i)
        saveCurrentSession()
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
        saveCurrentSession()
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
            fadeInSlider.isEnabled = false
            fadeOutSlider.isEnabled = false
            eventInfo.stringValue = "No sibilance selected"
        } else {
            let next = min(i, events.count - 1)
            selectEvent(next)
            timeline.playhead = events[next].peakTime
        }
        saveCurrentSession()
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

    private func playRegionOnly(_ i: Int) {
        guard events.indices.contains(i), let url = model.url else { return }
        if transportPlaying { stopTransport() }
        previewPlayer?.stop()
        stopTimer?.invalidate()
        fadeTimer?.invalidate()
        let e = events[i]
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            previewPlayer = p
            let duration = max(0.02, e.end - e.start)
            let repaired = auditionMode?.selectedSegment != 0
            let effectiveDB = repaired ? e.gainDB + (typeTrims[e.kind] ?? 0) : 0
            let fadeIn = repaired ? e.fadeIn : 0
            let fadeOutValue = repaired ? e.fadeOut : 0
            let targetVolume = Float(pow(10.0, effectiveDB / 20.0))
            p.currentTime = e.start
            p.volume = fadeIn > 0.001 ? 0 : targetVolume
            p.play()
            if fadeIn > 0.001 { p.setVolume(targetVolume, fadeDuration: fadeIn) }
            let fadeOut = min(fadeOutValue, duration * 0.48)
            if fadeOut > 0.001 {
                fadeTimer = Timer.scheduledTimer(withTimeInterval: max(0.001, duration - fadeOut), repeats: false) { [weak self, weak p] _ in
                    guard self?.previewPlayer === p else { return }
                    p?.setVolume(0, fadeDuration: fadeOut)
                }
            }
            stopTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self, weak p] _ in
                guard self?.previewPlayer === p else { return }
                p?.stop()
                self?.playButton.title = "▶ Play event"
            }
            timeline.playhead = e.start
            playButton.title = "■ Stop"
            status.stringValue = String(format: "REGION %@ [%@]   %.3f–%.3f s   %.1f dB", repaired ? "REPAIR" : "ORIGINAL", e.kind, e.start, e.end, effectiveDB)
        } catch {
            status.stringValue = "REGION PLAYBACK FAILED"
        }
    }

    @objc private func auditionModeChanged() {
        saveCurrentSession()
        status.stringValue = auditionMode.selectedSegment == 0 ? "A/B — ORIGINAL" : "A/B — REPAIR"
        if let i = timeline.selectedIndex { playRegionOnly(i) }
    }

    @objc private func autoRepairSelected() {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { return }
        let length = max(0.015, events[i].end - events[i].start)
        events[i].gainDB = RGRepairAdvisor.recommendedGain(for: events[i])
        events[i].fadeIn = min(0.018, length * 0.22)
        events[i].fadeOut = min(0.018, length * 0.22)
        timeline.events = events
        selectEvent(i)
        saveCurrentSession()
        status.stringValue = String(format: "AUTO SAFE — [%@] %.1f dB", events[i].kind, events[i].gainDB)
        playRegionOnly(i)
    }

    @objc private func applySimilar() {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { return }
        let source = events[i]
        var changed = 0
        for j in events.indices where j != i && events[j].kind == source.kind && events[j].userLabel != "GOOD" {
            events[j].gainDB = source.gainDB
            events[j].fadeIn = min(source.fadeIn, max(0, (events[j].end - events[j].start) * 0.48))
            events[j].fadeOut = min(source.fadeOut, max(0, (events[j].end - events[j].start) * 0.48))
            changed += 1
        }
        timeline.events = events
        saveCurrentSession()
        status.stringValue = "APPLY SIMILAR — \(changed) [\(source.kind)] events updated"
    }

    @objc private func exportAudio() {
        guard let url = model.url else { return }
        exportButton.isEnabled = false
        status.stringValue = "EXPORTING RG-SIB…"
        let snapshot = events
        let trims = typeTrims
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let out = try RGRenderEngine.export(sourceURL: url, events: snapshot, typeTrims: trims)
                DispatchQueue.main.async {
                    self?.exportButton.isEnabled = true
                    self?.status.stringValue = "EXPORT COMPLETE — \(out.lastPathComponent)"
                }
            } catch {
                DispatchQueue.main.async {
                    self?.exportButton.isEnabled = true
                    self?.status.stringValue = "EXPORT FAILED — \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func playSelected() {
        guard let url = model.url else { return }
        do {
            stopTimer?.invalidate()
            fadeTimer?.invalidate()
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
        fadeTimer?.invalidate()
        playButton.title = "▶ Play event"
        if loopEnabled { playSelected() }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playButton.title = "▶ Play event"
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveCurrentSession()
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
