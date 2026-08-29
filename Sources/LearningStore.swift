import Foundation

enum RGEventUserLabel: String, Codable {
    case good = "GOOD"
    case bad = "BAD"
    case normal = "NORMAL"
    case target = "TARGET"
}

struct RGEventFingerprint: Codable {
    let phoneme: String
    let duration: Double
    let severity: Double
    let brightness: Double
    let sharpness: Double
    let whistle: Double
    let level: Double
    let contextLevel: Double
}

struct RGLearnedEvent: Codable {
    let id: UUID
    let label: RGEventUserLabel
    let fingerprint: RGEventFingerprint
    let acceptedRepairMode: String?
    let acceptedRepairStrength: Double?
    let createdAt: Date
}

final class RGLearningStore {
    private(set) var events: [RGLearnedEvent] = []

    func add(
        label: RGEventUserLabel,
        fingerprint: RGEventFingerprint,
        repairMode: String? = nil,
        repairStrength: Double? = nil
    ) {
        events.append(RGLearnedEvent(
            id: UUID(),
            label: label,
            fingerprint: fingerprint,
            acceptedRepairMode: repairMode,
            acceptedRepairStrength: repairStrength,
            createdAt: Date()
        ))
    }

    func goodExamples(phoneme: String? = nil) -> [RGLearnedEvent] {
        events.filter { item in
            item.label == .good && (phoneme == nil || item.fingerprint.phoneme == phoneme)
        }
    }

    func nearestGood(to target: RGEventFingerprint) -> RGLearnedEvent? {
        goodExamples(phoneme: target.phoneme).min { a, b in
            distance(a.fingerprint, target) < distance(b.fingerprint, target)
        }
    }

    private func distance(_ a: RGEventFingerprint, _ b: RGEventFingerprint) -> Double {
        let values = [
            (a.duration - b.duration) * 2.0,
            a.severity - b.severity,
            a.brightness - b.brightness,
            a.sharpness - b.sharpness,
            (a.whistle - b.whistle) * 1.4,
            (a.level - b.level) * 0.5,
            (a.contextLevel - b.contextLevel) * 0.5
        ]
        return sqrt(values.reduce(0) { $0 + $1 * $1 })
    }
}
