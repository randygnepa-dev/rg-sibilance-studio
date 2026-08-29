import Cocoa
import AVFoundation
import Foundation

let RGVersion = "0.2.11"
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
        self.sampleRate = format.sampleRate
        self.channels = Int(format.channelCount)
        self.duration = Double(buffer.frameLength) / format.sampleRate

        let n = Int(buffer.frameLength)
        let c = max(1, channels)
        samples = Array(repeating: 0, count: n)

        for i in 0..<n {
            var sum: Float = 0
            for ch in 0..<c {
                sum += data[ch][i]
            }
            samples[i] = sum / Float(c)
        }

        var maxPeak: Float = 0
        var energy = 0.0
        for x in samples {
            maxPeak = max(maxPeak, abs(x))
            energy += Double(x * x)
        }
        peak = maxPeak
        rms = samples.isEmpty ? 0 : Float(sqrt(energy / Double(samples.count)))
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
                if (x >= 0) != (prev >= 0) {
                    crossings += 1
                }
                prev = x
            }

            let frameRMS = sqrt(full / Double(frame))
            let ratio = sqrt(diff / max(full, 1e-12))
            let zcr = Double(crossings) / Double(frame)
            let gate = min(1.0, max(0.0, (frameRMS - 0.0015) / 0.025))
            let score = ratio * (0.55 + 2.5 * zcr) * (0.20 + 0.80 * gate)
            let time = Double(i + frame / 2) / sampleRate
            values.append((time, score, frameRMS, ratio))
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
            let isActive = metric.value >= threshold && metric.rms > 0.0015 && metric.ratio > 0.48
            if isActive {
                if activeStart == nil {
                    activeStart = max(0, metric.time - frameDuration * 0.5)
                }
                bestScore = max(bestScore, metric.value)
            } else if let start = activeStart {
                let end = metric.time + frameDuration * 0.25
                if end - start >= 0.025 && end - start <= 0.55 {
                    raw.append((start, end, bestScore))
                }
                activeStart = nil
                bestScore = 0
            }
        }

        var merged: [(Double, Double, Double)] = []
        for event in raw {
            if let last = merged.last, event.0 - last.1 < 0.045 {
                merged[merged.count - 1] = (last.0, event.1, max(last.2, event.2))
            } else {
                merged.append(event)
            }
        }

        return merged.prefix(300).map { event in
            let duration = event.1 - event.0
            let kind = duration < 0.065 ? "T" : "S"
            return SibilanceEvent(
                start: event.0,
                end: event.1,
                peakTime: (event.0 + event.1) * 0.5,
                score: event.2,
                kind: kind,
                userLabel: ""
            )
        }
    }
}

final class DropAudioView: NSView {
    var onDrop: ((URL) -> Void)?
    private var active = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func audioURL(_ sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let url = urls.first else {
            return nil
        }

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
        return audioURL(sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = audioURL(sender) else { return false }
        active = false
        needsDisplay = true
        onDrop?(url)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        (active ? NSColor(hex: 0x12375C) : NSColor(hex: 0x0E1B28)).setFill()
        bounds.fill()

        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: 10,
            yRadius: 10
        )
        path.lineWidth = active ? 2 : 1
        (active ? NSColor.systemBlue : NSColor(hex: 0x28445F)).setStroke()
        path.stroke()

        let title = active ? "DROP AUDIO" : "DRAG & DROP WAV / AIFF"
        let subtitle = active ? "Release to load" : "Pretiahni audio priamo z Finderu"

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 17),
            .foregroundColor: NSColor.white
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor(hex: 0x8797A8)
        ]

        let titleSize = title.size(withAttributes: titleAttributes)
        let subtitleSize = subtitle.size(withAttributes: subtitleAttributes)
        title.draw(
            at: NSPoint(x: bounds.midX - titleSize.width / 2, y: bounds.midY + 5),
            withAttributes: titleAttributes
        )
        subtitle.draw(
            at: NSPoint(x: bounds.midX - subtitleSize.width / 2, y: bounds.midY - 22),
            withAttributes: subtitleAttributes
        )
    }
}

