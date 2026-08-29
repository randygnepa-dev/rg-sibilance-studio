from pathlib import Path
import re
main=Path('Sources/RGSibilanceStudio.swift')
s=main.read_text()
s=s.replace('let RGVersion = "0.2.25"','let RGVersion = "0.2.26"',1)

# Extend event nondestructively; optionals keep old saved sessions decodable.
s=s.replace('''    var fadeOut: Double = 0.012
}''','''    var fadeOut: Double = 0.012
    var spectralDB: [Double]? = nil
    var repairMethod: String? = nil
    var donorPath: String? = nil
    var donorStart: Double? = nil
    var donorEnd: Double? = nil
    var blendAmount: Double? = nil
    var referenceInfluence: Double? = nil
}''',1)

# Fingerprint from 5 spectral lanes for self/reference matching.
needle='''    private func buildOverview(binCount: Int) {'''
helper='''    func fingerprint(for event: SibilanceEvent) -> [Double] {
        let spec = spectralBands
        guard !spec.values.isEmpty else { return Array(repeating: 0.0, count: 5) }
        let a = max(0, min(spec.values.count - 1, Int(event.start * spec.sampleRate / Double(spec.hopSamples))))
        let b = max(a + 1, min(spec.values.count, Int(event.end * spec.sampleRate / Double(spec.hopSamples)) + 1))
        var sum = Array(repeating: 0.0, count: 5)
        var count = 0.0
        for i in a..<b {
            for band in 0..<5 { sum[band] += Double(spec.values[i][band]) }
            count += 1
        }
        guard count > 0 else { return sum }
        return sum.map { $0 / count }
    }

'''
s=s.replace(needle,helper+needle,1)

# Learning / reference state.
s=s.replace('    private let sessionStore = SessionStore()\n', '    private let sessionStore = SessionStore()\n    private let learningStore = RGLearningStore()\n',1)
s=s.replace('    private var typeTrims: [String: Double] = [:]\n', '    private var typeTrims: [String: Double] = [:]\n    private var externalReferenceURL: URL?\n    private var externalReferenceModel: AudioModel?\n    private var externalReferenceEvents: [SibilanceEvent] = []\n    private var levelMatchedAudition = true\n',1)

# Make reference buttons functional.
s=s.replace('let morph = button("Reference Morph", action: #selector(referenceModeInfo))', 'let morph = button("Reference Morph", action: #selector(referenceMorphSelected))',1)
s=s.replace('let blend = button("Reference Blend", action: #selector(referenceModeInfo))', 'let blend = button("Reference Blend", action: #selector(referenceBlendSelected))',1)

# Expanded audition modes; context is still the Play button with surrounding audio.
s=s.replace('NSSegmentedControl(labels: ["ORIGINAL", "REPAIR"], trackingMode: .selectOne, target: self, action: #selector(auditionModeChanged))', 'NSSegmentedControl(labels: ["ORIG", "REPAIR", "DELTA", "S ONLY"], trackingMode: .selectOne, target: self, action: #selector(auditionModeChanged))',1)
s=s.replace('self.auditionMode.selectedSegment = min(1, max(0, session.auditionMode ?? 1))', 'self.auditionMode.selectedSegment = min(3, max(0, session.auditionMode ?? 1))',1)

