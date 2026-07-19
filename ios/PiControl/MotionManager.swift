import CoreMotion
import UIKit

/// Streams the phone's fused gyro+accelerometer attitude into
/// ControllerState while the controller screen is up. CoreMotion does the
/// sensor fusion (CMDeviceMotion); we just forward pitch/roll/yaw radians.
///
/// Uses `.xArbitraryZVertical`: pitch and roll are gravity-referenced and
/// drift-free, yaw is relative to an arbitrary start heading (no
/// magnetometer, so no compass permission or calibration wobble). Receivers
/// steer with *changes* in attitude, so an arbitrary yaw zero is fine.
@MainActor
final class MotionManager {
    private let motion = CMMotionManager()
    private let state: ControllerState

    init(state: ControllerState) {
        self.state = state
    }

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical,
                                        to: .main) { [weak self] deviceMotion, _ in
            guard let self, let attitude = deviceMotion?.attitude else { return }
            MainActor.assumeIsolated {
                self.apply(attitude)
            }
        }
    }

    /// CoreMotion's attitude is in the hardware (portrait) device frame; the
    /// two landscape orientations differ by a 180° flip of that frame, so
    /// without correction the same physical tilt relative to the screen
    /// changes sign when the UI rotates. Normalize to the current interface
    /// orientation (exact transform for a 180° z-flip: negate pitch/roll,
    /// offset yaw by π) so gestures are consistent in both landscapes.
    private func apply(_ attitude: CMAttitude) {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation ?? .landscapeRight
        if orientation == .landscapeLeft {
            state.pitch = -attitude.pitch
            state.roll = -attitude.roll
            state.yaw = attitude.yaw > 0 ? attitude.yaw - .pi : attitude.yaw + .pi
        } else {
            state.pitch = attitude.pitch
            state.roll = attitude.roll
            state.yaw = attitude.yaw
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        state.pitch = 0
        state.roll = 0
        state.yaw = 0
    }
}
