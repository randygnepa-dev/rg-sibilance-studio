from pathlib import Path
import re

p=Path('Sources/RGSibilanceStudio.swift')
s=p.read_text()
s=s.replace('let RGVersion = "0.4.2"','let RGVersion = "0.4.3"',1)

# Timeline loop API/state
s=s.replace('    var onCreateEventRegion: ((Double, Double) -> Void)?\n', '    var onCreateEventRegion: ((Double, Double) -> Void)?\n    var onLoopRangeChanged: ((Double?, Double?) -> Void)?\n    var loopRange: (Double, Double)? { didSet { needsDisplay = true } }\n',1)
s=s.replace('    private var selectionCurrent: Double?\n', '    private var selectionCurrent: Double?\n    private var loopDragging = false\n    private var loopAnchor: Double?\n',1)

# Ruler drag becomes loop selection; single click still locator if tiny drag.
old='''        if rulerRect.contains(p) {\n            rulerDragging = true\n            lastDragX = p.x\n            let t = timeForX(p.x)\n            playhead = t\n            highlightedTime = t\n            needsDisplay = true\n            return\n        }'''
new='''        if rulerRect.contains(p) {\n            loopDragging = true\n            loopAnchor = timeForX(p.x)\n            let t = loopAnchor!\n            loopRange = (t, t)\n            playhead = t\n            highlightedTime = t\n            needsDisplay = true\n            return\n        }'''
s=s.replace(old,new,1)

# mouseDragged loop branch first
s=s.replace('''        if selectingRegion {\n            let t = timeForX(min(max(p.x, plotRect.minX), plotRect.maxX))''','''        if loopDragging, let a = loopAnchor {\n            let x = min(max(p.x, rulerRect.minX), rulerRect.maxX)\n            let t = timeForX(x)\n            loopRange = (min(a,t), max(a,t))\n            playhead = t\n            highlightedTime = t\n            needsDisplay = true\n        } else if selectingRegion {\n            let t = timeForX(min(max(p.x, plotRect.minX), plotRect.maxX))''',1)

# mouseUp finalize loop before selection handling
s=s.replace('''    override func mouseUp(with event: NSEvent) {\n        if selectingRegion, let a = selectionAnchor, let b = selectionCurrent {''','''    override func mouseUp(with event: NSEvent) {\n        if loopDragging, let a = loopAnchor, let r = loopRange {\n            let start = min(r.0, r.1)\n            let end = max(r.0, r.1)\n            if end - start < 0.025 {\n                loopRange = nil\n                playhead = a\n                highlightedTime = a\n                onLoopRangeChanged?(nil, nil)\n            } else {\n                loopRange = (start, end)\n                playhead = start\n                highlightedTime = start\n                onLoopRangeChanged?(start, end)\n            }\n        }\n        loopDragging = false\n        loopAnchor = nil\n        if selectingRegion, let a = selectionAnchor, let b = selectionCurrent {''',1)

# draw loop range before selection/events
s=s.replace('''        drawSelectionRegion()\n        drawEvents(m)''','''        drawLoopRange()\n        drawSelectionRegion()\n        drawEvents(m)''',1)

insert='''\n    private func drawLoopRange() {\n        guard let r = loopRange else { return }\n        let start=max(viewStart,min(r.0,r.1)), end=min(viewEnd,max(r.0,r.1))\n        guard end > start else { return }\n        let x1=xForTime(start), x2=xForTime(end)\n        let region=NSRect(x:x1,y:plotRect.minY,width:max(2,x2-x1),height:plotRect.height)\n        NSColor(hex:0x1688E8).withAlphaComponent(0.075).setFill(); region.fill()\n        let bar=NSRect(x:x1,y:rulerRect.maxY-7,width:max(2,x2-x1),height:6)\n        NSColor(hex:0x2EA8FF).withAlphaComponent(0.92).setFill(); NSBezierPath(roundedRect:bar,xRadius:2,yRadius:2).fill()\n        for x in [x1,x2] {\n            let line=NSBezierPath(); line.move(to:NSPoint(x:x,y:plotRect.minY)); line.line(to:NSPoint(x:x,y:rulerRect.maxY));\n            NSColor(hex:0x2EA8FF).withAlphaComponent(0.75).setStroke(); line.lineWidth=1; line.stroke()\n        }\n        let dur=max(0,end-start)\n        let txt=String(format:"LOOP  %.3f s",dur)\n        let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:8,weight:.semibold),.foregroundColor:NSColor(hex:0xA9DCFF)]\n        txt.draw(at:NSPoint(x:x1+6,y:rulerRect.maxY-24),withAttributes:attrs)\n    }\n'''
s=s.replace('\n    private func drawSelectionRegion() {',insert+'\n    private func drawSelectionRegion() {',1)

