from pathlib import Path
import re

p=Path('Sources/RGSibilanceStudio.swift')
s=p.read_text()
s=s.replace('let RGVersion = "0.3.2"','let RGVersion = "0.4.0"',1)

# Small visual spectral-shape graph used by Clean Pro repair module.
if 'final class RGSpectralShapeView' not in s:
    insert='''\nfinal class RGSpectralShapeView: NSView {\n    var tilt: Double = 0 { didSet { needsDisplay = true } }\n    var flatten: Double = 0 { didSet { needsDisplay = true } }\n    var whistleHz: Double? { didSet { needsDisplay = true } }\n    var whistleAmount: Double = 0 { didSet { needsDisplay = true } }\n    override func draw(_ dirtyRect: NSRect) {\n        NSColor(hex: 0x09131C).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()\n        let grid=NSBezierPath(); for i in 1..<4 { let y=bounds.minY+bounds.height*CGFloat(i)/4; grid.move(to:NSPoint(x:bounds.minX,y:y)); grid.line(to:NSPoint(x:bounds.maxX,y:y)) }\n        for i in 1..<5 { let x=bounds.minX+bounds.width*CGFloat(i)/5; grid.move(to:NSPoint(x:x,y:bounds.minY)); grid.line(to:NSPoint(x:x,y:bounds.maxY)) }\n        NSColor.white.withAlphaComponent(0.055).setStroke(); grid.lineWidth=0.5; grid.stroke()\n        let path=NSBezierPath(); path.lineWidth=1.6\n        for i in 0...100 {\n            let f=Double(i)/100.0; let hz=2000.0*pow(10.0,f); let x=bounds.minX+CGFloat(f)*bounds.width\n            var db=tilt*(f-0.35)*7.0\n            db *= (1.0-flatten*0.35)\n            if let wh=whistleHz, whistleAmount>0 { let oct=log2(max(100.0,hz)/max(100.0,wh)); db -= whistleAmount*8.0*exp(-oct*oct*42.0) }\n            let y=bounds.midY+CGFloat(db/12.0)*bounds.height*0.78\n            if i==0 { path.move(to:NSPoint(x:x,y:y)) } else { path.line(to:NSPoint(x:x,y:y)) }\n        }\n        NSColor(hex:0x62B6FF).setStroke(); path.stroke()\n        let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:7,weight:.regular),.foregroundColor:NSColor(hex:0x61798B)]\n        ["2k","4k","8k","12k","20k"].enumerated().forEach { i,t in t.draw(at:NSPoint(x:bounds.minX+CGFloat(i)*bounds.width/4-5,y:3),withAttributes:attrs) }\n    }\n}\n'''
    s=s.replace('\nfinal class AppDelegate:',insert+'\nfinal class AppDelegate:',1)

# Graph property.
s=s.replace('    private var referenceInfoLabel: NSTextField!\n','    private var referenceInfoLabel: NSTextField!\n    private var spectralShapeView: RGSpectralShapeView!\n',1)

