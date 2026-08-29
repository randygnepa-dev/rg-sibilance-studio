from pathlib import Path
import re
p=Path('Sources/RGSibilanceStudio.swift')
s=p.read_text()
s=s.replace('let RGVersion = "0.4.0"','let RGVersion = "0.4.1"',1)

# Interactive EQ-like spectral/whistle editor.
start=s.index('final class RGSpectralShapeView: NSView {')
end=s.index('\nfinal class AppDelegate:', start)
cls=r'''final class RGSpectralShapeView: NSView {
    var tilt: Double = 0 { didSet { needsDisplay = true } }
    var flatten: Double = 0 { didSet { needsDisplay = true } }
    var whistleHz: Double? { didSet { needsDisplay = true } }
    var whistleAmount: Double = 0 { didSet { needsDisplay = true } }
    var whistleQ: Double = 7.0 { didSet { needsDisplay = true } }
    var onWhistleChange: ((Double, Double, Double) -> Void)?
    private var draggingWhistle = false

    private func xForHz(_ hz: Double) -> CGFloat {
        let f = log10(max(2000, min(20000, hz))/2000.0)
        return bounds.minX + CGFloat(f) * bounds.width
    }
    private func hzForX(_ x: CGFloat) -> Double {
        let f = Double(min(1,max(0,(x-bounds.minX)/max(1,bounds.width))))
        return 2000.0 * pow(10.0, f)
    }
    private func whistleY() -> CGFloat {
        bounds.midY - CGFloat(min(1,max(0,whistleAmount))) * bounds.height * 0.31
    }
    override func mouseDown(with event: NSEvent) {
        let pt=convert(event.locationInWindow,from:nil)
        let nx=xForHz(whistleHz ?? 8500)
        if hypot(pt.x-nx,pt.y-whistleY()) < 22 || bounds.contains(pt) {
            draggingWhistle=true; updateWhistle(pt,event:event)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        if draggingWhistle { updateWhistle(convert(event.locationInWindow,from:nil),event:event) }
    }
    override func mouseUp(with event: NSEvent) { draggingWhistle=false }
    private func updateWhistle(_ pt:NSPoint,event:NSEvent) {
        let hz=hzForX(pt.x)
        let amount=Double(min(1,max(0,(bounds.midY-pt.y)/(bounds.height*0.31))))
        var q=whistleQ
        if event.modifierFlags.contains(.shift) {
            q=min(18,max(1.5, 1.5 + Double((pt.x-bounds.minX)/max(1,bounds.width))*16.5))
        }
        whistleHz=hz; whistleAmount=amount; whistleQ=q
        onWhistleChange?(hz,q,amount)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex:0x08121A).setFill(); NSBezierPath(roundedRect:bounds,xRadius:5,yRadius:5).fill()
        let grid=NSBezierPath()
        for i in 1..<4 { let y=bounds.minY+bounds.height*CGFloat(i)/4; grid.move(to:NSPoint(x:bounds.minX,y:y)); grid.line(to:NSPoint(x:bounds.maxX,y:y)) }
        for i in 1..<5 { let x=bounds.minX+bounds.width*CGFloat(i)/5; grid.move(to:NSPoint(x:x,y:bounds.minY)); grid.line(to:NSPoint(x:x,y:bounds.maxY)) }
        NSColor.white.withAlphaComponent(0.06).setStroke(); grid.lineWidth=0.5; grid.stroke()
        let zero=NSBezierPath(); zero.move(to:NSPoint(x:bounds.minX,y:bounds.midY)); zero.line(to:NSPoint(x:bounds.maxX,y:bounds.midY)); NSColor.white.withAlphaComponent(0.12).setStroke(); zero.stroke()
        let path=NSBezierPath(); path.lineWidth=1.8
        for i in 0...180 {
            let f=Double(i)/180.0; let hz=2000.0*pow(10.0,f); let x=bounds.minX+CGFloat(f)*bounds.width
            var db=tilt*(f-0.35)*7.0; db *= (1.0-flatten*0.35)
            if let wh=whistleHz, whistleAmount>0 { let oct=log2(max(100,hz)/max(100,wh)); let width=max(5.0,whistleQ); db -= whistleAmount*10.0*exp(-oct*oct*width*5.2) }
            let y=bounds.midY+CGFloat(db/12.0)*bounds.height*0.72
            if i==0 { path.move(to:NSPoint(x:x,y:y)) } else { path.line(to:NSPoint(x:x,y:y)) }
        }
        NSColor(hex:0x55AFFF).setStroke(); path.stroke()
        if let hz=whistleHz {
            let x=xForHz(hz), y=whistleY(); let node=NSBezierPath(ovalIn:NSRect(x:x-7,y:y-7,width:14,height:14)); NSColor(hex:0xB86CFF).setFill(); node.fill(); NSColor.white.setStroke(); node.lineWidth=1; node.stroke()
            let a:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:8,weight:.semibold),.foregroundColor:NSColor(hex:0xD7C7FF)]
            String(format:"%.1fk  Q%.1f",hz/1000.0,whistleQ).draw(at:NSPoint(x:min(bounds.maxX-76,max(bounds.minX+4,x-34)),y:max(4,y-22)),withAttributes:a)
        }
        let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:7,weight:.regular),.foregroundColor:NSColor(hex:0x61798B)]
        ["2k","4k","8k","12k","20k"].enumerated().forEach { i,t in t.draw(at:NSPoint(x:bounds.minX+CGFloat(i)*bounds.width/4-5,y:3),withAttributes:attrs) }
    }
}'''
s=s[:start]+cls+s[end:]

