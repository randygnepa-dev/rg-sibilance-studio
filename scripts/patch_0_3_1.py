from pathlib import Path
import re

src = Path('Sources/RGSibilanceStudio.swift')
s = src.read_text()
adv = Path('Sources/RGAdvancedEngine.swift')
a = adv.read_text()

s = s.replace('let RGVersion = "0.3.0"', 'let RGVersion = "0.3.1"', 1)

# Backward compatible resonance repair parameters.
s = s.replace('''    var referenceInfluence: Double? = nil\n}''', '''    var referenceInfluence: Double? = nil
    var resonanceAmount: Double? = nil
    var resonanceHz: Double? = nil
    var resonanceQ: Double? = nil
}''', 1)

# Timeline display mode: 0 waveform, 1 spectrogram.
anchor = '    var onCreateEventRegion: ((Double, Double) -> Void)?\n'
s = s.replace(anchor, anchor + '    var displayMode: Int = 0 { didSet { needsDisplay = true } }\n', 1)

s = s.replace('''        drawSpectralOverlay(m)\n        drawWaveform(m)\n''', '''        if displayMode == 1 {
            drawSpectralOverlay(m)
        } else {
            drawWaveform(m)
        }
''', 1)

# Replace the old colored 5-band overlay with a neutral, functional spectrogram view.
pat = re.compile(r'    private func drawSpectralOverlay\(_ m: AudioModel\) \{.*?\n    \}\n\n    private func drawWaveform', re.S)
new_spec = '''    private func drawSpectralOverlay(_ m: AudioModel) {
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

    private func drawWaveform'''
s, n = pat.subn(new_spec, s, count=1)
if n != 1:
    raise SystemExit('spectrogram function not replaced')

# App properties.
prop_anchor = '    private var annotationCountLabel: NSTextField!\n'
s = s.replace(prop_anchor, prop_anchor + '''    private var editorPanel: NSBox!
    private var annotationsPanel: NSBox!
    private var inspectorToggleButton: NSButton!
    private var inspectorHidden = false
    private var viewTabsControl: NSSegmentedControl!
    private var resonanceSlider: NSSlider!
    private var resonanceValueLabel: NSTextField!
    private var resonanceFreqLabel: NSTextField!
''', 1)

# Make window genuinely resizable with sane minimum size.
s = s.replace('''        window.title = "RG Sibilance Studio \\(RGVersion) BETA"\n        window.backgroundColor = NSColor(hex: 0x0A1016)''', '''        window.title = "RG Sibilance Studio \\(RGVersion) BETA"
        window.minSize = NSSize(width: 1120, height: 720)
        window.backgroundColor = NSColor(hex: 0x0A1016)''', 1)
s = s.replace('''        window.contentView = root\n''', '''        window.contentView = root
        root.autoresizingMask = [.width, .height]
''', 1)

# Keep major containers as properties and wire autoresizing.
s = s.replace('''        let editor = makePanel(NSRect(x: 42, y: editorY, width: mainW, height: editorH))\n        editor.fillColor = NSColor(hex: 0x0C141B)\n        root.addSubview(editor)''', '''        editorPanel = makePanel(NSRect(x: 42, y: editorY, width: mainW, height: editorH))
        let editor = editorPanel!
        editor.fillColor = NSColor(hex: 0x0C141B)
        editor.autoresizingMask = [.width, .height]
        root.addSubview(editor)''', 1)

s = s.replace('''        let viewTabs = NSSegmentedControl(labels: ["WAVEFORM", "SPECTROGRAM"], trackingMode: .selectOne, target: nil, action: nil)\n        viewTabs.selectedSegment = 0\n        viewTabs.frame = NSRect(x: 14, y: editorH - 35, width: 206, height: 24)\n        viewTabs.controlSize = .small\n        editor.addSubview(viewTabs)''', '''        viewTabsControl = NSSegmentedControl(labels: ["WAVEFORM", "SPECTROGRAM"], trackingMode: .selectOne, target: self, action: #selector(viewModeChanged(_:)))
        viewTabsControl.selectedSegment = 0
        viewTabsControl.frame = NSRect(x: 14, y: editorH - 35, width: 206, height: 24)
        viewTabsControl.controlSize = .small
        viewTabsControl.autoresizingMask = [.minYMargin]
        editor.addSubview(viewTabsControl)''', 1)

