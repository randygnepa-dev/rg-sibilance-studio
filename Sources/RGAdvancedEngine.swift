import Foundation
import AVFoundation

struct RGSpectralBands {
    let hopSamples: Int
    let sampleRate: Double
    let values: [[Float]]
}

enum RGSpectralAnalyzer {
    static func makeBands(samples: [Float], sampleRate: Double, hopSamples: Int = 512) -> RGSpectralBands {
        guard !samples.isEmpty, sampleRate > 0 else { return RGSpectralBands(hopSamples: hopSamples, sampleRate: sampleRate, values: []) }
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
                frames[i][b] = Float(min(1.0, max(0.0, (db + 48.0) / 48.0)))
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
        var mix = 1.0
        if event.fadeIn > 0, time < event.start + event.fadeIn {
            let x = min(1.0, max(0.0, (time - event.start) / event.fadeIn))
            let smooth = 0.5 - 0.5 * cos(Double.pi * x)
            mix = 1.0 + (target - 1.0) * smooth
        } else if event.fadeOut > 0, time > event.end - event.fadeOut {
            let x = min(1.0, max(0.0, (event.end - time) / event.fadeOut))
            let smooth = 0.5 - 0.5 * cos(Double.pi * x)
            mix = 1.0 + (target - 1.0) * smooth
        } else {
            mix = target
        }
        return Float(mix)
    }

    static func export(sourceURL: URL, events: [SibilanceEvent], typeTrims: [String: Double]) throws -> URL {
        let input = try AVAudioFile(forReading: sourceURL)
        let format = input.processingFormat
        let frameCount = AVAudioFrameCount(input.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "RGRender", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate export buffer"])
        }
        try input.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            throw NSError(domain: "RGRender", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported source audio format"])
        }
        let n = Int(buffer.frameLength)
        let sr = format.sampleRate
        let channelCount = Int(format.channelCount)

        for event in events {
            let start = max(0, min(n, Int(floor(event.start * sr))))
            let end = max(start, min(n, Int(ceil(event.end * sr))))
            guard end > start else { continue }
            let trim = typeTrims[event.kind] ?? 0
            for i in start..<end {
                let t = Double(i) / sr
                let g = gainAt(time: t, event: event, typeTrimDB: trim)
                for ch in 0..<channelCount { channels[ch][i] *= g }
            }
        }

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let outURL = sourceURL.deletingLastPathComponent().appendingPathComponent(stem + "-RG-SIB.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: channelCount,
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