# Instructions
s=s.replace('"Scroll: zoom   •   ⇧ drag: new event   •   center handle: gain   •   edge diamonds: fades   •   Space: play/stop"','"Ruler drag: LOOP   •   Scroll: zoom   •   ⇧ drag: new event   •   gain/fades edit on waveform   •   Space: play/stop"',1)

# App state
s=s.replace('    private var levelMatchedAudition = true\n','    private var levelMatchedAudition = true\n    private var transportLoopRange: (Double, Double)?\n',1)

# Wire callback
s=s.replace('''        timeline.onCreateEventRegion={ [weak self] a,b in self?.createEventFromSelection(start:a,end:b) }\n        editorPanel.addSubview(timeline)''','''        timeline.onCreateEventRegion={ [weak self] a,b in self?.createEventFromSelection(start:a,end:b) }\n        timeline.onLoopRangeChanged={ [weak self] a,b in self?.setTransportLoop(start:a,end:b) }\n        editorPanel.addSubview(timeline)''',1)

# Add loop button near transport footer after Fit button
needle='''        let fit=button("Fit",action:#selector(fitTimeline)); fit.frame=NSRect(x:82,y:16,width:42,height:26); editorPanel.addSubview(fit)'''
repl=needle+'''\n        loopButton=button("Loop",action:#selector(toggleTimelineLoop)); loopButton.frame=NSRect(x:130,y:16,width:58,height:26); editorPanel.addSubview(loopButton)'''
s=s.replace(needle,repl,1)
# move detected footer right a bit
s=s.replace('detectedFooter.frame=NSRect(x:136,y:20,width:160,height:18)','detectedFooter.frame=NSRect(x:198,y:20,width:160,height:18)',1)

# methods before zoom funcs
marker='''    @objc private func zoomInTimeline() { timeline.zoomIn() }'''
methods='''    private func setTransportLoop(start: Double?, end: Double?) {\n        if let a=start, let b=end, b-a >= 0.025 {\n            transportLoopRange=(a,b)\n            loopEnabled=true\n            loopButton?.title="Loop ON"\n            status.stringValue=String(format:"LOOP %.3f–%.3f s",a,b)\n        } else {\n            transportLoopRange=nil\n            loopEnabled=false\n            loopButton?.title="Loop"\n            status.stringValue="LOOP CLEARED"\n        }\n    }\n\n    @objc private func toggleTimelineLoop() {\n        guard let r=transportLoopRange else { status.stringValue="DRAG ON THE TIME RULER TO SET LOOP"; return }\n        loopEnabled.toggle()\n        loopButton.title=loopEnabled ? "Loop ON" : "Loop OFF"\n        timeline.loopRange = loopEnabled ? r : nil\n        if loopEnabled { timeline.playhead=r.0 }\n    }\n\n'''
s=s.replace(marker,methods+marker,1)

# transport start at loop start and timer wraps loop
s=s.replace('''            transportStartTime = min(max(0, timeline.playhead), max(0, p.duration - 0.01))\n            p.currentTime = transportStartTime''','''            if loopEnabled, let r=transportLoopRange {\n                transportStartTime = min(max(0,r.0),max(0,p.duration-0.01))\n            } else {\n                transportStartTime = min(max(0, timeline.playhead), max(0, p.duration - 0.01))\n            }\n            p.currentTime = transportStartTime''',1)

oldtimer='''                self.timeline.followPlayback(to: player.currentTime)\n                self.currentTimeLabel?.stringValue = self.formatTime(player.currentTime)\n                if !player.isPlaying && self.transportPlaying {'''
newtimer='''                if self.loopEnabled, let r=self.transportLoopRange, player.currentTime >= r.1 - 0.004 {\n                    player.currentTime = r.0\n                    if !player.isPlaying { player.play() }\n                }\n                self.timeline.followPlayback(to: player.currentTime)\n                self.currentTimeLabel?.stringValue = self.formatTime(player.currentTime)\n                if !player.isPlaying && self.transportPlaying && !(self.loopEnabled && self.transportLoopRange != nil) {'''
s=s.replace(oldtimer,newtimer,1)

# Existing toggleLoop used by event preview should use same button title but not clear range
s=s.replace('''    @objc private func toggleLoop() {\n        loopEnabled.toggle()\n        loopButton.title = loopEnabled ? "Loop ON" : "Loop OFF"\n    }''','''    @objc private func toggleLoop() { toggleTimelineLoop() }''',1)

p.write_text(s)
