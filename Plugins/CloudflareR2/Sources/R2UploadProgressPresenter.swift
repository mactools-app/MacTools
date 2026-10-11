import AppKit
import Combine
import MacToolsPluginKit

enum R2UploadNameGenerator {
    private static let compoundArchiveExtensions = [
        ".tar.bz2", ".tar.gz", ".tar.lz", ".tar.lzma", ".tar.xz", ".tar.zst",
    ]

    static func randomFileName(
        preservingExtensionOf originalFileName: String,
        uuid: UUID = UUID()
    ) -> String {
        let stem = uuid.uuidString.lowercased()
        let lowercasedName = originalFileName.lowercased()
        if let compoundExtension = compoundArchiveExtensions.first(where: {
            lowercasedName.hasSuffix($0)
        }) {
            let suffix = originalFileName.suffix(compoundExtension.count)
            return "\(stem)\(suffix)"
        }
        let pathExtension = (originalFileName as NSString).pathExtension
        return pathExtension.isEmpty ? stem : "\(stem).\(pathExtension)"
    }
}

enum R2UploadConflictResolution: Equatable {
    case rename
    case overwrite
    case cancelled
}

@MainActor
protocol R2UploadProgressPresenting: AnyObject {
    func requestObjectName(fileName: String) async -> String?
    func requestConflictResolution(fileName: String) async -> R2UploadConflictResolution
    func beginProgress(fileName: String, onCancel: @escaping @MainActor () -> Void)
    func update(progress: Double)
    func dismiss()
}

