from pathlib import Path
p=Path('Sources/RGSibilanceStudio.swift')
s=p.read_text()

s=s.replace('let RGVersion = "0.2.32"','let RGVersion = "0.2.33"',1)

# --- Header / global geometry closer to approved visual ---
s=s.replace('let inspectorW: CGFloat = 326','let inspectorW: CGFloat = 340',1)
s=s.replace('let inspectorGap: CGFloat = 12','let inspectorGap: CGFloat = 10',1)
s=s.replace('let title = label("RG Sibilance Studio", size: 28, weight: .bold, color: .white)','let title = label("RG Sibilance Studio", size: 20, weight: .bold, color: .white)',1)
s=s.replace('title.frame = NSRect(x: 42, y: h - 75, width: 460, height: 38)','title.frame = NSRect(x: 56, y: h - 64, width: 280, height: 28)',1)
s=s.replace('subtitle.frame = NSRect(x: 44, y: h - 101, width: 540, height: 20)','subtitle.frame = NSRect(x: 56, y: h - 86, width: 300, height: 18)',1)

header_anchor='''        root.addSubview(subtitle)\n\n        analyzeButton = button("⌁  Analyze", action: #selector(analyzeAudio))\n'''
header_insert='''        root.addSubview(subtitle)\n\n        let rgBadge = NSTextField(labelWithString: "RG")\n        rgBadge.font = NSFont.systemFont(ofSize: 12, weight: .bold)\n        rgBadge.alignment = .center\n        rgBadge.textColor = .white\n        rgBadge.frame = NSRect(x: 16, y: h - 70, width: 32, height: 32)\n        rgBadge.wantsLayer = true\n        rgBadge.layer?.cornerRadius = 16\n        rgBadge.layer?.borderWidth = 1.2\n        rgBadge.layer?.borderColor = NSColor(hex: 0x6E7E8A).cgColor\n        rgBadge.layer?.backgroundColor = NSColor(hex: 0x101820).cgColor\n        root.addSubview(rgBadge)\n\n        analyzeButton = button("⌁  Analyze", action: #selector(analyzeAudio))\n'''
if header_anchor not in s: raise SystemExit('header anchor missing')
s=s.replace(header_anchor,header_insert,1)

s=s.replace('analyzeButton.frame = NSRect(x: 42 + mainW - 326, y: h - 84, width: 150, height: 40)','analyzeButton.frame = NSRect(x: 42 + mainW - 152, y: h - 72, width: 140, height: 32)',1)
s=s.replace('open.frame = NSRect(x: 42 + mainW - 164, y: h - 84, width: 150, height: 40)','open.frame = NSRect(x: 42 + mainW - 302, y: h - 72, width: 140, height: 32)',1)

# Editor begins higher and gets more vertical room, matching the mockup proportions.
s=s.replace('let editorY: CGFloat = 286','let editorY: CGFloat = 274',1)
s=s.replace('let editorH = h - editorY - 124','let editorH = h - editorY - 104',1)

# Header-like tabs inside editor.
editor_anchor='''        editor.fillColor = NSColor(hex: 0x0C141B)\n        root.addSubview(editor)\n'''
editor_insert=editor_anchor+'''\n        let viewTabs = NSSegmentedControl(labels: ["WAVEFORM", "SPECTROGRAM"], trackingMode: .selectOne, target: nil, action: nil)\n        viewTabs.selectedSegment = 0\n        viewTabs.frame = NSRect(x: 14, y: editorH - 34, width: 214, height: 24)\n        editor.addSubview(viewTabs)\n'''
if editor_anchor not in s: raise SystemExit('editor anchor missing')
s=s.replace(editor_anchor,editor_insert,1)

# Annotations panel visually reaches header/footer like reference.
s=s.replace('let annotationsPanel = makePanel(NSRect(x: 42 + mainW + inspectorGap, y: 58, width: inspectorW, height: h - 182))','let annotationsPanel = makePanel(NSRect(x: 42 + mainW + inspectorGap, y: 44, width: inspectorW, height: h - 144))',1)
s=s.replace('annTitle.frame = NSRect(x: 14, y: annotationsPanel.bounds.height - 34, width: 190, height: 20)','annTitle.frame = NSRect(x: 16, y: annotationsPanel.bounds.height - 34, width: 210, height: 20)',1)
s=s.replace('annAdd.frame = NSRect(x: inspectorW - 86, y: annotationsPanel.bounds.height - 40, width: 72, height: 28)','annAdd.frame = NSRect(x: inspectorW - 88, y: annotationsPanel.bounds.height - 40, width: 74, height: 28)',1)

