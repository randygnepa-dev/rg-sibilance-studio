from pathlib import Path

p = Path('Sources/RGSibilanceStudio.swift')
s = p.read_text()

s = s.replace('let RGVersion = "0.2.29"', 'let RGVersion = "0.2.30"', 1)
s = s.replace('Sibilance detection & repair   •   AUTO UPDATE BETA', 'Sibilance detection & repair   •   AUTO UPDATE ON', 1)

# Remove the redundant top drag/drop card. Import remains directly in the editor.
old_drop = '''        dropView = AudioDropView(frame: NSRect(x: 42, y: h - 283, width: w - 84, height: 160))
        dropView.onAudioDrop = { [weak self] url in self?.loadAudio(url) }
        root.addSubview(dropView)

        let editorY = h - 674
        let editorH: CGFloat = 368
'''
new_drop = '''        let editorY: CGFloat = 286
        let editorH = h - editorY - 124
'''
assert old_drop in s, 'top drop/editor anchor not found'
s = s.replace(old_drop, new_drop, 1)

# Make the main editor the visual focus.
s = s.replace(
    'timeline = TimelineView(frame: NSRect(x: 12, y: 52, width: editor.bounds.width - 66, height: editorH - 92))',
    'timeline = TimelineView(frame: NSRect(x: 12, y: 48, width: editor.bounds.width - 66, height: editorH - 82))',
    1,
)

# Slightly wider repair panel, narrower detection panel.
s = s.replace(
    'let leftW: CGFloat = (w - 108) * 0.285\n        let centerW: CGFloat = (w - 108) * 0.37',
    'let leftW: CGFloat = (w - 108) * 0.22\n        let centerW: CGFloat = (w - 108) * 0.44',
    1,
)

# Detection becomes compact: main sensitivity lives in editor footer, advanced stays under gear.
start = s.index('        addTitle("DETECTION", to: p1, y: panelH - 30)')
end = s.index('\n        addTitle("REPAIR", to: p2, y: panelH - 30)', start)
new_detection = '''        addTitle("DETECTION", to: p1, y: panelH - 30)
        let autoBadge = label("AUTO", size: 9, weight: .bold, color: NSColor(hex: 0x4EB4FF))
        autoBadge.frame = NSRect(x: 16, y: panelH - 62, width: 54, height: 18)
        p1.addSubview(autoBadge)
        let detectHelp = label("Sensitivity is adjusted below the waveform. Manual regions: Shift-drag.", size: 10, color: NSColor(hex: 0x667784))
        detectHelp.frame = NSRect(x: 16, y: 70, width: leftW - 32, height: 42)
        detectHelp.lineBreakMode = .byWordWrapping
        detectHelp.maximumNumberOfLines = 3
        p1.addSubview(detectHelp)
        let gear = button("⚙ Advanced", action: #selector(showAdvancedInfo))
        gear.frame = NSRect(x: 16, y: 42, width: min(110, leftW - 32), height: 28)
        p1.addSubview(gear)
        let markS = button("+ Mark S", action: #selector(markManualS))
        markS.frame = NSRect(x: 16, y: 12, width: min(110, leftW - 32), height: 28)
        p1.addSubview(markS)
        sensitivitySlider = NSSlider(value: 0.72, minValue: 0, maxValue: 1, target: self, action: #selector(sensitivityChanged))
        sensitivitySlider.isHidden = true
        p1.addSubview(sensitivitySlider)
'''
s = s[:start] + new_detection + s[end:]

# Make the main de-ess control visually clearer.
s = s.replace('let rs = label("Repair Strength", size: 11);', 'let rs = label("SIBILANCE", size: 11, weight: .bold, color: .white);', 1)
s = s.replace('autoRepairButton = button("Repair", action: #selector(autoRepairSelected));', 'autoRepairButton = button("AUTO REPAIR", action: #selector(autoRepairSelected));', 1)

# Make selected-event preview more explicit.
s = s.replace('playButton = button("▶  Play", action: #selector(playSelected));', 'playButton = button("▶  PLAY EVENT", action: #selector(playSelected));', 1)
s = s.replace('let outTitle = label("OUTPUT", size: 11, weight: .bold, color: .white);', 'let outTitle = label("RENDER / OUTPUT", size: 11, weight: .bold, color: .white);', 1)

# Cleaner empty-editor copy.
s = s.replace('let sub = "Waveform, analýza aj editácia ostávajú v tomto okne"', 'let sub = "Drop vocal here • analyze • edit directly on waveform"', 1)

p.write_text(s)
print('patched 0.2.30 UI cleanup')
