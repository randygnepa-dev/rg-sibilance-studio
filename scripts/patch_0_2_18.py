from pathlib import Path

p = Path('Sources/RGSibilanceStudio.swift')
s = p.read_text()

s = s.replace('let RGVersion = "0.2.17"', 'let RGVersion = "0.2.18"', 1)
s = s.replace('["S", "Š", "Z", "C", "T", "D", "P", "B", "F", "CH", "OTHER"]', '["S", "Š", "Z", "C", "T", "D", "K", "P", "B", "F", "CH", "OTHER"]', 1)

old = '''    private var kindPopup: NSPopUpButton!\n    private var stopMode: NSSegmentedControl!'''
new = '''    private var kindPopup: NSPopUpButton!\n    private var typeTrimSlider: NSSlider!\n    private var typeTrimValue: NSTextField!\n    private var stopMode: NSSegmentedControl!'''
if old not in s:
    raise SystemExit('UI property marker missing')
s = s.replace(old, new, 1)

old = '''    private var transportPlaying = false\n    private var transportStartTime: Double = 0'''
new = '''    private var transportPlaying = false\n    private var transportStartTime: Double = 0\n    private var typeTrims: [String: Double] = [:]'''
if old not in s:
    raise SystemExit('state marker missing')
s = s.replace(old, new, 1)

old = '''        let rs = label("Repair Strength", size: 11); rs.frame = NSRect(x: 15, y: panelH - 146, width: 105, height: 18); p2.addSubview(rs)\n        repairSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)\n        repairSlider.frame = NSRect(x: 119, y: panelH - 149, width: pw - 150, height: 22)\n        repairSlider.isEnabled = false\n        p2.addSubview(repairSlider)\n        let repairNote = label("Repair engine follows after detector validation", size: 10, color: NSColor(hex: 0x667783))\n        repairNote.frame = NSRect(x: 15, y: 18, width: pw - 30, height: 18)\n        p2.addSubview(repairNote)'''
new = '''        let trimLabel = label("TYPE TRIM", size: 11)\n        trimLabel.frame = NSRect(x: 15, y: panelH - 146, width: 88, height: 18)\n        p2.addSubview(trimLabel)\n        typeTrimSlider = NSSlider(value: 0, minValue: -12, maxValue: 0, target: self, action: #selector(typeTrimChanged))\n        typeTrimSlider.frame = NSRect(x: 102, y: panelH - 149, width: pw - 185, height: 22)\n        typeTrimSlider.isEnabled = false\n        p2.addSubview(typeTrimSlider)\n        typeTrimValue = label("0.0 dB", size: 10, weight: .semibold, color: NSColor(hex: 0x9DB4C5))\n        typeTrimValue.alignment = .right\n        typeTrimValue.frame = NSRect(x: pw - 79, y: panelH - 146, width: 62, height: 18)\n        p2.addSubview(typeTrimValue)\n\n        let rs = label("Repair Strength", size: 11); rs.frame = NSRect(x: 15, y: panelH - 178, width: 105, height: 18); p2.addSubview(rs)\n        repairSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)\n        repairSlider.frame = NSRect(x: 119, y: panelH - 181, width: pw - 150, height: 22)\n        repairSlider.isEnabled = false\n        p2.addSubview(repairSlider)\n        let repairNote = label("TYPE TRIM applies to every event of the selected phoneme", size: 10, color: NSColor(hex: 0x667783))\n        repairNote.frame = NSRect(x: 15, y: 18, width: pw - 30, height: 18)\n        p2.addSubview(repairNote)'''
if old not in s:
    raise SystemExit('event panel marker missing')
s = s.replace(old, new, 1)

old = '''        kindPopup.isEnabled = true\n        kindPopup.selectItem(withTitle: e.kind)\n        eventInfo.stringValue = String(format: "#%03d   %@   %.3f–%.3f s   score %.2f   %@", i + 1, e.kind, e.start, e.end, e.score, e.userLabel.isEmpty ? "UNRATED" : e.userLabel)'''
new = '''        kindPopup.isEnabled = true\n        kindPopup.selectItem(withTitle: e.kind)\n        typeTrimSlider.isEnabled = true\n        let trim = typeTrims[e.kind] ?? 0\n        typeTrimSlider.doubleValue = trim\n        typeTrimValue.stringValue = String(format: "%.1f dB", trim)\n        eventInfo.stringValue = String(format: "#%03d   %@   %.3f–%.3f s   score %.2f   %@   type trim %.1f dB", i + 1, e.kind, e.start, e.end, e.score, e.userLabel.isEmpty ? "UNRATED" : e.userLabel, trim)'''
if old not in s:
    raise SystemExit('selectEvent marker missing')
s = s.replace(old, new, 1)

marker = '''    @objc private func kindChanged() {'''
insert = '''    @objc private func typeTrimChanged() {\n        guard let i = timeline.selectedIndex, events.indices.contains(i) else { return }\n        let kind = events[i].kind\n        let value = typeTrimSlider.doubleValue\n        typeTrims[kind] = value\n        typeTrimValue.stringValue = String(format: "%.1f dB", value)\n        selectEvent(i)\n        let count = events.filter { $0.kind == kind }.count\n        status.stringValue = String(format: "%@ TYPE TRIM %.1f dB — %d events", kind, value, count)\n    }\n\n'''
if marker not in s:
    raise SystemExit('type trim insert marker missing')
s = s.replace(marker, insert + marker, 1)

old = '''            kindPopup.isEnabled = false\n            eventInfo.stringValue = "No sibilance selected"'''
new = '''            kindPopup.isEnabled = false\n            typeTrimSlider.isEnabled = false\n            typeTrimValue.stringValue = "0.0 dB"\n            eventInfo.stringValue = "No sibilance selected"'''
if old not in s:
    raise SystemExit('empty event marker missing')
s = s.replace(old, new, 1)

p.write_text(s)