s = s.replace('''        let annotationsPanel = makePanel(NSRect(x: 42 + mainW + inspectorGap, y: 44, width: inspectorW, height: h - 144))\n        annotationsPanel.fillColor = NSColor(hex: 0x0A1219)\n        root.addSubview(annotationsPanel)''', '''        self.annotationsPanel = makePanel(NSRect(x: 42 + mainW + inspectorGap, y: 44, width: inspectorW, height: h - 144))
        let annotationsPanel = self.annotationsPanel!
        annotationsPanel.fillColor = NSColor(hex: 0x0A1219)
        annotationsPanel.autoresizingMask = [.minXMargin, .height]
        root.addSubview(annotationsPanel)''', 1)

# Persistent show/hide inspector button in header.
header_anchor = '''        analyzeButton.bezelColor = NSColor(hex: 0x1578E8)\n        root.addSubview(analyzeButton)\n'''
s = s.replace(header_anchor, header_anchor + '''        inspectorToggleButton = button("Hide Inspector", action: #selector(toggleInspector))
        inspectorToggleButton.frame = NSRect(x: w - 146, y: h - 67, width: 104, height: 30)
        inspectorToggleButton.autoresizingMask = [.minXMargin, .minYMargin]
        root.addSubview(inspectorToggleButton)
''', 1)

# Major child autoresizing masks.
s = s.replace('''        annAdd.frame = NSRect(x: inspectorW - 88, y: annotationsPanel.bounds.height - 40, width: 74, height: 28)\n        annotationsPanel.addSubview(annAdd)''', '''        annAdd.frame = NSRect(x: inspectorW - 88, y: annotationsPanel.bounds.height - 40, width: 74, height: 28)
        annAdd.autoresizingMask = [.minXMargin, .minYMargin]
        annotationsPanel.addSubview(annAdd)''', 1)
s = s.replace('''        annotationsPanel.addSubview(annScroll)\n''', '''        annScroll.autoresizingMask = [.width, .height]
        annotationsPanel.addSubview(annScroll)
''', 1)
s = s.replace('''        editor.addSubview(currentTimeLabel)\n''', '''        currentTimeLabel.autoresizingMask = [.minYMargin]
        editor.addSubview(currentTimeLabel)
''', 1)
s = s.replace('''        editor.addSubview(timeHint)\n''', '''        timeHint.autoresizingMask = [.minYMargin]
        editor.addSubview(timeHint)
''', 1)
s = s.replace('''        editor.addSubview(pinned)\n''', '''        pinned.autoresizingMask = [.width, .minYMargin]
        editor.addSubview(pinned)
''', 1)
s = s.replace('''        editor.addSubview(timeline)\n''', '''        timeline.autoresizingMask = [.width, .height]
        editor.addSubview(timeline)
''', 1)

# Header controls follow right edge while resizing.
s = s.replace('''        root.addSubview(analyzeButton)\n''', '''        analyzeButton.autoresizingMask = [.minXMargin, .minYMargin]
        root.addSubview(analyzeButton)
''', 1)
s = s.replace('''        root.addSubview(open)\n''', '''        open.autoresizingMask = [.minXMargin, .minYMargin]
        root.addSubview(open)
''', 1)

# Bottom layout gets flexible center and right-anchored modules.
s = s.replace('''        root.addSubview(p1); root.addSubview(p2); root.addSubview(pAdv); root.addSubview(p3)\n''', '''        p2.autoresizingMask = [.width]
        pAdv.autoresizingMask = [.minXMargin]
        p3.autoresizingMask = [.minXMargin]
        root.addSubview(p1); root.addSubview(p2); root.addSubview(pAdv); root.addSubview(p3)
''', 1)

