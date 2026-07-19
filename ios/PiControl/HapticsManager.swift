import CoreHaptics
import Foundation

/// Drives the phone's vibration from receiver haptics commands, like a
/// console driving controller rumble. A looping continuous haptic plays
/// while intensity is nonzero; intensity/sharpness changes are applied
/// live via dynamic parameters rather than restarting the pattern.
@MainActor
final class HapticsManager {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?

    nonisolated init() {}

    func set(intensity: Double, sharpness: Double) {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        guard intensity > 0 else {
            stop()
            return
        }
        do {
            try ensureRunningPlayer()
            try player?.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                         value: Float(intensity), relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl,
                                         value: Float(sharpness), relativeTime: 0),
            ], atTime: CHHapticTimeImmediate)
        } catch {
            // Engine can die in the background; drop it and let the next
            // command rebuild from scratch.
            engine = nil
            player = nil
        }
    }

    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
    }

    private func ensureRunningPlayer() throws {
        if engine == nil {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            // If the system stops us (background, interruption), rebuild
            // lazily on the next command.
            engine.stoppedHandler = { [weak self] _ in
                Task { @MainActor in
                    self?.engine = nil
                    self?.player = nil
                }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor in
                    self?.engine = nil
                    self?.player = nil
                }
            }
            self.engine = engine
        }
        guard let engine else { return }

        if player == nil {
            try engine.start()
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                ],
                relativeTime: 0,
                duration: 1.0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            player.loopEnabled = true
            try player.start(atTime: CHHapticTimeImmediate)
            self.player = player
        }
    }
}