# Replace placeholder reference hook with actual reference/self-learning engine.
old='''    @objc private func referenceModeInfo() {
        status.stringValue = "REFERENCE MODE — engine hook ready; current safe repair remains nondestructive"
    }
'''
new='''    private func referenceExemplar(for event: SibilanceEvent) -> RGExemplar? {
        if let learned = learningStore.best(kind: event.kind, excludingPath: model.url?.path) { return learned }
        if let learned = learningStore.best(kind: event.kind, excludingPath: nil) { return learned }
        if let refModel = externalReferenceModel, let refURL = externalReferenceURL, !externalReferenceEvents.isEmpty {
            let candidates = externalReferenceEvents.filter { $0.kind == event.kind || event.kind == "S" || $0.kind == "S" }
            let donor = (candidates.isEmpty ? externalReferenceEvents : candidates).max { $0.score < $1.score }
            if let d = donor {
                return RGExemplar(kind: event.kind, fingerprint: refModel.fingerprint(for: d), duration: d.end - d.start, sourcePath: refURL.path, start: d.start, end: d.end, createdAt: Date().timeIntervalSince1970)
            }
        }
        return nil
    }

    private func ensureReferenceLoaded() -> Bool {
        if externalReferenceModel != nil { return true }
        let p = NSOpenPanel()
        p.title = "Choose reference vocal"
        p.allowedFileTypes = ["wav", "wave", "aif", "aiff"]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return false }
        do {
            let m = AudioModel()
            try m.load(url)
            let found = detector.detect(samples: m.samples, sampleRate: m.sampleRate, sensitivity: 0.72) { _ in }
            externalReferenceURL = url
            externalReferenceModel = m
            externalReferenceEvents = found
            status.stringValue = "REFERENCE LOADED — \(url.lastPathComponent) • \(found.count) candidate events"
            return true
        } catch {
            status.stringValue = "REFERENCE LOAD FAILED — \(error.localizedDescription)"
            return false
        }
    }

    private func spectralMatch(target: [Double], reference: [Double], influence: Double, safeOnly: Bool) -> [Double] {
        var out: [Double] = []
        for i in 0..<5 {
            let deltaNorm = (reference[i] - target[i])
            var db = deltaNorm * 18.0 * influence
            if safeOnly { db = min(0, db) }
            db = min(3.0, max(-10.0, db))
            // Protect top air band more strongly.
            if i == 4 { db = min(1.5, max(-4.0, db)) }
            out.append(db)
        }
        return out
    }

    @objc private func referenceMorphSelected() {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { status.stringValue = "SELECT AN EVENT FIRST"; return }
        var exemplar = referenceExemplar(for: events[i])
        if exemplar == nil {
            guard ensureReferenceLoaded() else { status.stringValue = "MARK A GOOD EVENT OR LOAD A REFERENCE"; return }
            exemplar = referenceExemplar(for: events[i])
        }
        guard let ex = exemplar else { status.stringValue = "NO MATCHING REFERENCE EVENT"; return }
        let target = model.fingerprint(for: events[i])
        events[i].spectralDB = spectralMatch(target: target, reference: ex.fingerprint, influence: 0.68, safeOnly: false)
        events[i].repairMethod = "MORPH"
        events[i].referenceInfluence = 0.68
        events[i].donorPath = nil
        events[i].blendAmount = nil
        timeline.events = events
        previewPlayer?.stop(); transportPlayer?.stop()
        selectEvent(i); saveCurrentSession()
        status.stringValue = "REFERENCE MORPH — [\(events[i].kind)] 68% • Air protected"
        playRegionOnly(i)
    }

    @objc private func referenceBlendSelected() {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { status.stringValue = "SELECT AN EVENT FIRST"; return }
        var exemplar = referenceExemplar(for: events[i])
        if exemplar == nil {
            guard ensureReferenceLoaded() else { status.stringValue = "MARK A GOOD EVENT OR LOAD A REFERENCE"; return }
            exemplar = referenceExemplar(for: events[i])
        }
        guard let ex = exemplar else { status.stringValue = "NO MATCHING REFERENCE EVENT"; return }
        let target = model.fingerprint(for: events[i])
        events[i].spectralDB = spectralMatch(target: target, reference: ex.fingerprint, influence: 0.38, safeOnly: false)
        events[i].repairMethod = "BLEND"
        events[i].referenceInfluence = 0.38
        events[i].donorPath = ex.sourcePath
        events[i].donorStart = ex.start
        events[i].donorEnd = ex.end
        events[i].blendAmount = 0.28
        timeline.events = events
        previewPlayer?.stop(); transportPlayer?.stop()
        selectEvent(i); saveCurrentSession()
        status.stringValue = "REFERENCE BLEND — donor noise 28% + spectral match"
        playRegionOnly(i)
    }
'''
assert old in s
s=s.replace(old,new,1)

# GOOD now learns an actual 5-band fingerprint + donor location locally.
s=s.replace('    @objc private func markGood() { mark("GOOD") }', '''    @objc private func markGood() {
        mark("GOOD")
        guard let i = timeline.selectedIndex, events.indices.contains(i), let url = model.url else { return }
        let e = events[i]
        let ex = RGExemplar(kind: e.kind, fingerprint: model.fingerprint(for: e), duration: e.end - e.start, sourcePath: url.path, start: e.start, end: e.end, createdAt: Date().timeIntervalSince1970)
        learningStore.add(ex)
        status.stringValue = "GOOD EXEMPLAR SAVED — [\(e.kind)] • library \(learningStore.count(kind: e.kind))"
    }''',1)

