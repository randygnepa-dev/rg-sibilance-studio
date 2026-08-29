import Cocoa
import AVFoundation
import Foundation

let RGVersion = "0.2.10"
let RGRepoRaw = "https://raw.githubusercontent.com/randygnepa-dev/rg-sibilance-studio/main"

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1.0) {
        self.init(calibratedRed: CGFloat((hex >> 16) & 0xff) / 255.0,
                  green: CGFloat((hex >> 8) & 0xff) / 255.0,
                  blue: CGFloat(hex & 0xff) / 255.0,
                  alpha: alpha)
    }
}

struct SibilanceEvent {
    var start: Double
    var end: Double
    var peakTime: Double
    var score: Double
    var kind: String
    var userLabel: String
}

final class AudioModel {
    var url: URL?
    var samples: [Float] = []
    var sampleRate: Double = 48000
    var channels: Int = 0
    var duration: Double = 0
    var peak: Float = 0
    var rms: Float = 0

    func load(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw NSError(domain: "RG", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate audio buffer"])
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else {
            throw NSError(domain: "RG", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot read audio samples"])
        }
        self.url = url
        self.sampleRate = format.sampleRate
        self.channels = Int(format.channelCount)
        self.duration = Double(buffer.frameLength) / format.sampleRate
        let n = Int(buffer.frameLength)
        samples = Array(repeating: 0, count: n)
        let c = max(1, channels)
        for i in 0..<n {
            var s: Float = 0
            for ch in 0..<c { s += data[ch][i] }
            samples[i] = s / Float(c)
        }
        var p: Float = 0
        var e = 0.0
        for x in samples { p = max(p, abs(x)); e += Double(x * x) }
        peak = p
        rms = samples.isEmpty ? 0 : Float(sqrt(e / Double(samples.count)))
    }
}

final class SibilanceDetector {
    func detect(samples: [Float], sampleRate: Double, sensitivity: Double) -> [SibilanceEvent] {
        guard samples.count > 4096 else { return [] }
        let frame = 1024, hop = 512
        var values: [(t: Double, v: Double, rms: Double, ratio: Double)] = []
        var i = 0
        while i + frame < samples.count {
            var full = 0.0, diff = 0.0
            var prev = samples[i]
            var zc = 0
            for j in i..<(i + frame) {
                let x = samples[j]
                full += Double(x * x)
                let d = x - prev
                diff += Double(d * d)
                if (x >= 0) != (prev >= 0) { zc += 1 }
                prev = x
            }
            let r = sqrt(full / Double(frame))
            let ratio = sqrt(diff / max(full, 1e-12))
            let zcr = Double(zc) / Double(frame)
            let gate = min(1.0, max(0.0, (r - 0.0015) / 0.025))
            let v = ratio * (0.55 + 2.5 * zcr) * (0.20 + 0.80 * gate)
            values.append((Double(i + frame / 2) / sampleRate, v, r, ratio))
            i += hop
        }
        guard values.count > 10 else { return [] }
        let sorted = values.map { $0.v }.sorted()
        let sens = min(1.0, max(0.0, sensitivity))
        let percentile = 0.90 - sens * 0.28
        let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * percentile)))
        let threshold = max(0.62, sorted[idx])
        let frameDur = Double(frame) / sampleRate
        var raw: [(Double, Double, Double)] = []
        var start: Double? = nil
        var best = 0.0
        for m in values {
            let on = m.v >= threshold && m.rms > 0.0015 && m.ratio > 0.48
            if on {
                if start == nil { start = max(0, m.t - frameDur * 0.5) }
                best = max(best, m.v)
            } else if let s = start {
                let e = m.t + frameDur * 0.25
                if e - s >= 0.025 && e - s <= 0.55 { raw.append((s, e, best)) }
                start = nil; best = 0
            }
        }
        var merged: [(Double, Double, Double)] = []
        for r in raw {
            if let last = merged.last, r.0 - last.1 < 0.045 {
                merged[merged.count - 1] = (last.0, r.1, max(last.2, r.2))
            } else { merged.append(r) }
        }
        return merged.prefix(300).map {
            let kind = ($0.1 - $0.0) < 0.065 ? "T" : "S"
            return SibilanceEvent(start: $0.0, end: $0.1, peakTime: ($0.0 + $0.1) * 0.5, score: $0.2, kind: kind, userLabel: "")
        }
    }
}