# Current time / pinned strip moved below tabs so it no longer collides.
s=s.replace('currentTimeLabel.frame = NSRect(x: 16, y: editorH - 37, width: 150, height: 24)','currentTimeLabel.frame = NSRect(x: 16, y: editorH - 66, width: 150, height: 24)',1)
s=s.replace('timeHint.frame = NSRect(x: 166, y: editorH - 34, width: 150, height: 18)','timeHint.frame = NSRect(x: 166, y: editorH - 63, width: 150, height: 18)',1)
s=s.replace('let pinned = makePanel(NSRect(x: 330, y: editorH - 48, width: editor.bounds.width - 396, height: 38))','let pinned = makePanel(NSRect(x: 320, y: editorH - 72, width: editor.bounds.width - 334, height: 34))',1)
s=s.replace('pinnedEventLabel.frame = NSRect(x: 10, y: 10, width: 205, height: 18)','pinnedEventLabel.frame = NSRect(x: 10, y: 8, width: 190, height: 18)',1)
s=s.replace('let pPlay = button("▶", action: #selector(playSelected)); pPlay.frame = NSRect(x: 218, y: 5, width: 34, height: 28); pinned.addSubview(pPlay)','let pPlay = button("▶", action: #selector(playSelected)); pPlay.frame = NSRect(x: 198, y: 3, width: 32, height: 28); pinned.addSubview(pPlay)',1)
s=s.replace('let pGood = button("GOOD", action: #selector(markGood)); pGood.frame = NSRect(x: 256, y: 5, width: 55, height: 28); pinned.addSubview(pGood)','let pGood = button("GOOD", action: #selector(markGood)); pGood.frame = NSRect(x: 234, y: 3, width: 58, height: 28); pinned.addSubview(pGood)',1)
s=s.replace('let pBad = button("BAD", action: #selector(markBad)); pBad.frame = NSRect(x: 315, y: 5, width: 50, height: 28); pinned.addSubview(pBad)','let pBad = button("BAD", action: #selector(markBad)); pBad.frame = NSRect(x: 296, y: 3, width: 52, height: 28); pinned.addSubview(pBad)',1)
s=s.replace('let pNote = button("✎ Note", action: #selector(addAnnotation)); pNote.frame = NSRect(x: 369, y: 5, width: 72, height: 28); pinned.addSubview(pNote)','let pNote = button("✎ Note", action: #selector(addAnnotation)); pNote.frame = NSRect(x: 352, y: 3, width: 74, height: 28); pinned.addSubview(pNote)',1)
s=s.replace('pinnedGainSlider.frame = NSRect(x: 448, y: 8, width: 128, height: 22); pinnedGainSlider.isEnabled = false; pinned.addSubview(pinnedGainSlider)','pinnedGainSlider.frame = NSRect(x: 432, y: 6, width: 122, height: 22); pinnedGainSlider.isEnabled = false; pinned.addSubview(pinnedGainSlider)',1)
s=s.replace('pinnedNoteLabel.frame = NSRect(x: 582, y: 10, width: max(80, pinned.bounds.width - 592), height: 18)','pinnedNoteLabel.frame = NSRect(x: 560, y: 8, width: max(70, pinned.bounds.width - 570), height: 18)',1)

