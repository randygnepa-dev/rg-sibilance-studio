from pathlib import Path
import re

p=Path('Sources/RGSibilanceStudio.swift')
s=p.read_text()
s=s.replace('let RGVersion = "0.3.2"','let RGVersion = "0.3.3"',1)

# Fixed-canvas beta: precision first. Disable window resize entirely.
s=s.replace('styleMask: [.titled, .closable, .miniaturizable, .resizable]','styleMask: [.titled, .closable, .miniaturizable]',1)
# Remove inspector toggle from visible UI: fixed RX-like single workspace.
s=s.replace('inspectorToggleButton.frame = NSRect(x: w - 146, y: h - 67, width: 104, height: 30)','inspectorToggleButton.frame = NSRect(x: -1000, y: -1000, width: 1, height: 1)',1)
s=s.replace('inspectorToggleButton.title = "Show Inspector"','inspectorToggleButton.title = "Inspector"')

# Replace bottom geometry with three stable columns: Detect / Repair / Preview.
pat=re.compile(r'        let leftW: CGFloat = 190\n        let rightW: CGFloat = 250\n        let advancedW: CGFloat = 180\n        let centerW: CGFloat = max\(430, mainW - leftW - rightW - gap \* 2\).*?root.addSubview\(p1\); root.addSubview\(p2\); root.addSubview\(pAdv\); root.addSubview\(p3\)',re.S)
new='''        let leftW: CGFloat = 184
        let rightW: CGFloat = 224
        let advancedW: CGFloat = 1
        let centerW: CGFloat = mainW - leftW - rightW - gap * 2
        let p1 = makePanel(NSRect(x: 42, y: panelY, width: leftW, height: panelH))
        let p2 = makePanel(NSRect(x: 42 + leftW + gap, y: panelY, width: centerW, height: panelH))
        let pAdv = makePanel(NSRect(x: -1000, y: panelY, width: 1, height: 1)); pAdv.isHidden = true
        let p3 = makePanel(NSRect(x: 42 + leftW + gap + centerW + gap, y: panelY, width: rightW, height: panelH))
        root.addSubview(p1); root.addSubview(p2); root.addSubview(pAdv); root.addSubview(p3)'''
s,n=pat.subn(new,s,count=1)
if n!=1: raise SystemExit('fixed bottom geometry not found')