final class DropAudioView: NSView {
    var onDrop: ((URL) -> Void)?
    private var active = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func audioURL(_ sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let u = urls.first else { return nil }
        return ["wav","wave","aif","aiff"].contains(u.pathExtension.lowercased()) ? u : nil
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { if audioURL(sender) != nil { active = true; needsDisplay = true; return .copy }; return [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { active = false; needsDisplay = true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { audioURL(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { guard let u = audioURL(sender) else { return false }; active = false; needsDisplay = true; onDrop?(u); return true }
    override func draw(_ dirtyRect: NSRect) {
        (active ? NSColor(hex: 0x12375C) : NSColor(hex: 0x0E1B28)).setFill(); bounds.fill()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        p.lineWidth = active ? 2 : 1; (active ? NSColor.systemBlue : NSColor(hex: 0x28445F)).setStroke(); p.stroke()
        let title = active ? "DROP AUDIO" : "DRAG & DROP WAV / AIFF"
        let sub = active ? "Release to load" : "Pretiahni audio priamo z Finderu"
        let a1: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 17), .foregroundColor: NSColor.white]
        let a2: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(hex: 0x8797A8)]
        let z1 = title.size(withAttributes: a1), z2 = sub.size(withAttributes: a2)
        title.draw(at: NSPoint(x: bounds.midX-z1.width/2, y: bounds.midY+5), withAttributes: a1)
        sub.draw(at: NSPoint(x: bounds.midX-z2.width/2, y: bounds.midY-22), withAttributes: a2)
    }
}

final class TimelineView: NSView {
    var model: AudioModel? { didSet { needsDisplay = true } }
    var events: [SibilanceEvent] = [] { didSet { needsDisplay = true } }
    var selected: Int? { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    private var rect: NSRect { NSRect(x: 90, y: 28, width: max(100, bounds.width-115), height: max(80, bounds.height-48)) }
    override func mouseDown(with event: NSEvent) {
        guard let m = model, m.duration > 0, !events.isEmpty else { return }
        let p = convert(event.locationInWindow, from: nil); guard rect.contains(p) else { return }
        let t = Double((p.x-rect.minX)/rect.width) * m.duration
        var bi = 0, bd = Double.greatestFiniteMagnitude
        for (i,e) in events.enumerated() { let d = abs(e.peakTime-t); if d < bd { bd=d; bi=i } }
        selected = bi; onSelect?(bi)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: 0x0B1219).setFill(); bounds.fill(); NSColor(hex: 0x101A24).setFill(); rect.fill()
        guard let m = model, !m.samples.isEmpty else { return }
        let cols = max(100, Int(rect.width)), step = max(1, m.samples.count / cols)
        let wave = NSBezierPath()
        for x in 0..<cols {
            let s = min(m.samples.count-1, x*step), e = min(m.samples.count, s+step)
            var mn = m.samples[s], mx = mn
            if s < e { for i in s..<e { mn=min(mn,m.samples[i]); mx=max(mx,m.samples[i]) } }
            let xx = rect.minX + CGFloat(x)/CGFloat(max(1,cols-1))*rect.width
            wave.move(to: NSPoint(x:xx,y:rect.midY+CGFloat(mn)*rect.height*0.42)); wave.line(to: NSPoint(x:xx,y:rect.midY+CGFloat(mx)*rect.height*0.42))
        }
        NSColor(hex: 0x2F8CFF).setStroke(); wave.lineWidth=1; wave.stroke()
        for (i,e) in events.enumerated() {
            let x = rect.minX + CGFloat(e.peakTime/m.duration)*rect.width
            let c: NSColor = e.userLabel == "GOOD" ? NSColor.systemGreen : e.userLabel == "BAD" ? NSColor.systemRed : e.userLabel == "TARGET" ? NSColor.systemBlue : e.kind == "T" ? NSColor.systemOrange : NSColor.systemPink
            let line=NSBezierPath(); line.move(to:NSPoint(x:x,y:rect.minY)); line.line(to:NSPoint(x:x,y:rect.maxY)); c.setStroke(); line.lineWidth = i == selected ? 3 : 1; line.stroke()
            let badge=NSBezierPath(roundedRect:NSRect(x:x-8,y:rect.maxY-17,width:16,height:16),xRadius:3,yRadius:3); c.setFill(); badge.fill()
            let a:[NSAttributedString.Key:Any] = [.font:NSFont.boldSystemFont(ofSize:10),.foregroundColor:NSColor.white]; let z=e.kind.size(withAttributes:a); e.kind.draw(at:NSPoint(x:x-z.width/2,y:rect.maxY-16),withAttributes:a)
        }
    }
}

final class UpdateManager {
    private var timer: Timer?
    private var updating = false
    var status: ((String) -> Void)?
    func start() { check(); timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.check() } }
    private func parts(_ s:String)->[Int] { s.split(separator:".").map{Int($0) ?? 0} }
    private func newer(_ a:String,_ b:String)->Bool { let x=parts(a),y=parts(b),n=max(x.count,y.count); for i in 0..<n { let xv=i<x.count ? x[i]:0, yv=i<y.count ? y[i]:0; if xv != yv { return xv > yv } }; return false }
    private func check() {
        guard !updating, let u=URL(string:"\(RGRepoRaw)/VERSION?t=\(Date().timeIntervalSince1970)") else { return }
        URLSession.shared.dataTask(with:u){ [weak self] data,_,_ in
            guard let self=self, let data=data, let v=String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines), self.newer(v,RGVersion) else { return }
            self.updating=true; DispatchQueue.main.async{self.status?("UPDATE \(v) — applying…")}; self.apply(v)
        }.resume()
    }
    private func apply(_ version:String) {
        guard let u=URL(string:"\(RGRepoRaw)/Sources/RGSibilanceStudio.swift?t=\(Date().timeIntervalSince1970)") else { return }
        URLSession.shared.dataTask(with:u){ [weak self] data,_,_ in
            guard let self=self, let data=data else { self?.updating=false; return }
            do {
                let fm=FileManager.default, base=fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RG Sibilance Studio",isDirectory:true)
                try fm.createDirectory(at:base,withIntermediateDirectories:true)
                let src=base.appendingPathComponent("RGSibilanceStudio-\(version).swift"), bin=base.appendingPathComponent("RG Sibilance Studio-\(version)"), marker=base.appendingPathComponent("UPDATED_TO")
                try data.write(to:src,options:.atomic)
                let sdkP=Process(),pipe=Pipe(); sdkP.executableURL=URL(fileURLWithPath:"/usr/bin/xcrun"); sdkP.arguments=["--sdk","macosx","--show-sdk-path"]; sdkP.standardOutput=pipe; try sdkP.run(); sdkP.waitUntilExit()
                guard let sdk=String(data:pipe.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines), !sdk.isEmpty else { self.updating=false; return }
                let p=Process(); p.executableURL=URL(fileURLWithPath:"/usr/bin/xcrun"); p.arguments=["--sdk","macosx","swiftc",src.path,"-sdk",sdk,"-o",bin.path,"-framework","Cocoa","-framework","AVFoundation"]; try p.run(); p.waitUntilExit()
                guard p.terminationStatus==0 else { self.updating=false; DispatchQueue.main.async{self.status?("UPDATE FAILED — previous version kept")}; return }
                try version.write(to:marker,atomically:true,encoding:.utf8)
                DispatchQueue.main.async { let launch=Process(); launch.executableURL=bin; try? launch.run(); NSApp.terminate(nil) }
            } catch { self.updating=false; DispatchQueue.main.async{self.status?("UPDATE FAILED") } }
        }.resume()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, AVAudioPlayerDelegate {
    private var window:NSWindow!, status:NSTextField!, fileInfo:NSTextField!, eventInfo:NSTextField!, detected:NSTextField!, timeline:TimelineView!, sensitivity:NSSlider!, playButton:NSButton!, loopButton:NSButton!
    private var player:AVAudioPlayer?, stopTimer:Timer?, loop=false, model=AudioModel(), events:[SibilanceEvent]=[]
    private let detector=SibilanceDetector(), updater=UpdateManager()

    func applicationDidFinishLaunching(_ notification:Notification) { buildUI(); updater.status={ [weak self] s in self?.status.stringValue=s }; updater.start(); showUpdateNoticeIfNeeded() }
    private func label(_ t:String,_ size:CGFloat=13,_ weight:NSFont.Weight = .regular,_ color:NSColor=NSColor(hex:0xAAB5C0))->NSTextField { let l=NSTextField(labelWithString:t); l.font=NSFont.systemFont(ofSize:size,weight:weight); l.textColor=color; return l }
    private func button(_ t:String,_ action:Selector)->NSButton { let b=NSButton(title:t,target:self,action:action); b.bezelStyle=.rounded; return b }
    private func showUpdateNoticeIfNeeded() {
        let base=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RG Sibilance Studio",isDirectory:true), marker=base.appendingPathComponent("UPDATED_TO")
        if let v=try? String(contentsOf:marker,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines), v==RGVersion { try? FileManager.default.removeItem(at:marker); status.stringValue="AUTO UPDATE COMPLETE — v\(RGVersion)"; DispatchQueue.main.asyncAfter(deadline:.now()+0.4){ let a=NSAlert(); a.messageText="Auto update dokončený"; a.informativeText="RG Sibilance Studio bolo aktualizované na v\(RGVersion)."; a.addButton(withTitle:"OK"); a.runModal() } }
    }
    private func buildUI() {
        let sf=NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1400,height:900), w=min(CGFloat(1380),sf.width-40), h=min(CGFloat(860),sf.height-40)
        window=NSWindow(contentRect:NSRect(x:sf.midX-w/2,y:sf.midY-h/2,width:w,height:h),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false); window.title="RG Sibilance Studio \(RGVersion) BETA"; window.backgroundColor=NSColor(hex:0x0C1218)
        let root=NSView(frame:NSRect(x:0,y:0,width:w,height:h)); root.wantsLayer=true; root.layer?.backgroundColor=NSColor(hex:0x0C1218).cgColor; window.contentView=root
        let title=label("RG Sibilance Studio",28,.bold,.white); title.frame=NSRect(x:34,y:h-68,width:480,height:38); root.addSubview(title)
        let sub=label("Sibilance detection & repair   •   AUTO UPDATE BETA",13,.regular,NSColor(hex:0x8896A4)); sub.frame=NSRect(x:36,y:h-96,width:560,height:22); root.addSubview(sub)
        let analyze=button("Analyze",#selector(analyzeAudio)); analyze.frame=NSRect(x:w-330,y:h-73,width:130,height:34); root.addSubview(analyze)
        let open=button("Open WAV",#selector(openWav)); open.frame=NSRect(x:w-185,y:h-73,width:130,height:34); root.addSubview(open)
        let drop=DropAudioView(frame:NSRect(x:34,y:h-220,width:w-68,height:100)); drop.onDrop={ [weak self] u in self?.loadAudio(u) }; root.addSubview(drop)
        fileInfo=label("No audio loaded",12,.medium); fileInfo.frame=NSRect(x:40,y:h-244,width:w-80,height:20); root.addSubview(fileInfo)
        timeline=TimelineView(frame:NSRect(x:34,y:h-565,width:w-68,height:290)); timeline.wantsLayer=true; timeline.layer?.borderColor=NSColor(hex:0x26313B).cgColor; timeline.layer?.borderWidth=1; timeline.layer?.cornerRadius=8; timeline.onSelect={ [weak self] i in self?.selectEvent(i) }; root.addSubview(timeline)
        detected=label("Detected: 0 events",12,.semibold,NSColor.systemBlue); detected.frame=NSRect(x:52,y:h-590,width:220,height:20); root.addSubview(detected)
        eventInfo=label("Select an event",12,.regular,NSColor(hex:0x8997A5)); eventInfo.frame=NSRect(x:280,y:h-590,width:620,height:20); root.addSubview(eventInfo)
        let y:CGFloat=60, ph=max(CGFloat(170),h-650), gap:CGFloat=14, pw=(w-68-gap*2)/3
        let p1=NSBox(frame:NSRect(x:34,y:y,width:pw,height:ph)),p2=NSBox(frame:NSRect(x:34+pw+gap,y:y,width:pw,height:ph)),p3=NSBox(frame:NSRect(x:34+(pw+gap)*2,y:y,width:pw,height:ph)); for p in [p1,p2,p3] { p.boxType=.custom; p.borderColor=NSColor(hex:0x26313B); p.fillColor=NSColor(hex:0x111820); p.cornerRadius=8; root.addSubview(p) }
        let dtitle=label("DETECTION",12,.bold,.white); dtitle.frame=NSRect(x:16,y:ph-30,width:160,height:20); p1.addSubview(dtitle)
        let sl=label("Sensitivity",12); sl.frame=NSRect(x:16,y:ph-68,width:90,height:20); p1.addSubview(sl); sensitivity=NSSlider(value:0.72,minValue:0,maxValue:1,target:self,action:#selector(sensitivityChanged)); sensitivity.frame=NSRect(x:105,y:ph-72,width:pw-135,height:24); p1.addSubview(sensitivity)
        let et=label("EVENT",12,.bold,.white); et.frame=NSRect(x:16,y:ph-30,width:160,height:20); p2.addSubview(et)
        let good=button("GOOD",#selector(markGood)),bad=button("BAD",#selector(markBad)),target=button("TARGET",#selector(markTarget)),normal=button("NORMAL",#selector(markNormal)); good.frame=NSRect(x:16,y:ph-74,width:75,height:30); bad.frame=NSRect(x:96,y:ph-74,width:75,height:30); target.frame=NSRect(x:176,y:ph-74,width:85,height:30); normal.frame=NSRect(x:266,y:ph-74,width:90,height:30); for b in [good,bad,target,normal]{p2.addSubview(b)}
        let pt=label("PREVIEW",12,.bold,.white); pt.frame=NSRect(x:16,y:ph-30,width:160,height:20); p3.addSubview(pt); playButton=button("▶ Play event",#selector(playSelected)); playButton.frame=NSRect(x:16,y:ph-74,width:120,height:32); p3.addSubview(playButton); loopButton=button("Loop OFF",#selector(toggleLoop)); loopButton.frame=NSRect(x:145,y:ph-74,width:100,height:32); p3.addSubview(loopButton)
        status=label("READY — drop WAV/AIFF",12,.bold,NSColor.systemGreen); status.frame=NSRect(x:36,y:20,width:w-72,height:20); root.addSubview(status)
        let ver=label("Engine: Native   •   Auto update: ON   •   v\(RGVersion) BETA",11,.regular,NSColor(hex:0x75828E)); ver.alignment=.right; ver.frame=NSRect(x:w-470,y:20,width:430,height:20); root.addSubview(ver)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    @objc private func openWav(){ let p=NSOpenPanel(); p.allowedFileTypes=["wav","wave","aif","aiff"]; if p.runModal()==.OK, let u=p.url { loadAudio(u) } }
    private func loadAudio(_ u:URL){ status.stringValue="LOADING AUDIO…"; DispatchQueue.global(qos:.userInitiated).async{ [weak self] in guard let self=self else{return}; do{ let m=AudioModel(); try m.load(u); DispatchQueue.main.async{ self.model=m; self.events=[]; self.timeline.model=m; self.timeline.events=[]; self.timeline.selected=nil; self.fileInfo.stringValue="\(u.lastPathComponent)   •   \(Int(m.sampleRate)) Hz   •   \(m.channels) ch   •   \(String(format:"%.2f",m.duration)) s"; self.detected.stringValue="Detected: 0 events"; self.status.stringValue="AUDIO LOADED — ready to Analyze" } }catch{ DispatchQueue.main.async{self.status.stringValue="LOAD FAILED — \(error.localizedDescription)"} } } }
    @objc private func analyzeAudio(){ guard !model.samples.isEmpty else{status.stringValue="DROP WAV/AIFF FIRST";return}; status.stringValue="ANALYZING SIBILANCE…"; let s=model.samples,sr=model.sampleRate,se=sensitivity.doubleValue; DispatchQueue.global(qos:.userInitiated).async{ [weak self] in guard let self=self else{return}; let f=self.detector.detect(samples:s,sampleRate:sr,sensitivity:se); DispatchQueue.main.async{self.events=f;self.timeline.events=f;self.timeline.selected=f.isEmpty ? nil:0;self.detected.stringValue="Detected: \(f.count) events";self.status.stringValue="ANALYSIS DONE";if !f.isEmpty{self.selectEvent(0)}} } }
    @objc private func sensitivityChanged(){status.stringValue="Sensitivity \(Int(sensitivity.doubleValue*100))% — press Analyze"}
    private func selectEvent(_ i:Int){guard events.indices.contains(i) else{return};timeline.selected=i;let e=events[i];eventInfo.stringValue=String(format:"#%03d  %@  %.3f–%.3f s  score %.2f  %@",i+1,e.kind,e.start,e.end,e.score,e.userLabel.isEmpty ? "UNRATED":e.userLabel)}
    private func mark(_ v:String){guard let i=timeline.selected,events.indices.contains(i) else{return};events[i].userLabel=v;timeline.events=events;selectEvent(i);status.stringValue="EVENT #\(i+1) MARKED \(v)"}
    @objc private func markGood(){mark("GOOD")}; @objc private func markBad(){mark("BAD")}; @objc private func markTarget(){mark("TARGET")}; @objc private func markNormal(){mark("NORMAL")}
    @objc private func toggleLoop(){loop.toggle();loopButton.title=loop ? "Loop ON":"Loop OFF"}
    @objc private func playSelected(){guard let u=model.url else{return};do{stopTimer?.invalidate();let p=try AVAudioPlayer(contentsOf:u);p.delegate=self;player=p;if let i=timeline.selected,events.indices.contains(i){let e=events[i],pre=max(0,e.start-0.30),post=min(model.duration,e.end+0.40);p.currentTime=pre;p.play();playButton.title="■ Stop";stopTimer=Timer.scheduledTimer(withTimeInterval:max(0.1,post-pre),repeats:false){[weak self]_ in self?.finishPreview()}}else{p.play()}}catch{status.stringValue="PLAYBACK FAILED"}}
    private func finishPreview(){player?.stop();playButton.title="▶ Play event";if loop{playSelected()}else{status.stringValue="READY"}}
    func audioPlayerDidFinishPlaying(_ player:AVAudioPlayer,successfully flag:Bool){playButton.title="▶ Play event"}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
}

let app=NSApplication.shared
let delegate=AppDelegate()
app.delegate=delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps:true)
app.run()