final class TimelineView: NSView {
    var model: AudioModel? { didSet { needsDisplay = true } }
    var events: [SibilanceEvent] = [] { didSet { needsDisplay = true } }
    var selectedIndex: Int? { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?

    private var plotRect: NSRect {
        return NSRect(
            x: 90,
            y: 28,
            width: max(100, bounds.width - 115),
            height: max(80, bounds.height - 48)
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard let model = model, model.duration > 0, !events.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard plotRect.contains(point) else { return }

        let time = Double((point.x - plotRect.minX) / plotRect.width) * model.duration
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude

        for (index, item) in events.enumerated() {
            let distance = abs(item.peakTime - time)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        selectedIndex = bestIndex
        onSelect?(bestIndex)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: 0x0B1219).setFill()
        bounds.fill()
        NSColor(hex: 0x101A24).setFill()
        plotRect.fill()

        guard let model = model, !model.samples.isEmpty else { return }

        let columns = max(100, Int(plotRect.width))
        let step = max(1, model.samples.count / columns)
        let waveform = NSBezierPath()

        for column in 0..<columns {
            let start = min(model.samples.count - 1, column * step)
            let end = min(model.samples.count, start + step)
            var minValue = model.samples[start]
            var maxValue = minValue

            if start < end {
                for i in start..<end {
                    minValue = min(minValue, model.samples[i])
                    maxValue = max(maxValue, model.samples[i])
                }
            }

            let x = plotRect.minX + CGFloat(column) / CGFloat(max(1, columns - 1)) * plotRect.width
            waveform.move(to: NSPoint(x: x, y: plotRect.midY + CGFloat(minValue) * plotRect.height * 0.42))
            waveform.line(to: NSPoint(x: x, y: plotRect.midY + CGFloat(maxValue) * plotRect.height * 0.42))
        }

        NSColor(hex: 0x2F8CFF).setStroke()
        waveform.lineWidth = 1
        waveform.stroke()

        for (index, item) in events.enumerated() {
            let x = plotRect.minX + CGFloat(item.peakTime / model.duration) * plotRect.width
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
            line.lineWidth = index == selectedIndex ? 3 : 1
            line.stroke()

            let badge = NSBezierPath(
                roundedRect: NSRect(x: x - 8, y: plotRect.maxY - 17, width: 16, height: 16),
                xRadius: 3,
                yRadius: 3
            )
            color.setFill()
            badge.fill()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 10),
                .foregroundColor: NSColor.white
            ]
            let size = item.kind.size(withAttributes: attributes)
            item.kind.draw(
                at: NSPoint(x: x - size.width / 2, y: plotRect.maxY - 16),
                withAttributes: attributes
            )
        }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
        showUpdateNotice()
    }