# Replace crowded Repair panel construction with strict rows and an RX-like module hierarchy.
start=s.find('        let rtitle = label("REPAIR"')
end=s.find('        let ptitle = label("PREVIEW"',start)
if start<0 or end<0: raise SystemExit('repair panel block not found')
block='''        let rtitle = label("SIBILANCE REPAIR", size: 11, weight: .bold, color: .white)
        rtitle.frame = NSRect(x: 16, y: panelH - 30, width: 160, height: 18); p2.addSubview(rtitle)
        let modeHint = label("Selected event", size: 9, color: NSColor(hex: 0x71818D))
        modeHint.frame = NSRect(x: centerW - 100, y: panelH - 30, width: 84, height: 18); modeHint.alignment = .right; p2.addSubview(modeHint)

        let good = button("GOOD", action: #selector(markGood)); good.frame = NSRect(x: 16, y: panelH - 64, width: 58, height: 26); p2.addSubview(good)
        let bad = button("BAD", action: #selector(markBad)); bad.frame = NSRect(x: 80, y: panelH - 64, width: 54, height: 26); p2.addSubview(bad)
        let target = button("TARGET", action: #selector(markTarget)); target.frame = NSRect(x: 140, y: panelH - 64, width: 66, height: 26); p2.addSubview(target)
        let normal = button("NORMAL", action: #selector(markNormal)); normal.frame = NSRect(x: 212, y: panelH - 64, width: 70, height: 26); p2.addSubview(normal)
        let typeLabel = label("TYPE", size: 9, weight: .bold, color: NSColor(hex: 0x8394A1)); typeLabel.frame = NSRect(x: centerW - 120, y: panelH - 59, width: 34, height: 16); p2.addSubview(typeLabel)
        kindPopup = NSPopUpButton(frame: NSRect(x: centerW - 82, y: panelH - 66, width: 66, height: 28), pullsDown: false)
        kindPopup.addItems(withTitles: ["S", "Š", "Z", "C", "Č", "T", "Ť", "D", "K", "P", "B", "F", "CH", "OTHER"]); kindPopup.target=self; kindPopup.action=#selector(kindChanged(_:)); kindPopup.isEnabled=false; p2.addSubview(kindPopup)

        let levelTitle = label("LEVEL", size: 9, weight: .bold, color: NSColor(hex: 0xA9B8C3)); levelTitle.frame=NSRect(x:16,y:panelH-94,width:60,height:16); p2.addSubview(levelTitle)
        repairSlider=NSSlider(value:0.66,minValue:0,maxValue:1,target:self,action:#selector(repairStrengthChanged(_:)))
        repairSlider.frame=NSRect(x:82,y:panelH-98,width:centerW-98,height:20); p2.addSubview(repairSlider)

        let toneTitle=label("TILT",size:9,weight:.bold,color:NSColor(hex:0xA9B8C3)); toneTitle.frame=NSRect(x:16,y:panelH-122,width:60,height:16); p2.addSubview(toneTitle)
        spectralTiltSlider=NSSlider(value:0,minValue:-1,maxValue:1,target:self,action:#selector(spectralTiltChanged(_:))); spectralTiltSlider.frame=NSRect(x:82,y:panelH-126,width:centerW-170,height:20); spectralTiltSlider.isEnabled=false; p2.addSubview(spectralTiltSlider)
        spectralTiltValue=label("NEUTRAL",size:9,weight:.semibold,color:NSColor(hex:0x9FC6E6)); spectralTiltValue.frame=NSRect(x:centerW-82,y:panelH-122,width:66,height:16); spectralTiltValue.alignment = .right; p2.addSubview(spectralTiltValue)

        let flatTitle=label("FLATTEN",size:9,weight:.bold,color:NSColor(hex:0xA9B8C3)); flatTitle.frame=NSRect(x:16,y:panelH-150,width:60,height:16); p2.addSubview(flatTitle)
        flattenSlider=NSSlider(value:0,minValue:0,maxValue:1,target:self,action:#selector(flattenChanged(_:))); flattenSlider.frame=NSRect(x:82,y:panelH-154,width:150,height:20); flattenSlider.isEnabled=false; p2.addSubview(flattenSlider)
        flattenValue=label("0%",size:9,weight:.semibold,color:NSColor(hex:0xB9C8D3)); flattenValue.frame=NSRect(x:236,y:panelH-150,width:32,height:16); p2.addSubview(flattenValue)
        let whTitle=label("WHISTLE",size:9,weight:.bold,color:NSColor(hex:0xA9B8C3)); whTitle.frame=NSRect(x:286,y:panelH-150,width:60,height:16); p2.addSubview(whTitle)
        resonanceSlider=NSSlider(value:0,minValue:0,maxValue:1,target:self,action:#selector(resonanceChanged(_:))); resonanceSlider.frame=NSRect(x:350,y:panelH-154,width:max(70,centerW-438),height:20); resonanceSlider.isEnabled=false; p2.addSubview(resonanceSlider)
        resonanceValueLabel=label("0%",size:9,weight:.semibold,color:NSColor(hex:0xB9C8D3)); resonanceValueLabel.frame=NSRect(x:centerW-82,y:panelH-150,width:30,height:16); p2.addSubview(resonanceValueLabel)
        let findWhistle=button("FIND",action:#selector(autoFindWhistle)); findWhistle.frame=NSRect(x:centerW-48,y:panelH-157,width:34,height:24); p2.addSubview(findWhistle)
        resonanceFreqLabel=label("",size:8,color:NSColor(hex:0x71818D)); resonanceFreqLabel.frame=NSRect(x:286,y:panelH-168,width:160,height:14); p2.addSubview(resonanceFreqLabel)

        let divider=NSBox(frame:NSRect(x:16,y:49,width:centerW-32,height:1)); divider.boxType = .separator; p2.addSubview(divider)
        let refTitle=label("REFERENCE",size:9,weight:.bold,color:NSColor(hex:0xA9B8C3)); refTitle.frame=NSRect(x:16,y:55,width:70,height:16); p2.addSubview(refTitle)
        let setRef=button("SAVE GOOD",action:#selector(setSelectedAsReference)); setRef.frame=NSRect(x:88,y:52,width:90,height:24); p2.addSubview(setRef)
        let matchRef=button("MATCH",action:#selector(matchSelectedToReference)); matchRef.frame=NSRect(x:184,y:52,width:72,height:24); p2.addSubview(matchRef)
        referenceInfoLabel=label("No reference",size:9,color:NSColor(hex:0x7F93A2)); referenceInfoLabel.frame=NSRect(x:264,y:56,width:max(90,centerW-280),height:16); referenceInfoLabel.lineBreakMode = .byTruncatingTail; p2.addSubview(referenceInfoLabel)

        autoRepairButton=button("AUTO REPAIR",action:#selector(autoRepairSelected)); autoRepairButton.frame=NSRect(x:16,y:12,width:102,height:28); p2.addSubview(autoRepairButton)
        let morph=button("MORPH",action:#selector(referenceMorphSelected)); morph.frame=NSRect(x:124,y:12,width:78,height:28); p2.addSubview(morph)
        let blend=button("BLEND",action:#selector(referenceBlendSelected)); blend.frame=NSRect(x:208,y:12,width:76,height:28); p2.addSubview(blend)
        applySimilarButton=button("APPLY SIMILAR",action:#selector(applySimilar)); applySimilarButton.frame=NSRect(x:centerW-124,y:12,width:108,height:28); p2.addSubview(applySimilarButton)

'''
s=s[:start]+block+s[end:]

# Detection panel: remove misleading Advanced button; keep only manual mark action.
s=s.replace('let adv = button("◎ Advanced", action: #selector(showAdvancedInfo)); adv.frame = NSRect(x: 16, y: 48, width: 112, height: 30); p1.addSubview(adv)','let detectHint = label("AUTO DETECT", size: 9, weight: .semibold, color: NSColor(hex: 0x3198FF)); detectHint.frame = NSRect(x: 16, y: 52, width: 100, height: 18); p1.addSubview(detectHint)',1)

p.write_text(s)
print('patched 0.3.3 fixed RX-style workspace')
