from pathlib import Path
import re
p=Path('Sources/RGSibilanceStudio.swift')
s=p.read_text()
s=s.replace('let RGVersion = "0.2.24"','let RGVersion = "0.2.25"',1)
s=s.replace('var spectralBands = RGSpectralBands(hopSamples: 512, sampleRate: 48000, values: [])','var spectralBands = RGSpectralBands(hopSamples: 256, sampleRate: 48000, values: [])',1)
s=s.replace('RGSpectralAnalyzer.makeBands(samples: samples, sampleRate: sampleRate, hopSamples: 512)','RGSpectralAnalyzer.makeBands(samples: samples, sampleRate: sampleRate, hopSamples: 256)',1)

# Timeline type trims feed visual amplitude exactly like renderer.
s=s.replace('    var events: [SibilanceEvent] = [] { didSet { needsDisplay = true } }\n    var selectedIndex:', '    var events: [SibilanceEvent] = [] { didSet { needsDisplay = true } }\n    var typeTrims: [String: Double] = [:] { didSet { needsDisplay = true } }\n    var selectedIndex:',1)
s=s.replace('        let target = pow(10.0, e.gainDB / 20.0)', '        let target = pow(10.0, min(0.0, e.gainDB + (typeTrims[e.kind] ?? 0)) / 20.0)',1)

# Replace blocky vertical-stick waveform with filled high-resolution envelope and raw-sample trace at close zoom.
pattern=r'    private func drawWaveform\(_ m: AudioModel\) \{.*?\n    \}\n\n    private func drawSelectionRegion\(\) \{'
replacement=r'''    private func drawWaveform(_ m: AudioModel) {
        guard !m.samples.isEmpty else { return }
        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)
        NSGraphicsContext.current?.cgContext.setAllowsAntialiasing(true)

        let pixelColumns = max(240, Int(plotRect.width * 2.0))
        let startSample = max(0, min(m.samples.count - 1, Int(viewStart * m.sampleRate)))
        let endSample = max(startSample + 1, min(m.samples.count, Int(viewEnd * m.sampleRate) + 1))
        let visibleSamples = max(1, endSample - startSample)
        let samplesPerColumn = Double(visibleSamples) / Double(pixelColumns)
        let amp = plotRect.height * 0.47 * fixedVerticalScale

        // At sample-level zoom draw the true waveform as one continuous anti-aliased trace.
        if samplesPerColumn <= 2.2 {
            let trace = NSBezierPath()
            trace.lineJoinStyle = .round
            trace.lineCapStyle = .round
            let count = max(2, min(visibleSamples, Int(plotRect.width * 4.0)))
            for c in 0..<count {
                let f = Double(c) / Double(max(1, count - 1))
                let samplePosition = Double(startSample) + f * Double(max(1, visibleSamples - 1))
                let i0 = min(m.samples.count - 1, max(0, Int(floor(samplePosition))))
                let i1 = min(m.samples.count - 1, i0 + 1)
                let frac = Float(samplePosition - Double(i0))
                let v = m.samples[i0] * (1 - frac) + m.samples[i1] * frac
                let t = samplePosition / m.sampleRate
                let g = CGFloat(visualGain(at: t))
                let x = plotRect.minX + CGFloat(f) * plotRect.width
                let y = plotRect.midY + CGFloat(v) * g * amp
                if c == 0 { trace.move(to: NSPoint(x: x, y: y)) }
                else { trace.line(to: NSPoint(x: x, y: y)) }
            }
            NSColor(hex: 0x42B0FF).setStroke()
            trace.lineWidth = 1.35
            trace.stroke()
        } else {
            var tops: [NSPoint] = []
            var bottoms: [NSPoint] = []
            tops.reserveCapacity(pixelColumns)
            bottoms.reserveCapacity(pixelColumns)

            for c in 0..<pixelColumns {
                let s0 = min(endSample - 1, startSample + Int(Double(c) * samplesPerColumn))
                let s1 = min(endSample, max(s0 + 1, startSample + Int(Double(c + 1) * samplesPerColumn)))
                var mn = m.samples[s0]
                var mx = m.samples[s0]
                if s1 > s0 + 1 {
                    for i in (s0 + 1)..<s1 {
                        let v = m.samples[i]
                        if v < mn { mn = v }
                        if v > mx { mx = v }
                    }
                }
                // Blend neighboring extrema slightly so the display is continuous rather than rectangular.
                if c > 0 {
                    let prevTop = Float((tops.last!.y - plotRect.midY) / max(0.0001, amp))
                    let prevBottom = Float((bottoms.last!.y - plotRect.midY) / max(0.0001, amp))
                    mx = mx * 0.78 + prevTop * 0.22
                    mn = mn * 0.78 + prevBottom * 0.22
                }
                let f = Double(c) / Double(max(1, pixelColumns - 1))
                let t = viewStart + f * visibleDuration
                let g = CGFloat(visualGain(at: t))
                let x = plotRect.minX + CGFloat(f) * plotRect.width
                tops.append(NSPoint(x: x, y: plotRect.midY + CGFloat(mx) * g * amp))
                bottoms.append(NSPoint(x: x, y: plotRect.midY + CGFloat(mn) * g * amp))
            }

            let fill = NSBezierPath()
            if let first = tops.first { fill.move(to: first) }
            for pt in tops.dropFirst() { fill.line(to: pt) }
            for pt in bottoms.reversed() { fill.line(to: pt) }
            fill.close()
            NSColor(hex: 0x269AF4, alpha: 0.42).setFill()
            fill.fill()

            let topPath = NSBezierPath()
            let bottomPath = NSBezierPath()
            topPath.lineJoinStyle = .round; bottomPath.lineJoinStyle = .round
            if let first = tops.first { topPath.move(to: first) }
            for pt in tops.dropFirst() { topPath.line(to: pt) }
            if let first = bottoms.first { bottomPath.move(to: first) }
            for pt in bottoms.dropFirst() { bottomPath.line(to: pt) }
            NSColor(hex: 0x45B2FF).setStroke()
            topPath.lineWidth = 0.9; bottomPath.lineWidth = 0.9
            topPath.stroke(); bottomPath.stroke()
        }

        let zero = NSBezierPath()
        zero.move(to: NSPoint(x: plotRect.minX, y: plotRect.midY))
        zero.line(to: NSPoint(x: plotRect.maxX, y: plotRect.midY))
        NSColor.white.withAlphaComponent(0.10).setStroke()
        zero.lineWidth = 0.5
        zero.stroke()
    }

    private func drawSelectionRegion() {'''