# Fixed Pro Tools-like shell refinements, waveform only.
s=s.replace('let w: CGFloat = 1460\n        let h: CGFloat = 880','let w: CGFloat = 1540\n        let h: CGFloat = 920',1)
s=s.replace('CLEAN PRO 0.4.0: fixed geometry first','CLEAN PRO 0.4.1 PRO TOOLS: fixed geometry first',1)
s=s.replace('NSSegmentedControl(labels:["WAVEFORM","SPECTROGRAM"]','NSSegmentedControl(labels:["WAVEFORM"]',1)
s=s.replace('viewTabsControl.frame=NSRect(x:14,y:editorH-34,width:190,height:24)','viewTabsControl.frame=NSRect(x:14,y:editorH-34,width:104,height:24)',1)
s=s.replace('currentTimeLabel.frame=NSRect(x:216,y:editorH-33,width:100,height:22)','currentTimeLabel.frame=NSRect(x:132,y:editorH-33,width:100,height:22)',1)
s=s.replace('pinnedEventLabel.frame=NSRect(x:330,y:editorH-32,width:250,height:20)','pinnedEventLabel.frame=NSRect(x:246,y:editorH-32,width:250,height:20)',1)
s=s.replace('let pPlay=button("▶",action:#selector(playSelected)); pPlay.frame=NSRect(x:590','let pPlay=button("▶",action:#selector(playSelected)); pPlay.frame=NSRect(x:510',1)
s=s.replace('pGood.frame=NSRect(x:630','pGood.frame=NSRect(x:550',1).replace('pBad.frame=NSRect(x:692','pBad.frame=NSRect(x:612',1).replace('pNote.frame=NSRect(x:748','pNote.frame=NSRect(x:668',1).replace('pinnedGainSlider.frame=NSRect(x:818','pinnedGainSlider.frame=NSRect(x:738',1).replace('pinnedNoteLabel.frame=NSRect(x:948','pinnedNoteLabel.frame=NSRect(x:868',1).replace('width:editorW-962','width:editorW-882',1)
# Slightly larger editor, fixed bottom module lane.
s=s.replace('editorY:CGFloat=292, editorW=w-margin*2-inspectorW-gap, editorH:CGFloat=498','editorY:CGFloat=310, editorW=w-margin*2-inspectorW-gap, editorH:CGFloat=522',1)
s=s.replace('let bottomY:CGFloat=70, bottomH:CGFloat=208','let bottomY:CGFloat=70, bottomH:CGFloat=226',1)
# Keep five modules inside 1540 exactly.
s=s.replace('let detectW:CGFloat=202, repairW:CGFloat=540, refW:CGFloat=224, processW:CGFloat=210, previewW:CGFloat=226','let detectW:CGFloat=190, repairW:CGFloat=548, refW:CGFloat=220, processW:CGFloat=200, previewW:CGFloat=226',1)
# Spectral graph larger / more central.
s=s.replace('spectralShapeView.frame=NSRect(x:365,y:42,width:160,height:132)','spectralShapeView.frame=NSRect(x:318,y:40,width:214,height:154)',1)