new_build=r'''    private func buildUI() {
        // CLEAN PRO 0.4.0: fixed geometry first. No resize until the visual shell is stable.
        let w: CGFloat = 1460
        let h: CGFloat = 880
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: w, height: h)
        window = NSWindow(
            contentRect: NSRect(x: screen.midX - w/2, y: screen.midY - h/2, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RG Sibilance Studio \(RGVersion) BETA — Clean Pro"
        window.backgroundColor = NSColor(hex: 0x071019)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(hex: 0x071019).cgColor
        window.contentView = root

        // MARK: Header
        let header = NSView(frame: NSRect(x: 0, y: h-72, width: w, height: 72))
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(hex: 0x0A151F).cgColor
        header.layer?.borderColor = NSColor(hex: 0x213442).cgColor
        header.layer?.borderWidth = 0.6
        root.addSubview(header)

        let badge = NSTextField(labelWithString: "RG")
        badge.frame = NSRect(x: 20, y: h-54, width: 30, height: 30)
        badge.alignment = .center; badge.font = NSFont.systemFont(ofSize: 10, weight: .bold); badge.textColor = .white
        badge.wantsLayer = true; badge.layer?.cornerRadius = 15; badge.layer?.borderWidth = 1; badge.layer?.borderColor = NSColor(hex:0x728694).cgColor
        root.addSubview(badge)
        let title=label("RG Sibilance Studio",size:17,weight:.bold,color:.white); title.frame=NSRect(x:60,y:h-46,width:250,height:24); root.addSubview(title)
        let sub=label("Sibilance detection & repair",size:9,color:NSColor(hex:0x728696)); sub.frame=NSRect(x:60,y:h-61,width:220,height:16); root.addSubview(sub)
        fileInfo=label("Drop WAV/AIFF or Open File",size:9,color:NSColor(hex:0x708596)); fileInfo.frame=NSRect(x:360,y:h-49,width:430,height:18); root.addSubview(fileInfo)
        let open=button("Open File",action:#selector(openWav)); open.frame=NSRect(x:850,y:h-55,width:112,height:30); root.addSubview(open)
        analyzeButton=button("Analyze",action:#selector(analyzeAudio)); analyzeButton.frame=NSRect(x:972,y:h-55,width:112,height:30); root.addSubview(analyzeButton)
        inspectorToggleButton=button("Events",action:#selector(toggleInspector)); inspectorToggleButton.frame=NSRect(x:1325,y:h-55,width:94,height:30); root.addSubview(inspectorToggleButton)

        // MARK: Main editor + event inspector
        let margin: CGFloat = 18
        let inspectorW: CGFloat = 278
        let gap: CGFloat = 10
        let editorX=margin, editorY:CGFloat=292, editorW=w-margin*2-inspectorW-gap, editorH:CGFloat=498
        editorPanel=makePanel(NSRect(x:editorX,y:editorY,width:editorW,height:editorH)); editorPanel.fillColor=NSColor(hex:0x0A151E); root.addSubview(editorPanel)

        viewTabsControl=NSSegmentedControl(labels:["WAVEFORM","SPECTROGRAM"],trackingMode:.selectOne,target:self,action:#selector(viewModeChanged(_:)))
        viewTabsControl.selectedSegment=0; viewTabsControl.frame=NSRect(x:14,y:editorH-34,width:190,height:24); viewTabsControl.controlSize=.small; editorPanel.addSubview(viewTabsControl)
        currentTimeLabel=label("00:00.000",size:13,weight:.bold,color:NSColor(hex:0x4AABFF)); currentTimeLabel.font=NSFont.monospacedDigitSystemFont(ofSize:13,weight:.bold); currentTimeLabel.frame=NSRect(x:216,y:editorH-33,width:100,height:22); editorPanel.addSubview(currentTimeLabel)
        pinnedEventLabel=label("NO EVENT SELECTED",size:9,weight:.semibold,color:NSColor(hex:0x7F95A4)); pinnedEventLabel.frame=NSRect(x:330,y:editorH-32,width:250,height:20); editorPanel.addSubview(pinnedEventLabel)
        let pPlay=button("▶",action:#selector(playSelected)); pPlay.frame=NSRect(x:590,y:editorH-35,width:34,height:26); editorPanel.addSubview(pPlay)
        let pGood=button("GOOD",action:#selector(markGood)); pGood.frame=NSRect(x:630,y:editorH-35,width:56,height:26); editorPanel.addSubview(pGood)
        let pBad=button("BAD",action:#selector(markBad)); pBad.frame=NSRect(x:692,y:editorH-35,width:50,height:26); editorPanel.addSubview(pBad)
        let pNote=button("Note",action:#selector(addAnnotation)); pNote.frame=NSRect(x:748,y:editorH-35,width:58,height:26); editorPanel.addSubview(pNote)
        pinnedGainSlider=NSSlider(value:0,minValue:-18,maxValue:0,target:self,action:#selector(pinnedGainChanged(_:))); pinnedGainSlider.frame=NSRect(x:818,y:editorH-32,width:120,height:20); pinnedGainSlider.isEnabled=false; editorPanel.addSubview(pinnedGainSlider)
        pinnedNoteLabel=label("",size:8,color:NSColor(hex:0x647988)); pinnedNoteLabel.frame=NSRect(x:948,y:editorH-31,width:editorW-962,height:18); pinnedNoteLabel.lineBreakMode=.byTruncatingTail; editorPanel.addSubview(pinnedNoteLabel)

        timeline=TimelineView(frame:NSRect(x:10,y:54,width:editorW-20,height:editorH-98))
        timeline.onAudioDrop={ [weak self] u in self?.loadAudio(u) }
        timeline.onSelect={ [weak self] i in self?.selectEvent(i) }
        timeline.onScrub={ [weak self] t,a in self?.currentTimeLabel.stringValue=self?.formatTime(t) ?? "00:00.000"; self?.scrub(to:t,active:a) }
        timeline.onAddSibilance={ [weak self] t in self?.addManualS(at:t) }
        timeline.onDeleteEvent={ [weak self] i in self?.deleteEvent(i) }
        timeline.onEventBoundsChanged={ [weak self] i,a,b in self?.eventBoundsChanged(i,start:a,end:b) }
        timeline.onPlayEvent={ [weak self] i in self?.playRegionOnly(i) }
        timeline.onEventGainChanged={ [weak self] i,g in self?.eventGainChanged(i,gain:g) }
        timeline.onEventFadesChanged={ [weak self] i,a,b in self?.eventFadesChanged(i,fadeIn:a,fadeOut:b) }
        timeline.onCreateEventRegion={ [weak self] a,b in self?.createEventFromSelection(start:a,end:b) }
        editorPanel.addSubview(timeline)

        let zin=button("＋",action:#selector(zoomInTimeline)); zin.frame=NSRect(x:14,y:16,width:30,height:26); editorPanel.addSubview(zin)
        let zout=button("−",action:#selector(zoomOutTimeline)); zout.frame=NSRect(x:48,y:16,width:30,height:26); editorPanel.addSubview(zout)
        let fit=button("Fit",action:#selector(fitTimeline)); fit.frame=NSRect(x:82,y:16,width:42,height:26); editorPanel.addSubview(fit)
        let prevTop=button("◀",action:#selector(previousEvent)); prevTop.frame=NSRect(x:editorW/2-58,y:14,width:34,height:28); editorPanel.addSubview(prevTop)
        let playTop=button("▶",action:#selector(playSelected)); playTop.frame=NSRect(x:editorW/2-18,y:14,width:40,height:28); editorPanel.addSubview(playTop)
        let nextTop=button("▶|",action:#selector(nextEvent)); nextTop.frame=NSRect(x:editorW/2+28,y:14,width:38,height:28); editorPanel.addSubview(nextTop)
        detectedFooter=label("Detected: 0 events",size:9,weight:.semibold,color:NSColor(hex:0x4BAEFF)); detectedFooter.frame=NSRect(x:136,y:20,width:160,height:18); editorPanel.addSubview(detectedFooter)

        annotationsPanel=makePanel(NSRect(x:editorX+editorW+gap,y:editorY,width:inspectorW,height:editorH)); annotationsPanel.fillColor=NSColor(hex:0x0A151E); root.addSubview(annotationsPanel)
        let evTitle=label("EVENTS",size:10,weight:.bold,color:.white); evTitle.frame=NSRect(x:14,y:editorH-31,width:120,height:18); annotationsPanel.addSubview(evTitle)
        let annAdd=button("＋ Add",action:#selector(addAnnotation)); annAdd.frame=NSRect(x:inspectorW-76,y:editorH-36,width:62,height:26); annotationsPanel.addSubview(annAdd)
        annotationCountLabel=label("0 events",size:8,color:NSColor(hex:0x667D8D)); annotationCountLabel.frame=NSRect(x:14,y:12,width:100,height:18); annotationsPanel.addSubview(annotationCountLabel)
        let scroll=NSScrollView(frame:NSRect(x:10,y:36,width:inspectorW-20,height:editorH-78)); scroll.drawsBackground=false; scroll.hasVerticalScroller=true
        annotationStack=NSStackView(frame:NSRect(x:0,y:0,width:inspectorW-38,height:scroll.bounds.height)); annotationStack.orientation=.vertical; annotationStack.alignment=.leading; annotationStack.spacing=5; scroll.documentView=annotationStack; annotationsPanel.addSubview(scroll)

        // MARK: Bottom modules — exact fixed grid, no overlap possible.
        let bottomY:CGFloat=70, bottomH:CGFloat=208
        let detectW:CGFloat=202, repairW:CGFloat=540, refW:CGFloat=224, processW:CGFloat=210, previewW:CGFloat=226
        let x1=margin, x2=x1+detectW+gap, x3=x2+repairW+gap, x4=x3+refW+gap, x5=x4+processW+gap
        let detect=makePanel(NSRect(x:x1,y:bottomY,width:detectW,height:bottomH)); root.addSubview(detect)
        let repair=makePanel(NSRect(x:x2,y:bottomY,width:repairW,height:bottomH)); root.addSubview(repair)
        let ref=makePanel(NSRect(x:x3,y:bottomY,width:refW,height:bottomH)); root.addSubview(ref)
        let process=makePanel(NSRect(x:x4,y:bottomY,width:processW,height:bottomH)); root.addSubview(process)
        let preview=makePanel(NSRect(x:x5,y:bottomY,width:previewW,height:bottomH)); root.addSubview(preview)

        addTitle("DETECTION",to:detect,y:bottomH-28)
        let auto=label("AUTO",size:9,weight:.bold,color:NSColor(hex:0x4AAEFF)); auto.frame=NSRect(x:14,y:bottomH-57,width:50,height:18); detect.addSubview(auto)
        let sens=label("Sensitivity",size:9,color:NSColor(hex:0x8396A4)); sens.frame=NSRect(x:14,y:bottomH-88,width:74,height:18); detect.addSubview(sens)
        sensitivitySlider=NSSlider(value:0.72,minValue:0,maxValue:1,target:self,action:#selector(sensitivityChanged)); sensitivitySlider.frame=NSRect(x:86,y:bottomH-91,width:96,height:20); detect.addSubview(sensitivitySlider)
        let range=label("Range   4.5–12 kHz",size:9,color:NSColor(hex:0x718594)); range.frame=NSRect(x:14,y:bottomH-119,width:150,height:18); detect.addSubview(range)
        let adv=button("Advanced",action:#selector(showAdvancedInfo)); adv.frame=NSRect(x:14,y:44,width:94,height:28); detect.addSubview(adv)
        let mark=button("＋ Mark S",action:#selector(markManualS)); mark.frame=NSRect(x:14,y:10,width:94,height:28); detect.addSubview(mark)
        detectedLabel=label("Detected: 0",size:8,color:NSColor(hex:0x668090)); detectedLabel.frame=NSRect(x:116,y:15,width:78,height:18); detect.addSubview(detectedLabel)

        addTitle("SIBILANCE REPAIR",to:repair,y:bottomH-28)
        let rowLabelX:CGFloat=14, sliderX:CGFloat=110, sliderW:CGFloat=190
        let l1=label("Level",size:9,color:NSColor(hex:0xC2CDD5)); l1.frame=NSRect(x:rowLabelX,y:bottomH-61,width:80,height:18); repair.addSubview(l1)
        repairSlider=NSSlider(value:0.66,minValue:0,maxValue:1,target:self,action:#selector(repairStrengthChanged(_:))); repairSlider.frame=NSRect(x:sliderX,y:bottomH-64,width:sliderW,height:20); repair.addSubview(repairSlider)
        let l2=label("Spectral tone",size:9,color:NSColor(hex:0xC2CDD5)); l2.frame=NSRect(x:rowLabelX,y:bottomH-91,width:90,height:18); repair.addSubview(l2)
        spectralTiltSlider=NSSlider(value:0,minValue:-1,maxValue:1,target:self,action:#selector(spectralTiltChanged(_:))); spectralTiltSlider.frame=NSRect(x:sliderX,y:bottomH-94,width:sliderW,height:20); spectralTiltSlider.isEnabled=false; repair.addSubview(spectralTiltSlider)
        spectralTiltValue=label("NEUTRAL",size:8,weight:.semibold,color:NSColor(hex:0x79BFFF)); spectralTiltValue.frame=NSRect(x:304,y:bottomH-91,width:60,height:18); repair.addSubview(spectralTiltValue)
        let l3=label("Flatten",size:9,color:NSColor(hex:0xC2CDD5)); l3.frame=NSRect(x:rowLabelX,y:bottomH-121,width:80,height:18); repair.addSubview(l3)
        flattenSlider=NSSlider(value:0,minValue:0,maxValue:1,target:self,action:#selector(flattenChanged(_:))); flattenSlider.frame=NSRect(x:sliderX,y:bottomH-124,width:sliderW,height:20); flattenSlider.isEnabled=false; repair.addSubview(flattenSlider)
        flattenValue=label("0%",size:8,weight:.semibold,color:NSColor(hex:0xAFC2D0)); flattenValue.frame=NSRect(x:304,y:bottomH-121,width:40,height:18); repair.addSubview(flattenValue)
        let l4=label("Whistle",size:9,color:NSColor(hex:0xC2CDD5)); l4.frame=NSRect(x:rowLabelX,y:bottomH-151,width:80,height:18); repair.addSubview(l4)
        resonanceSlider=NSSlider(value:0,minValue:0,maxValue:1,target:self,action:#selector(resonanceChanged(_:))); resonanceSlider.frame=NSRect(x:sliderX,y:bottomH-154,width:150,height:20); resonanceSlider.isEnabled=false; repair.addSubview(resonanceSlider)
        resonanceValueLabel=label("0%",size:8,weight:.semibold,color:NSColor(hex:0xAFC2D0)); resonanceValueLabel.frame=NSRect(x:264,y:bottomH-151,width:34,height:18); repair.addSubview(resonanceValueLabel)
        let autoWh=button("AUTO",action:#selector(autoFindWhistle)); autoWh.frame=NSRect(x:302,y:bottomH-158,width:54,height:25); repair.addSubview(autoWh)
        resonanceFreqLabel=label("",size:8,color:NSColor(hex:0x6E8392)); resonanceFreqLabel.frame=NSRect(x:110,y:bottomH-173,width:180,height:15); repair.addSubview(resonanceFreqLabel)
        spectralShapeView=RGSpectralShapeView(frame:NSRect(x:370,y:44,width:154,height:126)); repair.addSubview(spectralShapeView)
        let graphTitle=label("SPECTRAL SHAPE",size:8,weight:.semibold,color:NSColor(hex:0x6F8798)); graphTitle.frame=NSRect(x:370,y:174,width:130,height:16); repair.addSubview(graphTitle)
        let type=label("Type",size:8,color:NSColor(hex:0x758A99)); type.frame=NSRect(x:14,y:14,width:32,height:16); repair.addSubview(type)
        kindPopup=NSPopUpButton(frame:NSRect(x:48,y:8,width:70,height:26),pullsDown:false); kindPopup.addItems(withTitles:["S","Š","Z","C","Č","T","Ť","D","K","P","B","F","CH","OTHER"]); kindPopup.target=self; kindPopup.action=#selector(kindChanged); kindPopup.isEnabled=false; repair.addSubview(kindPopup)
        let good=button("GOOD",action:#selector(markGood)); good.frame=NSRect(x:126,y:8,width:54,height:26); repair.addSubview(good)
        let bad=button("BAD",action:#selector(markBad)); bad.frame=NSRect(x:184,y:8,width:48,height:26); repair.addSubview(bad)
        let target=button("TARGET",action:#selector(markTarget)); target.frame=NSRect(x:236,y:8,width:62,height:26); repair.addSubview(target)
        let normal=button("NORMAL",action:#selector(markNormal)); normal.frame=NSRect(x:302,y:8,width:62,height:26); repair.addSubview(normal)

        addTitle("REFERENCE",to:ref,y:bottomH-28)
        referenceInfoLabel=label("No saved reference",size:8,color:NSColor(hex:0x718897)); referenceInfoLabel.frame=NSRect(x:14,y:bottomH-57,width:194,height:18); referenceInfoLabel.lineBreakMode=.byTruncatingTail; ref.addSubview(referenceInfoLabel)
        let saveRef=button("Save Good",action:#selector(setSelectedAsReference)); saveRef.frame=NSRect(x:14,y:bottomH-94,width:92,height:30); ref.addSubview(saveRef)
        let matchRef=button("Match",action:#selector(matchSelectedToReference)); matchRef.frame=NSRect(x:114,y:bottomH-94,width:92,height:30); ref.addSubview(matchRef)
        let refHint=label("Spectral shape is normalized before matching, then level stays independent.",size:8,color:NSColor(hex:0x627989)); refHint.frame=NSRect(x:14,y:52,width:194,height:44); refHint.lineBreakMode=.byWordWrapping; refHint.maximumNumberOfLines=3; ref.addSubview(refHint)
        let morphStrength=label("Reference character",size:8,color:NSColor(hex:0x6F8493)); morphStrength.frame=NSRect(x:14,y:25,width:150,height:16); ref.addSubview(morphStrength)

        addTitle("PROCESS",to:process,y:bottomH-28)
        autoRepairButton=button("Auto Repair",action:#selector(autoRepairSelected)); autoRepairButton.frame=NSRect(x:14,y:bottomH-70,width:182,height:30); autoRepairButton.isEnabled=false; process.addSubview(autoRepairButton)
        let morph=button("Reference Morph",action:#selector(referenceMorphSelected)); morph.frame=NSRect(x:14,y:bottomH-106,width:182,height:28); process.addSubview(morph)
        let blend=button("Reference Blend",action:#selector(referenceBlendSelected)); blend.frame=NSRect(x:14,y:bottomH-140,width:182,height:28); process.addSubview(blend)
        applySimilarButton=button("Apply Similar",action:#selector(applySimilar)); applySimilarButton.frame=NSRect(x:14,y:18,width:182,height:28); applySimilarButton.isEnabled=false; process.addSubview(applySimilarButton)

        addTitle("PREVIEW & RENDER",to:preview,y:bottomH-28)
        playButton=button("▶  Play",action:#selector(playSelected)); playButton.frame=NSRect(x:14,y:bottomH-70,width:78,height:30); preview.addSubview(playButton)
        loopButton=button("↻",action:#selector(toggleLoop)); loopButton.frame=NSRect(x:98,y:bottomH-70,width:34,height:30); preview.addSubview(loopButton)
        auditionMode=NSSegmentedControl(labels:["ORIG","REPAIR","DELTA","S"],trackingMode:.selectOne,target:self,action:#selector(auditionModeChanged)); auditionMode.selectedSegment=1; auditionMode.frame=NSRect(x:14,y:bottomH-108,width:198,height:26); preview.addSubview(auditionMode)
        exportButton=button("Export RG-SIB",action:#selector(exportAudio)); exportButton.frame=NSRect(x:14,y:50,width:198,height:32); exportButton.isEnabled=false; preview.addSubview(exportButton)
        stopMode=NSSegmentedControl(labels:["CONTINUE","RETURN"],trackingMode:.selectOne,target:self,action:nil); stopMode.selectedSegment=0; stopMode.frame=NSRect(x:14,y:16,width:130,height:26); preview.addSubview(stopMode)
        let prev=button("←",action:#selector(previousEvent)); prev.frame=NSRect(x:150,y:16,width:28,height:26); preview.addSubview(prev)
        let next=button("→",action:#selector(nextEvent)); next.frame=NSRect(x:184,y:16,width:28,height:26); preview.addSubview(next)

        // Hidden compatibility controls used by existing event/session methods. They stay functional but do not clutter Clean Pro.
        typeTrimSlider=NSSlider(value:0,minValue:-12,maxValue:0,target:self,action:#selector(typeTrimChanged)); typeTrimSlider.isHidden=true; root.addSubview(typeTrimSlider)
        typeTrimValue=label("0.0 dB",size:8); typeTrimValue.isHidden=true; root.addSubview(typeTrimValue)
        fadeInSlider=NSSlider(value:12,minValue:0,maxValue:120,target:self,action:#selector(fadeChanged)); fadeInSlider.isHidden=true; root.addSubview(fadeInSlider)
        fadeOutSlider=NSSlider(value:12,minValue:0,maxValue:120,target:self,action:#selector(fadeChanged)); fadeOutSlider.isHidden=true; root.addSubview(fadeOutSlider)
        fadeInValue=label("12 ms",size:8); fadeInValue.isHidden=true; root.addSubview(fadeInValue)
        fadeOutValue=label("12 ms",size:8); fadeOutValue.isHidden=true; root.addSubview(fadeOutValue)
        dropView=AudioDropView(frame:.zero); dropView.isHidden=true; root.addSubview(dropView)

        // Footer
        eventInfo=label("READY",size:8,color:NSColor(hex:0x748997)); eventInfo.frame=NSRect(x:18,y:32,width:1060,height:18); root.addSubview(eventInfo)
        status=label("READY — drop WAV/AIFF",size:9,weight:.bold,color:.systemGreen); status.frame=NSRect(x:18,y:10,width:880,height:18); root.addSubview(status)
        let ver=label("v\(RGVersion) CLEAN PRO BETA",size:8,color:NSColor(hex:0x627A8A)); ver.alignment=.right; ver.frame=NSRect(x:w-260,y:10,width:230,height:18); root.addSubview(ver)

        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
'''

