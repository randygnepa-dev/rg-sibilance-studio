from pathlib import Path
import re

p = Path('Sources/RGSibilanceStudio.swift')
s = p.read_text()
s = s.replace('let RGVersion = "0.4.1"', 'let RGVersion = "0.4.2"', 1)
s = s.replace('CLEAN PRO 0.4.1 PRO TOOLS', 'CLEAN PRO 0.4.2 PRO TOOLS', 1)

# Events inspector: compact single-line rows, correctly sized scroll document, no stacking overlap.
pat = re.compile(r'''    private func refreshAnnotationSidebar\(\) \{.*?\n    \}\n\n    @objc private func selectAnnotationEvent''', re.S)
rep = r'''    private func refreshAnnotationSidebar() {
        guard annotationStack != nil else { return }
        for v in annotationStack.arrangedSubviews {
            annotationStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        annotationCountLabel?.stringValue = "\(events.count) events"
        let rowH: CGFloat = 30
        let docH = max(annotationStack.enclosingScrollView?.contentSize.height ?? 0, CGFloat(events.count) * (rowH + 4) + 8)
        annotationStack.frame = NSRect(x: 0, y: 0, width: 240, height: docH)
        annotationStack.orientation = .vertical
        annotationStack.alignment = .leading
        annotationStack.spacing = 4
        annotationStack.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)

        for (i, e) in events.enumerated() {
            let statusText = e.userLabel.isEmpty ? "—" : e.userLabel.capitalized
            let title = String(format: "%02d   %@   %@   %5.1f dB   %@", i + 1, e.kind, formatTime(e.peakTime), e.gainDB, statusText)
            let b = NSButton(title: title, target: self, action: #selector(selectAnnotationEvent(_:)))
            b.tag = i
            b.isBordered = false
            b.alignment = .left
            b.font = NSFont.monospacedSystemFont(ofSize: 9, weight: i == timeline.selectedIndex ? .semibold : .regular)
            b.contentTintColor = i == timeline.selectedIndex ? NSColor.white : NSColor(hex: 0xB7C4CD)
            b.wantsLayer = true
            b.layer?.cornerRadius = 4
            if i == timeline.selectedIndex {
                b.layer?.backgroundColor = NSColor(hex: 0x4D171B).cgColor
                b.layer?.borderColor = NSColor(hex: 0xA5353D).cgColor
                b.layer?.borderWidth = 1
            } else {
                b.layer?.backgroundColor = NSColor(hex: 0x111C25).cgColor
                b.layer?.borderWidth = 0
            }
            b.widthAnchor.constraint(equalToConstant: 236).isActive = true
            b.heightAnchor.constraint(equalToConstant: rowH).isActive = true
            annotationStack.addArrangedSubview(b)
        }
        annotationStack.needsLayout = true
        annotationStack.enclosingScrollView?.documentView?.frame.size.height = docH
    }

    @objc private func selectAnnotationEvent'''
s, n = pat.subn(rep, s, count=1)
if n != 1:
    raise SystemExit('refreshAnnotationSidebar patch failed')