# Timeline larger, with proper transport strip space below.
s=s.replace('timeline = TimelineView(frame: NSRect(x: 12, y: 48, width: editor.bounds.width - 66, height: editorH - 124))','timeline = TimelineView(frame: NSRect(x: 12, y: 74, width: editor.bounds.width - 24, height: editorH - 154))',1)
s=s.replace('let zoomIn = button("+", action: #selector(zoomInTimeline)); zoomIn.frame = NSRect(x: editor.bounds.width - 45, y: editorH - 78, width: 32, height: 30); editor.addSubview(zoomIn)','let zoomIn = button("＋", action: #selector(zoomInTimeline)); zoomIn.frame = NSRect(x: 14, y: 42, width: 34, height: 26); editor.addSubview(zoomIn)',1)
s=s.replace('let zoomOut = button("−", action: #selector(zoomOutTimeline)); zoomOut.frame = NSRect(x: editor.bounds.width - 45, y: editorH - 113, width: 32, height: 30); editor.addSubview(zoomOut)','let zoomOut = button("−", action: #selector(zoomOutTimeline)); zoomOut.frame = NSRect(x: 52, y: 42, width: 34, height: 26); editor.addSubview(zoomOut)',1)
s=s.replace('let fit = button("Fit", action: #selector(fitTimeline)); fit.frame = NSRect(x: editor.bounds.width - 48, y: editorH - 149, width: 38, height: 30); editor.addSubview(fit)','let fit = button("Fit", action: #selector(fitTimeline)); fit.frame = NSRect(x: 90, y: 42, width: 44, height: 26); editor.addSubview(fit)',1)

# Transport bar visually centered under editor.
transport_anchor='''        let fit = button("Fit", action: #selector(fitTimeline)); fit.frame = NSRect(x: 90, y: 42, width: 44, height: 26); editor.addSubview(fit)\n\n        detectedFooter = label("Detected: 0 events", size: 11, weight: .semibold, color: NSColor(hex: 0x329CFF))\n'''
transport_insert='''        let fit = button("Fit", action: #selector(fitTimeline)); fit.frame = NSRect(x: 90, y: 42, width: 44, height: 26); editor.addSubview(fit)\n        let trPrev = button("◀", action: #selector(previousEvent)); trPrev.frame = NSRect(x: editor.bounds.midX - 74, y: 40, width: 34, height: 28); editor.addSubview(trPrev)\n        let trPlay = button("▶", action: #selector(playSelected)); trPlay.frame = NSRect(x: editor.bounds.midX - 34, y: 38, width: 46, height: 32); trPlay.bezelColor = NSColor(hex: 0x263746); editor.addSubview(trPlay)\n        let trNext = button("▶|", action: #selector(nextEvent)); trNext.frame = NSRect(x: editor.bounds.midX + 18, y: 40, width: 40, height: 28); editor.addSubview(trNext)\n\n        detectedFooter = label("Detected: 0 events", size: 11, weight: .semibold, color: NSColor(hex: 0x329CFF))\n'''
if transport_anchor not in s: raise SystemExit('transport anchor missing')
s=s.replace(transport_anchor,transport_insert,1)

# Move footer controls to bottom row and keep them away from transport.
s=s.replace('detectedFooter.frame = NSRect(x: 16, y: 16, width: 180, height: 20)','detectedFooter.frame = NSRect(x: 16, y: 13, width: 180, height: 20)',1)
s=s.replace('legend.frame = NSRect(x: 390, y: 16, width: 390, height: 20)','legend.frame = NSRect(x: 160, y: 13, width: 330, height: 20)',1)
s=s.replace('sensText.frame = NSRect(x: editor.bounds.width - 278, y: 16, width: 78, height: 20)','sensText.frame = NSRect(x: editor.bounds.width - 250, y: 13, width: 78, height: 20)',1)
s=s.replace('editorSensitivity.frame = NSRect(x: editor.bounds.width - 196, y: 14, width: 132, height: 22)','editorSensitivity.frame = NSRect(x: editor.bounds.width - 170, y: 11, width: 110, height: 22)',1)
s=s.replace('sensValue.frame = NSRect(x: editor.bounds.width - 58, y: 16, width: 45, height: 20)','sensValue.frame = NSRect(x: editor.bounds.width - 56, y: 13, width: 42, height: 20)',1)

# Bottom panels: fixed widths to stop all overlaps and match mockup proportions.
s=s.replace('let panelY: CGFloat = 58','let panelY: CGFloat = 44',1)
s=s.replace('let panelH = max(CGFloat(216), editorY - 72)','let panelH = max(CGFloat(214), editorY - 56)',1)
s=s.replace('let leftW: CGFloat = mainW * 0.22\n        let centerW: CGFloat = mainW * 0.38\n        let advancedW: CGFloat = mainW * 0.18\n        let rightW = mainW - leftW - centerW - advancedW - gap * 3','let leftW: CGFloat = 210\n        let centerW: CGFloat = 390\n        let advancedW: CGFloat = 180\n        let rightW = max(CGFloat(250), mainW - leftW - centerW - advancedW - gap * 3)',1)

