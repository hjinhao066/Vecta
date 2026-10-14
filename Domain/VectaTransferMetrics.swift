import Foundation

/// Runtime measurements belong to a single SDK export, never to a persisted
/// `.copying` row. The SDK uses 0–99 for transfer and 100 for local conversion.
struct VectaTransferProgress: Equatable {
    enum Phase: Equatable { case preparing, transferring, waitingForData, converting }
    let phase: Phase
    let fraction: Double?
    let bytesPerSecond: Double?
    let speedIsEstimated: Bool
    let remainingSeconds: TimeInterval?

    var percent: Int? { fraction.map { Int(($0 * 100).rounded()) } }
    var statusText: String {
        switch phase {
        case .preparing: return VL.text("Готовим копирование…")
        case .transferring: return VL.text("Копируем · \(percent ?? 0)%")
        case .waitingForData: return VL.text("Ожидаем данные диктофона")
        case .converting: return VL.text("Сохраняем аудио на Mac…")
        }
    }
    var speedText: String {
        guard let rate = bytesPerSecond, rate.isFinite, rate > 0 else { return VL.text("Скорость: —") }
        let amount = rate >= 1_048_576 ? rate / 1_048_576 : rate / 1024
        let unit = rate >= 1_048_576 ? VL.text("МБ/с") : VL.text("КБ/с")
        let number = String(format: "%.1f", locale: Locale(identifier: "ru_RU"), amount)
        return "\(speedIsEstimated ? "≈ " : "")\(number) \(unit)"
    }
    var remainingText: String {
        guard let remaining = remainingSeconds, remaining.isFinite, remaining >= 0 else {
            return phase == .converting ? VL.text("Завершаем обработку файла") : VL.text("Осталось: —")
        }
        if remaining > 86_400 { return VL.text("Осталось ≈ больше суток") }
        let seconds = Int(remaining.rounded(.up))
        if seconds < 60 { return VL.text("Осталось ≈ \(max(1, seconds)) сек") }
        if seconds < 3600 { return VL.text("Осталось ≈ \((seconds + 59) / 60) мин") }
        let minutes = (seconds + 59) / 60
        return VL.text("Осталось ≈ \(minutes / 60) ч \(minutes % 60) мин")
    }
}

struct VectaTransferMetrics {
    private let sourceByteCount: Double?
    private var fraction: Double?
    private var lastAdvancementTime: TimeInterval
    private var lastSampleTime: TimeInterval?
    private var lastSampleFraction: Double?
    private var bytesPerSecond: Double?
    private var speedIsEstimated = false
    private var converting = false

    init(sourceByteCount: Int, startedAt: TimeInterval) {
        self.sourceByteCount = sourceByteCount > 0 ? Double(sourceByteCount) : nil
        lastAdvancementTime = startedAt
    }

    mutating func observe(percent: Int, sdkBytesPerSecond: Double?, at time: TimeInterval) {
        guard (0...100).contains(percent), time.isFinite, time >= lastAdvancementTime, !converting else { return }
        if percent == 100 {
            converting = true
            bytesPerSecond = nil
            return
        }
        let next = Double(percent) / 100
        guard fraction.map({ next >= $0 }) ?? true else { return }
        if fraction == nil || next > fraction! { lastAdvancementTime = time }
        if let reported = sdkBytesPerSecond, reported.isFinite, reported > 0 {
            bytesPerSecond = reported
            speedIsEstimated = false
        } else if let total = sourceByteCount, let previous = lastSampleFraction,
                  let previousTime = lastSampleTime, time - previousTime >= 2,
                  next > previous {
            bytesPerSecond = total * (next - previous) / (time - previousTime)
            speedIsEstimated = true
        }
        if lastSampleTime == nil || (time - lastSampleTime! >= 2 && next > (lastSampleFraction ?? -1)) {
            lastSampleTime = time
            lastSampleFraction = next
        }
        fraction = next
    }

    func snapshot(at time: TimeInterval) -> VectaTransferProgress {
        if converting {
            return VectaTransferProgress(phase: .converting, fraction: fraction, bytesPerSecond: nil,
                                        speedIsEstimated: false, remainingSeconds: nil)
        }
        let stalled = time - lastAdvancementTime > 15
        let rate = stalled ? nil : bytesPerSecond
        let remaining: TimeInterval?
        if let total = sourceByteCount, let fraction, let rate, rate > 0 {
            remaining = total * (1 - fraction) / rate
        } else { remaining = nil }
        return VectaTransferProgress(phase: stalled ? .waitingForData : (fraction == nil ? .preparing : .transferring),
                                    fraction: fraction, bytesPerSecond: rate,
                                    speedIsEstimated: speedIsEstimated, remainingSeconds: remaining)
    }
}