# Force waveform mode even if old session/UI calls mode change.
s=s.replace('timeline.displayMode = sender.selectedSegment\n        status.stringValue = sender.selectedSegment == 1 ? "SPECTROGRAM VIEW" : "WAVEFORM VIEW"','timeline.displayMode = 0\n        sender.selectedSegment = 0\n        status.stringValue = "WAVEFORM VIEW"',1)

# Connect interactive de-whistle node.
needle='spectralShapeView?.whistleAmount = e.resonanceAmount ?? 0\n'
s=s.replace(needle, needle+'        spectralShapeView?.whistleQ = e.resonanceQ ?? 7.0\n',1)
# Find creation of graph and append callback.
pat='repair.addSubview(spectralShapeView)'
s=s.replace(pat,pat+'\n        spectralShapeView.onWhistleChange = { [weak self] hz, q, amount in self?.spectralWhistleEdited(hz: hz, q: q, amount: amount) }',1)
handler=r'''
    private func spectralWhistleEdited(hz: Double, q: Double, amount: Double) {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { return }
        events[i].resonanceHz = hz
        events[i].resonanceQ = q
        events[i].resonanceAmount = amount
        events[i].repairMethod = amount > 0.01 ? "WHISTLE EQ" : events[i].repairMethod
        resonanceSlider?.doubleValue = amount
        resonanceValueLabel?.stringValue = "\(Int(amount * 100))%"
        resonanceFreqLabel?.stringValue = String(format: "%.1f kHz  Q %.1f", hz/1000.0, q)
        timeline.events = events
        previewPlayer?.stop(); transportPlayer?.stop()
        saveCurrentSession()
        status.stringValue = String(format: "DE-WHISTLE EQ %.1f kHz • Q %.1f • %d%%", hz/1000.0, q, Int(amount*100))
    }

'''
s=s.replace('    @objc private func resonanceChanged(_ sender: NSSlider) {',handler+'    @objc private func resonanceChanged(_ sender: NSSlider) {',1)

# Repair sidebar event list: compact Pro Tools-like rows, no giant overlap.
old=r'''        for (i,e) in events.enumerated() {
            let note = (e.note?.isEmpty == false) ? e.note! : "No annotation"
            let title = String(format: "%@   [%@]   %.1f dB\n%@", formatTime(e.peakTime), e.kind, e.gainDB, note)
            let b = NSButton(title: title, target: self, action: #selector(selectAnnotationEvent(_:)))
            b.tag = i
            b.bezelStyle = .rounded
            b.alignment = .left
            b.font = NSFont.systemFont(ofSize: 10, weight: i == timeline.selectedIndex ? .semibold : .regular)
            b.contentTintColor = i == timeline.selectedIndex ? NSColor(hex: 0x4AA8FF) : NSColor(hex: 0xD1D8DE)
            b.widthAnchor.constraint(equalToConstant: 236).isActive = true
            b.heightAnchor.constraint(equalToConstant: 42).isActive = true
            annotationStack.addArrangedSubview(b)
        }
        annotationStack.needsLayout = true'''
