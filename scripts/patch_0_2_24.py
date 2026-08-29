from pathlib import Path
p=Path('Sources/RGSibilanceStudio.swift')
s=p.read_text()
s=s.replace('let RGVersion = "0.2.23"','let RGVersion = "0.2.24"',1)

# Add drop proxy view before AppDelegate if missing
anchor='final class AppDelegate: NSObject, NSApplicationDelegate, AVAudioPlayerDelegate {'
if 'final class AudioDropView: NSView' not in s:
    drop='''final class AudioDropView: NSView {\n    var onAudioDrop: ((URL) -> Void)?\n    private var dragActive = false\n\n    override init(frame frameRect: NSRect) {\n        super.init(frame: frameRect)\n        wantsLayer = true\n        registerForDraggedTypes([.fileURL])\n    }\n\n    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }\n\n    private func audioURL(_ sender: NSDraggingInfo) -> URL? {\n        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let url = urls.first else { return nil }\n        return ["wav", "wave", "aif", "aiff"].contains(url.pathExtension.lowercased()) ? url : nil\n    }\n\n    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {\n        guard audioURL(sender) != nil else { return [] }\n        dragActive = true\n        needsDisplay = true\n        return .copy\n    }\n\n    override func draggingExited(_ sender: NSDraggingInfo?) {\n        dragActive = false\n        needsDisplay = true\n    }\n\n    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {\n        guard let url = audioURL(sender) else { return false }\n        dragActive = false\n        needsDisplay = true\n        onAudioDrop?(url)\n        return true\n    }\n\n    override func draw(_ dirtyRect: NSRect) {\n        let fill = NSColor(hex: dragActive ? 0x102A40 : 0x0D1A26)\n        fill.setFill()\n        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()\n        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)\n        NSColor(hex: dragActive ? 0x2F95FF : 0x27435A).withAlphaComponent(0.9).setStroke()\n        border.lineWidth = dragActive ? 2 : 1\n        border.setLineDash([5,4], count: 2, phase: 0)\n        border.stroke()\n        let title = dragActive ? "DROP AUDIO" : "DRAG & DROP WAV / AIFF"\n        let sub = "Drop audio file here to analyze"\n        let a1: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.white]\n        let a2: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(hex: 0x8A9AA8)]\n        let t1 = title.size(withAttributes: a1)\n        let t2 = sub.size(withAttributes: a2)\n        title.draw(at: NSPoint(x: bounds.midX - t1.width / 2, y: bounds.midY + 4), withAttributes: a1)\n        sub.draw(at: NSPoint(x: bounds.midX - t2.width / 2, y: bounds.midY - 24), withAttributes: a2)\n    }\n}\n\n'''
    s=s.replace(anchor,drop+anchor,1)

# Add zoom API to timeline
if 'func zoomIn()' not in s:
    timeline_anchor='    func followPlayback(to time: Double) {'
    funcs='''    func zoomIn() {\n        guard model != nil else { return }\n        let center = viewStart + visibleDuration * 0.5\n        zoom = min(640, zoom * 1.55)\n        viewStart = center - visibleDuration * 0.5\n        clampViewStart()\n        needsDisplay = true\n    }\n\n    func zoomOut() {\n        guard model != nil else { return }\n        let center = viewStart + visibleDuration * 0.5\n        zoom = max(1, zoom / 1.55)\n        viewStart = center - visibleDuration * 0.5\n        clampViewStart()\n        needsDisplay = true\n    }\n\n    func fitAll() {\n        zoom = 1\n        viewStart = 0\n        needsDisplay = true\n    }\n\n'''
    s=s.replace(timeline_anchor,funcs+timeline_anchor,1)

# Additional properties
prop_anchor='    private var auditionMode: NSSegmentedControl!\n'
if 'private var dropView: AudioDropView!' not in s:
    s=s.replace(prop_anchor,prop_anchor+'    private var dropView: AudioDropView!\n    private var currentTimeLabel: NSTextField!\n    private var detectedFooter: NSTextField!\n',1)

start=s.index('    private func buildUI() {')
end=s.index('    private func makePanel(', start)
new_build=r'''    private func buildUI() {
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
        let morph = button("Reference Morph", action: #selector(referenceModeInfo)); morph.frame = NSRect(x: 130, y: 70, width: 140, height: 34); p2.addSubview(morph)
        let blend = button("Reference Blend", action: #selector(referenceModeInfo)); blend.frame = NSRect(x: 276, y: 70, width: 140, height: 34); p2.addSubview(blend)
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
        auditionMode = NSSegmentedControl(labels: ["ORIGINAL", "REPAIR"], trackingMode: .selectOne, target: self, action: #selector(auditionModeChanged)); auditionMode.selectedSegment = 1; auditionMode.frame = NSRect(x: 156, y: panelH - 77, width: rightW - 260, height: 30); p3.addSubview(auditionMode)
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
        timeline.events = events
        selectEvent(i)
        saveCurrentSession()
        status.stringValue = String(format: "REPAIR STRENGTH %d%% — %.1f dB", Int(amount * 100), events[i].gainDB)
    }

    @objc private func showAdvancedInfo() {
        status.stringValue = "ADVANCED — direct event handles, TYPE TRIM, crossfades and detector controls remain available"
    }

    @objc private func referenceModeInfo() {
        status.stringValue = "REFERENCE MODE — engine hook ready; current safe repair remains nondestructive"
    }

'''
s=s[:start]+new_build+s[end:]

# keep time readout synced when selecting event / following transport
s=s.replace('        let e = events[i]\n        kindPopup.isEnabled = true','        let e = events[i]\n        currentTimeLabel?.stringValue = formatTime(e.peakTime)\n        kindPopup.isEnabled = true',1)
s=s.replace('            self.timeline.followPlayback(to: player.currentTime)','            self.timeline.followPlayback(to: player.currentTime)\n            self.currentTimeLabel?.stringValue = self.formatTime(player.currentTime)',1)
# sync footer counts
s=s.replace('self.detectedLabel.stringValue = "Detected: \\(found.count) events"','self.detectedLabel.stringValue = "Detected: \\(found.count) events"\n                self.detectedFooter?.stringValue = "Detected: \\(found.count) events"',1)
s=s.replace('detectedLabel.stringValue = "Detected: \\(events.count) events"','detectedLabel.stringValue = "Detected: \\(events.count) events"\n        detectedFooter?.stringValue = "Detected: \\(events.count) events"')
s=s.replace('self.detectedLabel.stringValue = "Restored: \\(session.events.count) events"','self.detectedLabel.stringValue = "Restored: \\(session.events.count) events"\n                        self.detectedFooter?.stringValue = "Detected: \\(session.events.count) events"',1)

p.write_text(s)
