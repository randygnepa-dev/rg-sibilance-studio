from pathlib import Path
p=Path('Sources/RGSibilanceStudio.swift')
s=p.read_text()
s=s.replace('let RGVersion = "0.2.31"','let RGVersion = "0.2.32"',1)

s=s.replace('    private var pinnedNoteLabel: NSTextField!\n','    private var pinnedNoteLabel: NSTextField!\n    private var annotationStack: NSStackView!\n    private var annotationCountLabel: NSTextField!\n',1)

layout_anchor='''        window.contentView = root\n\n'''
layout_insert=layout_anchor+'''        let inspectorW: CGFloat = 326\n        let inspectorGap: CGFloat = 12\n        let mainW = w - 84 - inspectorW - inspectorGap\n\n'''
if layout_anchor not in s: raise SystemExit('layout anchor missing')
s=s.replace(layout_anchor,layout_insert,1)

s=s.replace('''        let editorY: CGFloat = 286\n        let editorH = h - editorY - 124\n        let editor = makePanel(NSRect(x: 42, y: editorY, width: w - 84, height: editorH))\n''','''        let editorY: CGFloat = 286\n        let editorH = h - editorY - 124\n        let editor = makePanel(NSRect(x: 42, y: editorY, width: mainW, height: editorH))\n''',1)

editor_anchor='''        editor.fillColor = NSColor(hex: 0x0C141B)\n        root.addSubview(editor)\n'''
editor_insert=editor_anchor+'''\n        let annotationsPanel = makePanel(NSRect(x: 42 + mainW + inspectorGap, y: 58, width: inspectorW, height: h - 182))\n        annotationsPanel.fillColor = NSColor(hex: 0x0D161F)\n        root.addSubview(annotationsPanel)\n        let annTitle = label("EDITS & ANNOTATIONS", size: 11, weight: .bold, color: .white)\n        annTitle.frame = NSRect(x: 14, y: annotationsPanel.bounds.height - 34, width: 190, height: 20)\n        annotationsPanel.addSubview(annTitle)\n        let annAdd = button("＋ Add", action: #selector(addAnnotation))\n        annAdd.frame = NSRect(x: inspectorW - 86, y: annotationsPanel.bounds.height - 40, width: 72, height: 28)\n        annotationsPanel.addSubview(annAdd)\n        annotationCountLabel = label("0 edits", size: 10, color: NSColor(hex: 0x71818D))\n        annotationCountLabel.frame = NSRect(x: 14, y: 12, width: 100, height: 18)\n        annotationsPanel.addSubview(annotationCountLabel)\n        let annScroll = NSScrollView(frame: NSRect(x: 10, y: 38, width: inspectorW - 20, height: annotationsPanel.bounds.height - 82))\n        annScroll.drawsBackground = false\n        annScroll.hasVerticalScroller = true\n        annotationStack = NSStackView(frame: NSRect(x: 0, y: 0, width: inspectorW - 38, height: annScroll.bounds.height))\n        annotationStack.orientation = .vertical\n        annotationStack.alignment = .leading\n        annotationStack.spacing = 7\n        annotationStack.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)\n        annScroll.documentView = annotationStack\n        annotationsPanel.addSubview(annScroll)\n'''
if editor_anchor not in s: raise SystemExit('editor anchor missing')
s=s.replace(editor_anchor,editor_insert,1)

s=s.replace('analyzeButton.frame = NSRect(x: w - 378, y: h - 84, width: 176, height: 40)','analyzeButton.frame = NSRect(x: 42 + mainW - 326, y: h - 84, width: 150, height: 40)',1)
s=s.replace('open.frame = NSRect(x: w - 188, y: h - 84, width: 146, height: 40)','open.frame = NSRect(x: 42 + mainW - 164, y: h - 84, width: 150, height: 40)',1)

panels_old='''        let panelY: CGFloat = 58\n        let panelH = max(CGFloat(216), editorY - 72)\n        let gap: CGFloat = 12\n        let leftW: CGFloat = (w - 108) * 0.22\n        let centerW: CGFloat = (w - 108) * 0.44\n        let rightW = w - 84 - leftW - centerW - gap * 2\n        let p1 = makePanel(NSRect(x: 42, y: panelY, width: leftW, height: panelH))\n        let p2 = makePanel(NSRect(x: 42 + leftW + gap, y: panelY, width: centerW, height: panelH))\n        let p3 = makePanel(NSRect(x: 42 + leftW + centerW + gap * 2, y: panelY, width: rightW, height: panelH))\n        root.addSubview(p1); root.addSubview(p2); root.addSubview(p3)\n'''
panels_new='''        let panelY: CGFloat = 58\n        let panelH = max(CGFloat(216), editorY - 72)\n        let gap: CGFloat = 10\n        let leftW: CGFloat = mainW * 0.22\n        let centerW: CGFloat = mainW * 0.38\n        let advancedW: CGFloat = mainW * 0.18\n        let rightW = mainW - leftW - centerW - advancedW - gap * 3\n        let p1 = makePanel(NSRect(x: 42, y: panelY, width: leftW, height: panelH))\n        let p2 = makePanel(NSRect(x: 42 + leftW + gap, y: panelY, width: centerW, height: panelH))\n        let pAdv = makePanel(NSRect(x: 42 + leftW + centerW + gap * 2, y: panelY, width: advancedW, height: panelH))\n        let p3 = makePanel(NSRect(x: 42 + leftW + centerW + advancedW + gap * 3, y: panelY, width: rightW, height: panelH))\n        root.addSubview(p1); root.addSubview(p2); root.addSubview(pAdv); root.addSubview(p3)\n        addTitle("ADVANCED", to: pAdv, y: panelH - 30)\n        let advHint = label("Selected event", size: 9, color: NSColor(hex: 0x71818D)); advHint.frame = NSRect(x: 16, y: panelH - 59, width: advancedW - 32, height: 18); pAdv.addSubview(advHint)\n'''
if panels_old not in s: raise SystemExit('panels block missing')
s=s.replace(panels_old,panels_new,1)

