import Cocoa
import AVFoundation
import Foundation

let RGVersion = "0.4.0"
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
    var note: String? = nil
    var gainDB: Double = 0
    var fadeIn: Double = 0.012
    var fadeOut: Double = 0.012
    var spectralDB: [Double]? = nil
    var repairMethod: String? = nil
    var donorPath: String? = nil
    var donorStart: Double? = nil
    var donorEnd: Double? = nil
    var blendAmount: Double? = nil
    var referenceInfluence: Double? = nil
    var resonanceAmount: Double? = nil
    var resonanceHz: Double? = nil
    var resonanceQ: Double? = nil
    var spectralTilt: Double? = nil
    var spectralFlatten: Double? = nil
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
    var spectralBands = RGSpectralBands(hopSamples: 256, sampleRate: 48000, values: [])

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
        spectralBands = RGSpectralAnalyzer.makeBands(samples: samples, sampleRate: sampleRate, hopSamples: 256)
    }

    func fingerprint(for event: SibilanceEvent) -> [Double] {
        let spec = spectralBands
        guard !spec.values.isEmpty else { return Array(repeating: 0.0, count: 5) }
        let a = max(0, min(spec.values.count - 1, Int(event.start * spec.sampleRate / Double(spec.hopSamples))))
        let b = max(a + 1, min(spec.values.count, Int(event.end * spec.sampleRate / Double(spec.hopSamples)) + 1))
        var sum = Array(repeating: 0.0, count: 5)
        var count = 0.0
        for i in a..<b {
            for band in 0..<5 { sum[band] += Double(spec.values[i][band]) }
            count += 1
        }
        guard count > 0 else { return sum }
        return sum.map { $0 / count }
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
    var typeTrims: [String: Double] = [:] { didSet { needsDisplay = true } }
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
    var displayMode: Int = 0 { didSet { needsDisplay = true } }

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
        let target = pow(10.0, min(0.0, e.gainDB + (typeTrims[e.kind] ?? 0)) / 20.0)
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

    func zoomIn() {
        guard model != nil else { return }
        let center = viewStart + visibleDuration * 0.5
        zoom = min(640, zoom * 1.55)
        viewStart = center - visibleDuration * 0.5
        clampViewStart()
        needsDisplay = true
    }

    func zoomOut() {
        guard model != nil else { return }
        let center = viewStart + visibleDuration * 0.5
        zoom = max(1, zoom / 1.55)
        viewStart = center - visibleDuration * 0.5
        clampViewStart()
        needsDisplay = true
    }

    func fitAll() {
        zoom = 1
        viewStart = 0
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
            let sub = "Drop vocal here • analyze • edit directly on waveform"
            drawCentered(title, y: bounds.midY + 4, size: 20, color: .white, bold: true)
            drawCentered(sub, y: bounds.midY - 27, size: 12, color: NSColor(hex: 0x778895), bold: false)
            return
        }

        if displayMode == 1 {
            drawSpectralOverlay(m)
        } else {
            drawWaveform(m)
        }
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
        let laneH = plotRect.height / 5.0
        let columns = max(220, Int(plotRect.width * 0.75))
        NSColor(hex: 0x0A1118).setFill()
        plotRect.fill()
        for c in 0..<columns {
            let t = viewStart + Double(c) / Double(max(1, columns - 1)) * visibleDuration
            let frame = min(spec.values.count - 1, max(0, Int(t * spec.sampleRate / Double(spec.hopSamples))))
            let x0 = plotRect.minX + CGFloat(c) / CGFloat(columns) * plotRect.width
            let x1 = plotRect.minX + CGFloat(c + 1) / CGFloat(columns) * plotRect.width
            for b in 0..<5 {
                let v = CGFloat(spec.values[frame][b])
                if v < 0.045 { continue }
                let y = plotRect.minY + CGFloat(b) * laneH
                let intensity = min(0.72, 0.04 + v * 0.66)
                NSColor(calibratedWhite: 0.76 + min(0.20, v * 0.20), alpha: intensity).setFill()
                NSRect(x: x0, y: y, width: max(1, x1 - x0 + 0.5), height: laneH + 0.5).fill()
            }
        }
        let grid = NSBezierPath()
        for b in 1..<5 {
            let y = plotRect.minY + CGFloat(b) * laneH
            grid.move(to: NSPoint(x: plotRect.minX, y: y))
            grid.line(to: NSPoint(x: plotRect.maxX, y: y))
        }
        NSColor.white.withAlphaComponent(0.055).setStroke()
        grid.lineWidth = 0.5
        grid.stroke()
    }

    private func drawWaveform(_ m: AudioModel) {
        guard !m.samples.isEmpty else { return }
        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)
        NSGraphicsContext.current?.cgContext.setAllowsAntialiasing(true)

        let pixelColumns = max(240, Int(plotRect.width * 2.0))
        let startSample = max(0, min(m.samples.count - 1, Int(viewStart * m.sampleRate)))
        let endSample = max(startSample + 1, min(m.samples.count, Int(viewEnd * m.sampleRate) + 1))
        let visibleSamples = max(1, endSample - startSample)
        let samplesPerColumn = Double(visibleSamples) / Double(pixelColumns)
        let waveCenter = plotRect.minY + plotRect.height * 0.68
        let amp = plotRect.height * 0.27 * fixedVerticalScale

        // At sample-level zoom draw the true waveform as one continuous anti-aliased trace.
        if samplesPerColumn <= 2.2 {
            let trace = NSBezierPath()
            trace.lineJoinStyle = .round
            trace.lineCapStyle = .round
            let count = max(2, min(visibleSamples, Int(plotRect.width * 4.0)))
            for c in 0..<count {
                let f = Double(c) / Double(max(1, count - 1))
                let samplePosition = Double(startSample) + f * Double(max(1, visibleSamples - 1))
                let i0 = min(m.samples.count - 1, max(0, Int(floor(samplePosition))))
                let i1 = min(m.samples.count - 1, i0 + 1)
                let frac = Float(samplePosition - Double(i0))
                let v = m.samples[i0] * (1 - frac) + m.samples[i1] * frac
                let t = samplePosition / m.sampleRate
                let g = CGFloat(visualGain(at: t))
                let x = plotRect.minX + CGFloat(f) * plotRect.width
                let y = waveCenter + CGFloat(v) * g * amp
                if c == 0 { trace.move(to: NSPoint(x: x, y: y)) }
                else { trace.line(to: NSPoint(x: x, y: y)) }
            }
            NSColor(hex: 0xF2F5F7).withAlphaComponent(0.90).setStroke()
            trace.lineWidth = 1.35
            trace.stroke()
        } else {
            var tops: [NSPoint] = []
            var bottoms: [NSPoint] = []
            tops.reserveCapacity(pixelColumns)
            bottoms.reserveCapacity(pixelColumns)

            for c in 0..<pixelColumns {
                let s0 = min(endSample - 1, startSample + Int(Double(c) * samplesPerColumn))
                let s1 = min(endSample, max(s0 + 1, startSample + Int(Double(c + 1) * samplesPerColumn)))
                var mn = m.samples[s0]
                var mx = m.samples[s0]
                if s1 > s0 + 1 {
                    for i in (s0 + 1)..<s1 {
                        let v = m.samples[i]
                        if v < mn { mn = v }
                        if v > mx { mx = v }
                    }
                }
                // Blend neighboring extrema slightly so the display is continuous rather than rectangular.
                if c > 0 {
                    let prevTop = Float((tops.last!.y - waveCenter) / max(0.0001, amp))
                    let prevBottom = Float((bottoms.last!.y - waveCenter) / max(0.0001, amp))
                    mx = mx * 0.78 + prevTop * 0.22
                    mn = mn * 0.78 + prevBottom * 0.22
                }
                let f = Double(c) / Double(max(1, pixelColumns - 1))
                let t = viewStart + f * visibleDuration
                let g = CGFloat(visualGain(at: t))
                let x = plotRect.minX + CGFloat(f) * plotRect.width
                tops.append(NSPoint(x: x, y: waveCenter + CGFloat(mx) * g * amp))
                bottoms.append(NSPoint(x: x, y: waveCenter + CGFloat(mn) * g * amp))
            }

            let fill = NSBezierPath()
            if let first = tops.first { fill.move(to: first) }
            for pt in tops.dropFirst() { fill.line(to: pt) }
            for pt in bottoms.reversed() { fill.line(to: pt) }
            fill.close()
            NSColor(hex: 0xD8DEE4, alpha: 0.62).setFill()
            fill.fill()

            let topPath = NSBezierPath()
            let bottomPath = NSBezierPath()
            topPath.lineJoinStyle = .round; bottomPath.lineJoinStyle = .round
            if let first = tops.first { topPath.move(to: first) }
            for pt in tops.dropFirst() { topPath.line(to: pt) }
            if let first = bottoms.first { bottomPath.move(to: first) }
            for pt in bottoms.dropFirst() { bottomPath.line(to: pt) }
            NSColor(hex: 0xF2F5F7).withAlphaComponent(0.86).setStroke()
            topPath.lineWidth = 0.9; bottomPath.lineWidth = 0.9
            topPath.stroke(); bottomPath.stroke()
        }

        let zero = NSBezierPath()
        zero.move(to: NSPoint(x: plotRect.minX, y: waveCenter))
        zero.line(to: NSPoint(x: plotRect.maxX, y: waveCenter))
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

            if let note = e.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let bubbleText = "✎ " + note
                let nattrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor.white]
                let ns = bubbleText.size(withAttributes: nattrs)
                let bw = min(CGFloat(220), max(CGFloat(54), ns.width + 16))
                let bx = min(plotRect.maxX - bw - 4, max(plotRect.minX + 4, centerX - bw / 2))
                let by = badgeY - 25
                let bubble = NSBezierPath(roundedRect: NSRect(x: bx, y: by, width: bw, height: 20), xRadius: 6, yRadius: 6)
                NSColor(hex: 0x243A4A).withAlphaComponent(selected ? 0.98 : 0.78).setFill(); bubble.fill()
                bubbleText.draw(in: NSRect(x: bx + 8, y: by + 4, width: bw - 16, height: 14), withAttributes: nattrs)
            }

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
        guard let shaURL = URL(string: "\(RGRepoRaw)/dist/SHA256?t=\(stamp)") else { busy = false; return }
        guard let expectedData = try? Data(contentsOf: shaURL),
              let expectedHash = String(data: expectedData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !expectedHash.isEmpty,
              let zipURL = URL(string: "\(RGRepoRaw)/dist/RG-Sibilance-Studio-\(version).zip?sha=\(expectedHash)") else {
            busy = false
            DispatchQueue.main.async { self.onStatus?("UPDATE FAILED — manifest unavailable") }
            return
        }

        URLSession.shared.downloadTask(with: zipURL) { [weak self] tempURL, _, error in
            guard let self = self, let tempURL = tempURL, error == nil else {
                self?.busy = false
                DispatchQueue.main.async { self?.onStatus?("UPDATE FAILED — download error") }
                return
            }
            do {
                let expected = expectedHash
                let actual = try self.sha256(tempURL).lowercased()
                guard expected == actual else {
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

final class AudioDropView: NSView {
    var onAudioDrop: ((URL) -> Void)?
    private var dragActive = false

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

    override func draw(_ dirtyRect: NSRect) {
        let fill = NSColor(hex: dragActive ? 0x102A40 : 0x0D1A26)
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor(hex: dragActive ? 0x2F95FF : 0x27435A).withAlphaComponent(0.9).setStroke()
        border.lineWidth = dragActive ? 2 : 1
        border.setLineDash([5,4], count: 2, phase: 0)
        border.stroke()
        let title = dragActive ? "DROP AUDIO" : "DRAG & DROP WAV / AIFF"
        let sub = "Drop audio file here to analyze"
        let a1: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.white]
        let a2: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(hex: 0x8A9AA8)]
        let t1 = title.size(withAttributes: a1)
        let t2 = sub.size(withAttributes: a2)
        title.draw(at: NSPoint(x: bounds.midX - t1.width / 2, y: bounds.midY + 4), withAttributes: a1)
        sub.draw(at: NSPoint(x: bounds.midX - t2.width / 2, y: bounds.midY - 24), withAttributes: a2)
    }
}


final class RGButton: NSButton {
    enum Role { case primary, secondary, ghost, danger }
    var role: Role = .secondary { didSet { updateStyle() } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }
    private func configure() {
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        focusRingType = .none
        imagePosition = .imageLeading
        updateStyle()
    }
    private func updateStyle() {
        switch role {
        case .primary:
            layer?.backgroundColor = NSColor(hex: 0x1677E8).cgColor
            layer?.borderColor = NSColor(hex: 0x3D9BFF).withAlphaComponent(0.65).cgColor
            contentTintColor = .white
        case .secondary:
            layer?.backgroundColor = NSColor(hex: 0x17232D).cgColor
            layer?.borderColor = NSColor(hex: 0x31424F).cgColor
            contentTintColor = NSColor(hex: 0xD9E1E7)
        case .ghost:
            layer?.backgroundColor = NSColor(hex: 0x101920).withAlphaComponent(0.72).cgColor
            layer?.borderColor = NSColor(hex: 0x263742).cgColor
            contentTintColor = NSColor(hex: 0xAAB7C1)
        case .danger:
            layer?.backgroundColor = NSColor(hex: 0x3A1B20).cgColor
            layer?.borderColor = NSColor(hex: 0x7B313C).cgColor
            contentTintColor = NSColor(hex: 0xFFB5BD)
        }
    }
    override var isHighlighted: Bool {
        didSet { alphaValue = isHighlighted ? 0.76 : 1.0 }
    }
}

final class RGSpectralShapeView: NSView {
    var tilt: Double = 0 { didSet { needsDisplay = true } }
    var flatten: Double = 0 { didSet { needsDisplay = true } }
    var whistleHz: Double? { didSet { needsDisplay = true } }
    var whistleAmount: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: 0x09131C).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        let grid=NSBezierPath(); for i in 1..<4 { let y=bounds.minY+bounds.height*CGFloat(i)/4; grid.move(to:NSPoint(x:bounds.minX,y:y)); grid.line(to:NSPoint(x:bounds.maxX,y:y)) }
        for i in 1..<5 { let x=bounds.minX+bounds.width*CGFloat(i)/5; grid.move(to:NSPoint(x:x,y:bounds.minY)); grid.line(to:NSPoint(x:x,y:bounds.maxY)) }
        NSColor.white.withAlphaComponent(0.055).setStroke(); grid.lineWidth=0.5; grid.stroke()
        let path=NSBezierPath(); path.lineWidth=1.6
        for i in 0...100 {
            let f=Double(i)/100.0; let hz=2000.0*pow(10.0,f); let x=bounds.minX+CGFloat(f)*bounds.width
            var db=tilt*(f-0.35)*7.0
            db *= (1.0-flatten*0.35)
            if let wh=whistleHz, whistleAmount>0 { let oct=log2(max(100.0,hz)/max(100.0,wh)); db -= whistleAmount*8.0*exp(-oct*oct*42.0) }
            let y=bounds.midY+CGFloat(db/12.0)*bounds.height*0.78
            if i==0 { path.move(to:NSPoint(x:x,y:y)) } else { path.line(to:NSPoint(x:x,y:y)) }
        }
        NSColor(hex:0x62B6FF).setStroke(); path.stroke()
        let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:7,weight:.regular),.foregroundColor:NSColor(hex:0x61798B)]
        ["2k","4k","8k","12k","20k"].enumerated().forEach { i,t in t.draw(at:NSPoint(x:bounds.minX+CGFloat(i)*bounds.width/4-5,y:3),withAttributes:attrs) }
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
    private var dropView: AudioDropView!
    private var currentTimeLabel: NSTextField!
    private var detectedFooter: NSTextField!
    private var pinnedEventLabel: NSTextField!
    private var pinnedGainSlider: NSSlider!
    private var pinnedNoteLabel: NSTextField!
    private var annotationStack: NSStackView!
    private var annotationCountLabel: NSTextField!
    private var editorPanel: NSBox!
    private var annotationsPanel: NSBox!
    private var inspectorToggleButton: NSButton!
    private var inspectorHidden = false
    private var viewTabsControl: NSSegmentedControl!
    private var resonanceSlider: NSSlider!
    private var resonanceValueLabel: NSTextField!
    private var resonanceFreqLabel: NSTextField!
    private var spectralTiltSlider: NSSlider!
    private var spectralTiltValue: NSTextField!
    private var flattenSlider: NSSlider!
    private var flattenValue: NSTextField!
    private var referenceInfoLabel: NSTextField!
    private var spectralShapeView: RGSpectralShapeView!

    private var model = AudioModel()
    private var events: [SibilanceEvent] = []
    private let detector = SibilanceDetector()
    private let progressUI = AnalysisProgressController()
    private let updater = UpdateManager()
    private let sessionStore = SessionStore()
    private let learningStore = RGExemplarStore()
    private var previewPlayer: AVAudioPlayer?
    private var scrubPlayer: AVAudioPlayer?
    private var transportPlayer: AVAudioPlayer?
    private var stopTimer: Timer?
    private var fadeTimer: Timer?
    private var loopEnabled = false
    private var keyMonitor: Any?
    private var transportTimer: Timer?
    private var transportPlaying = false
    private var transportStartTime: Double = 0
    private var typeTrims: [String: Double] = [:]
    private var externalReferenceURL: URL?
    private var externalReferenceModel: AudioModel?
    private var externalReferenceEvents: [SibilanceEvent] = []
    private var levelMatchedAudition = true

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
        let b = RGButton(title: title, target: self, action: action)
        if title.contains("Analyze") || title.contains("AUTO REPAIR") || title.contains("Export") { b.role = .primary }
        else if title == "BAD" { b.role = .danger }
        else if title.contains("Fit") || title == "＋" || title == "−" || title == "◀" || title == "▶" || title == "■" { b.role = .ghost }
        else { b.role = .secondary }
        return b
    }

    private func buildUI() {
        // CLEAN PRO 0.4.0: fixed geometry first. No resize until the visual shell is stable.
        let w: CGFloat = 1460
        let h: CGFloat = 880
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: w, height: h)
        window = NSWindow(
            contentRect: NSRect(x: screen.midX - w/2, y: screen.midY - h/2, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RG Sibilance Studio \(RGVersion) BETA — Clean Pro"
        window.backgroundColor = NSColor(hex: 0x071019)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(hex: 0x071019).cgColor
        window.contentView = root

        // MARK: Header
        let header = NSView(frame: NSRect(x: 0, y: h-72, width: w, height: 72))
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(hex: 0x0A151F).cgColor
        header.layer?.borderColor = NSColor(hex: 0x213442).cgColor
        header.layer?.borderWidth = 0.6
        root.addSubview(header)

        let badge = NSTextField(labelWithString: "RG")
        badge.frame = NSRect(x: 20, y: h-54, width: 30, height: 30)
        badge.alignment = .center; badge.font = NSFont.systemFont(ofSize: 10, weight: .bold); badge.textColor = .white
        badge.wantsLayer = true; badge.layer?.cornerRadius = 15; badge.layer?.borderWidth = 1; badge.layer?.borderColor = NSColor(hex:0x728694).cgColor
        root.addSubview(badge)
        let title=label("RG Sibilance Studio",size:17,weight:.bold,color:.white); title.frame=NSRect(x:60,y:h-46,width:250,height:24); root.addSubview(title)
        let sub=label("Sibilance detection & repair",size:9,color:NSColor(hex:0x728696)); sub.frame=NSRect(x:60,y:h-61,width:220,height:16); root.addSubview(sub)
        fileInfo=label("Drop WAV/AIFF or Open File",size:9,color:NSColor(hex:0x708596)); fileInfo.frame=NSRect(x:360,y:h-49,width:430,height:18); root.addSubview(fileInfo)
        let open=button("Open File",action:#selector(openWav)); open.frame=NSRect(x:850,y:h-55,width:112,height:30); root.addSubview(open)
        analyzeButton=button("Analyze",action:#selector(analyzeAudio)); analyzeButton.frame=NSRect(x:972,y:h-55,width:112,height:30); root.addSubview(analyzeButton)
        inspectorToggleButton=button("Events",action:#selector(toggleInspector)); inspectorToggleButton.frame=NSRect(x:1325,y:h-55,width:94,height:30); root.addSubview(inspectorToggleButton)

        // MARK: Main editor + event inspector
        let margin: CGFloat = 18
        let inspectorW: CGFloat = 278
        let gap: CGFloat = 10
        let editorX=margin, editorY:CGFloat=292, editorW=w-margin*2-inspectorW-gap, editorH:CGFloat=498
        editorPanel=makePanel(NSRect(x:editorX,y:editorY,width:editorW,height:editorH)); editorPanel.fillColor=NSColor(hex:0x0A151E); root.addSubview(editorPanel)

        viewTabsControl=NSSegmentedControl(labels:["WAVEFORM","SPECTROGRAM"],trackingMode:.selectOne,target:self,action:#selector(viewModeChanged(_:)))
        viewTabsControl.selectedSegment=0; viewTabsControl.frame=NSRect(x:14,y:editorH-34,width:190,height:24); viewTabsControl.controlSize = .small; editorPanel.addSubview(viewTabsControl)
        currentTimeLabel=label("00:00.000",size:13,weight:.bold,color:NSColor(hex:0x4AABFF)); currentTimeLabel.font=NSFont.monospacedDigitSystemFont(ofSize:13,weight:.bold); currentTimeLabel.frame=NSRect(x:216,y:editorH-33,width:100,height:22); editorPanel.addSubview(currentTimeLabel)
        pinnedEventLabel=label("NO EVENT SELECTED",size:9,weight:.semibold,color:NSColor(hex:0x7F95A4)); pinnedEventLabel.frame=NSRect(x:330,y:editorH-32,width:250,height:20); editorPanel.addSubview(pinnedEventLabel)
        let pPlay=button("▶",action:#selector(playSelected)); pPlay.frame=NSRect(x:590,y:editorH-35,width:34,height:26); editorPanel.addSubview(pPlay)
        let pGood=button("GOOD",action:#selector(markGood)); pGood.frame=NSRect(x:630,y:editorH-35,width:56,height:26); editorPanel.addSubview(pGood)
        let pBad=button("BAD",action:#selector(markBad)); pBad.frame=NSRect(x:692,y:editorH-35,width:50,height:26); editorPanel.addSubview(pBad)
        let pNote=button("Note",action:#selector(addAnnotation)); pNote.frame=NSRect(x:748,y:editorH-35,width:58,height:26); editorPanel.addSubview(pNote)
        pinnedGainSlider=NSSlider(value:0,minValue:-18,maxValue:0,target:self,action:#selector(pinnedGainChanged(_:))); pinnedGainSlider.frame=NSRect(x:818,y:editorH-32,width:120,height:20); pinnedGainSlider.isEnabled=false; editorPanel.addSubview(pinnedGainSlider)
        pinnedNoteLabel=label("",size:8,color:NSColor(hex:0x647988)); pinnedNoteLabel.frame=NSRect(x:948,y:editorH-31,width:editorW-962,height:18); pinnedNoteLabel.lineBreakMode = .byTruncatingTail; editorPanel.addSubview(pinnedNoteLabel)

        timeline=TimelineView(frame:NSRect(x:10,y:54,width:editorW-20,height:editorH-98))
        timeline.onAudioDrop={ [weak self] u in self?.loadAudio(u) }
        timeline.onSelect={ [weak self] i in self?.selectEvent(i) }
        timeline.onScrub={ [weak self] t,a in self?.currentTimeLabel.stringValue=self?.formatTime(t) ?? "00:00.000"; self?.scrub(to:t,active:a) }
        timeline.onAddSibilance={ [weak self] t in self?.addManualS(at:t) }
        timeline.onDeleteEvent={ [weak self] i in self?.deleteEvent(i) }
        timeline.onEventBoundsChanged={ [weak self] i,a,b in self?.eventBoundsChanged(i,start:a,end:b) }
        timeline.onPlayEvent={ [weak self] i in self?.playRegionOnly(i) }
        timeline.onEventGainChanged={ [weak self] i,g in self?.eventGainChanged(i,gain:g) }
        timeline.onEventFadesChanged={ [weak self] i,a,b in self?.eventFadesChanged(i,fadeIn:a,fadeOut:b) }
        timeline.onCreateEventRegion={ [weak self] a,b in self?.createEventFromSelection(start:a,end:b) }
        editorPanel.addSubview(timeline)

        let zin=button("＋",action:#selector(zoomInTimeline)); zin.frame=NSRect(x:14,y:16,width:30,height:26); editorPanel.addSubview(zin)
        let zout=button("−",action:#selector(zoomOutTimeline)); zout.frame=NSRect(x:48,y:16,width:30,height:26); editorPanel.addSubview(zout)
        let fit=button("Fit",action:#selector(fitTimeline)); fit.frame=NSRect(x:82,y:16,width:42,height:26); editorPanel.addSubview(fit)
        let prevTop=button("◀",action:#selector(previousEvent)); prevTop.frame=NSRect(x:editorW/2-58,y:14,width:34,height:28); editorPanel.addSubview(prevTop)
        let playTop=button("▶",action:#selector(playSelected)); playTop.frame=NSRect(x:editorW/2-18,y:14,width:40,height:28); editorPanel.addSubview(playTop)
        let nextTop=button("▶|",action:#selector(nextEvent)); nextTop.frame=NSRect(x:editorW/2+28,y:14,width:38,height:28); editorPanel.addSubview(nextTop)
        detectedFooter=label("Detected: 0 events",size:9,weight:.semibold,color:NSColor(hex:0x4BAEFF)); detectedFooter.frame=NSRect(x:136,y:20,width:160,height:18); editorPanel.addSubview(detectedFooter)

        annotationsPanel=makePanel(NSRect(x:editorX+editorW+gap,y:editorY,width:inspectorW,height:editorH)); annotationsPanel.fillColor=NSColor(hex:0x0A151E); root.addSubview(annotationsPanel)
        let evTitle=label("EVENTS",size:10,weight:.bold,color:.white); evTitle.frame=NSRect(x:14,y:editorH-31,width:120,height:18); annotationsPanel.addSubview(evTitle)
        let annAdd=button("＋ Add",action:#selector(addAnnotation)); annAdd.frame=NSRect(x:inspectorW-76,y:editorH-36,width:62,height:26); annotationsPanel.addSubview(annAdd)
        annotationCountLabel=label("0 events",size:8,color:NSColor(hex:0x667D8D)); annotationCountLabel.frame=NSRect(x:14,y:12,width:100,height:18); annotationsPanel.addSubview(annotationCountLabel)
        let scroll=NSScrollView(frame:NSRect(x:10,y:36,width:inspectorW-20,height:editorH-78)); scroll.drawsBackground=false; scroll.hasVerticalScroller=true
        annotationStack=NSStackView(frame:NSRect(x:0,y:0,width:inspectorW-38,height:scroll.bounds.height)); annotationStack.orientation = .vertical; annotationStack.alignment = .leading; annotationStack.spacing=5; scroll.documentView=annotationStack; annotationsPanel.addSubview(scroll)

        // MARK: Bottom modules — exact fixed grid, no overlap possible.
        let bottomY:CGFloat=70, bottomH:CGFloat=208
        let detectW:CGFloat=202, repairW:CGFloat=540, refW:CGFloat=224, processW:CGFloat=210, previewW:CGFloat=226
        let x1=margin, x2=x1+detectW+gap, x3=x2+repairW+gap, x4=x3+refW+gap, x5=x4+processW+gap
        let detect=makePanel(NSRect(x:x1,y:bottomY,width:detectW,height:bottomH)); root.addSubview(detect)
        let repair=makePanel(NSRect(x:x2,y:bottomY,width:repairW,height:bottomH)); root.addSubview(repair)
        let ref=makePanel(NSRect(x:x3,y:bottomY,width:refW,height:bottomH)); root.addSubview(ref)
        let process=makePanel(NSRect(x:x4,y:bottomY,width:processW,height:bottomH)); root.addSubview(process)
        let preview=makePanel(NSRect(x:x5,y:bottomY,width:previewW,height:bottomH)); root.addSubview(preview)

        addTitle("DETECTION",to:detect,y:bottomH-28)
        let auto=label("AUTO",size:9,weight:.bold,color:NSColor(hex:0x4AAEFF)); auto.frame=NSRect(x:14,y:bottomH-57,width:50,height:18); detect.addSubview(auto)
        let sens=label("Sensitivity",size:9,color:NSColor(hex:0x8396A4)); sens.frame=NSRect(x:14,y:bottomH-88,width:74,height:18); detect.addSubview(sens)
        sensitivitySlider=NSSlider(value:0.72,minValue:0,maxValue:1,target:self,action:#selector(sensitivityChanged)); sensitivitySlider.frame=NSRect(x:86,y:bottomH-91,width:96,height:20); detect.addSubview(sensitivitySlider)
        let range=label("Range   4.5–12 kHz",size:9,color:NSColor(hex:0x718594)); range.frame=NSRect(x:14,y:bottomH-119,width:150,height:18); detect.addSubview(range)
        let adv=button("Advanced",action:#selector(showAdvancedInfo)); adv.frame=NSRect(x:14,y:44,width:94,height:28); detect.addSubview(adv)
        let mark=button("＋ Mark S",action:#selector(markManualS)); mark.frame=NSRect(x:14,y:10,width:94,height:28); detect.addSubview(mark)
        detectedLabel=label("Detected: 0",size:8,color:NSColor(hex:0x668090)); detectedLabel.frame=NSRect(x:116,y:15,width:78,height:18); detect.addSubview(detectedLabel)

        addTitle("SIBILANCE REPAIR",to:repair,y:bottomH-28)
        let rowLabelX:CGFloat=14, sliderX:CGFloat=110, sliderW:CGFloat=190
        let l1=label("Level",size:9,color:NSColor(hex:0xC2CDD5)); l1.frame=NSRect(x:rowLabelX,y:bottomH-61,width:80,height:18); repair.addSubview(l1)
        repairSlider=NSSlider(value:0.66,minValue:0,maxValue:1,target:self,action:#selector(repairStrengthChanged(_:))); repairSlider.frame=NSRect(x:sliderX,y:bottomH-64,width:sliderW,height:20); repair.addSubview(repairSlider)
        let l2=label("Spectral tone",size:9,color:NSColor(hex:0xC2CDD5)); l2.frame=NSRect(x:rowLabelX,y:bottomH-91,width:90,height:18); repair.addSubview(l2)
        spectralTiltSlider=NSSlider(value:0,minValue:-1,maxValue:1,target:self,action:#selector(spectralTiltChanged(_:))); spectralTiltSlider.frame=NSRect(x:sliderX,y:bottomH-94,width:sliderW,height:20); spectralTiltSlider.isEnabled=false; repair.addSubview(spectralTiltSlider)
        spectralTiltValue=label("NEUTRAL",size:8,weight:.semibold,color:NSColor(hex:0x79BFFF)); spectralTiltValue.frame=NSRect(x:304,y:bottomH-91,width:60,height:18); repair.addSubview(spectralTiltValue)
        let l3=label("Flatten",size:9,color:NSColor(hex:0xC2CDD5)); l3.frame=NSRect(x:rowLabelX,y:bottomH-121,width:80,height:18); repair.addSubview(l3)
        flattenSlider=NSSlider(value:0,minValue:0,maxValue:1,target:self,action:#selector(flattenChanged(_:))); flattenSlider.frame=NSRect(x:sliderX,y:bottomH-124,width:sliderW,height:20); flattenSlider.isEnabled=false; repair.addSubview(flattenSlider)
        flattenValue=label("0%",size:8,weight:.semibold,color:NSColor(hex:0xAFC2D0)); flattenValue.frame=NSRect(x:304,y:bottomH-121,width:40,height:18); repair.addSubview(flattenValue)
        let l4=label("Whistle",size:9,color:NSColor(hex:0xC2CDD5)); l4.frame=NSRect(x:rowLabelX,y:bottomH-151,width:80,height:18); repair.addSubview(l4)
        resonanceSlider=NSSlider(value:0,minValue:0,maxValue:1,target:self,action:#selector(resonanceChanged(_:))); resonanceSlider.frame=NSRect(x:sliderX,y:bottomH-154,width:150,height:20); resonanceSlider.isEnabled=false; repair.addSubview(resonanceSlider)
        resonanceValueLabel=label("0%",size:8,weight:.semibold,color:NSColor(hex:0xAFC2D0)); resonanceValueLabel.frame=NSRect(x:264,y:bottomH-151,width:34,height:18); repair.addSubview(resonanceValueLabel)
        let autoWh=button("AUTO",action:#selector(autoFindWhistle)); autoWh.frame=NSRect(x:302,y:bottomH-158,width:54,height:25); repair.addSubview(autoWh)
        resonanceFreqLabel=label("",size:8,color:NSColor(hex:0x6E8392)); resonanceFreqLabel.frame=NSRect(x:110,y:bottomH-173,width:180,height:15); repair.addSubview(resonanceFreqLabel)
        spectralShapeView=RGSpectralShapeView(frame:NSRect(x:370,y:44,width:154,height:126)); repair.addSubview(spectralShapeView)
        let graphTitle=label("SPECTRAL SHAPE",size:8,weight:.semibold,color:NSColor(hex:0x6F8798)); graphTitle.frame=NSRect(x:370,y:174,width:130,height:16); repair.addSubview(graphTitle)
        let type=label("Type",size:8,color:NSColor(hex:0x758A99)); type.frame=NSRect(x:14,y:14,width:32,height:16); repair.addSubview(type)
        kindPopup=NSPopUpButton(frame:NSRect(x:48,y:8,width:70,height:26),pullsDown:false); kindPopup.addItems(withTitles:["S","Š","Z","C","Č","T","Ť","D","K","P","B","F","CH","OTHER"]); kindPopup.target=self; kindPopup.action=#selector(kindChanged); kindPopup.isEnabled=false; repair.addSubview(kindPopup)
        let good=button("GOOD",action:#selector(markGood)); good.frame=NSRect(x:126,y:8,width:54,height:26); repair.addSubview(good)
        let bad=button("BAD",action:#selector(markBad)); bad.frame=NSRect(x:184,y:8,width:48,height:26); repair.addSubview(bad)
        let target=button("TARGET",action:#selector(markTarget)); target.frame=NSRect(x:236,y:8,width:62,height:26); repair.addSubview(target)
        let normal=button("NORMAL",action:#selector(markNormal)); normal.frame=NSRect(x:302,y:8,width:62,height:26); repair.addSubview(normal)

        addTitle("REFERENCE",to:ref,y:bottomH-28)
        referenceInfoLabel=label("No saved reference",size:8,color:NSColor(hex:0x718897)); referenceInfoLabel.frame=NSRect(x:14,y:bottomH-57,width:194,height:18); referenceInfoLabel.lineBreakMode = .byTruncatingTail; ref.addSubview(referenceInfoLabel)
        let saveRef=button("Save Good",action:#selector(setSelectedAsReference)); saveRef.frame=NSRect(x:14,y:bottomH-94,width:92,height:30); ref.addSubview(saveRef)
        let matchRef=button("Match",action:#selector(matchSelectedToReference)); matchRef.frame=NSRect(x:114,y:bottomH-94,width:92,height:30); ref.addSubview(matchRef)
        let refHint=label("Spectral shape is normalized before matching, then level stays independent.",size:8,color:NSColor(hex:0x627989)); refHint.frame=NSRect(x:14,y:52,width:194,height:44); refHint.lineBreakMode = .byWordWrapping; refHint.maximumNumberOfLines=3; ref.addSubview(refHint)
        let morphStrength=label("Reference character",size:8,color:NSColor(hex:0x6F8493)); morphStrength.frame=NSRect(x:14,y:25,width:150,height:16); ref.addSubview(morphStrength)

        addTitle("PROCESS",to:process,y:bottomH-28)
        autoRepairButton=button("Auto Repair",action:#selector(autoRepairSelected)); autoRepairButton.frame=NSRect(x:14,y:bottomH-70,width:182,height:30); autoRepairButton.isEnabled=false; process.addSubview(autoRepairButton)
        let morph=button("Reference Morph",action:#selector(referenceMorphSelected)); morph.frame=NSRect(x:14,y:bottomH-106,width:182,height:28); process.addSubview(morph)
        let blend=button("Reference Blend",action:#selector(referenceBlendSelected)); blend.frame=NSRect(x:14,y:bottomH-140,width:182,height:28); process.addSubview(blend)
        applySimilarButton=button("Apply Similar",action:#selector(applySimilar)); applySimilarButton.frame=NSRect(x:14,y:18,width:182,height:28); applySimilarButton.isEnabled=false; process.addSubview(applySimilarButton)

        addTitle("PREVIEW & RENDER",to:preview,y:bottomH-28)
        playButton=button("▶  Play",action:#selector(playSelected)); playButton.frame=NSRect(x:14,y:bottomH-70,width:78,height:30); preview.addSubview(playButton)
        loopButton=button("↻",action:#selector(toggleLoop)); loopButton.frame=NSRect(x:98,y:bottomH-70,width:34,height:30); preview.addSubview(loopButton)
        auditionMode=NSSegmentedControl(labels:["ORIG","REPAIR","DELTA","S"],trackingMode:.selectOne,target:self,action:#selector(auditionModeChanged)); auditionMode.selectedSegment=1; auditionMode.frame=NSRect(x:14,y:bottomH-108,width:198,height:26); preview.addSubview(auditionMode)
        exportButton=button("Export RG-SIB",action:#selector(exportAudio)); exportButton.frame=NSRect(x:14,y:50,width:198,height:32); exportButton.isEnabled=false; preview.addSubview(exportButton)
        stopMode=NSSegmentedControl(labels:["CONTINUE","RETURN"],trackingMode:.selectOne,target:self,action:nil); stopMode.selectedSegment=0; stopMode.frame=NSRect(x:14,y:16,width:130,height:26); preview.addSubview(stopMode)
        let prev=button("←",action:#selector(previousEvent)); prev.frame=NSRect(x:150,y:16,width:28,height:26); preview.addSubview(prev)
        let next=button("→",action:#selector(nextEvent)); next.frame=NSRect(x:184,y:16,width:28,height:26); preview.addSubview(next)

        // Hidden compatibility controls used by existing event/session methods. They stay functional but do not clutter Clean Pro.
        typeTrimSlider=NSSlider(value:0,minValue:-12,maxValue:0,target:self,action:#selector(typeTrimChanged)); typeTrimSlider.isHidden=true; root.addSubview(typeTrimSlider)
        typeTrimValue=label("0.0 dB",size:8); typeTrimValue.isHidden=true; root.addSubview(typeTrimValue)
        fadeInSlider=NSSlider(value:12,minValue:0,maxValue:120,target:self,action:#selector(fadeChanged)); fadeInSlider.isHidden=true; root.addSubview(fadeInSlider)
        fadeOutSlider=NSSlider(value:12,minValue:0,maxValue:120,target:self,action:#selector(fadeChanged)); fadeOutSlider.isHidden=true; root.addSubview(fadeOutSlider)
        fadeInValue=label("12 ms",size:8); fadeInValue.isHidden=true; root.addSubview(fadeInValue)
        fadeOutValue=label("12 ms",size:8); fadeOutValue.isHidden=true; root.addSubview(fadeOutValue)
        dropView=AudioDropView(frame:.zero); dropView.isHidden=true; root.addSubview(dropView)

        // Footer
        eventInfo=label("READY",size:8,color:NSColor(hex:0x748997)); eventInfo.frame=NSRect(x:18,y:32,width:1060,height:18); root.addSubview(eventInfo)
        status=label("READY — drop WAV/AIFF",size:9,weight:.bold,color:.systemGreen); status.frame=NSRect(x:18,y:10,width:880,height:18); root.addSubview(status)
        let ver=label("v\(RGVersion) CLEAN PRO BETA",size:8,color:NSColor(hex:0x627A8A)); ver.alignment = .right; ver.frame=NSRect(x:w-260,y:10,width:230,height:18); root.addSubview(ver)

        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }

    private func refreshAnnotationSidebar() {
        guard annotationStack != nil else { return }
        for v in annotationStack.arrangedSubviews { annotationStack.removeArrangedSubview(v); v.removeFromSuperview() }
        annotationCountLabel?.stringValue = "\(events.count) edits"
        for (i,e) in events.enumerated() {
            let note = (e.note?.isEmpty == false) ? e.note! : "No annotation"
            let title = String(format: "%@   [%@]   %.1f dB\n%@", formatTime(e.peakTime), e.kind, e.gainDB, note)
            let b = NSButton(title: title, target: self, action: #selector(selectAnnotationEvent(_:)))
            b.tag = i
            b.bezelStyle = .rounded
            b.alignment = .left
            b.font = NSFont.systemFont(ofSize: 10, weight: i == timeline.selectedIndex ? .semibold : .regular)
            b.contentTintColor = i == timeline.selectedIndex ? NSColor(hex: 0x4AA8FF) : NSColor(hex: 0xD1D8DE)
            b.widthAnchor.constraint(equalToConstant: 236).isActive = true
            b.heightAnchor.constraint(equalToConstant: 42).isActive = true
            annotationStack.addArrangedSubview(b)
        }
        annotationStack.needsLayout = true
    }

    @objc private func selectAnnotationEvent(_ sender: NSButton) {
        guard events.indices.contains(sender.tag) else { return }
        selectEvent(sender.tag)
        timeline.followPlayback(to: events[sender.tag].peakTime)
        playRegionOnly(sender.tag)
    }

    private func formatTime(_ t: Double) -> String {
        let safe = max(0, t)
        return String(format: "%02d:%02d.%03d", Int(safe) / 60, Int(safe) % 60, Int((safe - floor(safe)) * 1000))
    }

    @objc private func viewModeChanged(_ sender: NSSegmentedControl) {
        timeline.displayMode = sender.selectedSegment
        status.stringValue = sender.selectedSegment == 1 ? "SPECTROGRAM VIEW" : "WAVEFORM VIEW"
    }

    @objc private func toggleInspector() {
        guard annotationsPanel != nil else { return }
        inspectorHidden.toggle()
        annotationsPanel.isHidden = inspectorHidden
        inspectorToggleButton.title = inspectorHidden ? "Show Events" : "Events"
        status.stringValue = inspectorHidden ? "EVENTS PANEL HIDDEN" : "EVENTS PANEL VISIBLE"
    }

    @objc private func zoomInTimeline() { timeline.zoomIn() }
    @objc private func zoomOutTimeline() { timeline.zoomOut() }
    @objc private func fitTimeline() { timeline.fitAll() }

    @objc private func editorSensitivityChanged(_ sender: NSSlider) {
        sensitivitySlider.doubleValue = sender.doubleValue
        if let editor = sender.superview, let value = editor.subviews.first(where: { $0.identifier?.rawValue == "editorSensitivityValue" }) as? NSTextField {
            value.stringValue = "\(Int(sender.doubleValue * 100))%"
        }
        sensitivityChanged()
    }

    @objc private func repairStrengthChanged(_ sender: NSSlider) {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else {
            status.stringValue = "SELECT AN EVENT FIRST"
            return
        }
        let amount = min(1, max(0, sender.doubleValue))
        events[i].gainDB = -12.0 * amount
        previewPlayer?.stop()
        transportPlayer?.stop()
        timeline.events = events
        selectEvent(i)
        saveCurrentSession()
        status.stringValue = String(format: "REPAIR STRENGTH %d%% — %.1f dB", Int(amount * 100), events[i].gainDB)
    }

    private func applySpectralShape(to i: Int) {
        guard events.indices.contains(i) else { return }
        let tilt = min(1, max(-1, events[i].spectralTilt ?? 0))
        let flat = min(1, max(0, events[i].spectralFlatten ?? 0))
        let fp = model.fingerprint(for: events[i])
        guard fp.count == 5 else { return }
        let mean = fp.reduce(0,+) / 5.0
        var db = Array(repeating: 0.0, count: 5)
        for b in 0..<5 {
            let flattenDelta = (mean - fp[b]) * 14.0 * flat
            let pos = Double(b) / 4.0
            let tiltDB = tilt * (pos - 0.35) * 7.0
            db[b] = min(3.0, max(-10.0, flattenDelta + tiltDB))
        }
        db[0] = min(1.5, max(-5.0, db[0]))
        db[4] = min(2.0, max(-6.0, db[4]))
        events[i].spectralDB = db
        events[i].repairMethod = "SPECTRAL SHAPE"
    }

    @objc private func spectralTiltChanged(_ sender: NSSlider) {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { return }
        events[i].spectralTilt = sender.doubleValue
        applySpectralShape(to: i)
        timeline.events = events; saveCurrentSession(); previewPlayer?.stop(); transportPlayer?.stop(); selectEvent(i)
        spectralTiltValue.stringValue = sender.doubleValue < -0.08 ? "DARK" : (sender.doubleValue > 0.08 ? "BRIGHT" : "NEUTRAL")
        status.stringValue = String(format: "SPECTRAL TILT %+0.0f%%", sender.doubleValue * 100)
    }

    @objc private func flattenChanged(_ sender: NSSlider) {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { return }
        events[i].spectralFlatten = sender.doubleValue
        applySpectralShape(to: i)
        timeline.events = events; saveCurrentSession(); previewPlayer?.stop(); transportPlayer?.stop(); selectEvent(i)
        flattenValue.stringValue = "\(Int(sender.doubleValue * 100))%"
        status.stringValue = "SPECTRAL FLATTEN \(Int(sender.doubleValue * 100))%"
    }

    @objc private func setSelectedAsReference() {
        guard let i = timeline.selectedIndex, events.indices.contains(i), let url = model.url else { status.stringValue = "SELECT AN EVENT FIRST"; return }
        events[i].userLabel = "GOOD"
        let ex = RGExemplar(kind: events[i].kind, fingerprint: model.fingerprint(for: events[i]), duration: events[i].end-events[i].start, sourcePath: url.path, start: events[i].start, end: events[i].end, createdAt: Date().timeIntervalSince1970)
        learningStore.add(ex)
        timeline.events = events; saveCurrentSession(); selectEvent(i); refreshAnnotationSidebar()
        status.stringValue = "REFERENCE SAVED — [\(events[i].kind)] \(formatTime(events[i].peakTime))"
    }

    @objc private func matchSelectedToReference() {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { status.stringValue = "SELECT AN EVENT FIRST"; return }
        guard let ref = learningStore.best(kind: events[i].kind, excludingPath: nil) else { status.stringValue = "NO SAVED REFERENCE FOR [\(events[i].kind)]"; return }
        let target = model.fingerprint(for: events[i])
        let targetMean = max(1e-6, target.reduce(0,+)/5.0)
        let refMean = max(1e-6, ref.fingerprint.reduce(0,+)/Double(max(1,ref.fingerprint.count)))
        var shape=[Double]()
        for b in 0..<5 {
            let t = target[b]/targetMean
            let r = ref.fingerprint[b]/refMean
            let delta = 20.0 * log10(max(0.05,r)/max(0.05,t))
            shape.append(min(3.0,max(-10.0,delta*0.72)))
        }
        shape[4] = min(2.0,max(-5.0,shape[4]))
        events[i].spectralDB = shape
        events[i].gainDB = min(0, max(-12, events[i].gainDB))
        events[i].repairMethod = "REFERENCE MATCH"
        events[i].referenceInfluence = 0.72
        timeline.events=events; saveCurrentSession(); previewPlayer?.stop(); transportPlayer?.stop(); selectEvent(i)
        status.stringValue = "MATCHED TO SAVED [\(events[i].kind)] REFERENCE — spectral shape + level preserved"
    }

    @objc private func resonanceChanged(_ sender: NSSlider) {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { return }
        let amount = min(1, max(0, sender.doubleValue))
        events[i].resonanceAmount = amount
        if events[i].resonanceHz == nil { autoSetWhistleFrequency(for: i) }
        if events[i].resonanceQ == nil { events[i].resonanceQ = 7.0 }
        events[i].repairMethod = amount > 0 ? "WHISTLE" : events[i].repairMethod
        resonanceValueLabel.stringValue = "\(Int(amount * 100))%"
        timeline.events = events
        saveCurrentSession()
        previewPlayer?.stop(); transportPlayer?.stop()
        selectEvent(i)
        status.stringValue = String(format: "WHISTLE SUPPRESSION %d%% @ %.1f kHz", Int(amount * 100), (events[i].resonanceHz ?? 8500) / 1000.0)
    }

    private func autoSetWhistleFrequency(for i: Int) {
        guard events.indices.contains(i) else { return }
        let fp = model.fingerprint(for: events[i])
        guard fp.count >= 5 else { events[i].resonanceHz = 8500; events[i].resonanceQ = 7; return }
        let candidates: [(Int, Double)] = [(1, 5600), (2, 8500), (3, 11600), (4, 15000)]
        let best = candidates.max { fp[$0.0] < fp[$1.0] }
        events[i].resonanceHz = best?.1 ?? 8500
        events[i].resonanceQ = (best?.0 == 2 || best?.0 == 3) ? 8.5 : 6.5
    }

    @objc private func autoFindWhistle() {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { status.stringValue = "SELECT AN EVENT FIRST"; return }
        autoSetWhistleFrequency(for: i)
        if (events[i].resonanceAmount ?? 0) < 0.01 { events[i].resonanceAmount = 0.55 }
        timeline.events = events
        saveCurrentSession()
        selectEvent(i)
        status.stringValue = String(format: "WHISTLE FOUND — %.1f kHz • Q %.1f • suppression %d%%", (events[i].resonanceHz ?? 8500) / 1000.0, events[i].resonanceQ ?? 7.0, Int((events[i].resonanceAmount ?? 0) * 100))
        playRegionOnly(i)
    }

    @objc private func showAdvancedInfo() {
        status.stringValue = "ADVANCED — direct event handles, TYPE TRIM, crossfades and detector controls remain available"
    }

    private func referenceExemplar(for event: SibilanceEvent) -> RGExemplar? {
        if let learned = learningStore.best(kind: event.kind, excludingPath: model.url?.path) { return learned }
        if let learned = learningStore.best(kind: event.kind, excludingPath: nil) { return learned }
        if let refModel = externalReferenceModel, let refURL = externalReferenceURL, !externalReferenceEvents.isEmpty {
            let candidates = externalReferenceEvents.filter { $0.kind == event.kind || event.kind == "S" || $0.kind == "S" }
            let donor = (candidates.isEmpty ? externalReferenceEvents : candidates).max { $0.score < $1.score }
            if let d = donor {
                return RGExemplar(kind: event.kind, fingerprint: refModel.fingerprint(for: d), duration: d.end - d.start, sourcePath: refURL.path, start: d.start, end: d.end, createdAt: Date().timeIntervalSince1970)
            }
        }
        return nil
    }

    private func ensureReferenceLoaded() -> Bool {
        if externalReferenceModel != nil { return true }
        let p = NSOpenPanel()
        p.title = "Choose reference vocal"
        p.allowedFileTypes = ["wav", "wave", "aif", "aiff"]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return false }
        do {
            let m = AudioModel()
            try m.load(url)
            let found = detector.detect(samples: m.samples, sampleRate: m.sampleRate, sensitivity: 0.72) { _ in }
            externalReferenceURL = url
            externalReferenceModel = m
            externalReferenceEvents = found
            status.stringValue = "REFERENCE LOADED — \(url.lastPathComponent) • \(found.count) candidate events"
            return true
        } catch {
            status.stringValue = "REFERENCE LOAD FAILED — \(error.localizedDescription)"
            return false
        }
    }

    private func spectralMatch(target: [Double], reference: [Double], influence: Double, safeOnly: Bool) -> [Double] {
        var out: [Double] = []
        for i in 0..<5 {
            let deltaNorm = (reference[i] - target[i])
            var db = deltaNorm * 18.0 * influence
            if safeOnly { db = min(0, db) }
            db = min(3.0, max(-10.0, db))
            // Protect top air band more strongly.
            if i == 4 { db = min(1.5, max(-4.0, db)) }
            out.append(db)
        }
        return out
    }

    @objc private func referenceMorphSelected() {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { status.stringValue = "SELECT AN EVENT FIRST"; return }
        var exemplar = referenceExemplar(for: events[i])
        if exemplar == nil {
            guard ensureReferenceLoaded() else { status.stringValue = "MARK A GOOD EVENT OR LOAD A REFERENCE"; return }
            exemplar = referenceExemplar(for: events[i])
        }
        guard let ex = exemplar else { status.stringValue = "NO MATCHING REFERENCE EVENT"; return }
        let target = model.fingerprint(for: events[i])
        events[i].spectralDB = spectralMatch(target: target, reference: ex.fingerprint, influence: 0.68, safeOnly: false)
        events[i].repairMethod = "MORPH"
        events[i].referenceInfluence = 0.68
        events[i].donorPath = nil
        events[i].blendAmount = nil
        timeline.events = events
        previewPlayer?.stop(); transportPlayer?.stop()
        selectEvent(i); saveCurrentSession()
        status.stringValue = "REFERENCE MORPH — [\(events[i].kind)] 68% • Air protected"
        playRegionOnly(i)
    }

    @objc private func referenceBlendSelected() {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { status.stringValue = "SELECT AN EVENT FIRST"; return }
        var exemplar = referenceExemplar(for: events[i])
        if exemplar == nil {
            guard ensureReferenceLoaded() else { status.stringValue = "MARK A GOOD EVENT OR LOAD A REFERENCE"; return }
            exemplar = referenceExemplar(for: events[i])
        }
        guard let ex = exemplar else { status.stringValue = "NO MATCHING REFERENCE EVENT"; return }
        let target = model.fingerprint(for: events[i])
        events[i].spectralDB = spectralMatch(target: target, reference: ex.fingerprint, influence: 0.38, safeOnly: false)
        events[i].repairMethod = "BLEND"
        events[i].referenceInfluence = 0.38
        events[i].donorPath = ex.sourcePath
        events[i].donorStart = ex.start
        events[i].donorEnd = ex.end
        events[i].blendAmount = 0.28
        timeline.events = events
        previewPlayer?.stop(); transportPlayer?.stop()
        selectEvent(i); saveCurrentSession()
        status.stringValue = "REFERENCE BLEND — donor noise 28% + spectral match"
        playRegionOnly(i)
    }

    private func makePanel(_ frame: NSRect) -> NSBox {
        let p = NSBox(frame: frame)
        p.boxType = .custom
        p.borderColor = NSColor(hex: 0x263744)
        p.fillColor = NSColor(hex: 0x0D151C)
        p.cornerRadius = 6
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
                    self.typeTrims = [:]
                    self.scrubPlayer = scrub
                    self.timeline.model = m
                    self.timeline.typeTrims = [:]
                    self.timeline.events = []
                    self.timeline.selectedIndex = nil
                    self.timeline.playhead = 0
                    self.fileInfo.stringValue = "\(url.lastPathComponent)   •   \(Int(m.sampleRate)) Hz   •   \(m.channels) ch   •   \(String(format: "%.2f", m.duration)) s"
                    self.detectedLabel.stringValue = "Detected: 0 events"
                    if let session = self.sessionStore.load(for: url, duration: m.duration, sampleRate: m.sampleRate) {
                        self.events = session.events
                        self.typeTrims = session.typeTrims
                        self.timeline.typeTrims = session.typeTrims
                        self.timeline.events = session.events
                        self.refreshAnnotationSidebar()
                        let restoredIndex = min(max(0, session.selectedIndex ?? 0), max(0, session.events.count - 1))
                        self.timeline.selectedIndex = session.events.isEmpty ? nil : restoredIndex
                        self.timeline.playhead = min(m.duration, max(0, session.playhead ?? 0))
                        self.sensitivitySlider.doubleValue = min(1, max(0, session.sensitivity ?? self.sensitivitySlider.doubleValue))
                        self.auditionMode.selectedSegment = min(3, max(0, session.auditionMode ?? 1))
                        self.exportButton.isEnabled = true
                        self.detectedLabel.stringValue = "Restored: \(session.events.count) events"
                        self.detectedFooter?.stringValue = "Detected: \(session.events.count) events"
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
                self.refreshAnnotationSidebar()
                self.timeline.selectedIndex = found.isEmpty ? nil : 0
                self.detectedLabel.stringValue = "Detected: \(found.count) events"
                self.detectedFooter?.stringValue = "Detected: \(found.count) events"
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
        detectedFooter?.stringValue = "Detected: \(events.count) events"
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
        currentTimeLabel?.stringValue = formatTime(e.peakTime)
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
        pinnedEventLabel?.stringValue = String(format: "#%03d  [%@]  %.3f–%.3f", i + 1, e.kind, e.start, e.end)
        pinnedGainSlider?.isEnabled = true
        pinnedGainSlider?.doubleValue = e.gainDB
        pinnedNoteLabel?.stringValue = (e.note?.isEmpty == false) ? "✎ \(e.note!)" : "No annotation"
        resonanceSlider?.isEnabled = ["S", "Š", "Z", "C", "Č", "CH"].contains(e.kind)
        resonanceSlider?.doubleValue = min(1, max(0, e.resonanceAmount ?? 0))
        resonanceValueLabel?.stringValue = "\(Int((e.resonanceAmount ?? 0) * 100))%"
        if let hz = e.resonanceHz { resonanceFreqLabel?.stringValue = String(format: "%.1f kHz  Q %.1f", hz / 1000.0, e.resonanceQ ?? 7.0) }
        else { resonanceFreqLabel?.stringValue = "AUTO frequency not set" }
        spectralTiltSlider?.isEnabled = ["S", "Š", "Z", "C", "Č", "CH"].contains(e.kind)
        spectralTiltSlider?.doubleValue = e.spectralTilt ?? 0
        let tilt = e.spectralTilt ?? 0
        spectralTiltValue?.stringValue = tilt < -0.08 ? "DARK" : (tilt > 0.08 ? "BRIGHT" : "NEUTRAL")
        flattenSlider?.isEnabled = ["S", "Š", "Z", "C", "Č", "CH"].contains(e.kind)
        flattenSlider?.doubleValue = e.spectralFlatten ?? 0
        flattenValue?.stringValue = "\(Int((e.spectralFlatten ?? 0) * 100))%"
        let refs = learningStore.count(kind: e.kind)
        referenceInfoLabel?.stringValue = refs > 0 ? "\(refs) saved [\(e.kind)] reference\(refs == 1 ? "" : "s")" : "No saved [\(e.kind)] reference"
        spectralShapeView?.tilt = e.spectralTilt ?? 0
        spectralShapeView?.flatten = e.spectralFlatten ?? 0
        spectralShapeView?.whistleHz = e.resonanceHz
        spectralShapeView?.whistleAmount = e.resonanceAmount ?? 0
        eventInfo.stringValue = String(format: "#%03d [%@]  %.3f–%.3f s  %.0f ms  GAIN %.1f dB  IN %.0f / OUT %.0f ms  %@  •  %@", i + 1, e.kind, e.start, e.end, (e.end - e.start) * 1000, e.gainDB, e.fadeIn * 1000, e.fadeOut * 1000, e.userLabel.isEmpty ? "UNRATED" : e.userLabel, "METHOD \(e.repairMethod ?? "MANUAL") • \(RGRepairAdvisor.qualityText(for: e))")
        refreshAnnotationSidebar()
    }

    @objc private func pinnedGainChanged(_ sender: NSSlider) {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { return }
        eventGainChanged(i, gain: sender.doubleValue)
    }

    @objc private func addAnnotation() {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { status.stringValue = "SELECT AN EVENT FIRST"; return }
        let alert = NSAlert()
        alert.messageText = "Event annotation"
        alert.informativeText = "Add a note to event #\(i + 1) [\(events[i].kind)]. It will stay attached to this event and appear on the waveform."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "e.g. too sharp, whistle, keep air, good reference…"
        field.stringValue = events[i].note ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        let r = alert.runModal()
        if r == .alertFirstButtonReturn {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            events[i].note = text.isEmpty ? nil : text
        } else if r == .alertSecondButtonReturn {
            events[i].note = nil
        } else { return }
        timeline.events = events
        selectEvent(i)
        refreshAnnotationSidebar()
        saveCurrentSession()
        status.stringValue = events[i].note == nil ? "ANNOTATION CLEARED" : "ANNOTATION SAVED — EVENT #\(i + 1)"
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
        previewPlayer?.stop()
        transportPlayer?.stop()
        timeline.events = events
        selectEvent(i)
        saveCurrentSession()
        status.stringValue = String(format: "EVENT #%d GAIN %.1f dB", i + 1, events[i].gainDB)
    }

    private func eventFadesChanged(_ i: Int, fadeIn: Double, fadeOut: Double) {
        guard events.indices.contains(i) else { return }
        events[i].fadeIn = fadeIn
        events[i].fadeOut = fadeOut
        previewPlayer?.stop()
        transportPlayer?.stop()
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
        timeline.typeTrims = typeTrims
        previewPlayer?.stop()
        transportPlayer?.stop()
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

    @objc private func markGood() {
        mark("GOOD")
        guard let i = timeline.selectedIndex, events.indices.contains(i), let url = model.url else { return }
        let e = events[i]
        let ex = RGExemplar(kind: e.kind, fingerprint: model.fingerprint(for: e), duration: e.end - e.start, sourcePath: url.path, start: e.start, end: e.end, createdAt: Date().timeIntervalSince1970)
        learningStore.add(ex)
        status.stringValue = "GOOD EXEMPLAR SAVED — [\(e.kind)] • library \(learningStore.count(kind: e.kind))"
    }
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
        detectedFooter?.stringValue = "Detected: \(events.count) events"
        if let i = events.firstIndex(where: { abs($0.peakTime - clamped) < 0.0001 }) { selectEvent(i) }
        saveCurrentSession()
        status.stringValue = "MANUAL SIBILANCE ADDED"
    }

    private func deleteEvent(_ i: Int) {
        guard events.indices.contains(i) else { return }
        events.remove(at: i)
        timeline.events = events
        detectedLabel.stringValue = "Detected: \(events.count) events"
        detectedFooter?.stringValue = "Detected: \(events.count) events"
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

    private func activeTransportPlayer() -> AVAudioPlayer? {
        return transportPlayer ?? scrubPlayer
    }

    private func startTransport() {
        guard let url = model.url, model.duration > 0 else { return }
        previewPlayer?.stop()
        stopTimer?.invalidate()
        let mode = RGAuditionMode.from(segment: auditionMode?.selectedSegment ?? 1)
        let repaired = mode != .original
        transportPlayer?.stop()
        transportPlayer = nil
        do {
            let p: AVAudioPlayer
            if repaired {
                status.stringValue = "RENDERING REPAIR PREVIEW…"
                let rendered = try RGRenderEngine.renderFullPreviewMode(sourceURL: url, events: events, typeTrims: typeTrims, mode: mode, levelMatched: levelMatchedAudition)
                p = try AVAudioPlayer(contentsOf: rendered)
                transportPlayer = p
            } else if let original = scrubPlayer {
                p = original
            } else {
                p = try AVAudioPlayer(contentsOf: url)
                scrubPlayer = p
            }
            transportStartTime = min(max(0, timeline.playhead), max(0, p.duration - 0.01))
            p.currentTime = transportStartTime
            p.play()
            transportPlaying = true
            playButton.title = "■ Stop"
            status.stringValue = repaired ? "PLAYING \(mode.displayName) — rendered DSP" : "PLAYING ORIGINAL"
            transportTimer?.invalidate()
            transportTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self = self, let player = self.activeTransportPlayer() else { return }
                self.timeline.followPlayback(to: player.currentTime)
                self.currentTimeLabel?.stringValue = self.formatTime(player.currentTime)
                if !player.isPlaying && self.transportPlaying {
                    self.transportPlaying = false
                    self.transportTimer?.invalidate()
                    self.playButton.title = "▶  Play"
                    self.status.stringValue = "PLAYBACK END"
                }
            }
        } catch {
            status.stringValue = "REPAIR PREVIEW FAILED — \(error.localizedDescription)"
        }
    }

    private func stopTransport() {
        guard let p = activeTransportPlayer() else { return }
        let stoppedAt = p.currentTime
        p.pause()
        transportPlaying = false
        transportTimer?.invalidate()
        transportTimer = nil
        if stopMode.selectedSegment == 1 {
            p.currentTime = transportStartTime
            timeline.followPlayback(to: transportStartTime)
            currentTimeLabel?.stringValue = formatTime(transportStartTime)
            status.stringValue = "STOP — returned to start"
        } else {
            timeline.followPlayback(to: stoppedAt)
            currentTimeLabel?.stringValue = formatTime(stoppedAt)
            status.stringValue = "STOP — locator stays at stop position"
        }
        playButton.title = "▶  Play"
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
        let mode = RGAuditionMode.from(segment: auditionMode?.selectedSegment ?? 1)
        do {
            let rendered = try RGRenderEngine.renderAuditionMode(sourceURL: url, events: events, typeTrims: typeTrims, startTime: e.start, endTime: e.end, mode: mode, levelMatched: levelMatchedAudition)
            let p = try AVAudioPlayer(contentsOf: rendered)
            p.delegate = self
            previewPlayer = p
            p.currentTime = 0
            p.play()
            timeline.playhead = e.start
            currentTimeLabel?.stringValue = formatTime(e.start)
            playButton.title = "■ Stop"
            let effectiveDB = mode == .original ? 0 : min(0, e.gainDB + (typeTrims[e.kind] ?? 0))
            status.stringValue = String(format: "REGION %@ [%@] %.3f–%.3f s  %.1f dB  IN %.0f / OUT %.0f ms", mode.displayName, e.kind, e.start, e.end, effectiveDB, e.fadeIn * 1000, e.fadeOut * 1000)
            stopTimer = Timer.scheduledTimer(withTimeInterval: max(0.02, e.end - e.start), repeats: false) { [weak self] _ in
                self?.previewPlayer?.stop()
                self?.playButton.title = "▶  Play"
            }
        } catch {
            status.stringValue = "REGION PLAYBACK FAILED — \(error.localizedDescription)"
        }
    }

    @objc private func auditionModeChanged() {
        previewPlayer?.stop()
        transportPlayer?.stop()
        transportPlaying = false
        transportTimer?.invalidate()
        saveCurrentSession()
        status.stringValue = "AUDITION — \(RGAuditionMode.from(segment: auditionMode.selectedSegment).displayName)"
        if let i = timeline.selectedIndex { playRegionOnly(i) }
    }

    @objc private func autoRepairSelected() {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { return }
        let length = max(0.015, events[i].end - events[i].start)
        let base = RGRepairAdvisor.recommendedGain(for: events[i])
        // Minimum intervention: broadband correction is deliberately smaller when a learned spectral target exists.
        if let ex = referenceExemplar(for: events[i]) {
            let target = model.fingerprint(for: events[i])
            events[i].spectralDB = spectralMatch(target: target, reference: ex.fingerprint, influence: 0.52, safeOnly: true)
            events[i].gainDB = max(-4.0, base * 0.48)
            events[i].repairMethod = "SELF SAFE"
            events[i].referenceInfluence = 0.52
        } else {
            events[i].spectralDB = nil
            events[i].gainDB = base
            events[i].repairMethod = "GAIN SAFE"
        }
        events[i].fadeIn = min(0.018, length * 0.22)
        events[i].fadeOut = min(0.018, length * 0.22)
        timeline.events = events
        previewPlayer?.stop(); transportPlayer?.stop()
        selectEvent(i)
        saveCurrentSession()
        status.stringValue = String(format: "AUTO SAFE — [%@] %.1f dB • %@", events[i].kind, events[i].gainDB, events[i].repairMethod ?? "SAFE")
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
            events[j].spectralDB = source.spectralDB
            events[j].repairMethod = source.repairMethod
            events[j].referenceInfluence = source.referenceInfluence
            events[j].donorPath = source.donorPath
            events[j].donorStart = source.donorStart
            events[j].donorEnd = source.donorEnd
            events[j].blendAmount = source.blendAmount
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
        if transportPlaying { stopTransport() }
        stopTimer?.invalidate()
        fadeTimer?.invalidate()
        previewPlayer?.stop()
        do {
            if let i = timeline.selectedIndex, events.indices.contains(i) {
                let e = events[i]
                let pre = max(0, e.start - 0.30)
                let post = min(model.duration, e.end + 0.40)
                let mode = RGAuditionMode.from(segment: auditionMode?.selectedSegment ?? 1)
                let rendered = try RGRenderEngine.renderAuditionMode(sourceURL: url, events: events, typeTrims: typeTrims, startTime: pre, endTime: post, mode: mode, levelMatched: levelMatchedAudition)
                let p = try AVAudioPlayer(contentsOf: rendered)
                p.delegate = self
                previewPlayer = p
                p.currentTime = 0
                p.play()
                playButton.title = "■ Stop"
                status.stringValue = "CONTEXT — \(mode.displayName)"
                stopTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, post - pre), repeats: false) { [weak self] _ in self?.finishPreview() }
            } else {
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                previewPlayer = p
                p.currentTime = timeline.playhead
                p.play()
            }
        } catch {
            status.stringValue = "PLAYBACK FAILED — \(error.localizedDescription)"
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

@main
struct RGSibilanceStudioMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
