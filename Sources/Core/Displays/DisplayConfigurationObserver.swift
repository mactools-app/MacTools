import AppKit
import Foundation
import MacToolsPluginKit

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
            DisplayDDCIdentity.invalidateBindings()
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
        guard !flags.isEmpty, let userInfo else { return }
        DisplayDDCIdentity.invalidateBindings()

        let observer = Unmanaged<SystemDisplayConfigurationObserver>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        DispatchQueue.main.async { [weak observer] in
            observer?.onConfigurationChange?()
        }
    }
}