repls={
'let trimLabel = label("TYPE TRIM", size: 10); trimLabel.frame = NSRect(x: 16, y: 22, width: 78, height: 18); p2.addSubview(trimLabel)':'let trimLabel = label("TYPE TRIM", size: 10); trimLabel.frame = NSRect(x: 16, y: panelH - 91, width: 78, height: 18); pAdv.addSubview(trimLabel)',
'typeTrimSlider = NSSlider(value: 0, minValue: -12, maxValue: 0, target: self, action: #selector(typeTrimChanged)); typeTrimSlider.frame = NSRect(x: 91, y: 19, width: 130, height: 22); typeTrimSlider.isEnabled = false; p2.addSubview(typeTrimSlider)':'typeTrimSlider = NSSlider(value: 0, minValue: -12, maxValue: 0, target: self, action: #selector(typeTrimChanged)); typeTrimSlider.frame = NSRect(x: 16, y: panelH - 116, width: advancedW - 72, height: 22); typeTrimSlider.isEnabled = false; pAdv.addSubview(typeTrimSlider)',
'typeTrimValue = label("0.0 dB", size: 9, weight: .semibold, color: NSColor(hex: 0x9DB4C5)); typeTrimValue.frame = NSRect(x: 224, y: 22, width: 52, height: 18); p2.addSubview(typeTrimValue)':'typeTrimValue = label("0.0 dB", size: 9, weight: .semibold, color: NSColor(hex: 0x9DB4C5)); typeTrimValue.frame = NSRect(x: advancedW - 54, y: panelH - 112, width: 44, height: 18); pAdv.addSubview(typeTrimValue)',
'fadeInSlider = NSSlider(value: 12, minValue: 0, maxValue: 120, target: self, action: #selector(fadeChanged)); fadeInSlider.isHidden = true; p2.addSubview(fadeInSlider)':'fadeInSlider = NSSlider(value: 12, minValue: 0, maxValue: 120, target: self, action: #selector(fadeChanged)); fadeInSlider.frame = NSRect(x: 16, y: 67, width: advancedW - 68, height: 22); pAdv.addSubview(fadeInSlider)',
'fadeOutSlider = NSSlider(value: 12, minValue: 0, maxValue: 120, target: self, action: #selector(fadeChanged)); fadeOutSlider.isHidden = true; p2.addSubview(fadeOutSlider)':'fadeOutSlider = NSSlider(value: 12, minValue: 0, maxValue: 120, target: self, action: #selector(fadeChanged)); fadeOutSlider.frame = NSRect(x: 16, y: 37, width: advancedW - 68, height: 22); pAdv.addSubview(fadeOutSlider)',
'fadeInValue = label("12 ms", size: 9); fadeInValue.isHidden = true; p2.addSubview(fadeInValue)':'fadeInValue = label("IN 12", size: 9); fadeInValue.frame = NSRect(x: advancedW - 48, y: 69, width: 42, height: 18); pAdv.addSubview(fadeInValue)',
'fadeOutValue = label("12 ms", size: 9); fadeOutValue.isHidden = true; p2.addSubview(fadeOutValue)':'fadeOutValue = label("OUT 12", size: 9); fadeOutValue.frame = NSRect(x: advancedW - 48, y: 39, width: 42, height: 18); pAdv.addSubview(fadeOutValue)'
}
for a,b in repls.items(): s=s.replace(a,b,1)

start=s.index('    private func drawSpectralOverlay(_ m: AudioModel) {')
end=s.index('\n    private func drawWaveform(_ m: AudioModel) {', start)
block=s[start:end]
block=block.replace('let laneH = plotRect.height / 5.0','let spectralHeight = plotRect.height * 0.34\n        let laneH = spectralHeight / 5.0')
s=s[:start]+block+s[end:]