    private func label(
        _ text: String,
        size: CGFloat = 13,
        weight: NSFont.Weight = .regular,
        color: NSColor = NSColor(hex: 0xAAB5C0)
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func buildUI() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
        let width = min(CGFloat(1380), screen.width - 40)
        let height = min(CGFloat(860), screen.height - 40)

        window = NSWindow(
            contentRect: NSRect(
                x: screen.midX - width / 2,
                y: screen.midY - height / 2,
                width: width,
                height: height
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RG Sibilance Studio \(RGVersion) BETA"
        window.backgroundColor = NSColor(hex: 0x0C1218)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(hex: 0x0C1218).cgColor
        window.contentView = root

        let title = label("RG Sibilance Studio", size: 28, weight: .bold, color: .white)
        title.frame = NSRect(x: 34, y: height - 68, width: 480, height: 38)
        root.addSubview(title)

        let subtitle = label(
            "Sibilance detection & repair   •   AUTO UPDATE BETA",
            size: 13,
            color: NSColor(hex: 0x8896A4)
        )
        subtitle.frame = NSRect(x: 36, y: height - 96, width: 560, height: 22)
        root.addSubview(subtitle)

        let analyze = button("Analyze", action: #selector(analyzeAudio))
        analyze.frame = NSRect(x: width - 330, y: height - 73, width: 130, height: 34)
        root.addSubview(analyze)

        let open = button("Open WAV", action: #selector(openWav))
        open.frame = NSRect(x: width - 185, y: height - 73, width: 130, height: 34)
        root.addSubview(open)

        let dropView = DropAudioView(frame: NSRect(x: 34, y: height - 220, width: width - 68, height: 100))
        dropView.onDrop = { [weak self] url in
            self?.loadAudio(url)
        }
        root.addSubview(dropView)

        fileInfo = label("No audio loaded", size: 12, weight: .medium)
        fileInfo.frame = NSRect(x: 40, y: height - 244, width: width - 80, height: 20)
        root.addSubview(fileInfo)

        timeline = TimelineView(frame: NSRect(x: 34, y: height - 565, width: width - 68, height: 290))
        timeline.wantsLayer = true
        timeline.layer?.borderColor = NSColor(hex: 0x26313B).cgColor
        timeline.layer?.borderWidth = 1
        timeline.layer?.cornerRadius = 8
        timeline.onSelect = { [weak self] index in
            self?.selectEvent(index)
        }
        root.addSubview(timeline)

        detectedLabel = label("Detected: 0 events", size: 12, weight: .semibold, color: .systemBlue)
        detectedLabel.frame = NSRect(x: 52, y: height - 590, width: 220, height: 20)
        root.addSubview(detectedLabel)

        eventInfo = label("Select an event", size: 12, color: NSColor(hex: 0x8997A5))
        eventInfo.frame = NSRect(x: 280, y: height - 590, width: 620, height: 20)
        root.addSubview(eventInfo)

        let panelY: CGFloat = 60
        let panelHeight = max(CGFloat(170), height - 650)
        let gap: CGFloat = 14
        let panelWidth = (width - 68 - gap * 2) / 3

        let detectionPanel = NSBox(frame: NSRect(x: 34, y: panelY, width: panelWidth, height: panelHeight))
        let eventPanel = NSBox(frame: NSRect(x: 34 + panelWidth + gap, y: panelY, width: panelWidth, height: panelHeight))
        let previewPanel = NSBox(frame: NSRect(x: 34 + (panelWidth + gap) * 2, y: panelY, width: panelWidth, height: panelHeight))

        for panel in [detectionPanel, eventPanel, previewPanel] {
            panel.boxType = .custom
            panel.borderColor = NSColor(hex: 0x26313B)
            panel.fillColor = NSColor(hex: 0x111820)
            panel.cornerRadius = 8
            root.addSubview(panel)
        }

        let detectionTitle = label("DETECTION", size: 12, weight: .bold, color: .white)
        detectionTitle.frame = NSRect(x: 16, y: panelHeight - 30, width: 160, height: 20)
        detectionPanel.addSubview(detectionTitle)

        let sensitivityLabel = label("Sensitivity", size: 12)
        sensitivityLabel.frame = NSRect(x: 16, y: panelHeight - 68, width: 90, height: 20)
        detectionPanel.addSubview(sensitivityLabel)

        sensitivitySlider = NSSlider(
            value: 0.72,
            minValue: 0,
            maxValue: 1,
            target: self,
            action: #selector(sensitivityChanged)
        )
        sensitivitySlider.frame = NSRect(x: 105, y: panelHeight - 72, width: panelWidth - 135, height: 24)
        detectionPanel.addSubview(sensitivitySlider)

        let eventTitle = label("EVENT", size: 12, weight: .bold, color: .white)
        eventTitle.frame = NSRect(x: 16, y: panelHeight - 30, width: 160, height: 20)
        eventPanel.addSubview(eventTitle)

        let good = button("GOOD", action: #selector(markGood))
        let bad = button("BAD", action: #selector(markBad))
        let target = button("TARGET", action: #selector(markTarget))
        let normal = button("NORMAL", action: #selector(markNormal))

        good.frame = NSRect(x: 16, y: panelHeight - 74, width: 75, height: 30)
        bad.frame = NSRect(x: 96, y: panelHeight - 74, width: 75, height: 30)
        target.frame = NSRect(x: 176, y: panelHeight - 74, width: 85, height: 30)
        normal.frame = NSRect(x: 266, y: panelHeight - 74, width: 90, height: 30)

        for control in [good, bad, target, normal] {
            eventPanel.addSubview(control)
        }

        let previewTitle = label("PREVIEW", size: 12, weight: .bold, color: .white)
        previewTitle.frame = NSRect(x: 16, y: panelHeight - 30, width: 160, height: 20)
        previewPanel.addSubview(previewTitle)

        playButton = button("▶ Play event", action: #selector(playSelected))
        playButton.frame = NSRect(x: 16, y: panelHeight - 74, width: 120, height: 32)
        previewPanel.addSubview(playButton)

        loopButton = button("Loop OFF", action: #selector(toggleLoop))
        loopButton.frame = NSRect(x: 145, y: panelHeight - 74, width: 100, height: 32)
        previewPanel.addSubview(loopButton)

        status = label("READY — drop WAV/AIFF", size: 12, weight: .bold, color: .systemGreen)
        status.frame = NSRect(x: 36, y: 20, width: width - 72, height: 20)
        root.addSubview(status)

        let versionLabel = label(
            "Engine: Native   •   Auto update: ON   •   v\(RGVersion) BETA",
            size: 11,
            color: NSColor(hex: 0x75828E)
        )
        versionLabel.alignment = .right
        versionLabel.frame = NSRect(x: width - 470, y: 20, width: 430, height: 20)
        root.addSubview(versionLabel)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showUpdateNotice() {
        status.stringValue = "AUTO UPDATE COMPLETE — v\(RGVersion)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let alert = NSAlert()
            alert.messageText = "Auto update dokončený"
            alert.informativeText = "RG Sibilance Studio bolo aktualizované na v\(RGVersion)."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func openWav() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["wav", "wave", "aif", "aiff"]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            loadAudio(url)
        }
    }

    private func loadAudio(_ url: URL) {
        status.stringValue = "LOADING AUDIO…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let loadedModel = AudioModel()
                try loadedModel.load(url)

                DispatchQueue.main.async {
                    self.model = loadedModel
                    self.events = []
                    self.timeline.model = loadedModel
                    self.timeline.events = []
                    self.timeline.selectedIndex = nil
                    self.fileInfo.stringValue = "\(url.lastPathComponent)   •   \(Int(loadedModel.sampleRate)) Hz   •   \(loadedModel.channels) ch   •   \(String(format: "%.2f", loadedModel.duration)) s"
                    self.detectedLabel.stringValue = "Detected: 0 events"
                    self.eventInfo.stringValue = "Audio loaded — press Analyze"
                    self.status.stringValue = "AUDIO LOADED — ready to Analyze"
                }
            } catch {
                DispatchQueue.main.async {
                    self.status.stringValue = "LOAD FAILED — \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func analyzeAudio() {
        guard !model.samples.isEmpty else {
            status.stringValue = "DROP WAV/AIFF FIRST"
            return
        }

        status.stringValue = "ANALYZING SIBILANCE…"
        let samples = model.samples
        let sampleRate = model.sampleRate
        let sensitivity = sensitivitySlider.doubleValue

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let found = self.detector.detect(
                samples: samples,
                sampleRate: sampleRate,
                sensitivity: sensitivity
            )

            DispatchQueue.main.async {
                self.events = found
                self.timeline.events = found
                self.timeline.selectedIndex = found.isEmpty ? nil : 0
                self.detectedLabel.stringValue = "Detected: \(found.count) events"
                self.status.stringValue = found.isEmpty ? "ANALYSIS DONE — no events" : "ANALYSIS DONE — select an event"
                if !found.isEmpty {
                    self.selectEvent(0)
                }
            }
        }
    }

    @objc private func sensitivityChanged() {
        status.stringValue = "Sensitivity \(Int(sensitivitySlider.doubleValue * 100))% — press Analyze"
    }

    private func selectEvent(_ index: Int) {
        guard events.indices.contains(index) else { return }
        timeline.selectedIndex = index
        let event = events[index]
        eventInfo.stringValue = String(
            format: "#%03d  %@  %.3f–%.3f s  score %.2f  %@",
            index + 1,
            event.kind,
            event.start,
            event.end,
            event.score,
            event.userLabel.isEmpty ? "UNRATED" : event.userLabel
        )
    }

    private func mark(_ value: String) {
        guard let index = timeline.selectedIndex, events.indices.contains(index) else {
            status.stringValue = "SELECT AN EVENT FIRST"
            return
        }

        events[index].userLabel = value
        timeline.events = events
        selectEvent(index)
        status.stringValue = "EVENT #\(index + 1) MARKED \(value)"
    }

    @objc private func markGood() { mark("GOOD") }
    @objc private func markBad() { mark("BAD") }
    @objc private func markTarget() { mark("TARGET") }
    @objc private func markNormal() { mark("NORMAL") }

    @objc private func toggleLoop() {
        loopEnabled.toggle()
        loopButton.title = loopEnabled ? "Loop ON" : "Loop OFF"
    }

    @objc private func playSelected() {
        guard let url = model.url else {
            status.stringValue = "LOAD AUDIO FIRST"
            return
        }

        do {
            stopTimer?.invalidate()
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.delegate = self
            player = audioPlayer

            if let index = timeline.selectedIndex, events.indices.contains(index) {
                let event = events[index]
                let pre = max(0, event.start - 0.30)
                let post = min(model.duration, event.end + 0.40)
                audioPlayer.currentTime = pre
                audioPlayer.play()
                playButton.title = "■ Stop"
                status.stringValue = "PLAYING EVENT #\(index + 1)"

                stopTimer = Timer.scheduledTimer(
                    withTimeInterval: max(0.1, post - pre),
                    repeats: false
                ) { [weak self] _ in
                    self?.finishPreview()
                }
            } else {
                audioPlayer.play()
                playButton.title = "■ Stop"
                status.stringValue = "PLAYING AUDIO"
            }
        } catch {
            status.stringValue = "PLAYBACK FAILED — \(error.localizedDescription)"
        }
    }

    private func finishPreview() {
        player?.stop()
        playButton.title = "▶ Play event"
        if loopEnabled {
            playSelected()
        } else {
            status.stringValue = "READY"
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playButton.title = "▶ Play event"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