pat=re.compile(r'    private func buildUI\(\) \{.*?\n    \}\n\n    private func refreshAnnotationSidebar',re.S)
m=pat.search(s)
if not m: raise SystemExit('buildUI block not found')
s=s[:m.start()]+new_build+'\n    private func refreshAnnotationSidebar'+s[m.end():]

# Inspector cards fit the new fixed inspector width and look more like a list than macOS default blocks.
s=s.replace('b.widthAnchor.constraint(equalToConstant: 284).isActive = true','b.widthAnchor.constraint(equalToConstant: 236).isActive = true')
s=s.replace('b.heightAnchor.constraint(equalToConstant: 54).isActive = true','b.heightAnchor.constraint(equalToConstant: 42).isActive = true')

# Inspector is fixed: hide/show only, editor geometry never mutates.
pat2=re.compile(r'    @objc private func toggleInspector\(\) \{.*?\n    \}\n\n    @objc private func zoomInTimeline',re.S)
rep='''    @objc private func toggleInspector() {\n        guard annotationsPanel != nil else { return }\n        inspectorHidden.toggle()\n        annotationsPanel.isHidden = inspectorHidden\n        inspectorToggleButton.title = inspectorHidden ? "Show Events" : "Events"\n        status.stringValue = inspectorHidden ? "EVENTS PANEL HIDDEN" : "EVENTS PANEL VISIBLE"\n    }\n\n    @objc private func zoomInTimeline'''
s,n=pat2.subn(rep,s,count=1)
if n!=1: raise SystemExit('toggle inspector block not found')

# Keep the graph synchronized with selected-event shaping.
needle='''        referenceInfoLabel?.stringValue = refs > 0 ? "\\(refs) saved [\\(e.kind)] reference\\(refs == 1 ? "" : "s")" : "No saved [\\(e.kind)] reference"\n'''
if needle in s:
    s=s.replace(needle,needle+'''        spectralShapeView?.tilt = e.spectralTilt ?? 0\n        spectralShapeView?.flatten = e.spectralFlatten ?? 0\n        spectralShapeView?.whistleHz = e.resonanceHz\n        spectralShapeView?.whistleAmount = e.resonanceAmount ?? 0\n''',1)

p.write_text(s)
print('patched Clean Pro 0.4.0')