# Auto repair uses same-singer/self GOOD profile when possible: minimum intervention and air protection.
pat=r'    @objc private func autoRepairSelected\(\) \{.*?\n    \}\n\n    @objc private func applySimilar\(\) \{'
rep=r'''    @objc private func autoRepairSelected() {
        guard let i = timeline.selectedIndex, events.indices.contains(i) else { return }
        let length = max(0.015, events[i].end - events[i].start)
        let base = RGRepairAdvisor.recommendedGain(for: events[i])
        // Minimum intervention: broadband correction is deliberately smaller when a learned spectral target exists.
        if let ex = referenceExemplar(for: events[i]) {
            let target = model.fingerprint(for: events[i])
            events[i].spectralDB = spectralMatch(target: target, reference: ex.fingerprint, influence: 0.52, safeOnly: true)
            events[i].gainDB = max(-4.0, base * 0.48)
            events[i].repairMethod = "SELF SAFE"
            events[i].referenceInfluence = 0.52
        } else {
            events[i].spectralDB = nil
            events[i].gainDB = base
            events[i].repairMethod = "GAIN SAFE"
        }
        events[i].fadeIn = min(0.018, length * 0.22)
        events[i].fadeOut = min(0.018, length * 0.22)
        timeline.events = events
        previewPlayer?.stop(); transportPlayer?.stop()
        selectEvent(i)
        saveCurrentSession()
        status.stringValue = String(format: "AUTO SAFE — [%@] %.1f dB • %@", events[i].kind, events[i].gainDB, events[i].repairMethod ?? "SAFE")
        playRegionOnly(i)
    }

    @objc private func applySimilar() {'''
s,n=re.subn(pat,rep,s,flags=re.S)
assert n==1, n

# Apply Similar copies spectral repair/donor recipe too.
s=s.replace('''            events[j].fadeOut = min(source.fadeOut, max(0, (events[j].end - events[j].start) * 0.48))
            changed += 1''','''            events[j].fadeOut = min(source.fadeOut, max(0, (events[j].end - events[j].start) * 0.48))
            events[j].spectralDB = source.spectralDB
            events[j].repairMethod = source.repairMethod
            events[j].referenceInfluence = source.referenceInfluence
            events[j].donorPath = source.donorPath
            events[j].donorStart = source.donorStart
            events[j].donorEnd = source.donorEnd
            events[j].blendAmount = source.blendAmount
            changed += 1''',1)

# Show method in selected-event line.
s=s.replace('e.userLabel.isEmpty ? "UNRATED" : e.userLabel, RGRepairAdvisor.qualityText(for: e))', 'e.userLabel.isEmpty ? "UNRATED" : e.userLabel, "METHOD \(e.repairMethod ?? \"MANUAL\") • \(RGRepairAdvisor.qualityText(for: e))")',1)

# Audition mode mapping and true delta/S-only render path.
s=s.replace('''        let repaired = auditionMode?.selectedSegment != 0
        do {
            let rendered = try RGRenderEngine.renderAudition(sourceURL: url, events: events, typeTrims: typeTrims, startTime: e.start, endTime: e.end, repaired: repaired)''','''        let mode = RGAuditionMode.from(segment: auditionMode?.selectedSegment ?? 1)
        do {
            let rendered = try RGRenderEngine.renderAuditionMode(sourceURL: url, events: events, typeTrims: typeTrims, startTime: e.start, endTime: e.end, mode: mode, levelMatched: levelMatchedAudition)''',1)
s=s.replace('let effectiveDB = repaired ? min(0, e.gainDB + (typeTrims[e.kind] ?? 0)) : 0', 'let effectiveDB = mode == .original ? 0 : min(0, e.gainDB + (typeTrims[e.kind] ?? 0))',1)
s=s.replace('repaired ? "REPAIR" : "ORIGINAL"', 'mode.displayName',1)

s=s.replace('''                let repaired = auditionMode?.selectedSegment != 0
                let rendered = try RGRenderEngine.renderAudition(sourceURL: url, events: events, typeTrims: typeTrims, startTime: pre, endTime: post, repaired: repaired)''','''                let mode = RGAuditionMode.from(segment: auditionMode?.selectedSegment ?? 1)
                let rendered = try RGRenderEngine.renderAuditionMode(sourceURL: url, events: events, typeTrims: typeTrims, startTime: pre, endTime: post, mode: mode, levelMatched: levelMatchedAudition)''',1)
s=s.replace('status.stringValue = repaired ? "CONTEXT — REPAIR" : "CONTEXT — ORIGINAL"', 'status.stringValue = "CONTEXT — \(mode.displayName)"',1)