# Wire actual waveform/spectrogram switching.
method_anchor = '    @objc private func zoomInTimeline() { timeline.zoomIn() }\n'
s = s.replace(method_anchor, '''    @objc private func viewModeChanged(_ sender: NSSegmentedControl) {
        timeline.displayMode = sender.selectedSegment
        status.stringValue = sender.selectedSegment == 1 ? "SPECTROGRAM VIEW" : "WAVEFORM VIEW"
    }

    @objc private func toggleInspector() {
        guard annotationsPanel != nil, editorPanel != nil else { return }
        let delta: CGFloat = 350
        inspectorHidden.toggle()
        annotationsPanel.isHidden = inspectorHidden
        inspectorToggleButton.title = inspectorHidden ? "Show Inspector" : "Hide Inspector"
        var f = editorPanel.frame
        f.size.width += inspectorHidden ? delta : -delta
        editorPanel.frame = f
        status.stringValue = inspectorHidden ? "ANNOTATIONS INSPECTOR HIDDEN" : "ANNOTATIONS INSPECTOR VISIBLE"
    }

''' + method_anchor, 1)

# Add whistle controls to Repair without creating more permanent complexity.
repair_anchor = '''        let more = label("MORE S", size: 9, color: NSColor(hex: 0x738390)); more.frame = NSRect(x: centerW - 76, y: panelH - 138, width: 60, height: 16); p2.addSubview(more)\n\n'''
repair_insert = repair_anchor + '''        let whistleTitle = label("WHISTLE", size: 10, weight: .bold, color: NSColor(hex: 0xD9E1E7)); whistleTitle.frame = NSRect(x: 16, y: 48, width: 62, height: 18); p2.addSubview(whistleTitle)
        resonanceSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(resonanceChanged(_:)))
        resonanceSlider.frame = NSRect(x: 78, y: 45, width: 148, height: 22); resonanceSlider.isEnabled = false; p2.addSubview(resonanceSlider)
        resonanceValueLabel = label("0%", size: 9, weight: .semibold, color: NSColor(hex: 0xB9C8D3)); resonanceValueLabel.frame = NSRect(x: 230, y: 48, width: 34, height: 18); p2.addSubview(resonanceValueLabel)
        let findWhistle = button("AUTO FIND", action: #selector(autoFindWhistle)); findWhistle.frame = NSRect(x: 268, y: 43, width: 82, height: 26); p2.addSubview(findWhistle)
        resonanceFreqLabel = label("—", size: 9, color: NSColor(hex: 0x8394A1)); resonanceFreqLabel.frame = NSRect(x: 16, y: 27, width: 150, height: 16); p2.addSubview(resonanceFreqLabel)

'''
s = s.replace(repair_anchor, repair_insert, 1)

# Move secondary repair buttons lower to avoid overlap with the new whistle suppressor.
s = s.replace('autoRepairButton.frame = NSRect(x: 16, y: 70, width: 102, height: 32)', 'autoRepairButton.frame = NSRect(x: 16, y: 4, width: 102, height: 28)', 1)
s = s.replace('morph.frame = NSRect(x: 124, y: 70, width: 120, height: 32)', 'morph.frame = NSRect(x: 124, y: 4, width: 120, height: 28)', 1)
s = s.replace('blend.frame = NSRect(x: 250, y: 70, width: 120, height: 32)', 'blend.frame = NSRect(x: 250, y: 4, width: 120, height: 28)', 1)
s = s.replace('applySimilarButton.frame = NSRect(x: centerW - 132, y: 18, width: 116, height: 30)', 'applySimilarButton.frame = NSRect(x: centerW - 132, y: 34, width: 116, height: 26)', 1)