s,n=re.subn(pattern,replacement,s,flags=re.S)
assert n==1, f'drawWaveform replacement count {n}'

# Real processed transport player.
s=s.replace('    private var scrubPlayer: AVAudioPlayer?\n', '    private var scrubPlayer: AVAudioPlayer?\n    private var transportPlayer: AVAudioPlayer?\n',1)

# Keep timeline type trim state synchronized.
s=s.replace('                        self.typeTrims = session.typeTrims\n                        self.timeline.events = session.events', '                        self.typeTrims = session.typeTrims\n                        self.timeline.typeTrims = session.typeTrims\n                        self.timeline.events = session.events',1)
s=s.replace('                    self.events = []\n                    self.scrubPlayer = scrub', '                    self.events = []\n                    self.typeTrims = [:]\n                    self.scrubPlayer = scrub',1)
s=s.replace('                    self.timeline.model = m\n                    self.timeline.events = []', '                    self.timeline.model = m\n                    self.timeline.typeTrims = [:]\n                    self.timeline.events = []',1)
s=s.replace('        typeTrims[kind] = value\n        typeTrimValue.stringValue', '        typeTrims[kind] = value\n        timeline.typeTrims = typeTrims\n        previewPlayer?.stop()\n        transportPlayer?.stop()\n        typeTrimValue.stringValue',1)

