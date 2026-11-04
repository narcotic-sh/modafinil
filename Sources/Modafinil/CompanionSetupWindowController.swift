import AppKit
import CoreImage
import ModafinilRemoteProtocol

protocol CompanionSetupWindowControllerDelegate: AnyObject {
    func companionSetupWindowControllerDidClose(
        _ windowController: CompanionSetupWindowController
    )
}

final class CompanionSetupWindowController: NSWindowController, NSWindowDelegate {
    weak var setupDelegate: CompanionSetupWindowControllerDelegate?

    init(configurationStore: CompanionConfigurationStore) {
        let windowSize = NSSize(width: 820, height: 420)
        let viewController = CompanionSetupViewController(
            configurationStore: configurationStore
        )
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: windowSize
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Modafinil Companion Setup"
        window.contentViewController = viewController
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = windowSize
        window.contentMaxSize = windowSize

        super.init(window: window)

        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func refresh() {
        (window?.contentViewController as? CompanionSetupViewController)?.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        setupDelegate?.companionSetupWindowControllerDidClose(self)
    }
}

private final class CompanionSetupViewController: NSViewController {
    private let configurationStore: CompanionConfigurationStore
    private var networkInformation: CompanionNetworkInformation
    private let qrImageView = NSImageView()
    private let macHostField = NSTextField()
    private let relayHostField = NSTextField()
    private let relayPortField = NSTextField()
    private let targetMACsField = NSTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var pairingLink: String?
    private let copyButton = NSButton(
        title: "Copy Pairing Link",
        target: nil,
        action: nil
    )