# Full transport uses selected audition mode as well.
s=s.replace('''        let repaired = auditionMode?.selectedSegment != 0
        transportPlayer?.stop()''','''        let mode = RGAuditionMode.from(segment: auditionMode?.selectedSegment ?? 1)
        let repaired = mode != .original
        transportPlayer?.stop()''',1)
s=s.replace('''                let rendered = try RGRenderEngine.renderFullPreview(sourceURL: url, events: events, typeTrims: typeTrims, repaired: true)
                p = try AVAudioPlayer(contentsOf: rendered)''','''                let rendered = try RGRenderEngine.renderFullPreviewMode(sourceURL: url, events: events, typeTrims: typeTrims, mode: mode, levelMatched: levelMatchedAudition)
                p = try AVAudioPlayer(contentsOf: rendered)''',1)
s=s.replace('status.stringValue = repaired ? "PLAYING REPAIR — rendered event gain + TYPE TRIM + crossfades" : "PLAYING ORIGINAL"', 'status.stringValue = repaired ? "PLAYING \(mode.displayName) — rendered DSP" : "PLAYING ORIGINAL"',1)

# A/B status supports all modes.
s=s.replace('status.stringValue = auditionMode.selectedSegment == 0 ? "A/B — ORIGINAL" : "A/B — REPAIR"', 'status.stringValue = "AUDITION — \(RGAuditionMode.from(segment: auditionMode.selectedSegment).displayName)"',1)

main.write_text(s)