# Stop stale audition whenever an edit changes sound.
s=s.replace('        events[i].gainDB = min(0, max(-18, gain))\n        selectEvent(i)', '        events[i].gainDB = min(0, max(-18, gain))\n        previewPlayer?.stop()\n        transportPlayer?.stop()\n        timeline.events = events\n        selectEvent(i)',1)
s=s.replace('        events[i].fadeIn = fadeIn\n        events[i].fadeOut = fadeOut', '        events[i].fadeIn = fadeIn\n        events[i].fadeOut = fadeOut\n        previewPlayer?.stop()\n        transportPlayer?.stop()',1)
s=s.replace('        events[i].gainDB = -12.0 * amount\n        timeline.events = events', '        events[i].gainDB = -12.0 * amount\n        previewPlayer?.stop()\n        transportPlayer?.stop()\n        timeline.events = events',1)

# Replace transport with actual repaired full-file render when REPAIR is selected.
pat=r'    private func startTransport\(\) \{.*?\n    \}\n\n    private func stopTransport\(\) \{.*?\n    \}\n\n    private func scrub\(to time: Double, active: Bool\) \{'
rep=r'''    private func activeTransportPlayer() -> AVAudioPlayer? {
        return transportPlayer ?? scrubPlayer
    }

    private func startTransport() {
        guard let url = model.url, model.duration > 0 else { return }
        previewPlayer?.stop()
        stopTimer?.invalidate()
        let repaired = auditionMode?.selectedSegment != 0
        transportPlayer?.stop()
        transportPlayer = nil
        do {
            let p: AVAudioPlayer
            if repaired {
                status.stringValue = "RENDERING REPAIR PREVIEW…"
                let rendered = try RGRenderEngine.renderFullPreview(sourceURL: url, events: events, typeTrims: typeTrims, repaired: true)
                p = try AVAudioPlayer(contentsOf: rendered)
                transportPlayer = p
            } else if let original = scrubPlayer {
                p = original
            } else {
                p = try AVAudioPlayer(contentsOf: url)
                scrubPlayer = p
            }
            transportStartTime = min(max(0, timeline.playhead), max(0, p.duration - 0.01))
            p.currentTime = transportStartTime
            p.play()
            transportPlaying = true
            playButton.title = "■ Stop"
            status.stringValue = repaired ? "PLAYING REPAIR — rendered event gain + TYPE TRIM + crossfades" : "PLAYING ORIGINAL"
            transportTimer?.invalidate()
            transportTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self = self, let player = self.activeTransportPlayer() else { return }
                self.timeline.followPlayback(to: player.currentTime)
                self.currentTimeLabel?.stringValue = self.formatTime(player.currentTime)
                if !player.isPlaying && self.transportPlaying {
                    self.transportPlaying = false
                    self.transportTimer?.invalidate()
                    self.playButton.title = "▶  Play"
                    self.status.stringValue = "PLAYBACK END"
                }
            }
        } catch {
            status.stringValue = "REPAIR PREVIEW FAILED — \(error.localizedDescription)"
        }
    }

    private func stopTransport() {
        guard let p = activeTransportPlayer() else { return }
        let stoppedAt = p.currentTime
        p.pause()
        transportPlaying = false
        transportTimer?.invalidate()
        transportTimer = nil
        if stopMode.selectedSegment == 1 {
            p.currentTime = transportStartTime
            timeline.followPlayback(to: transportStartTime)
            currentTimeLabel?.stringValue = formatTime(transportStartTime)
            status.stringValue = "STOP — returned to start"
        } else {
            timeline.followPlayback(to: stoppedAt)
            currentTimeLabel?.stringValue = formatTime(stoppedAt)
            status.stringValue = "STOP — locator stays at stop position"
        }
        playButton.title = "▶  Play"
    }

    private func scrub(to time: Double, active: Bool) {'''
s,n=re.subn(pat,rep,s,flags=re.S)
assert n==1, f'transport replacement count {n}'