# Selected event populates whistle controls.
sel_anchor = '''        pinnedNoteLabel?.stringValue = (e.note?.isEmpty == false) ? "✎ \\(e.note!)" : "No annotation"\n'''
s = s.replace(sel_anchor, sel_anchor + '''        resonanceSlider?.isEnabled = ["S", "Š", "Z", "C", "Č", "CH"].contains(e.kind)
        resonanceSlider?.doubleValue = min(1, max(0, e.resonanceAmount ?? 0))
        resonanceValueLabel?.stringValue = "\(Int((e.resonanceAmount ?? 0) * 100))%"
        if let hz = e.resonanceHz { resonanceFreqLabel?.stringValue = String(format: "%.1f kHz  Q %.1f", hz / 1000.0, e.resonanceQ ?? 7.0) }
        else { resonanceFreqLabel?.stringValue = "AUTO frequency not set" }
''', 1)

# Whistle handlers: coarse auto-find now; DSP is narrow peaking attenuation in advanced engine.
insert_before = '    @objc private func showAdvancedInfo() {\n'
handlers = '''    @objc private func resonanceChanged(_ sender: NSSlider) {
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

'''
s = s.replace(insert_before, handlers + insert_before, 1)

src.write_text(s)

# Advanced DSP: add a narrow peaking cut, smoothly mixed only inside the event.
adv_anchor = 'extension RGRenderEngine {\n'
biquad = '''extension RGRenderEngine {
    struct RGBiquad {
        var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        mutating func process(_ x: Double) -> Double {
            let y = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    static func resonanceFilter(sampleRate: Double, hz: Double, q: Double, amount: Double) -> RGBiquad {
        let f = min(sampleRate * 0.45, max(2500.0, hz))
        let qq = min(18.0, max(1.2, q))
        let gainDB = -min(15.0, max(0.0, amount) * 15.0)
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * f / sampleRate
        let alpha = sin(w0) / (2.0 * qq)
        let cw = cos(w0)
        let b0 = 1.0 + alpha * A
        let b1 = -2.0 * cw
        let b2 = 1.0 - alpha * A
        let a0 = 1.0 + alpha / A
        let a1 = -2.0 * cw
        let a2 = 1.0 - alpha / A
        return RGBiquad(b0: b0/a0, b1: b1/a0, b2: b2/a0, a1: a1/a0, a2: a2/a0)
    }
'''
if adv_anchor not in a:
    raise SystemExit('advanced extension anchor missing')
a = a.replace(adv_anchor, biquad, 1)

# Event parameters in processor.
a = a.replace('''            let broadbandTarget=pow(10.0,totalDB/20.0)\n\n            for ch in 0..<cc {''', '''            let broadbandTarget=pow(10.0,totalDB/20.0)
            let resonanceAmount=min(1.0,max(0.0,e.resonanceAmount ?? 0.0))
            let resonanceHz=e.resonanceHz ?? 8500.0
            let resonanceQ=e.resonanceQ ?? 7.0

            for ch in 0..<cc {''', 1)

a = a.replace('''                var lp = Array(repeating:0.0,count:6)\n                let pre=max(0,start-Int(sr*0.020))''', '''                var lp = Array(repeating:0.0,count:6)
                var resonance = resonanceFilter(sampleRate: sr, hz: resonanceHz, q: resonanceQ, amount: resonanceAmount)
                let pre=max(0,start-Int(sr*0.020))''', 1)

a = a.replace('''                    if let donor=donor, i-start<donor.count, blend>0 {\n                        y += Double(donor[i-start])*targetHFRMS*blend*mix*0.72\n                    }\n                    channels[ch][i]=Float(y)''', '''                    if let donor=donor, i-start<donor.count, blend>0 {
                        y += Double(donor[i-start])*targetHFRMS*blend*mix*0.72
                    }
                    if resonanceAmount > 0.0001 {
                        let filtered = resonance.process(y)
                        y = y + (filtered - y) * mix
                    }
                    channels[ch][i]=Float(y)''', 1)

adv.write_text(a)
print('patched 0.3.1')