new=r'''        annotationStack.frame.size.height = CGFloat(max(1, events.count)) * 30.0
        for (i,e) in events.enumerated() {
            let state = e.userLabel.isEmpty ? "—" : e.userLabel.capitalized
            let title = String(format: "%02d   %-2@   %@    %5.1f dB   %@", i+1, e.kind, formatTime(e.peakTime), e.gainDB, state)
            let b = RGButton(title: title, target: self, action: #selector(selectAnnotationEvent(_:)))
            b.role = i == timeline.selectedIndex ? .primary : .ghost
            b.tag = i
            b.alignment = .left
            b.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: i == timeline.selectedIndex ? .semibold : .regular)
            b.widthAnchor.constraint(equalToConstant: 240).isActive = true
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            annotationStack.addArrangedSubview(b)
        }
        annotationStack.needsLayout = true
        annotationStack.layoutSubtreeIfNeeded()'''
if old not in s: raise SystemExit('sidebar block not found')
s=s.replace(old,new,1)

# More Pro Tools-like waveform: dB grid and labels.
needle='''        let zero = NSBezierPath()\n        zero.move(to: NSPoint(x: plotRect.minX, y: waveCenter))'''
insert='''        let dbGrid = NSBezierPath()\n        for frac in [0.18,0.34,0.66,0.82] {\n            let gy = plotRect.minY + plotRect.height * CGFloat(frac)\n            dbGrid.move(to: NSPoint(x: plotRect.minX, y: gy)); dbGrid.line(to: NSPoint(x: plotRect.maxX, y: gy))\n        }\n        NSColor.white.withAlphaComponent(0.055).setStroke(); dbGrid.lineWidth = 0.5; dbGrid.stroke()\n        let dba:[NSAttributedString.Key:Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize:7,weight:.regular),.foregroundColor:NSColor(hex:0x61798B)]\n        "-6".draw(at:NSPoint(x:plotRect.minX+4,y:plotRect.maxY-18),withAttributes:dba)\n        "-12".draw(at:NSPoint(x:plotRect.minX+4,y:plotRect.midY+22),withAttributes:dba)\n        "-18".draw(at:NSPoint(x:plotRect.minX+4,y:plotRect.midY-34),withAttributes:dba)\n\n        let zero = NSBezierPath()\n        zero.move(to: NSPoint(x: plotRect.minX, y: waveCenter))'''
s=s.replace(needle,insert,1)

# Replace old vertical gain fader drawing with clip-gain horizontal envelope + fade curves.
oldfrag='''                let fader = gainFaderRect(for: i)\n                let centerX = fader.midX\n                let range: CGFloat = 48'''
newfrag='''                let fader = gainFaderRect(for: i)\n                let centerX = fader.midX\n                let range: CGFloat = 48'''
# Keep hit target logic; drawing will be enhanced by overlay below.
# Add a Pro Tools-style clip gain envelope before fade calculation.
anchor='''                let inX = xForTime(min(e.end, e.start + e.fadeIn))'''
envelope='''                let envY = plotRect.midY + CGFloat(min(0,max(-18,e.gainDB))/18.0) * 72.0\n                let env = NSBezierPath(); env.lineWidth = 1.6\n                env.move(to:NSPoint(x:startX,y:plotRect.midY)); env.line(to:NSPoint(x:min(endX,startX+14),y:envY)); env.line(to:NSPoint(x:max(startX,endX-14),y:envY)); env.line(to:NSPoint(x:endX,y:plotRect.midY))\n                NSColor.white.withAlphaComponent(0.86).setStroke(); env.stroke()\n                let clipHandle=NSBezierPath(roundedRect:NSRect(x:centerX-22,y:envY-8,width:44,height:16),xRadius:5,yRadius:5); NSColor(hex:0xE7EDF2).setFill(); clipHandle.fill()\n                let ca:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:8,weight:.bold),.foregroundColor:NSColor(hex:0x17212A)]\n                let ct=String(format:"%.1f",e.gainDB); let cs=ct.size(withAttributes:ca); ct.draw(at:NSPoint(x:centerX-cs.width/2,y:envY-5),withAttributes:ca)\n\n                let inX = xForTime(min(e.end, e.start + e.fadeIn))'''
s=s.replace(anchor,envelope,1)

p.write_text(s)
print('patched 0.4.1')