# Selected event drawing: replace vertical clip-gain fader with Pro Tools-like horizontal clip gain line + center node.
pat = re.compile(r'''            if selected \{\n                let fader = gainFaderRect\(for: i\).*?String\(format: "OUT %.0f ms", e.fadeOut \* 1000\)\.draw\(at: NSPoint\(x: max\(startX, endX - 58\), y: fadeTop \+ 5\), withAttributes: fattrs\)\n            \}''', re.S)
rep = r'''            if selected {
                // Pro Tools-like clip gain: horizontal line across the event, center node controls level.
                let minDB: Double = -18.0
                let maxDB: Double = 0.0
                let gdb = min(maxDB, max(minDB, e.gainDB))
                let norm = CGFloat((gdb - minDB) / (maxDB - minDB))
                let gainTop = plotRect.midY + 54
                let gainBottom = plotRect.midY - 54
                let gainY = gainBottom + norm * (gainTop - gainBottom)

                let gainLine = NSBezierPath()
                gainLine.move(to: NSPoint(x: startX + 4, y: gainY))
                gainLine.line(to: NSPoint(x: endX - 4, y: gainY))
                NSColor.white.withAlphaComponent(0.92).setStroke()
                gainLine.lineWidth = 1.5
                gainLine.stroke()

                let centerX = (startX + endX) * 0.5
                let node = NSBezierPath(ovalIn: NSRect(x: centerX - 6, y: gainY - 6, width: 12, height: 12))
                NSColor.white.setFill(); node.fill()
                color.setStroke(); node.lineWidth = 1.5; node.stroke()

                let tag = String(format: "%.1f dB", e.gainDB)
                let tagAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                    .foregroundColor: NSColor.white
                ]
                let ts = tag.size(withAttributes: tagAttrs)
                let tr = NSRect(x: centerX - ts.width/2 - 6, y: gainY + 9, width: ts.width + 12, height: 18)
                NSColor(hex: 0x3B1115).withAlphaComponent(0.94).setFill()
                NSBezierPath(roundedRect: tr, xRadius: 4, yRadius: 4).fill()
                tag.draw(at: NSPoint(x: tr.minX + 6, y: tr.minY + 3), withAttributes: tagAttrs)

                // Fades: handles live on the event top corners; curve visually ends at the gain line.
                let inX = xForTime(min(e.end, e.start + e.fadeIn))
                let outX = xForTime(max(e.start, e.end - e.fadeOut))
                let fadeTop = plotRect.maxY - 26
                let fadeInPath = NSBezierPath()
                fadeInPath.move(to: NSPoint(x: startX, y: fadeTop))
                fadeInPath.curve(to: NSPoint(x: inX, y: gainY), controlPoint1: NSPoint(x: startX + (inX-startX)*0.35, y: fadeTop), controlPoint2: NSPoint(x: inX - (inX-startX)*0.20, y: gainY))
                color.withAlphaComponent(0.95).setStroke(); fadeInPath.lineWidth = 1.6; fadeInPath.stroke()
                let fadeOutPath = NSBezierPath()
                fadeOutPath.move(to: NSPoint(x: outX, y: gainY))
                fadeOutPath.curve(to: NSPoint(x: endX, y: fadeTop), controlPoint1: NSPoint(x: outX + (endX-outX)*0.20, y: gainY), controlPoint2: NSPoint(x: endX - (endX-outX)*0.35, y: fadeTop))
                fadeOutPath.lineWidth = 1.6; fadeOutPath.stroke()

                for x in [inX, outX] {
                    let h = NSBezierPath(ovalIn: NSRect(x: x - 4, y: gainY - 4, width: 8, height: 8))
                    color.setFill(); h.fill(); NSColor.white.setStroke(); h.lineWidth = 1; h.stroke()
                }
                let fattrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.75)]
                String(format: "%.0f ms", e.fadeIn * 1000).draw(at: NSPoint(x: startX + 5, y: plotRect.minY + 8), withAttributes: fattrs)
                String(format: "%.0f ms", e.fadeOut * 1000).draw(at: NSPoint(x: max(startX, endX - 42), y: plotRect.minY + 8), withAttributes: fattrs)
            }'''
s, n = pat.subn(rep, s, count=1)
if n != 1:
    raise SystemExit('selected event drawing patch failed')

# Hit testing / drag gain follows the horizontal line area, full event width.
pat = re.compile(r'''    private func gainFaderRect\(for i: Int\) -> NSRect \{.*?\n    \}\n\n    private func updateGainDrag\(_ i: Int, y: CGFloat\) \{.*?\n    \}''', re.S)
rep = r'''    private func gainFaderRect(for i: Int) -> NSRect {
        guard events.indices.contains(i) else { return .zero }
        let startX = xForTime(events[i].start)
        let endX = xForTime(events[i].end)
        return NSRect(x: min(startX, endX), y: plotRect.midY - 64, width: max(36, abs(endX - startX)), height: 128)
    }

    private func updateGainDrag(_ i: Int, y: CGFloat) {
        guard events.indices.contains(i) else { return }
        let top = plotRect.midY + 54
        let bottom = plotRect.midY - 54
        let clampedY = min(top, max(bottom, y))
        let normalized = Double((clampedY - bottom) / max(1, top - bottom))
        let value = -18.0 + normalized * 18.0
        events[i].gainDB = min(0, max(-18, value))
        onEventGainChanged?(i, events[i].gainDB)
        needsDisplay = true
    }'''
s, n = pat.subn(rep, s, count=1)
if n != 1:
    raise SystemExit('gain drag patch failed')

# Remove the redundant pinned gain slider from top toolbar visually; clip gain belongs on waveform.
s = s.replace('pinnedGainSlider.frame=NSRect(x:738,y:editorH-32,width:120,height:20); pinnedGainSlider.isEnabled=false; editorPanel.addSubview(pinnedGainSlider)', 'pinnedGainSlider.frame = .zero; pinnedGainSlider.isHidden = true; pinnedGainSlider.isEnabled = false; editorPanel.addSubview(pinnedGainSlider)', 1)
s = s.replace('pinnedNoteLabel.frame=NSRect(x:868,y:editorH-31,width:editorW-882,height:18)', 'pinnedNoteLabel.frame=NSRect(x:742,y:editorH-31,width:editorW-756,height:18)', 1)

# Footer/version text.
s = s.replace('CLEAN PRO BETA', 'PRO TOOLS BETA', 1)

p.write_text(s)
