import Foundation
import AVFoundation

struct RGSpectralBands {
    let hopSamples: Int
    let sampleRate: Double
    let values: [[Float]]
}

enum RGSpectralAnalyzer {
    static func makeBands(samples: [Float], sampleRate: Double, hopSamples: Int = 256) -> RGSpectralBands {
        guard !samples.isEmpty, sampleRate > 0 else {
            return RGSpectralBands(hopSamples: hopSamples, sampleRate: sampleRate, values: [])
        }
        let edges = [2000.0, 4000.0, 7000.0, 10000.0, 14000.0, min(20000.0, sampleRate * 0.47)]
        let alpha = edges.map { 1.0 - exp(-2.0 * Double.pi * $0 / sampleRate) }
        var lp = Array(repeating: 0.0, count: edges.count)
        var energy = Array(repeating: 0.0, count: 5)
        var frames: [[Float]] = []
        frames.reserveCapacity(max(1, samples.count / hopSamples + 1))
        var count = 0
        var maxima = Array(repeating: 1e-12, count: 5)

        for x0 in samples {
            let x = Double(x0)
            for j in 0..<lp.count { lp[j] += alpha[j] * (x - lp[j]) }
            let bands = [lp[1] - lp[0], lp[2] - lp[1], lp[3] - lp[2], lp[4] - lp[3], lp[5] - lp[4]]
            for b in 0..<5 { energy[b] += bands[b] * bands[b] }
            count += 1
            if count >= hopSamples {
                var frame = Array(repeating: Float(0), count: 5)
                for b in 0..<5 {
                    let rms = sqrt(energy[b] / Double(count))
                    maxima[b] = max(maxima[b], rms)
                    frame[b] = Float(rms)
                    energy[b] = 0
                }
                frames.append(frame)
                count = 0
            }
        }
        if count > 0 {
            var frame = Array(repeating: Float(0), count: 5)
            for b in 0..<5 {
                let rms = sqrt(energy[b] / Double(count))
                maxima[b] = max(maxima[b], rms)
                frame[b] = Float(rms)
            }
            frames.append(frame)
        }

        for i in frames.indices {
            for b in 0..<5 {
                let ratio = max(1e-8, Double(frames[i][b]) / maxima[b])
                let db = 20.0 * log10(ratio)
                frames[i][b] = Float(min(1.0, max(0.0, (db + 54.0) / 54.0)))
            }
        }
        return RGSpectralBands(hopSamples: hopSamples, sampleRate: sampleRate, values: frames)
    }
}

enum RGRepairAdvisor {
    static func recommendedGain(for event: SibilanceEvent) -> Double {
        if event.userLabel == "GOOD" { return 0 }
        if event.userLabel == "BAD" { return -6.0 }
        let normalized = min(1.0, max(0.0, (event.score - 0.65) / 1.6))
        return -(2.0 + normalized * 5.0)
    }

    static func qualityText(for event: SibilanceEvent) -> String {
        let intervention = abs(event.gainDB)
        let artifact: Int
        if intervention <= 3 { artifact = 8 }
        else if intervention <= 6 { artifact = 18 }
        else if intervention <= 10 { artifact = 34 }
        else { artifact = 55 }
        let confidence = Int(min(99.0, max(45.0, 62.0 + event.score * 16.0)))
        return "Repair confidence \(confidence)%   •   artifact risk \(artifact)%"
    }
}

enum RGRenderEngine {
    static func gainAt(time: Double, event: SibilanceEvent, typeTrimDB: Double) -> Float {
        let totalDB = min(0.0, event.gainDB + typeTrimDB)
        let target = pow(10.0, totalDB / 20.0)
        if event.fadeIn > 0, time < event.start + event.fadeIn {
            let x = min(1.0, max(0.0, (time - event.start) / event.fadeIn))
            let smooth = 0.5 - 0.5 * cos(Double.pi * x)
            return Float(1.0 + (target - 1.0) * smooth)
        }
        if event.fadeOut > 0, time > event.end - event.fadeOut {
            let x = min(1.0, max(0.0, (event.end - time) / event.fadeOut))
            let smooth = 0.5 - 0.5 * cos(Double.pi * x)
            return Float(1.0 + (target - 1.0) * smooth)
        }
        return Float(target)
    }

    static func process(buffer: AVAudioPCMBuffer,
                        absoluteStartTime: Double,
                        events: [SibilanceEvent],
                        typeTrims: [String: Double],
                        repaired: Bool) {
        guard repaired else { return }
        processAdvanced(buffer: buffer, absoluteStartTime: absoluteStartTime, events: events, typeTrims: typeTrims)
    }

    static func renderAudition(sourceURL: URL,
                               events: [SibilanceEvent],
                               typeTrims: [String: Double],
                               startTime: Double,
                               endTime: Double,
                               repaired: Bool) throws -> URL {
        let input = try AVAudioFile(forReading: sourceURL)
        let format = input.processingFormat
        let sr = format.sampleRate
        let duration = Double(input.length) / sr
        let safeStart = min(max(0, startTime), duration)
        let safeEnd = min(max(safeStart + 0.001, endTime), duration)
        let startFrame = AVAudioFramePosition(floor(safeStart * sr))
        let frameCount64 = max(1, AVAudioFramePosition(ceil((safeEnd - safeStart) * sr)))
        let frameCount = AVAudioFrameCount(min(Int64(UInt32.max), frameCount64))

        input.framePosition = startFrame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "RGAudition", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate audition buffer"])
        }
        try input.read(into: buffer, frameCount: frameCount)
        process(buffer: buffer, absoluteStartTime: safeStart, events: events, typeTrims: typeTrims, repaired: repaired)

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RG Sibilance Studio/Audition", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("audition-\(UUID().uuidString).caf")
        let output = try AVAudioFile(forWriting: out, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        try output.write(from: buffer)
        return out
    }

    static func renderFullPreview(sourceURL: URL,
                                  events: [SibilanceEvent],
                                  typeTrims: [String: Double],
                                  repaired: Bool) throws -> URL {
        let input = try AVAudioFile(forReading: sourceURL)
        let duration = Double(input.length) / input.processingFormat.sampleRate
        return try renderAudition(sourceURL: sourceURL, events: events, typeTrims: typeTrims, startTime: 0, endTime: duration, repaired: repaired)
    }

    static func export(sourceURL: URL, events: [SibilanceEvent], typeTrims: [String: Double]) throws -> URL {
        let input = try AVAudioFile(forReading: sourceURL)
        let format = input.processingFormat
        let frameCount = AVAudioFrameCount(input.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "RGRender", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate export buffer"])
        }
        try input.read(into: buffer)
        process(buffer: buffer, absoluteStartTime: 0, events: events, typeTrims: typeTrims, repaired: true)

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let outURL = sourceURL.deletingLastPathComponent().appendingPathComponent(stem + "-RG-SIB.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        try? FileManager.default.removeItem(at: outURL)
        let output = try AVAudioFile(forWriting: outURL, settings: settings)
        try output.write(from: buffer)
        return outURL
    }
}


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
