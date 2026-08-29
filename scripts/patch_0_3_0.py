from pathlib import Path
p=Path('Sources/RGSibilanceStudio.swift')
s=p.read_text()
s=s.replace('let RGVersion = "0.2.33"','let RGVersion = "0.3.0"',1)

# Add custom DAW-style button class once.
anchor='final class AppDelegate: NSObject, NSApplicationDelegate, AVAudioPlayerDelegate {'
if 'final class RGButton:' not in s:
    custom=r'''
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

'''
    s=s.replace(anchor,custom+anchor,1)

old='''    private func button(_ title: String, action: Selector) -> NSButton {\n        let b = NSButton(title: title, target: self, action: action)\n        b.bezelStyle = .rounded\n        return b\n    }'''
new='''    private func button(_ title: String, action: Selector) -> NSButton {\n        let b = RGButton(title: title, target: self, action: action)\n        if title.contains("Analyze") || title.contains("AUTO REPAIR") || title.contains("Export") { b.role = .primary }\n        else if title == "BAD" { b.role = .danger }\n        else if title.contains("Fit") || title == "＋" || title == "−" || title == "◀" || title == "▶" || title == "■" { b.role = .ghost }\n        else { b.role = .secondary }\n        return b\n    }'''
if old not in s: raise SystemExit('button helper anchor missing')
s=s.replace(old,new,1)

# Stronger DAW chrome and spacing.
s=s.replace('window.backgroundColor = NSColor(hex: 0x0A1016)','window.backgroundColor = NSColor(hex: 0x080D12)',1)
s=s.replace('window.titlebarAppearsTransparent = false','window.titlebarAppearsTransparent = true\n        window.titleVisibility = .hidden',1)
s=s.replace('root.layer?.backgroundColor = NSColor(hex: 0x0A1016).cgColor','root.layer?.backgroundColor = NSColor(hex: 0x080D12).cgColor',1)

# Insert top toolbar plate behind title/file/actions.
root_anchor='''        let inspectorW: CGFloat = 340\n        let inspectorGap: CGFloat = 10\n        let mainW = w - 84 - inspectorW - inspectorGap\n'''
if root_anchor in s and 'let topPlate = NSView' not in s:
    insert=root_anchor+'''\n        let topPlate = NSView(frame: NSRect(x: 0, y: h - 96, width: w, height: 96))\n        topPlate.wantsLayer = true\n        topPlate.layer?.backgroundColor = NSColor(hex: 0x0B1218).cgColor\n        topPlate.layer?.borderWidth = 0.5\n        topPlate.layer?.borderColor = NSColor(hex: 0x25343F).cgColor\n        root.addSubview(topPlate)\n'''
    s=s.replace(root_anchor,insert,1)

# Bring main header closer to mockup.
s=s.replace('title.frame = NSRect(x: 56, y: h - 64, width: 280, height: 28)','title.frame = NSRect(x: 56, y: h - 58, width: 300, height: 28)',1)
s=s.replace('subtitle.frame = NSRect(x: 56, y: h - 86, width: 300, height: 18)','subtitle.frame = NSRect(x: 56, y: h - 79, width: 300, height: 18)',1)
s=s.replace('rgBadge.frame = NSRect(x: 16, y: h - 70, width: 32, height: 32)','rgBadge.frame = NSRect(x: 16, y: h - 64, width: 32, height: 32)',1)
s=s.replace('analyzeButton.frame = NSRect(x: 42 + mainW - 152, y: h - 72, width: 140, height: 32)','analyzeButton.frame = NSRect(x: 42 + mainW - 138, y: h - 67, width: 126, height: 30)',1)
s=s.replace('open.frame = NSRect(x: 42 + mainW - 302, y: h - 72, width: 140, height: 32)','open.frame = NSRect(x: 42 + mainW - 274, y: h - 67, width: 126, height: 30)',1)

# Larger editor / slimmer bottom controls.
s=s.replace('let editorY: CGFloat = 274','let editorY: CGFloat = 246',1)
s=s.replace('let editorH = h - editorY - 104','let editorH = h - editorY - 112',1)

# Panels become flatter / more DAW-like.
s=s.replace('p.borderColor = NSColor(hex: 0x263540)','p.borderColor = NSColor(hex: 0x263744)',1)
s=s.replace('p.fillColor = NSColor(hex: 0x101820)','p.fillColor = NSColor(hex: 0x0D151C)',1)
s=s.replace('p.cornerRadius = 8','p.cornerRadius = 6',1)

# Sidebar deeper contrast.
s=s.replace('annotationsPanel.fillColor = NSColor(hex: 0x0D161F)','annotationsPanel.fillColor = NSColor(hex: 0x0A1219)',1)

# Timeline styling: darker spectrogram bed and light waveform.
s=s.replace('NSColor(hex: 0x269AF4, alpha: 0.42).setFill()','NSColor(hex: 0xD8DEE4, alpha: 0.62).setFill()',1)
s=s.replace('NSColor(hex: 0x45B2FF).setStroke()','NSColor(hex: 0xF2F5F7).withAlphaComponent(0.86).setStroke()',1)
s=s.replace('NSColor(hex: 0x42B0FF).setStroke()','NSColor(hex: 0xF2F5F7).withAlphaComponent(0.90).setStroke()',1)

# Custom tab look: disable default glossy feel and use compact size.
s=s.replace('viewTabs.frame = NSRect(x: 14, y: editorH - 34, width: 214, height: 24)','viewTabs.frame = NSRect(x: 14, y: editorH - 35, width: 206, height: 24)\n        viewTabs.controlSize = .small',1)

# Status/footer becomes quieter.
s=s.replace('status = label("READY — drop WAV/AIFF", size: 10, weight: .semibold, color: NSColor(hex: 0x40FF68))','status = label("READY", size: 10, weight: .semibold, color: NSColor(hex: 0x48D977))',1)

p.write_text(s)
print('patched 0.3.0 beta visual shell')