# Repair controls compacted.
s=s.replace('good.frame = NSRect(x: 16, y: panelH - 73, width: 74, height: 28)','good.frame = NSRect(x: 16, y: panelH - 70, width: 62, height: 26)',1)
s=s.replace('bad.frame = NSRect(x: 96, y: panelH - 73, width: 70, height: 28)','bad.frame = NSRect(x: 82, y: panelH - 70, width: 58, height: 26)',1)
s=s.replace('target.frame = NSRect(x: 172, y: panelH - 73, width: 82, height: 28)','target.frame = NSRect(x: 144, y: panelH - 70, width: 70, height: 26)',1)
s=s.replace('normal.frame = NSRect(x: 260, y: panelH - 73, width: 86, height: 28)','normal.frame = NSRect(x: 218, y: panelH - 70, width: 72, height: 26)',1)
s=s.replace('typeLabel.frame = NSRect(x: centerW - 142, y: panelH - 68, width: 40, height: 18)','typeLabel.frame = NSRect(x: centerW - 92, y: panelH - 66, width: 34, height: 18)',1)
s=s.replace('kindPopup = NSPopUpButton(frame: NSRect(x: centerW - 104, y: panelH - 74, width: 88, height: 26), pullsDown: false)','kindPopup = NSPopUpButton(frame: NSRect(x: centerW - 60, y: panelH - 72, width: 48, height: 26), pullsDown: false)',1)
s=s.replace('repairSlider.frame = NSRect(x: 126, y: panelH - 116, width: centerW - 210, height: 22)','repairSlider.frame = NSRect(x: 96, y: panelH - 116, width: centerW - 150, height: 22)',1)
s=s.replace('autoRepairButton.frame = NSRect(x: 16, y: 70, width: 108, height: 34)','autoRepairButton.frame = NSRect(x: 16, y: 70, width: 102, height: 32)',1)
s=s.replace('morph.frame = NSRect(x: 130, y: 70, width: 140, height: 34)','morph.frame = NSRect(x: 124, y: 70, width: 120, height: 32)',1)
s=s.replace('blend.frame = NSRect(x: 276, y: 70, width: 140, height: 34)','blend.frame = NSRect(x: 250, y: 70, width: 120, height: 32)',1)

# Preview panel rebuilt compactly so nothing overlaps.
s=s.replace('playButton = button("▶  PLAY EVENT", action: #selector(playSelected)); playButton.frame = NSRect(x: 16, y: panelH - 76, width: 132, height: 36); p3.addSubview(playButton)','playButton = button("▶", action: #selector(playSelected)); playButton.frame = NSRect(x: 16, y: panelH - 72, width: 42, height: 30); p3.addSubview(playButton)',1)
s=s.replace('auditionMode = NSSegmentedControl(labels: ["ORIG", "REPAIR", "DELTA", "S ONLY"], trackingMode: .selectOne, target: self, action: #selector(auditionModeChanged)); auditionMode.selectedSegment = 1; auditionMode.frame = NSRect(x: 156, y: panelH - 77, width: rightW - 260, height: 30); p3.addSubview(auditionMode)','auditionMode = NSSegmentedControl(labels: ["ORIG", "REPAIR", "DELTA", "S"], trackingMode: .selectOne, target: self, action: #selector(auditionModeChanged)); auditionMode.selectedSegment = 1; auditionMode.frame = NSRect(x: 62, y: panelH - 72, width: max(150, rightW - 78), height: 28); p3.addSubview(auditionMode)',1)
s=s.replace('loopButton = button("↻ Loop", action: #selector(toggleLoop)); loopButton.frame = NSRect(x: rightW - 96, y: panelH - 76, width: 80, height: 36); p3.addSubview(loopButton)','loopButton = button("↻", action: #selector(toggleLoop)); loopButton.frame = NSRect(x: 16, y: panelH - 108, width: 42, height: 28); p3.addSubview(loopButton)',1)
s=s.replace('let outTitle = label("RENDER / OUTPUT", size: 11, weight: .bold, color: .white); outTitle.frame = NSRect(x: 16, y: panelH - 126, width: 100, height: 18); p3.addSubview(outTitle)','let outTitle = label("OUTPUT", size: 11, weight: .bold, color: .white); outTitle.frame = NSRect(x: 16, y: panelH - 140, width: 100, height: 18); p3.addSubview(outTitle)',1)
s=s.replace('outputHelp.frame = NSRect(x: 16, y: panelH - 158, width: rightW - 32, height: 32)','outputHelp.frame = NSRect(x: 16, y: panelH - 168, width: rightW - 32, height: 30)',1)
s=s.replace('exportButton.frame = NSRect(x: 16, y: 64, width: rightW - 32, height: 36)','exportButton.frame = NSRect(x: 16, y: 52, width: rightW - 32, height: 32)',1)
s=s.replace('stopMode.frame = NSRect(x: 16, y: 18, width: 176, height: 28)','stopMode.frame = NSRect(x: 16, y: 14, width: min(150, rightW - 110), height: 26)',1)
s=s.replace('prev.frame = NSRect(x: rightW - 124, y: 18, width: 48, height: 28)','prev.frame = NSRect(x: rightW - 92, y: 14, width: 34, height: 26)',1)
s=s.replace('next.frame = NSRect(x: rightW - 68, y: 18, width: 48, height: 28)','next.frame = NSRect(x: rightW - 52, y: 14, width: 34, height: 26)',1)