    init(configurationStore: CompanionConfigurationStore) {
        self.configurationStore = configurationStore
        networkInformation = .discover()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let view = NSView(
            frame: NSRect(origin: .zero, size: NSSize(width: 820, height: 420))
        )
        self.view = view

        let content = NSStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.distribution = .fill
        content.spacing = 12
        view.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20)
        ])

        let title = NSTextField(labelWithString: "Pair an iPhone")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        content.addArrangedSubview(title)

        let explanation = NSTextField(
            wrappingLabelWithString: """
            Configure the wake relay (the iPad at home), then scan the private QR code \
            in Modafinil Companion on your iPhone. To wake a second Mac with the same \
            relay, copy the relay secret on the first Mac and paste it here.
            """
        )
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 0
        explanation.preferredMaxLayoutWidth = 772
        content.addArrangedSubview(explanation)

        content.addArrangedSubview(makeSeparator())

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.distribution = .fill
        form.spacing = 10

        form.addArrangedSubview(
            makeRow(title: "Mac Tailscale IP", field: macHostField)
        )
        macHostField.isEditable = false
        macHostField.isSelectable = true

        form.addArrangedSubview(
            makeRow(title: "Relay Tailscale host", field: relayHostField)
        )
        relayHostField.placeholderString = "100.x.y.z or MagicDNS name"

        form.addArrangedSubview(
            makeRow(title: "Relay port", field: relayPortField)
        )

        form.addArrangedSubview(
            makeRow(title: "Wake MAC address(es)", field: targetMACsField)
        )
        targetMACsField.placeholderString = "aa:bb:cc:dd:ee:ff"

        let macHint = NSTextField(
            wrappingLabelWithString: """
            Prefilled from Ethernet and Wi-Fi. Enter up to four comma-separated addresses if macOS uses private addresses.
            """
        )
        macHint.font = .systemFont(ofSize: 11)
        macHint.textColor = .secondaryLabelColor
        macHint.maximumNumberOfLines = 0
        macHint.preferredMaxLayoutWidth = 410
        form.addArrangedSubview(macHint)

        let saveButton = NSButton(
            title: "Save and Refresh QR",
            target: self,
            action: #selector(saveAndRefresh)
        )
        saveButton.bezelStyle = .rounded

        let resetButton = NSButton(
            title: "Generate New Secrets…",
            target: self,
            action: #selector(resetSecrets)
        )
        resetButton.bezelStyle = .rounded

        let relaySecretButton = NSButton(
            title: "Copy Relay Secret",
            target: self,
            action: #selector(copyRelaySecret)
        )
        relaySecretButton.bezelStyle = .rounded

        let pasteRelaySecretButton = NSButton(
            title: "Paste Relay Secret",
            target: self,
            action: #selector(pasteRelaySecret)
        )
        pasteRelaySecretButton.bezelStyle = .rounded
        pasteRelaySecretButton.toolTip = "Use the relay secret copied from another Mac, so the same iPad relay can wake this Mac too."

        let editActions = NSStackView(views: [saveButton, resetButton, relaySecretButton, pasteRelaySecretButton])
        editActions.orientation = .horizontal
        editActions.spacing = 8
        form.addArrangedSubview(editActions)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.maximumNumberOfLines = 0
        statusLabel.preferredMaxLayoutWidth = 410
        form.addArrangedSubview(statusLabel)

        let qrTitle = NSTextField(labelWithString: "Scan on iPhone")
        qrTitle.font = .systemFont(ofSize: 13, weight: .semibold)

        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        qrImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            qrImageView.widthAnchor.constraint(equalToConstant: 188),
            qrImageView.heightAnchor.constraint(equalToConstant: 188)
        ])

        copyButton.target = self
        copyButton.action = #selector(copyPairingLink)
        copyButton.bezelStyle = .rounded

        let qrHint = NSTextField(
            wrappingLabelWithString: "The QR code and copied link contain your private pairing secret."
        )
        qrHint.font = .systemFont(ofSize: 10)
        qrHint.textColor = .secondaryLabelColor
        qrHint.maximumNumberOfLines = 0
        qrHint.alignment = .center
        qrHint.preferredMaxLayoutWidth = 188

        let qrColumn = NSStackView(views: [qrTitle, qrImageView, copyButton, qrHint])
        qrColumn.orientation = .vertical
        qrColumn.alignment = .centerX
        qrColumn.distribution = .fill
        qrColumn.spacing = 9

        let body = NSStackView(views: [form, qrColumn])
        body.orientation = .horizontal
        body.alignment = .top
        body.distribution = .fill
        body.spacing = 24
        content.addArrangedSubview(body)

        NSLayoutConstraint.activate([
            body.widthAnchor.constraint(equalTo: content.widthAnchor),
            form.widthAnchor.constraint(equalToConstant: 560),
            qrColumn.widthAnchor.constraint(equalToConstant: 188)
        ])

        refresh()
    }

    func refresh() {
        networkInformation = .discover()
        let configuration = configurationStore.pairingConfiguration(
            networkInformation: networkInformation
        )
        macHostField.stringValue = configuration.macHost
        relayHostField.stringValue = configuration.relayHost
        relayPortField.stringValue = String(configuration.relayPort)
        targetMACsField.stringValue = configuration.targetMAC
        updatePairingOutput(configuration)
    }

    private func makeRow(title: String, field: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 132).isActive = true

        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.distribution = .fill
        row.spacing = 10
        field.widthAnchor.constraint(equalToConstant: 298).isActive = true
        return row
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    @objc private func saveAndRefresh() {
        do {
            let relayPort = try validatedRelayPort()
            let targetMACs = try validatedTargetMACs()
            let relayHost = relayHostField.stringValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !relayHost.isEmpty else {
                throw SetupError("Enter the relay's Tailscale address.")
            }

            configurationStore.updatePairing(
                relayHost: relayHost,
                relayPort: relayPort,
                targetMACs: targetMACs
            )
            statusLabel.textColor = .systemGreen
            statusLabel.stringValue = "Pairing settings saved locally."
            refresh()
        } catch {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func resetSecrets() {
        let alert = NSAlert()
        alert.messageText = "Generate new pairing secrets?"
        alert.informativeText = """
        Existing iPhone pairings will stop working until you scan the new QR \
        code, and the wake relay will reject wake requests until you provision \
        the new relay secret on it.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Generate")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        configurationStore.resetSecrets()
        statusLabel.textColor = .systemGreen
        statusLabel.stringValue = "New secrets were generated locally."
        refresh()
    }

    @objc private func copyRelaySecret() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            configurationStore.relaySecret.base64EncodedString(),
            forType: .string
        )
        statusLabel.textColor = .systemGreen
        statusLabel.stringValue = """
        Relay secret copied. Paste it into Companion Setup on another Mac, or write it \
        as SharedSecret in /etc/modafinil-relay.plist on the relay (root-owned, mode 0600).
        """
    }

    @objc private func pasteRelaySecret() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        if configurationStore.importRelaySecret(base64: text) {
            statusLabel.textColor = .systemGreen
            statusLabel.stringValue = "Relay secret saved. This Mac now shares the iPad relay with the Mac it came from."
            refresh()
        } else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "The clipboard does not hold a relay secret. On the other Mac, click Copy Relay Secret first."
        }
    }

    @objc private func copyPairingLink() {
        guard let pairingLink else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingLink, forType: .string)
        statusLabel.textColor = .systemGreen
        statusLabel.stringValue = "Private pairing link copied."
    }

    private func updatePairingOutput(_ configuration: PairingConfiguration) {
        let targetMACsAreValid = (try? validateTargetMACs(configuration.targetMAC)) != nil
        let isComplete = !configuration.macHost.isEmpty &&
            !configuration.relayHost.isEmpty &&
            targetMACsAreValid

        guard isComplete else {
            pairingLink = nil
            qrImageView.image = NSImage(
                systemSymbolName: "qrcode",
                accessibilityDescription: "Pairing QR code unavailable"
            )
            qrImageView.contentTintColor = .tertiaryLabelColor
            copyButton.isEnabled = false

            if configuration.macHost.isEmpty {
                statusLabel.textColor = .systemOrange
                statusLabel.stringValue = """
                Tailscale IPv4 could not be detected. Connect Tailscale on this Mac, then reopen this window.
                """
            } else if configuration.relayHost.isEmpty {
                statusLabel.textColor = .secondaryLabelColor
                statusLabel.stringValue = "Enter the relay's Tailscale address to create the QR code."
            } else {
                statusLabel.textColor = .systemRed
                statusLabel.stringValue = "Enter 1–4 valid comma-separated MAC addresses."
            }
            return
        }

        let link = configuration.pairingURL.absoluteString
        pairingLink = link
        qrImageView.image = makeQRCode(from: link)
        qrImageView.contentTintColor = nil
        copyButton.isEnabled = true
    }

    private func validatedRelayPort() throws -> UInt16 {
        guard let port = UInt16(relayPortField.stringValue), port != 0 else {
            throw SetupError("Enter a valid relay port.")
        }
        return port
    }

    private func validatedTargetMACs() throws -> String {
        try validateTargetMACs(targetMACsField.stringValue)
    }

    private func validateTargetMACs(_ value: String) throws -> String {
        let candidates = value
            .split(separator: ",", omittingEmptySubsequences: false)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }

        guard (1...4).contains(candidates.count),
              candidates.allSatisfy(isMACAddress)
        else {
            throw SetupError("Enter 1–4 valid comma-separated MAC addresses.")
        }

        return candidates.joined(separator: ",")
    }

    private func isMACAddress(_ value: String) -> Bool {
        let bytes = value.split(separator: ":")
        return bytes.count == 6 && bytes.allSatisfy {
            $0.count == 2 && UInt8($0, radix: 16) != nil
        }
    }

    private func makeQRCode(from value: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        let scale = 8.0
        let transformed = outputImage.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(
            transformed,
            from: transformed.extent
        ) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: 220, height: 220))
    }

    private struct SetupError: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }
}
