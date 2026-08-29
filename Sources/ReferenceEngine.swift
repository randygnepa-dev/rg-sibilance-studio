import Foundation

struct RGReferenceCandidate {
    let id: UUID
    let fingerprint: RGEventFingerprint
    let quality: Double
    let source: String
}

struct RGReferenceMatch {
    let candidate: RGReferenceCandidate
    let similarity: Double
    let influence: Double
}

final class RGReferenceEngine {
    func rankSelfReferences(
        target: RGEventFingerprint,
        candidates: [RGReferenceCandidate],
        maximum: Int = 8
    ) -> [RGReferenceMatch] {
        candidates
            .filter { $0.quality >= 0.55 && $0.fingerprint.phoneme == target.phoneme }
            .map { candidate in
                let similarity = max(0, 1 - normalizedDistance(target, candidate.fingerprint))
                let influence = min(0.85, max(0.15, similarity * candidate.quality))
                return RGReferenceMatch(candidate: candidate, similarity: similarity, influence: influence)
            }
            .sorted { ($0.similarity * $0.candidate.quality) > ($1.similarity * $1.candidate.quality) }
            .prefix(maximum)
            .map { $0 }
    }

    private func normalizedDistance(_ a: RGEventFingerprint, _ b: RGEventFingerprint) -> Double {
        let dDuration = min(1, abs(a.duration - b.duration) / 0.25)
        let dSeverity = abs(a.severity - b.severity)
        let dBrightness = abs(a.brightness - b.brightness)
        let dSharpness = abs(a.sharpness - b.sharpness)
        let dWhistle = abs(a.whistle - b.whistle)
        let dLevel = min(1, abs(a.level - b.level) / 12.0)
        let dContext = min(1, abs(a.contextLevel - b.contextLevel) / 12.0)
        return min(1, (dDuration * 0.16 + dSeverity * 0.14 + dBrightness * 0.17 + dSharpness * 0.17 + dWhistle * 0.18 + dLevel * 0.08 + dContext * 0.10))
    }
}