# File info moved into header, as in mockup.
s=s.replace('fileInfo.frame = NSRect(x: 44, y: 35, width: w * 0.44, height: 18)','fileInfo.frame = NSRect(x: 360, y: h - 66, width: max(260, mainW - 690), height: 20)',1)
s=s.replace('detectedLabel.frame = NSRect(x: 44, y: 17, width: 220, height: 18)','detectedLabel.frame = NSRect(x: 42, y: 18, width: 220, height: 18)',1)

# Sidebar cards: more visual, fixed width and selected state.
s=s.replace('b.bezelStyle = .texturedRounded','b.bezelStyle = .rounded',1)
s=s.replace('b.frame.size = NSSize(width: max(220, annotationStack.bounds.width - 4), height: 48)','b.frame.size = NSSize(width: max(248, annotationStack.bounds.width - 4), height: 54)',1)
s=s.replace('b.heightAnchor.constraint(equalToConstant: 48).isActive = true','b.heightAnchor.constraint(equalToConstant: 54).isActive = true',1)

# Updater cache fix: SHA is fetched first, then used as cache-busting token for the ZIP URL.
old='''        let stamp = String(Int(Date().timeIntervalSince1970))\n        guard let zipURL = URL(string: "\\(RGRepoRaw)/dist/RG-Sibilance-Studio-\\(version).zip?t=\\(stamp)"),\n              let shaURL = URL(string: "\\(RGRepoRaw)/dist/SHA256?t=\\(stamp)") else { busy = false; return }\n\n        URLSession.shared.downloadTask(with: zipURL) { [weak self] tempURL, _, error in\n'''
new='''        let stamp = String(Int(Date().timeIntervalSince1970))\n        guard let shaURL = URL(string: "\\(RGRepoRaw)/dist/SHA256?t=\\(stamp)") else { busy = false; return }\n        guard let expectedData = try? Data(contentsOf: shaURL),\n              let expectedHash = String(data: expectedData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),\n              !expectedHash.isEmpty,\n              let zipURL = URL(string: "\\(RGRepoRaw)/dist/RG-Sibilance-Studio-\\(version).zip?sha=\\(expectedHash)") else {\n            busy = false\n            DispatchQueue.main.async { self.onStatus?("UPDATE FAILED — manifest unavailable") }\n            return\n        }\n\n        URLSession.shared.downloadTask(with: zipURL) { [weak self] tempURL, _, error in\n'''
if old not in s: raise SystemExit('updater preamble missing')
s=s.replace(old,new,1)
s=s.replace('''                let expectedData = try Data(contentsOf: shaURL)\n                let expected = (String(data: expectedData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()\n                let actual = try self.sha256(tempURL).lowercased()\n                guard !expected.isEmpty, expected == actual else {\n''','''                let expected = expectedHash\n                let actual = try self.sha256(tempURL).lowercased()\n                guard expected == actual else {\n''',1)

p.write_text(s)
print('patched 0.2.33 visual match')