# Advanced engine: local exemplar store, audition difference modes, spectral repair and donor blend.
adv=Path('Sources/RGAdvancedEngine.swift')
a=adv.read_text()
append=r'''

struct RGExemplar: Codable {
    var kind: String
    var fingerprint: [Double]
    var duration: Double
    var sourcePath: String
    var start: Double
    var end: Double
    var createdAt: Double
}

final class RGLearningStore {
    private var exemplars: [RGExemplar] = []
    private let url: URL

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RG Sibilance Studio/Learning", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("good-exemplars.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([RGExemplar].self, from: data) { exemplars = decoded }
    }

    func add(_ exemplar: RGExemplar) {
        if exemplars.contains(where: { $0.sourcePath == exemplar.sourcePath && abs($0.start - exemplar.start) < 0.001 && $0.kind == exemplar.kind }) { return }
        exemplars.append(exemplar)
        if exemplars.count > 1200 { exemplars.removeFirst(exemplars.count - 1200) }
        if let data = try? JSONEncoder().encode(exemplars) { try? data.write(to: url, options: .atomic) }
    }

    func count(kind: String) -> Int { exemplars.filter { $0.kind == kind }.count }

    func best(kind: String, excludingPath: String?) -> RGExemplar? {
        var pool = exemplars.filter { $0.kind == kind }
        if let path = excludingPath { pool = pool.filter { $0.sourcePath != path } }
        if pool.isEmpty && ["Š","Č","CH","Z","C"].contains(kind) { pool = exemplars.filter { ["S","Š","Č","CH","Z","C"].contains($0.kind) } }
        return pool.sorted { $0.createdAt > $1.createdAt }.first
    }
}

enum RGAuditionMode: Equatable {
    case original, repair, delta, sibilanceOnly
    static func from(segment: Int) -> RGAuditionMode {
        switch segment { case 0: return .original; case 2: return .delta; case 3: return .sibilanceOnly; default: return .repair }
    }
    var displayName: String {
        switch self { case .original: return "ORIGINAL"; case .repair: return "REPAIR"; case .delta: return "DELTA"; case .sibilanceOnly: return "SIBILANCE ONLY" }
    }
}

extension RGRenderEngine {
    static func repairMix(time: Double, event: SibilanceEvent) -> Double {
        if time < event.start || time > event.end { return 0 }
        if event.fadeIn > 0, time < event.start + event.fadeIn {
            let x = min(1.0, max(0.0, (time - event.start) / event.fadeIn))
            return 0.5 - 0.5 * cos(Double.pi * x)
        }
        if event.fadeOut > 0, time > event.end - event.fadeOut {
            let x = min(1.0, max(0.0, (event.end - time) / event.fadeOut))
            return 0.5 - 0.5 * cos(Double.pi * x)
        }
        return 1
    }

    static func donorHF(event: SibilanceEvent, targetCount: Int, sampleRate: Double) -> [Float]? {
        guard event.repairMethod == "BLEND", let path = event.donorPath, let ds = event.donorStart, let de = event.donorEnd, de > ds, targetCount > 1 else { return nil }
        do {
            let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let sr = f.processingFormat.sampleRate
            let start = max(0, AVAudioFramePosition(ds * sr))
            let count = AVAudioFrameCount(max(2, Int((de - ds) * sr)))
            f.framePosition = min(start, f.length)
            guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: count) else { return nil }
            try f.read(into: b, frameCount: min(count, AVAudioFrameCount(max(0, f.length - f.framePosition))))
            guard let d = b.floatChannelData, b.frameLength > 1 else { return nil }
            let n = Int(b.frameLength)
            var mono = Array(repeating: Float(0), count: n)
            let cc = Int(b.format.channelCount)
            for i in 0..<n { var v: Float = 0; for ch in 0..<cc { v += d[ch][i] }; mono[i] = v / Float(max(1,cc)) }
            let alpha = Float(1.0 - exp(-2.0 * Double.pi * 2000.0 / sr))
            var lp: Float = 0
            var hf = Array(repeating: Float(0), count: n)
            var energy = 0.0
            for i in 0..<n { lp += alpha * (mono[i] - lp); hf[i] = mono[i] - lp; energy += Double(hf[i]*hf[i]) }
            let rms = max(1e-6, sqrt(energy / Double(n)))
            for i in hf.indices { hf[i] /= Float(rms) }
            var out = Array(repeating: Float(0), count: targetCount)
            for i in 0..<targetCount {
                let pos = Double(i) / Double(max(1,targetCount-1)) * Double(n-1)
                let i0 = min(n-1, Int(pos)); let i1 = min(n-1, i0+1); let f = Float(pos-Double(i0))
                out[i] = hf[i0]*(1-f)+hf[i1]*f
            }
            return out
        } catch { return nil }
    }

    static func processAdvanced(buffer: AVAudioPCMBuffer, absoluteStartTime: Double, events: [SibilanceEvent], typeTrims: [String: Double]) {
        guard let channels = buffer.floatChannelData else { return }
        let sr = buffer.format.sampleRate
        let n = Int(buffer.frameLength)
        let cc = Int(buffer.format.channelCount)
        let absoluteEnd = absoluteStartTime + Double(n)/sr
        let active = events.filter { $0.end > absoluteStartTime && $0.start < absoluteEnd }
        guard !active.isEmpty else { return }
        let edges=[2000.0,4000.0,7000.0,10000.0,14000.0,min(20000.0,sr*0.47)]
        let alpha=edges.map { 1.0-exp(-2.0*Double.pi*$0/sr) }

        for e in active {
            let start=max(0,min(n,Int(floor((e.start-absoluteStartTime)*sr))))
            let end=max(start,min(n,Int(ceil((e.end-absoluteStartTime)*sr))))
            guard end>start else { continue }
            let donor = donorHF(event:e,targetCount:end-start,sampleRate:sr)
            let blend = min(0.55,max(0,e.blendAmount ?? 0))
            let bandDB = (e.spectralDB?.count == 5 ? e.spectralDB! : Array(repeating:0.0,count:5))
            let totalDB=min(0.0,e.gainDB+(typeTrims[e.kind] ?? 0))
            let broadbandTarget=pow(10.0,totalDB/20.0)

            for ch in 0..<cc {
                var lp = Array(repeating:0.0,count:6)
                let pre=max(0,start-Int(sr*0.020))
                var hpLP=0.0
                let hpAlpha=alpha[0]
                var hfEnergy=0.0
                for i in pre..<end {
                    let x=Double(channels[ch][i]); hpLP += hpAlpha*(x-hpLP)
                    if i>=start { let h=x-hpLP; hfEnergy += h*h }
                }
                let targetHFRMS=max(1e-6,sqrt(hfEnergy/Double(max(1,end-start))))
                for i in pre..<end {
                    let x=Double(channels[ch][i])
                    for j in 0..<6 { lp[j]+=alpha[j]*(x-lp[j]) }
                    guard i>=start else { continue }
                    let time=absoluteStartTime+Double(i)/sr
                    let mix=repairMix(time:time,event:e)
                    let bands=[lp[1]-lp[0],lp[2]-lp[1],lp[3]-lp[2],lp[4]-lp[3],lp[5]-lp[4]]
                    var shaped=lp[0]+(x-lp[5])
                    for b in 0..<5 {
                        let tg=pow(10.0,bandDB[b]/20.0)
                        let g=1.0+(tg-1.0)*mix
                        shaped += bands[b]*g
                    }
                    let broad=1.0+(broadbandTarget-1.0)*mix
                    var y=shaped*broad
                    if let donor=donor, i-start<donor.count, blend>0 {
                        y += Double(donor[i-start])*targetHFRMS*blend*mix*0.72
                    }
                    channels[ch][i]=Float(y)
                }
            }
        }
    }

    static func renderAuditionMode(sourceURL: URL, events: [SibilanceEvent], typeTrims: [String: Double], startTime: Double, endTime: Double, mode: RGAuditionMode, levelMatched: Bool) throws -> URL {
        let input=try AVAudioFile(forReading:sourceURL); let format=input.processingFormat; let sr=format.sampleRate
        let duration=Double(input.length)/sr; let a=min(max(0,startTime),duration); let b=min(max(a+0.001,endTime),duration)
        let startFrame=AVAudioFramePosition(floor(a*sr)); let count=AVAudioFrameCount(max(1,Int(ceil((b-a)*sr))))
        input.framePosition=startFrame
        guard let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:count) else { throw NSError(domain:"RGAudition",code:10,userInfo:nil) }
        try input.read(into:buffer,frameCount:count)
        guard let data=buffer.floatChannelData else { throw NSError(domain:"RGAudition",code:11,userInfo:nil) }
        let n=Int(buffer.frameLength), cc=Int(format.channelCount)
        var original=Array(repeating:Array(repeating:Float(0),count:n),count:cc)
        var originalEnergy=0.0
        for ch in 0..<cc { for i in 0..<n { original[ch][i]=data[ch][i]; originalEnergy += Double(data[ch][i]*data[ch][i]) } }
        if mode != .original { processAdvanced(buffer:buffer,absoluteStartTime:a,events:events,typeTrims:typeTrims) }
        if mode == .delta {
            for ch in 0..<cc { for i in 0..<n { data[ch][i]=original[ch][i]-data[ch][i] } }
        } else if mode == .sibilanceOnly {
            for i in 0..<n {
                let t=a+Double(i)/sr
                let inside=events.contains { t >= $0.start && t <= $0.end }
                if !inside { for ch in 0..<cc { data[ch][i]=0 } }
            }
        } else if mode == .repair && levelMatched {
            var processedEnergy=0.0
            for ch in 0..<cc { for i in 0..<n { processedEnergy += Double(data[ch][i]*data[ch][i]) } }
            if processedEnergy>1e-12 {
                let g=min(1.25,max(0.8,sqrt(originalEnergy/processedEnergy)))
                for ch in 0..<cc { for i in 0..<n { data[ch][i]*=Float(g) } }
            }
        }
        let dir=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RG Sibilance Studio/Audition",isDirectory:true)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let out=dir.appendingPathComponent("audition-mode-\(UUID().uuidString).caf")
        let output=try AVAudioFile(forWriting:out,settings:format.settings,commonFormat:format.commonFormat,interleaved:format.isInterleaved)
        try output.write(from:buffer); return out
    }

    static func renderFullPreviewMode(sourceURL: URL, events: [SibilanceEvent], typeTrims: [String: Double], mode: RGAuditionMode, levelMatched: Bool) throws -> URL {
        let f=try AVAudioFile(forReading:sourceURL); let duration=Double(f.length)/f.processingFormat.sampleRate
        return try renderAuditionMode(sourceURL:sourceURL,events:events,typeTrims:typeTrims,startTime:0,endTime:duration,mode:mode,levelMatched:levelMatched)
    }
}
'''
# Replace old process body so export uses advanced spectral/donor engine too.
pat=r'    static func process\(buffer: AVAudioPCMBuffer,\n                        absoluteStartTime: Double,\n                        events: \[SibilanceEvent\],\n                        typeTrims: \[String: Double\],\n                        repaired: Bool\) \{.*?\n    \}\n\n    static func renderAudition'
rep='''    static func process(buffer: AVAudioPCMBuffer,\n                        absoluteStartTime: Double,\n                        events: [SibilanceEvent],\n                        typeTrims: [String: Double],\n                        repaired: Bool) {\n        guard repaired else { return }\n        processAdvanced(buffer: buffer, absoluteStartTime: absoluteStartTime, events: events, typeTrims: typeTrims)\n    }\n\n    static func renderAudition'''
a,n=re.subn(pat,rep,a,flags=re.S)
assert n==1,n
# append only once
assert 'final class RGLearningStore' not in a
a += append
adv.write_text(a)