start=s.index('    private func drawWaveform(_ m: AudioModel) {')
end=s.index('\n    private func drawSelectionRegion()', start)
block=s[start:end]
block=block.replace('let amp = plotRect.height * 0.47 * fixedVerticalScale','let waveCenter = plotRect.minY + plotRect.height * 0.68\n        let amp = plotRect.height * 0.27 * fixedVerticalScale')
block=block.replace('plotRect.midY + CGFloat(v) * g * amp','waveCenter + CGFloat(v) * g * amp')
block=block.replace('(tops.last!.y - plotRect.midY)', '(tops.last!.y - waveCenter)')
block=block.replace('(bottoms.last!.y - plotRect.midY)', '(bottoms.last!.y - waveCenter)')
block=block.replace('plotRect.midY + CGFloat(mx) * g * amp','waveCenter + CGFloat(mx) * g * amp')
block=block.replace('plotRect.midY + CGFloat(mn) * g * amp','waveCenter + CGFloat(mn) * g * amp')
block=block.replace('zero.move(to: NSPoint(x: plotRect.minX, y: plotRect.midY))','zero.move(to: NSPoint(x: plotRect.minX, y: waveCenter))')
block=block.replace('zero.line(to: NSPoint(x: plotRect.maxX, y: plotRect.midY))','zero.line(to: NSPoint(x: plotRect.maxX, y: waveCenter))')
s=s[:start]+block+s[end:]

helper_anchor='''    private func formatTime(_ t: Double) -> String {\n'''
helpers='''    private func refreshAnnotationSidebar() {\n        guard annotationStack != nil else { return }\n        for v in annotationStack.arrangedSubviews { annotationStack.removeArrangedSubview(v); v.removeFromSuperview() }\n        annotationCountLabel?.stringValue = "\\(events.count) edits"\n        for (i,e) in events.enumerated() {\n            let note = (e.note?.isEmpty == false) ? e.note! : "No annotation"\n            let title = String(format: "%@   [%@]   %.1f dB\\n%@", formatTime(e.peakTime), e.kind, e.gainDB, note)\n            let b = NSButton(title: title, target: self, action: #selector(selectAnnotationEvent(_:)))\n            b.tag = i\n            b.bezelStyle = .texturedRounded\n            b.alignment = .left\n            b.font = NSFont.systemFont(ofSize: 10, weight: i == timeline.selectedIndex ? .semibold : .regular)\n            b.contentTintColor = i == timeline.selectedIndex ? NSColor(hex: 0x4AA8FF) : NSColor(hex: 0xD1D8DE)\n            b.widthAnchor.constraint(equalToConstant: 284).isActive = true\n            b.heightAnchor.constraint(equalToConstant: 48).isActive = true\n            annotationStack.addArrangedSubview(b)\n        }\n        annotationStack.needsLayout = true\n    }\n\n    @objc private func selectAnnotationEvent(_ sender: NSButton) {\n        guard events.indices.contains(sender.tag) else { return }\n        selectEvent(sender.tag)\n        timeline.followPlayback(to: events[sender.tag].peakTime)\n        playRegionOnly(sender.tag)\n    }\n\n'''+helper_anchor
if helper_anchor not in s: raise SystemExit('format helper anchor missing')
s=s.replace(helper_anchor,helpers,1)

select_end='''        eventInfo.stringValue = String(format: "#%03d [%@]  %.3f–%.3f s  %.0f ms  GAIN %.1f dB  IN %.0f / OUT %.0f ms  %@  •  %@", i + 1, e.kind, e.start, e.end, (e.end - e.start) * 1000, e.gainDB, e.fadeIn * 1000, e.fadeOut * 1000, e.userLabel.isEmpty ? "UNRATED" : e.userLabel, "METHOD \\(e.repairMethod ?? \"MANUAL\") • \\(RGRepairAdvisor.qualityText(for: e))")\n'''
if select_end in s: s=s.replace(select_end,select_end+'        refreshAnnotationSidebar()\n',1)
s=s.replace('self.timeline.events = found\n                self.timeline.selectedIndex = found.isEmpty ? nil : 0','self.timeline.events = found\n                self.refreshAnnotationSidebar()\n                self.timeline.selectedIndex = found.isEmpty ? nil : 0',1)
s=s.replace('self.timeline.events = session.events\n                        let restoredIndex','self.timeline.events = session.events\n                        self.refreshAnnotationSidebar()\n                        let restoredIndex',1)
s=s.replace('timeline.events = events\n        selectEvent(i)\n        saveCurrentSession()\n        status.stringValue = events[i].note == nil ? "ANNOTATION CLEARED"','timeline.events = events\n        selectEvent(i)\n        refreshAnnotationSidebar()\n        saveCurrentSession()\n        status.stringValue = events[i].note == nil ? "ANNOTATION CLEARED"',1)

s=s.replace('"Sibilance detection & repair   •   AUTO UPDATE ON"','"Sibilance detection & repair"',1)
s=s.replace('button("▱  Open WAV"','button("▱  Open File"',1)

p.write_text(s)
print('patched 0.2.32 UI match')