@MainActor
final class R2UploadProgressPresenter: NSObject, R2UploadProgressPresenting {
    private let localization: PluginLocalization
    private var panel: NSPanel?
    private var nameField: NSTextField?
    private var validationLabel: NSTextField?
    private var progressIndicator: NSProgressIndicator?
    private var percentageLabel: NSTextField?
    private var cancelButton: NSButton?
    private var namingContinuation: CheckedContinuation<String?, Never>?
    private var conflictContinuation: CheckedContinuation<R2UploadConflictResolution, Never>?
    private var cancellationHandler: (@MainActor () -> Void)?
    private var originalFileName = ""
    private var currentProgress = 0.0
    private var localeSubscription: AnyCancellable?
    private var refreshContentLocalization: (@MainActor () -> Void)?

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
        super.init()
        localeSubscription = PluginRuntimeLocalization.source.$revision.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshPanelLocalization() }
        }
    }

    func requestObjectName(fileName: String) async -> String? {
        resolvePendingNaming(returning: nil)
        resolvePendingConflict(returning: .cancelled)
        originalFileName = fileName
        let panel = panel ?? makePanel()
        panel.setContentSize(NSSize(width: 460, height: 150))
        panel.contentView = makeNamingContentView(fileName: fileName)
        self.panel = panel
        show(panel)
        panel.makeFirstResponder(nameField)
        selectFileNameStem()

        return await withCheckedContinuation { continuation in
            namingContinuation = continuation
        }
    }

    func requestConflictResolution(fileName: String) async -> R2UploadConflictResolution {
        resolvePendingNaming(returning: nil)
        resolvePendingConflict(returning: .cancelled)
        let panel = panel ?? makePanel()
        panel.setContentSize(NSSize(width: 460, height: 112))
        panel.contentView = makeConflictContentView(fileName: fileName)
        self.panel = panel
        if !panel.isVisible {
            show(panel)
        }
        return await withCheckedContinuation { continuation in
            conflictContinuation = continuation
        }
    }

    func beginProgress(
        fileName: String,
        onCancel: @escaping @MainActor () -> Void
    ) {
        cancellationHandler = onCancel
        let panel = panel ?? makePanel()
        panel.setContentSize(NSSize(width: 460, height: 136))
        panel.contentView = makeProgressContentView(fileName: fileName)
        self.panel = panel
        if !panel.isVisible {
            show(panel)
        }
    }

    func update(progress: Double) {
        let clamped = min(1, max(0, progress))
        currentProgress = clamped
        progressIndicator?.doubleValue = clamped * 100
        refreshPercentage()
    }

    func dismiss() {
        resolvePendingNaming(returning: nil)
        resolvePendingConflict(returning: .cancelled)
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        nameField = nil
        validationLabel = nil
        progressIndicator = nil
        percentageLabel = nil
        cancelButton = nil
        cancellationHandler = nil
        originalFileName = ""
        currentProgress = 0
        refreshContentLocalization = nil
    }

    private func refreshPanelLocalization() {
        panel?.title = localization.string("metadata.title", defaultValue: "Cloudflare R2 上传")
        refreshContentLocalization?()
    }

    private func refreshPercentage() {
        percentageLabel?.stringValue = (floor(currentProgress * 100) / 100).formatted(
            .percent.precision(.fractionLength(0)).locale(PluginRuntimeLocalization.locale)
        )
    }

    private func resolvePendingNaming(returning value: String?) {
        guard let namingContinuation else { return }
        self.namingContinuation = nil
        namingContinuation.resume(returning: value)
    }

    private func resolvePendingConflict(returning value: R2UploadConflictResolution) {
        guard let conflictContinuation else { return }
        self.conflictContinuation = nil
        conflictContinuation.resume(returning: value)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 150),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = localization.string(
            "metadata.title",
            defaultValue: "Cloudflare R2 上传"
        )
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.center()
        return panel
    }

    private func show(_ panel: NSPanel) {
        PluginPresentationSafety.prepareForWindowOrdering()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makeNamingContentView(fileName: String) -> NSView {
        let contentView = NSView()

        let promptLabel = NSTextField(labelWithString: localization.string(
            "upload.naming.fileName",
            defaultValue: "文件名"
        ))
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        promptLabel.font = PluginTypography.control.nsFont
        promptLabel.textColor = .secondaryLabelColor

        let nameField = NSTextField(string: fileName)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = PluginTypography.body.nsFont
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.placeholderString = localization.string(
            "upload.naming.placeholder",
            defaultValue: "输入上传后的文件名"
        )
        nameField.target = self
        nameField.action = #selector(confirmUpload)

        let randomButton = NSButton(
            image: NSImage(
                systemSymbolName: "dice",
                accessibilityDescription: localization.string(
                    "upload.naming.random.accessibility",
                    defaultValue: "生成随机文件名"
                )
            ) ?? NSImage(),
            target: self,
            action: #selector(generateRandomName)
        )
        randomButton.translatesAutoresizingMaskIntoConstraints = false
        randomButton.bezelStyle = .rounded
        randomButton.imagePosition = .imageOnly
        randomButton.toolTip = localization.string(
            "upload.naming.random.help",
            defaultValue: "生成随机 UUID 文件名（保留扩展名）"
        )

        let validationLabel = NSTextField(labelWithString: "")
        validationLabel.translatesAutoresizingMaskIntoConstraints = false
        validationLabel.font = PluginTypography.detail.nsFont
        validationLabel.textColor = .systemRed

        let cancelButton = NSButton(
            title: localization.string("common.cancel", defaultValue: "取消"),
            target: self,
            action: #selector(cancelNaming)
        )
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let uploadButton = NSButton(
            title: localization.string(
                "upload.naming.start",
                defaultValue: "开始上传"
            ),
            target: self,
            action: #selector(confirmUpload)
        )
        uploadButton.translatesAutoresizingMaskIntoConstraints = false
        uploadButton.bezelStyle = .rounded
        uploadButton.keyEquivalent = "\r"

        [promptLabel, nameField, randomButton, validationLabel, cancelButton, uploadButton]
            .forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            promptLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            promptLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            nameField.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 7),
            nameField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            nameField.trailingAnchor.constraint(equalTo: randomButton.leadingAnchor, constant: -8),
            nameField.heightAnchor.constraint(equalToConstant: 26),

            randomButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            randomButton.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            randomButton.widthAnchor.constraint(equalToConstant: 32),

            validationLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 4),
            validationLabel.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            validationLabel.trailingAnchor.constraint(equalTo: randomButton.trailingAnchor),

            uploadButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            uploadButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            cancelButton.trailingAnchor.constraint(equalTo: uploadButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: uploadButton.centerYAnchor),
        ])

        self.nameField = nameField
        self.validationLabel = validationLabel
        refreshContentLocalization = { [weak self] in
            guard let self else { return }
            promptLabel.stringValue = localization.string("upload.naming.fileName", defaultValue: "文件名")
            nameField.placeholderString = localization.string("upload.naming.placeholder", defaultValue: "输入上传后的文件名")
            let randomLabel = localization.string("upload.naming.random.accessibility", defaultValue: "生成随机文件名")
            randomButton.image = NSImage(systemSymbolName: "dice", accessibilityDescription: randomLabel)
            randomButton.setAccessibilityLabel(randomLabel)
            randomButton.toolTip = localization.string("upload.naming.random.help", defaultValue: "生成随机 UUID 文件名（保留扩展名）")
            cancelButton.title = localization.string("common.cancel", defaultValue: "取消")
            uploadButton.title = localization.string("upload.naming.start", defaultValue: "开始上传")
            if !validationLabel.stringValue.isEmpty {
                validationLabel.stringValue = localization.string("upload.naming.validation", defaultValue: "请输入不包含 / 的有效文件名。")
            }
        }
        return contentView
    }

    private func makeProgressContentView(fileName: String) -> NSView {
        let contentView = NSView()

        let fileLabel = NSTextField(labelWithString: fileName)
        fileLabel.translatesAutoresizingMaskIntoConstraints = false
        fileLabel.font = PluginTypography.body.nsFont
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.maximumNumberOfLines = 1

        let progressIndicator = NSProgressIndicator()
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100

        let percentageLabel = NSTextField(labelWithString: "0%")
        percentageLabel.translatesAutoresizingMaskIntoConstraints = false
        percentageLabel.font = PluginTypography.value.nsFont
        percentageLabel.alignment = .right

        let cancelButton = NSButton(
            title: localization.string(
                "common.cancelUpload",
                defaultValue: "取消上传"
            ),
            target: self,
            action: #selector(cancelUpload)
        )
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        [fileLabel, progressIndicator, percentageLabel, cancelButton]
            .forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            fileLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            fileLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            fileLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            progressIndicator.topAnchor.constraint(equalTo: fileLabel.bottomAnchor, constant: 16),
            progressIndicator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            progressIndicator.trailingAnchor.constraint(equalTo: percentageLabel.leadingAnchor, constant: -10),
            progressIndicator.centerYAnchor.constraint(equalTo: percentageLabel.centerYAnchor),

            percentageLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            percentageLabel.widthAnchor.constraint(equalToConstant: 42),

            cancelButton.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 16),
            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
        ])

        self.progressIndicator = progressIndicator
        self.percentageLabel = percentageLabel
        self.cancelButton = cancelButton
        currentProgress = 0
        refreshPercentage()
        refreshContentLocalization = { [weak self] in
            guard let self else { return }
            cancelButton.title = localization.string("common.cancelUpload", defaultValue: "取消上传")
            refreshPercentage()
        }
        return contentView
    }

    private func makeConflictContentView(fileName: String) -> NSView {
        let contentView = NSView()

        let titleLabel = NSTextField(labelWithString: localization.format(
            "upload.conflict.title",
            defaultValue: "“%@” 已存在",
            fileName
        ))
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = PluginTypography.sectionTitle.nsFont
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1

        let detailLabel = NSTextField(labelWithString: localization.string(
            "upload.conflict.detail",
            defaultValue: "覆盖上传会替换 R2 中的现有对象。"
        ))
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = PluginTypography.detail.nsFont
        detailLabel.textColor = .secondaryLabelColor

        let renameButton = NSButton(
            title: localization.string(
                "upload.conflict.rename",
                defaultValue: "重新命名"
            ),
            target: self,
            action: #selector(resolveConflictByRenaming)
        )
        renameButton.translatesAutoresizingMaskIntoConstraints = false
        renameButton.bezelStyle = .rounded
        renameButton.keyEquivalent = "\r"

        let cancelButton = NSButton(
            title: localization.string("common.cancel", defaultValue: "取消"),
            target: self,
            action: #selector(cancelConflict)
        )
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let overwriteButton = NSButton(
            title: localization.string(
                "upload.conflict.overwrite",
                defaultValue: "覆盖上传"
            ),
            target: self,
            action: #selector(resolveConflictByOverwriting)
        )
        overwriteButton.translatesAutoresizingMaskIntoConstraints = false
        overwriteButton.bezelStyle = .rounded

        [titleLabel, detailLabel, cancelButton, renameButton, overwriteButton]
            .forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            overwriteButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            overwriteButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            renameButton.trailingAnchor.constraint(equalTo: overwriteButton.leadingAnchor, constant: -8),
            renameButton.centerYAnchor.constraint(equalTo: overwriteButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: renameButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: overwriteButton.centerYAnchor),
        ])
        refreshContentLocalization = { [weak self] in
            guard let self else { return }
            titleLabel.stringValue = localization.format("upload.conflict.title", defaultValue: "“%@” 已存在", fileName)
            detailLabel.stringValue = localization.string("upload.conflict.detail", defaultValue: "覆盖上传会替换 R2 中的现有对象。")
            renameButton.title = localization.string("upload.conflict.rename", defaultValue: "重新命名")
            cancelButton.title = localization.string("common.cancel", defaultValue: "取消")
            overwriteButton.title = localization.string("upload.conflict.overwrite", defaultValue: "覆盖上传")
        }
        return contentView
    }

    @objc private func generateRandomName() {
        nameField?.stringValue = R2UploadNameGenerator.randomFileName(
            preservingExtensionOf: originalFileName
        )
        validationLabel?.stringValue = ""
        selectFileNameStem()
    }

    private func selectFileNameStem() {
        guard let nameField,
              let editor = nameField.currentEditor()
        else { return }
        let fileName = nameField.stringValue as NSString
        let extensionLength = fileName.pathExtension.isEmpty
            ? 0
            : fileName.pathExtension.utf16.count + 1
        editor.selectedRange = NSRange(
            location: 0,
            length: max(0, fileName.length - extensionLength)
        )
    }

    @objc private func confirmUpload() {
        let value = nameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard R2ObjectNameValidator.isValid(value) else {
            validationLabel?.stringValue = localization.string(
                "upload.naming.validation",
                defaultValue: "请输入不包含 / 的有效文件名。"
            )
            NSSound.beep()
            return
        }
        guard let namingContinuation else { return }
        self.namingContinuation = nil
        namingContinuation.resume(returning: value)
    }

    @objc private func cancelNaming() {
        guard let namingContinuation else { return }
        self.namingContinuation = nil
        namingContinuation.resume(returning: nil)
        dismiss()
    }

    @objc private func cancelUpload() {
        cancelButton?.isEnabled = false
        cancellationHandler?()
    }

    @objc private func resolveConflictByRenaming() {
        resolvePendingConflict(returning: .rename)
    }

    @objc private func cancelConflict() {
        resolvePendingConflict(returning: .cancelled)
    }

    @objc private func resolveConflictByOverwriting() {
        resolvePendingConflict(returning: .overwrite)
    }
}