# Region click now uses the exact same sample renderer as export, not AVAudioPlayer volume.
pat=r'    private func playRegionOnly\(_ i: Int\) \{.*?\n    \}\n\n    @objc private func auditionModeChanged\(\) \{'
rep=r'''    private func playRegionOnly(_ i: Int) {
        guard events.indices.contains(i), let url = model.url else { return }
        if transportPlaying { stopTransport() }
        previewPlayer?.stop()
        stopTimer?.invalidate()
        fadeTimer?.invalidate()
        let e = events[i]
        let repaired = auditionMode?.selectedSegment != 0
        do {
            let rendered = try RGRenderEngine.renderAudition(sourceURL: url, events: events, typeTrims: typeTrims, startTime: e.start, endTime: e.end, repaired: repaired)
            let p = try AVAudioPlayer(contentsOf: rendered)
            p.delegate = self
            previewPlayer = p
            p.currentTime = 0
            p.play()
            timeline.playhead = e.start
            currentTimeLabel?.stringValue = formatTime(e.start)
            playButton.title = "■ Stop"
            let effectiveDB = repaired ? min(0, e.gainDB + (typeTrims[e.kind] ?? 0)) : 0
            status.stringValue = String(format: "REGION %@ [%@] %.3f–%.3f s  %.1f dB  IN %.0f / OUT %.0f ms", repaired ? "REPAIR" : "ORIGINAL", e.kind, e.start, e.end, effectiveDB, e.fadeIn * 1000, e.fadeOut * 1000)
            stopTimer = Timer.scheduledTimer(withTimeInterval: max(0.02, e.end - e.start), repeats: false) { [weak self] _ in
                self?.previewPlayer?.stop()
                self?.playButton.title = "▶  Play"
            }
        } catch {
            status.stringValue = "REGION PLAYBACK FAILED — \(error.localizedDescription)"
        }
    }

    @objc private func auditionModeChanged() {'''
s,n=re.subn(pat,rep,s,flags=re.S)
assert n==1, f'region replacement count {n}'

# Context Play now also renders selected edits.
pat=r'    @objc private func playSelected\(\) \{.*?\n    \}\n\n    @objc private func toggleLoop\(\) \{'
rep=r'''    @objc private func playSelected() {
        guard let url = model.url else { return }
        if transportPlaying { stopTransport() }
        stopTimer?.invalidate()
        fadeTimer?.invalidate()
        previewPlayer?.stop()
        do {
            if let i = timeline.selectedIndex, events.indices.contains(i) {
                let e = events[i]
                let pre = max(0, e.start - 0.30)
                let post = min(model.duration, e.end + 0.40)
                let repaired = auditionMode?.selectedSegment != 0
                let rendered = try RGRenderEngine.renderAudition(sourceURL: url, events: events, typeTrims: typeTrims, startTime: pre, endTime: post, repaired: repaired)
                let p = try AVAudioPlayer(contentsOf: rendered)
                p.delegate = self
                previewPlayer = p
                p.currentTime = 0
                p.play()
                playButton.title = "■ Stop"
                status.stringValue = repaired ? "CONTEXT — REPAIR" : "CONTEXT — ORIGINAL"
                stopTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, post - pre), repeats: false) { [weak self] _ in self?.finishPreview() }
            } else {
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                previewPlayer = p
                p.currentTime = timeline.playhead
                p.play()
            }
        } catch {
            status.stringValue = "PLAYBACK FAILED — \(error.localizedDescription)"
        }
    }

    @objc private func toggleLoop() {'''
s,n=re.subn(pat,rep,s,flags=re.S)
assert n==1, f'playSelected replacement count {n}'

# A/B must stop old buffer before rendering the other path.
s=s.replace('    @objc private func auditionModeChanged() {\n        saveCurrentSession()', '    @objc private func auditionModeChanged() {\n        previewPlayer?.stop()\n        transportPlayer?.stop()\n        transportPlaying = false\n        transportTimer?.invalidate()\n        saveCurrentSession()',1)

p.write_text(s)
