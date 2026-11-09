import AppKit
import Foundation

@MainActor
protocol DisplayConfigurationObserving: AnyObject {
    var onConfigurationChange: (() -> Void)? { get set }
}

@MainActor
final class SystemDisplayConfigurationObserver: DisplayConfigurationObserving {
    var onConfigurationChange: (() -> Void)?

    private let notificationCenter: NotificationCenter
    private var screenParametersObserver: NSObjectProtocol?
    private var isRegisteredForCGDisplayChanges = false

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        screenParametersObserver = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onConfigurationChange?()
            }
        }

        let registrationError = CGDisplayRegisterReconfigurationCallback(
            Self.displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if registrationError == .success {
            isRegisteredForCGDisplayChanges = true
        } else {
            AppLog.displayConfigurationObserver.error(
                "failed to register display reconfiguration callback: \(registrationError.rawValue)"
            )
        }
    }

    isolated deinit {
        if isRegisteredForCGDisplayChanges {
            CGDisplayRemoveReconfigurationCallback(
                Self.displayReconfigurationCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }

        if let screenParametersObserver {
            notificationCenter.removeObserver(screenParametersObserver)
        }
    }

    nonisolated private static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = {
        _, flags, userInfo in
        guard
            flags.contains(.beginConfigurationFlag)
                || flags.contains(.addFlag)
                || flags.contains(.removeFlag)
                || flags.contains(.setModeFlag)
                || flags.contains(.enabledFlag)
                || flags.contains(.disabledFlag),
            let userInfo
        else {
            return
        }

        let observer = Unmanaged<SystemDisplayConfigurationObserver>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        DispatchQueue.main.async { [weak observer] in
            observer?.onConfigurationChange?()
        }
    }
}
