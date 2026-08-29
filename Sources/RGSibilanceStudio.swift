import Cocoa
import AVFoundation
import Foundation

let RGVersion = "0.2.29"
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
    var spectralDB: [Double]? = nil
    var repairMethod: String? = nil
    var donorPath: String? = nil
    var donorStart: Double? = nil
    var donorEnd: Double? = nil
    var blendAmount: Double? = nil
    var referenceInfluence: Double? = nil
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
        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)
        NSGraphicsContext.current?.cgContext.setAllowsAntialiasing(true)

        let pixelColumns = max(240, Int(plotRect.width * 2.0))
        let startSample = max(0, min(m.samples.count - 1, Int(viewStart * m.sampleRate)))
        let endSample = max(startSample + 1, min(m.samples.count, Int(viewEnd * m.sampleRate) + 1))
        let visibleSamples = max(1, endSample - startSample)
        let samplesPerColumn = Double(visibleSamples) / Double(pixelColumns)
        let amp = plotRect.height * 0.47 * fixedVerticalScale

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
                let y = plotRect.midY + CGFloat(v) * g * amp
                if c == 0 { trace.move(to: NSPoint(x: x, y: y)) }
                else { trace.line(to: NSPoint(x: x, y: y)) }
            }
            NSColor(hex: 0x42B0FF).setStroke()
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
                    let prevTop = Float((tops.last!.y - plotRect.midY) / max(0.0001, amp))
                    let prevBottom = Float((bottoms.last!.y - plotRect.midY) / max(0.0001, amp))
                    mx = mx * 0.78 + prevTop * 0.22
                    mn = mn * 0.78 + prevBottom * 0.22
                }
                let f = Double(c) / Double(max(1, pixelColumns - 1))
                let t = viewStart + f * visibleDuration
                let g = CGFloat(visualGain(at: t))
                let x = plotRect.minX + CGFloat(f) * plotRect.width
                tops.append(NSPoint(x: x, y: plotRect.midY + CGFloat(mx) * g * amp))
                bottoms.append(NSPoint(x: x, y: plotRect.midY + CGFloat(mn) * g * amp))
            }

            let fill = NSBezierPath()
            if let first = tops.first { fill.move(to: first) }
            for pt in tops.dropFirst() { fill.line(to: pt) }
            for pt in bottoms.reversed() { fill.line(to: pt) }
            fill.close()
            NSColor(hex: 0x269AF4, alpha: 0.42).setFill()
            fill.fill()

            let topPath = NSBezierPath()
            let bottomPath = NSBezierPath()
            topPath.lineJoinStyle = .round; bottomPath.lineJoinStyle = .round
            if let first = tops.first { topPath.move(to: first) }
            for pt in tops.dropFirst() { topPath.line(to: pt) }
            if let first = bottoms.first { bottomPath.move(to: first) }
            for pt in bottoms.dropFirst() { bottomPath.line(to: pt) }
            NSColor(hex: 0x45B2FF).setStroke()
            topPath.lineWidth = 0.9; bottomPath.lineWidth = 0.9
            topPath.stroke(); bottomPath.stroke()
        }

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
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func buildUI() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1510, height: 980)
        let w = min(CGFloat(1500), screen.width - 28)
        let h = min(CGFloat(970), screen.height - 28)
        window = NSWindow(
            contentRect: NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RG Sibilance Studio \(RGVersion) BETA"
        window.backgroundColor = NSColor(hex: 0x0A1016)
        window.titlebarAppearsTransparent = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(hex: 0x0A1016).cgColor
        window.contentView = root

        let title = label("RG Sibilance Studio", size: 28, weight: .bold, color: .white)
        title.frame = NSRect(x: 42, y: h - 75, width: 460, height: 38)
        root.addSubview(title)
        let subtitle = label("Sibilance detection & repair   •   AUTO UPDATE BETA", size: 12, color: NSColor(hex: 0x8D9AA6))
        subtitle.frame = NSRect(x: 44, y: h - 101, width: 540, height: 20)
        root.addSubview(subtitle)

        analyzeButton = button("⌁  Analyze", action: #selector(analyzeAudio))
        analyzeButton.frame = NSRect(x: w - 378, y: h - 84, width: 176, height: 40)
        analyzeButton.bezelColor = NSColor(hex: 0x1578E8)
        root.addSubview(analyzeButton)
        let open = button("▱  Open WAV", action: #selector(openWav))
        open.frame = NSRect(x: w - 188, y: h - 84, width: 146, height: 40)
        root.addSubview(open)

        dropView = AudioDropView(frame: NSRect(x: 42, y: h - 283, width: w - 84, height: 160))
        dropView.onAudioDrop = { [weak self] url in self?.loadAudio(url) }
        root.addSubview(dropView)

        let editorY = h - 674
        let editorH: CGFloat = 368
        let editor = makePanel(NSRect(x: 42, y: editorY, width: w - 84, height: editorH))
        editor.fillColor = NSColor(hex: 0x0C141B)
        root.addSubview(editor)

        currentTimeLabel = label("00:00.000", size: 16, weight: .bold, color: NSColor(hex: 0x3198FF))
        currentTimeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .bold)
        currentTimeLabel.frame = NSRect(x: 16, y: editorH - 37, width: 150, height: 24)
        editor.addSubview(currentTimeLabel)

        let timeHint = label("locator / selected event", size: 9, color: NSColor(hex: 0x637482))
        timeHint.frame = NSRect(x: 166, y: editorH - 34, width: 150, height: 18)
        editor.addSubview(timeHint)

        timeline = TimelineView(frame: NSRect(x: 12, y: 52, width: editor.bounds.width - 66, height: editorH - 92))
        timeline.onAudioDrop = { [weak self] url in self?.loadAudio(url) }
        timeline.onSelect = { [weak self] i in self?.selectEvent(i) }
        timeline.onScrub = { [weak self] t, active in
            self?.currentTimeLabel.stringValue = self?.formatTime(t) ?? "00:00.000"
            self?.scrub(to: t, active: active)
        }
        timeline.onAddSibilance = { [weak self] t in self?.addManualS(at: t) }
        timeline.onDeleteEvent = { [weak self] i in self?.deleteEvent(i) }
        timeline.onEventBoundsChanged = { [weak self] i, start, end in self?.eventBoundsChanged(i, start: start, end: end) }
        timeline.onPlayEvent = { [weak self] i in self?.playRegionOnly(i) }
        timeline.onEventGainChanged = { [weak self] i, gain in self?.eventGainChanged(i, gain: gain) }
        timeline.onEventFadesChanged = { [weak self] i, fadeIn, fadeOut in self?.eventFadesChanged(i, fadeIn: fadeIn, fadeOut: fadeOut) }
        timeline.onCreateEventRegion = { [weak self] start, end in self?.createEventFromSelection(start: start, end: end) }
        editor.addSubview(timeline)

        let zoomIn = button("+", action: #selector(zoomInTimeline)); zoomIn.frame = NSRect(x: editor.bounds.width - 45, y: editorH - 78, width: 32, height: 30); editor.addSubview(zoomIn)
        let zoomOut = button("−", action: #selector(zoomOutTimeline)); zoomOut.frame = NSRect(x: editor.bounds.width - 45, y: editorH - 113, width: 32, height: 30); editor.addSubview(zoomOut)
        let fit = button("Fit", action: #selector(fitTimeline)); fit.frame = NSRect(x: editor.bounds.width - 48, y: editorH - 149, width: 38, height: 30); editor.addSubview(fit)

        detectedFooter = label("Detected: 0 events", size: 11, weight: .semibold, color: NSColor(hex: 0x329CFF))
        detectedFooter.frame = NSRect(x: 16, y: 16, width: 180, height: 20)
        editor.addSubview(detectedFooter)
        let legend = label("●  S / Š      ●  T / Ť      ●  C / Č      ●  Z / Ž", size: 10, color: NSColor(hex: 0x9FAAB4))
        legend.frame = NSRect(x: 390, y: 16, width: 390, height: 20)
        editor.addSubview(legend)
        let sensText = label("Sensitivity", size: 10, color: NSColor(hex: 0x9FAAB4))
        sensText.frame = NSRect(x: editor.bounds.width - 278, y: 16, width: 78, height: 20)
        editor.addSubview(sensText)
        let editorSensitivity = NSSlider(value: 0.72, minValue: 0, maxValue: 1, target: self, action: #selector(editorSensitivityChanged(_:)))
        editorSensitivity.frame = NSRect(x: editor.bounds.width - 196, y: 14, width: 132, height: 22)
        editorSensitivity.identifier = NSUserInterfaceItemIdentifier("editorSensitivity")
        editor.addSubview(editorSensitivity)
        let sensValue = label("72%", size: 10, weight: .semibold, color: NSColor(hex: 0xBFC8D0))
        sensValue.frame = NSRect(x: editor.bounds.width - 58, y: 16, width: 45, height: 20)
        sensValue.identifier = NSUserInterfaceItemIdentifier("editorSensitivityValue")
        editor.addSubview(sensValue)

        let panelY: CGFloat = 58
        let panelH = max(CGFloat(216), editorY - 72)
        let gap: CGFloat = 12
        let leftW: CGFloat = (w - 108) * 0.285
        let centerW: CGFloat = (w - 108) * 0.37
        let rightW = w - 84 - leftW - centerW - gap * 2
        let p1 = makePanel(NSRect(x: 42, y: panelY, width: leftW, height: panelH))
        let p2 = makePanel(NSRect(x: 42 + leftW + gap, y: panelY, width: centerW, height: panelH))
        let p3 = makePanel(NSRect(x: 42 + leftW + centerW + gap * 2, y: panelY, width: rightW, height: panelH))
        root.addSubview(p1); root.addSubview(p2); root.addSubview(p3)

        addTitle("DETECTION", to: p1, y: panelH - 30)
        let gear = button("⚙", action: #selector(showAdvancedInfo)); gear.frame = NSRect(x: leftW - 48, y: panelH - 43, width: 32, height: 28); p1.addSubview(gear)
        let sl = label("Sensitivity", size: 11); sl.frame = NSRect(x: 16, y: panelH - 74, width: 92, height: 18); p1.addSubview(sl)
        sensitivitySlider = NSSlider(value: 0.72, minValue: 0, maxValue: 1, target: self, action: #selector(sensitivityChanged))
        sensitivitySlider.frame = NSRect(x: 118, y: panelH - 78, width: leftW - 178, height: 22); p1.addSubview(sensitivitySlider)
        let detectHelp = label("Advanced detector limits and phoneme options stay under ⚙", size: 10, color: NSColor(hex: 0x667784))
        detectHelp.frame = NSRect(x: 16, y: 64, width: leftW - 32, height: 34); detectHelp.lineBreakMode = .byWordWrapping; detectHelp.maximumNumberOfLines = 2; p1.addSubview(detectHelp)
        let markS = button("+ Mark S at playhead", action: #selector(markManualS)); markS.frame = NSRect(x: 16, y: 18, width: 164, height: 30); p1.addSubview(markS)

        addTitle("REPAIR", to: p2, y: panelH - 30)
        let good = button("GOOD", action: #selector(markGood)); good.frame = NSRect(x: 16, y: panelH - 73, width: 74, height: 28)
        let bad = button("BAD", action: #selector(markBad)); bad.frame = NSRect(x: 96, y: panelH - 73, width: 70, height: 28)
        let target = button("TARGET", action: #selector(markTarget)); target.frame = NSRect(x: 172, y: panelH - 73, width: 82, height: 28)
        let normal = button("NORMAL", action: #selector(markNormal)); normal.frame = NSRect(x: 260, y: panelH - 73, width: 86, height: 28)
        p2.addSubview(good); p2.addSubview(bad); p2.addSubview(target); p2.addSubview(normal)

        let typeLabel = label("Type", size: 10); typeLabel.frame = NSRect(x: centerW - 142, y: panelH - 68, width: 40, height: 18); p2.addSubview(typeLabel)
        kindPopup = NSPopUpButton(frame: NSRect(x: centerW - 104, y: panelH - 74, width: 88, height: 26), pullsDown: false)
        kindPopup.addItems(withTitles: ["S", "Š", "Z", "C", "Č", "T", "Ť", "D", "K", "P", "B", "F", "CH", "OTHER"])
        kindPopup.target = self; kindPopup.action = #selector(kindChanged); kindPopup.isEnabled = false; p2.addSubview(kindPopup)

        let rs = label("Repair Strength", size: 11); rs.frame = NSRect(x: 16, y: panelH - 112, width: 110, height: 18); p2.addSubview(rs)
        repairSlider = NSSlider(value: 0.66, minValue: 0, maxValue: 1, target: self, action: #selector(repairStrengthChanged(_:)))
        repairSlider.frame = NSRect(x: 126, y: panelH - 116, width: centerW - 210, height: 22); p2.addSubview(repairSlider)
        let less = label("LESS S", size: 9, color: NSColor(hex: 0x738390)); less.frame = NSRect(x: 16, y: panelH - 138, width: 55, height: 16); p2.addSubview(less)
        let more = label("MORE S", size: 9, color: NSColor(hex: 0x738390)); more.frame = NSRect(x: centerW - 76, y: panelH - 138, width: 60, height: 16); p2.addSubview(more)

        autoRepairButton = button("Repair", action: #selector(autoRepairSelected)); autoRepairButton.frame = NSRect(x: 16, y: 70, width: 108, height: 34); autoRepairButton.isEnabled = false; p2.addSubview(autoRepairButton)
        let morph = button("Reference Morph", action: #selector(referenceMorphSelected)); morph.frame = NSRect(x: 130, y: 70, width: 140, height: 34); p2.addSubview(morph)
        let blend = button("Reference Blend", action: #selector(referenceBlendSelected)); blend.frame = NSRect(x: 276, y: 70, width: 140, height: 34); p2.addSubview(blend)
        applySimilarButton = button("Apply Similar", action: #selector(applySimilar)); applySimilarButton.frame = NSRect(x: centerW - 132, y: 18, width: 116, height: 30); applySimilarButton.isEnabled = false; p2.addSubview(applySimilarButton)

        let trimLabel = label("TYPE TRIM", size: 10); trimLabel.frame = NSRect(x: 16, y: 22, width: 78, height: 18); p2.addSubview(trimLabel)
        typeTrimSlider = NSSlider(value: 0, minValue: -12, maxValue: 0, target: self, action: #selector(typeTrimChanged)); typeTrimSlider.frame = NSRect(x: 91, y: 19, width: 130, height: 22); typeTrimSlider.isEnabled = false; p2.addSubview(typeTrimSlider)
        typeTrimValue = label("0.0 dB", size: 9, weight: .semibold, color: NSColor(hex: 0x9DB4C5)); typeTrimValue.frame = NSRect(x: 224, y: 22, width: 52, height: 18); p2.addSubview(typeTrimValue)

        fadeInSlider = NSSlider(value: 12, minValue: 0, maxValue: 120, target: self, action: #selector(fadeChanged)); fadeInSlider.isHidden = true; p2.addSubview(fadeInSlider)
        fadeOutSlider = NSSlider(value: 12, minValue: 0, maxValue: 120, target: self, action: #selector(fadeChanged)); fadeOutSlider.isHidden = true; p2.addSubview(fadeOutSlider)
        fadeInValue = label("12 ms", size: 9); fadeInValue.isHidden = true; p2.addSubview(fadeInValue)
        fadeOutValue = label("12 ms", size: 9); fadeOutValue.isHidden = true; p2.addSubview(fadeOutValue)

        addTitle("PREVIEW", to: p3, y: panelH - 30)
        playButton = button("▶  Play", action: #selector(playSelected)); playButton.frame = NSRect(x: 16, y: panelH - 76, width: 132, height: 36); p3.addSubview(playButton)
        auditionMode = NSSegmentedControl(labels: ["ORIG", "REPAIR", "DELTA", "S ONLY"], trackingMode: .selectOne, target: self, action: #selector(auditionModeChanged)); auditionMode.selectedSegment = 1; auditionMode.frame = NSRect(x: 156, y: panelH - 77, width: rightW - 260, height: 30); p3.addSubview(auditionMode)
        loopButton = button("↻ Loop", action: #selector(toggleLoop)); loopButton.frame = NSRect(x: rightW - 96, y: panelH - 76, width: 80, height: 36); p3.addSubview(loopButton)

        let outTitle = label("OUTPUT", size: 11, weight: .bold, color: .white); outTitle.frame = NSRect(x: 16, y: panelH - 126, width: 100, height: 18); p3.addSubview(outTitle)
        let outputHelp = label("Event gain + TYPE TRIM + crossfades are rendered to RG-SIB export.", size: 10, color: NSColor(hex: 0x71818D)); outputHelp.frame = NSRect(x: 16, y: panelH - 158, width: rightW - 32, height: 32); outputHelp.lineBreakMode = .byWordWrapping; outputHelp.maximumNumberOfLines = 2; p3.addSubview(outputHelp)
        exportButton = button("Export RG-SIB", action: #selector(exportAudio)); exportButton.frame = NSRect(x: 16, y: 64, width: rightW - 32, height: 36); exportButton.isEnabled = false; p3.addSubview(exportButton)
        stopMode = NSSegmentedControl(labels: ["CONTINUE", "RETURN"], trackingMode: .selectOne, target: self, action: nil); stopMode.selectedSegment = 0; stopMode.frame = NSRect(x: 16, y: 18, width: 176, height: 28); p3.addSubview(stopMode)
        let prev = button("←", action: #selector(previousEvent)); prev.frame = NSRect(x: rightW - 124, y: 18, width: 48, height: 28); p3.addSubview(prev)
        let next = button("→", action: #selector(nextEvent)); next.frame = NSRect(x: rightW - 68, y: 18, width: 48, height: 28); p3.addSubview(next)

        fileInfo = label("Drop WAV/AIFF or Open WAV", size: 10, color: NSColor(hex: 0x697A87))
        fileInfo.frame = NSRect(x: 44, y: 35, width: w * 0.44, height: 18)
        root.addSubview(fileInfo)
        detectedLabel = label("Detected: 0 events", size: 10, color: NSColor(hex: 0x657683))
        detectedLabel.frame = NSRect(x: 44, y: 17, width: 220, height: 18)
        root.addSubview(detectedLabel)
        eventInfo = label("READY", size: 10, color: NSColor(hex: 0x7F909D))
        eventInfo.frame = NSRect(x: 280, y: 17, width: w - 610, height: 18)
        root.addSubview(eventInfo)
        status = label("READY — drop WAV/AIFF", size: 11, weight: .bold, color: .systemGreen)
        status.frame = NSRect(x: 44, y: 1, width: 520, height: 18)
        root.addSubview(status)
        let ver = label("Auto update: ON   •   v\(RGVersion) BETA", size: 10, color: NSColor(hex: 0x73818D))
        ver.alignment = .right
        ver.frame = NSRect(x: w - 310, y: 1, width: 266, height: 18)
        root.addSubview(ver)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func formatTime(_ t: Double) -> String {
        let safe = max(0, t)
        return String(format: "%02d:%02d.%03d", Int(safe) / 60, Int(safe) % 60, Int((safe - floor(safe)) * 1000))
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
        eventInfo.stringValue = String(format: "#%03d [%@]  %.3f–%.3f s  %.0f ms  GAIN %.1f dB  IN %.0f / OUT %.0f ms  %@  •  %@", i + 1, e.kind, e.start, e.end, (e.end - e.start) * 1000, e.gainDB, e.fadeIn * 1000, e.fadeOut * 1000, e.userLabel.isEmpty ? "UNRATED" : e.userLabel, "METHOD \(e.repairMethod ?? "MANUAL") • \(RGRepairAdvisor.qualityText(for: e))")
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
