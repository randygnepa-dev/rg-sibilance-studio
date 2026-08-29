from pathlib import Path

p = Path('Sources/RGSibilanceStudio.swift')
s = p.read_text()

s = s.replace('let RGVersion = "0.2.18"', 'let RGVersion = "0.2.19"', 1)

old = '''    var onAddSibilance: ((Double) -> Void)?
    var onDeleteEvent: ((Int) -> Void)?'''
new = '''    var onAddSibilance: ((Double) -> Void)?
    var onDeleteEvent: ((Int) -> Void)?
    var onEventBoundsChanged: ((Int, Double, Double) -> Void)?'''
if old not in s:
    raise SystemExit('callback marker missing')
s = s.replace(old, new, 1)

old = '''    private var rulerDragging = false
    private var highlightedTime: Double?'''
new = '''    private var rulerDragging = false
    private var highlightedTime: Double?
    private var boundaryDrag: Int = 0'''
if old not in s:
    raise SystemExit('boundary state marker missing')
s = s.replace(old, new, 1)

old = '''        guard plotRect.contains(p) else { return }
        lastDragX = p.x
        panning = event.modifierFlags.contains(.option)
        scrubbing = !panning
        if scrubbing {
            let t = timeForX(p.x)
            playhead = t
            highlightedTime = t
            onScrub?(t, true)
            selectNearestEvent(at: t)
        }'''
new = '''        guard plotRect.contains(p) else { return }

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
        }'''
if old not in s:
    raise SystemExit('mouseDown edit marker missing')
s = s.replace(old, new, 1)

old = '''        if rulerDragging {
            let dx = p.x - lastDragX'''
new = '''        if boundaryDrag != 0, let i = selectedIndex, events.indices.contains(i), let m = model {
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
            let dx = p.x - lastDragX'''
if old not in s:
    raise SystemExit('mouseDragged edit marker missing')
s = s.replace(old, new, 1)

old = '''        scrubbing = false
        panning = false
        rulerDragging = false
        needsDisplay = true'''
new = '''        scrubbing = false
        panning = false
        rulerDragging = false
        boundaryDrag = 0
        needsDisplay = true'''
if old not in s:
    raise SystemExit('mouseUp boundary marker missing')
s = s.replace(old, new, 1)

start = s.index('    private func drawEvents(_ m: AudioModel) {')
end = s.index('\n    private func drawPlayhead()', start)
replacement = '''    private func drawEvents(_ m: AudioModel) {
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
        }
    }
'''
s = s[:start] + replacement + s[end:]

s = s.replace(
    '"Scroll: zoom   •   drag waveform: scrub   •   drag time ruler: move timeline   •   ⌥ drag: pan   •   Space: play/stop"',
    '"Scroll: zoom   •   drag waveform: scrub   •   drag region edges: edit START/END   •   drag time ruler: move timeline   •   Space: play/stop"',
    1
)

old = '''        timeline.onAddSibilance = { [weak self] t in self?.addManualS(at: t) }
        timeline.onDeleteEvent = { [weak self] i in self?.deleteEvent(i) }'''
new = '''        timeline.onAddSibilance = { [weak self] t in self?.addManualS(at: t) }
        timeline.onDeleteEvent = { [weak self] i in self?.deleteEvent(i) }
        timeline.onEventBoundsChanged = { [weak self] i, start, end in self?.eventBoundsChanged(i, start: start, end: end) }'''
if old not in s:
    raise SystemExit('wiring marker missing')
s = s.replace(old, new, 1)

s = s.replace(
    'kindPopup.addItems(withTitles: ["S", "Š", "Z", "C", "T", "D", "K", "P", "B", "F", "CH", "OTHER"])',
    'kindPopup.addItems(withTitles: ["S", "Š", "Z", "C", "Č", "T", "Ť", "D", "K", "P", "B", "F", "CH", "OTHER"])',
    1
)

old = '''        eventInfo.stringValue = String(format: "#%03d   %@   %.3f–%.3f s   score %.2f   %@   type trim %.1f dB", i + 1, e.kind, e.start, e.end, e.score, e.userLabel.isEmpty ? "UNRATED" : e.userLabel, trim)'''
new = '''        eventInfo.stringValue = String(format: "#%03d   [%@]   START %.3f s   END %.3f s   LEN %.0f ms   score %.2f   %@   trim %.1f dB", i + 1, e.kind, e.start, e.end, (e.end - e.start) * 1000, e.score, e.userLabel.isEmpty ? "UNRATED" : e.userLabel, trim)'''
if old not in s:
    raise SystemExit('event info marker missing')
s = s.replace(old, new, 1)

marker = '''    @objc private func typeTrimChanged() {'''
insert = '''    private func eventBoundsChanged(_ i: Int, start: Double, end: Double) {
        guard events.indices.contains(i) else { return }
        events[i].start = start
        events[i].end = end
        events[i].peakTime = (start + end) * 0.5
        timeline.events = events
        selectEvent(i)
        status.stringValue = String(format: "EVENT #%d REGION → %.3f–%.3f s", i + 1, start, end)
    }

'''
if marker not in s:
    raise SystemExit('bounds callback insert marker missing')
s = s.replace(marker, insert + marker, 1)

p.write_text(s)
