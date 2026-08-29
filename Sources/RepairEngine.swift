import Foundation

struct RGRepairEnvelope {
    let startSample: Int
    let endSample: Int
    let gain: Float
}

enum RGRepairMode: String, Codable {
    case none
    case gain
    case spectralLevel
    case spectralShape
}

struct RGRepairCandidate {
    let mode: RGRepairMode
    let strength: Double
    let score: Double
    let artifactRisk: Double
}

final class RGRepairEngine {
    func recommendedMode(severity: Double, whistle: Double) -> RGRepairMode {
        if severity < 0.30 { return .none }
        if whistle > 0.65 { return .spectralShape }
        if severity < 0.62 { return .gain }
        return .spectralLevel
    }

    func makeGainEnvelope(
        start: Double,
        end: Double,
        sampleRate: Double,
        strength: Double,
        sampleCount: Int
    ) -> RGRepairEnvelope {
        let s = max(0, min(sampleCount - 1, Int(start * sampleRate)))
        let e = max(s + 1, min(sampleCount, Int(end * sampleRate)))
        let clamped = min(1.0, max(0.0, strength))
        let attenuationDB = -8.0 * clamped
        let linear = Float(pow(10.0, attenuationDB / 20.0))
        return RGRepairEnvelope(startSample: s, endSample: e, gain: linear)
    }

    func applyGainRepair(
        samples: [Float],
        envelope: RGRepairEnvelope,
        fadeSamples: Int = 192
    ) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var output = samples
        let start = max(0, min(samples.count - 1, envelope.startSample))
        let end = max(start + 1, min(samples.count, envelope.endSample))
        let fade = max(1, fadeSamples)

        for i in start..<end {
            let inPos = Double(i - start) / Double(fade)
            let outPos = Double(end - i - 1) / Double(fade)
            let edge = min(1.0, max(0.0, min(inPos, outPos)))
            let smooth = edge * edge * (3.0 - 2.0 * edge)
            let gain = 1.0 + (Double(envelope.gain) - 1.0) * smooth
            output[i] *= Float(gain)
        }
        return output
    }

    func candidateSet(severity: Double, whistle: Double, strength: Double) -> [RGRepairCandidate] {
        let preferred = recommendedMode(severity: severity, whistle: whistle)
        var result = [RGRepairCandidate(mode: .none, strength: 0, score: max(0, 1 - severity), artifactRisk: 0)]
        result.append(RGRepairCandidate(mode: .gain, strength: strength, score: 0.72 + 0.15 * (1 - whistle), artifactRisk: 0.08 + strength * 0.08))
        result.append(RGRepairCandidate(mode: .spectralLevel, strength: strength, score: 0.75 + 0.10 * severity, artifactRisk: 0.12 + strength * 0.10))
        result.append(RGRepairCandidate(mode: .spectralShape, strength: strength, score: preferred == .spectralShape ? 0.92 : 0.72, artifactRisk: 0.16 + strength * 0.12))
        return result.sorted { ($0.score - $0.artifactRisk) > ($1.score - $1.artifactRisk) }
    }
}
