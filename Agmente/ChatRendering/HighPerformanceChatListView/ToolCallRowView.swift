#if canImport(UIKit)
import UIKit
import ACP
import ACPClient

final class ToolCallRowView: BaseRowView {
    private enum Style {
        static let cardBackground = UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 66.0 / 255.0, green: 48.0 / 255.0, blue: 42.0 / 255.0, alpha: 1)
            }
            return UIColor(red: 247.0 / 255.0, green: 235.0 / 255.0, blue: 228.0 / 255.0, alpha: 1)
        }
        static let hammerColor = UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 247.0 / 255.0, green: 163.0 / 255.0, blue: 109.0 / 255.0, alpha: 1)
            }
            return UIColor(red: 224.0 / 255.0, green: 123.0 / 255.0, blue: 65.0 / 255.0, alpha: 1)
        }
        static let warningColor = UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 255.0 / 255.0, green: 183.0 / 255.0, blue: 77.0 / 255.0, alpha: 1)
            }
            return UIColor(red: 235.0 / 255.0, green: 145.0 / 255.0, blue: 29.0 / 255.0, alpha: 1)
        }
        static let detailColor = UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 205.0 / 255.0, green: 190.0 / 255.0, blue: 183.0 / 255.0, alpha: 1)
            }
            return UIColor(red: 127.0 / 255.0, green: 110.0 / 255.0, blue: 100.0 / 255.0, alpha: 1)
        }
        static let approveForeground = UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 92.0 / 255.0, green: 214.0 / 255.0, blue: 129.0 / 255.0, alpha: 1)
            }
            return UIColor(red: 38.0 / 255.0, green: 150.0 / 255.0, blue: 71.0 / 255.0, alpha: 1)
        }
        static let approveBackground = UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 44.0 / 255.0, green: 82.0 / 255.0, blue: 55.0 / 255.0, alpha: 1)
            }
            return UIColor(red: 210.0 / 255.0, green: 239.0 / 255.0, blue: 219.0 / 255.0, alpha: 1)
        }
        static let declineForeground = UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 255.0 / 255.0, green: 109.0 / 255.0, blue: 107.0 / 255.0, alpha: 1)
            }
            return UIColor(red: 198.0 / 255.0, green: 46.0 / 255.0, blue: 56.0 / 255.0, alpha: 1)
        }
        static let declineBackground = UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 92.0 / 255.0, green: 54.0 / 255.0, blue: 56.0 / 255.0, alpha: 1)
            }
            return UIColor(red: 245.0 / 255.0, green: 221.0 / 255.0, blue: 220.0 / 255.0, alpha: 1)
        }
        static let unknownForeground = UIColor.systemGray
        static let unknownBackground = UIColor.systemGray5
        static let regularCornerRadius: CGFloat = 20
        static let compactCornerRadius: CGFloat = 14
        static let compactMultilineCornerRadius: CGFloat = 12
        static let regularInset: CGFloat = 16
        static let compactInset: CGFloat = 14
        static let titleFont = UIFont.systemFont(ofSize: 16, weight: .semibold)
        static let detailFont = UIFont.systemFont(ofSize: 14, weight: .regular)
        static let buttonFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
        static let buttonIconPointSize: CGFloat = 17
        static let buttonRowHeight: CGFloat = 34
        static let compactTitleFont = UIFont.systemFont(ofSize: 15, weight: .medium)
        static let compactCommandTitleFont = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
        static let compactMultilineCommandTitleFont = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        static let compactSingleLineTopInset: CGFloat = 9
        static let compactSingleLineBottomInset: CGFloat = 7
        static let compactMultilineTopInset: CGFloat = 6
        static let compactMultilineBottomInset: CGFloat = 1
    }

    struct Payload {
        let title: String
        let status: String?
        let kind: String?
        let output: String?
        let acpPermissionRequestId: ACP.ID?
        let permissionRequestId: JSONRPCID?
        let permissionOptions: [ACPPermissionOption]
        let approvalRequestId: JSONRPCID?
        let approvalReason: String?
        let approvalCommand: String?
        let approvalCwd: String?
        let isStreaming: Bool

        init(entry: ChatEntry) {
            let tool = entry.segment?.toolCall
            self.title = tool?.title ?? entry.text
            self.status = tool?.status
            self.kind = tool?.kind
            self.output = tool?.output
            self.acpPermissionRequestId = tool?.acpPermissionRequestId
            self.permissionRequestId = tool?.permissionRequestId
            self.permissionOptions = tool?.permissionOptions ?? []
            self.approvalRequestId = tool?.approvalRequestId
            self.approvalReason = tool?.approvalReason
            self.approvalCommand = tool?.approvalCommand
            self.approvalCwd = tool?.approvalCwd
            self.isStreaming = entry.isStreaming
        }

        var hasOutput: Bool {
            !(output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }

        var hasDetailLines: Bool {
            !(approvalReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                || !(approvalCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                || !(approvalCwd?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }

        var hasActions: Bool {
            approvalRequestId != nil || !permissionOptions.isEmpty
        }

        var isCommandLike: Bool {
            switch kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "execute", "command", "shell":
                return true
            default:
                return false
            }
        }

        var usesCompactStyle: Bool {
            !hasOutput && !hasDetailLines && !hasActions
        }
    }

    private var onACPPermission: ((ACP.ID, String) -> Void)?
    private var onJSONRPCPermission: ((JSONRPCID, String) -> Void)?
    private var onApprove: ((JSONRPCID, Bool?) -> Void)?
    private var onDecline: ((JSONRPCID) -> Void)?

    private var payload: Payload?
    private var lastButtonLayoutWidth: CGFloat = -1

    private let card = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let resultIcon = UIImageView()
    private let resultLabel = UILabel()
    private let outputLabel = UILabel()
    private let leadingIcon = UIImageView()
    private let trailingStatusIcon = UIImageView()
    private let trailingStatusSpinner = UIActivityIndicatorView(style: .medium)
    private let buttonStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        card.layer.cornerRadius = Style.regularCornerRadius
        card.layer.cornerCurve = .continuous
        card.backgroundColor = Style.cardBackground
        card.layer.borderWidth = 0

        titleLabel.numberOfLines = 0
        titleLabel.font = Style.titleFont
        titleLabel.textColor = .label

        subtitleLabel.numberOfLines = 0
        subtitleLabel.font = Style.detailFont
        subtitleLabel.textColor = Style.detailColor

        resultIcon.image = UIImage(systemName: "checkmark.circle")
        resultIcon.tintColor = Style.approveForeground
        resultIcon.contentMode = .scaleAspectFit

        resultLabel.text = "Result"
        resultLabel.font = Style.titleFont
        resultLabel.textColor = Style.approveForeground

        outputLabel.numberOfLines = 5
        outputLabel.font = Style.detailFont
        outputLabel.textColor = Style.detailColor

        leadingIcon.tintColor = Style.hammerColor
        trailingStatusIcon.tintColor = .secondaryLabel
        trailingStatusSpinner.hidesWhenStopped = true

        buttonStack.axis = .vertical
        buttonStack.spacing = 10
        buttonStack.alignment = .leading

        rowContainer.addSubview(card)
        card.addSubview(leadingIcon)
        card.addSubview(trailingStatusIcon)
        card.addSubview(trailingStatusSpinner)
        card.addSubview(titleLabel)
        card.addSubview(subtitleLabel)
        card.addSubview(resultIcon)
        card.addSubview(resultLabel)
        card.addSubview(outputLabel)
        card.addSubview(buttonStack)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        payload = nil
        lastButtonLayoutWidth = -1
        clearButtons()
    }

    func configure(
        payload: Payload,
        onACPPermission: @escaping (ACP.ID, String) -> Void,
        onJSONRPCPermission: @escaping (JSONRPCID, String) -> Void,
        onApprove: @escaping (JSONRPCID, Bool?) -> Void,
        onDecline: @escaping (JSONRPCID) -> Void
    ) {
        self.payload = payload
        self.onACPPermission = onACPPermission
        self.onJSONRPCPermission = onJSONRPCPermission
        self.onApprove = onApprove
        self.onDecline = onDecline

        titleLabel.text = payload.title

        let normalizedStatus = payload.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isAwaitingPermission = normalizedStatus == "awaiting_permission"
            && (!payload.permissionOptions.isEmpty || payload.approvalRequestId != nil)
        leadingIcon.image = UIImage(systemName: "hammer.fill") ?? UIImage(systemName: "hammer")
        leadingIcon.tintColor = Style.hammerColor

        trailingStatusIcon.isHidden = true
        trailingStatusSpinner.stopAnimating()
        trailingStatusIcon.frame = .zero
        trailingStatusSpinner.frame = .zero
        if isAwaitingPermission {
            trailingStatusIcon.isHidden = false
            trailingStatusIcon.image = UIImage(systemName: "exclamationmark.shield.fill")
            trailingStatusIcon.tintColor = Style.warningColor
        }

        card.backgroundColor = Style.cardBackground
        card.layer.borderColor = UIColor.clear.cgColor
        card.layer.borderWidth = 0

        let details = Self.detailLines(for: payload)
        subtitleLabel.text = details.joined(separator: "\n")

        if let output = payload.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
            outputLabel.text = output.truncatedToolOutput(maxLines: 6, maxChars: 1200)
            outputLabel.isHidden = false
            resultIcon.isHidden = true
            resultLabel.isHidden = true
        } else {
            outputLabel.text = nil
            outputLabel.isHidden = true
            resultIcon.isHidden = true
            resultLabel.isHidden = true
        }

        titleLabel.font = titleFont(for: payload)
        let compactCornerRadius = payload.usesCompactStyle && isCompactMultiline(payload: payload, width: bounds.width)
            ? Style.compactMultilineCornerRadius
            : Style.compactCornerRadius
        card.layer.cornerRadius = payload.usesCompactStyle ? compactCornerRadius : Style.regularCornerRadius

        let availableWidth = max(0, bounds.width - (contentInset(for: payload) * 2))
        rebuildButtons(payload: payload, availableWidth: availableWidth)
        lastButtonLayoutWidth = availableWidth
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = rowContainer.bounds

        let inset = contentInset(for: payload)
        let availableWidth = max(0, card.bounds.width - (inset * 2))
        guard availableWidth > 0 else {
            leadingIcon.frame = .zero
            trailingStatusIcon.frame = .zero
            trailingStatusSpinner.frame = .zero
            titleLabel.frame = .zero
            subtitleLabel.frame = .zero
            resultIcon.frame = .zero
            resultLabel.frame = .zero
            outputLabel.frame = .zero
            buttonStack.frame = .zero
            return
        }

        if let payload, abs(lastButtonLayoutWidth - availableWidth) > 0.5 {
            rebuildButtons(payload: payload, availableWidth: availableWidth)
            lastButtonLayoutWidth = availableWidth
        }

        let titleIconSize: CGFloat = payload?.usesCompactStyle == true ? 16 : 17
        let statusSize: CGFloat = 18
        let iconX = inset
        let trailingX = card.bounds.width - inset - statusSize
        let hasTrailingStatus = !trailingStatusIcon.isHidden || trailingStatusSpinner.isAnimating

        let titleX = iconX + titleIconSize + 8
        let trailingReservedWidth: CGFloat = hasTrailingStatus ? (statusSize + 8) : 0
        let titleWidth = max(1, card.bounds.width - titleX - inset - trailingReservedWidth)
        let measuredTitleHeight = ceil(titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
        let titleHeight = max(measuredTitleHeight, ceil(titleLabel.font.lineHeight))
        let subtitleText = subtitleLabel.text ?? ""
        let hasSubtitle = !subtitleText.isEmpty
        let hasOutput = !outputLabel.isHidden
        let hasButtons = !buttonStack.arrangedSubviews.isEmpty
        let hasSupplementaryContent = hasSubtitle || hasOutput || hasButtons
        let isCompact = payload?.usesCompactStyle == true
        let isCompactMultiline = isCompact && measuredTitleHeight > ceil(titleLabel.font.lineHeight * 1.4)
        let compactTopInset = isCompactMultiline ? Style.compactMultilineTopInset : Style.compactSingleLineTopInset
        let titleY = isCompact
            ? compactTopInset
            : (
                hasSupplementaryContent
                    ? CGFloat(14)
                    : max(14, floor((card.bounds.height - titleHeight) / 2))
            )
        titleLabel.frame = CGRect(x: titleX, y: titleY, width: titleWidth, height: titleHeight)

        let titleIconY = isCompact
            ? titleLabel.frame.minY + 2
            : titleLabel.frame.minY + max(0, (titleLabel.frame.height - titleIconSize) / 2)
        leadingIcon.frame = CGRect(x: iconX, y: titleIconY, width: titleIconSize, height: titleIconSize)
        let statusY = titleLabel.frame.minY + max(0, (titleLabel.frame.height - statusSize) / 2)
        if trailingStatusSpinner.isAnimating {
            trailingStatusSpinner.frame = CGRect(x: trailingX, y: statusY, width: statusSize, height: statusSize)
            trailingStatusIcon.frame = .zero
        } else if trailingStatusIcon.isHidden {
            trailingStatusIcon.frame = .zero
            trailingStatusSpinner.frame = .zero
        } else {
            trailingStatusIcon.frame = CGRect(x: trailingX, y: statusY, width: statusSize, height: statusSize)
            trailingStatusSpinner.frame = .zero
        }

        var currentY = titleLabel.frame.maxY + 10

        if hasSubtitle {
            let subtitleHeight = ceil(subtitleLabel.sizeThatFits(CGSize(width: availableWidth, height: .greatestFiniteMagnitude)).height)
            subtitleLabel.frame = CGRect(x: inset, y: currentY, width: availableWidth, height: subtitleHeight)
            currentY = subtitleLabel.frame.maxY + 10
        } else {
            subtitleLabel.frame = .zero
        }

        if !outputLabel.isHidden {
            resultIcon.frame = .zero
            resultLabel.frame = .zero
            let outputHeight = ceil(outputLabel.sizeThatFits(CGSize(width: availableWidth, height: .greatestFiniteMagnitude)).height)
            outputLabel.frame = CGRect(x: inset, y: currentY, width: availableWidth, height: outputHeight)
            currentY = outputLabel.frame.maxY + 10
        } else {
            resultIcon.frame = .zero
            resultLabel.frame = .zero
            outputLabel.frame = .zero
        }

        let buttonHeight = measuredButtonStackHeight()
        if buttonHeight > 0 {
            buttonStack.frame = CGRect(x: inset, y: currentY, width: availableWidth, height: buttonHeight)
        } else {
            buttonStack.frame = .zero
        }

        let contentBottom = max(
            titleLabel.frame.maxY,
            subtitleLabel.frame.maxY,
            outputLabel.frame.maxY,
            buttonStack.frame.maxY
        )
        let bottomInset = Self.bottomInset(for: payload)
        let desiredHeight = max(contentBottom + bottomInset, 34)
        card.frame = CGRect(
            x: 0,
            y: 0,
            width: rowContainer.bounds.width,
            height: min(desiredHeight, rowContainer.bounds.height)
        )
    }

    static func estimatedHeight(for payload: Payload, width: CGFloat) -> CGFloat {
        let inset = payload.usesCompactStyle ? Style.compactInset : Style.regularInset
        let contentWidth = max(0, width - (inset * 2))
        let titleFont = payload.usesCompactStyle
            ? (payload.isCommandLike ? Style.compactCommandTitleFont : Style.compactTitleFont)
            : Style.titleFont
        let compactTitleWidth = max(1, contentWidth - 24)
        let titleHeight = (payload.title as NSString).boundingRect(
            with: CGSize(width: payload.usesCompactStyle ? compactTitleWidth : max(1, contentWidth - 30), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: titleFont],
            context: nil
        ).height

        if payload.usesCompactStyle {
            let isCompactMultiline = ceil(titleHeight) > ceil(titleFont.lineHeight * 1.4)
            let topInset = isCompactMultiline ? Style.compactMultilineTopInset : Style.compactSingleLineTopInset
            let bottomInset = isCompactMultiline ? Style.compactMultilineBottomInset : Style.compactSingleLineBottomInset
            return max(ceil(titleHeight) + topInset + bottomInset, 34)
        }

        var total = ceil(titleHeight) + 14

        let details = detailLines(for: payload)
        if !details.isEmpty {
            let text = details.joined(separator: "\n")
            let subtitleHeight = (text as NSString).boundingRect(
                with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: Style.detailFont],
                context: nil
            ).height
            total += 10 + ceil(subtitleHeight)
        }

        if let output = payload.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
            let displayOutput = output.truncatedToolOutput(maxLines: 6, maxChars: 1200)
            total += 10
            let outputHeight = (displayOutput as NSString).boundingRect(
                with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: Style.detailFont],
                context: nil
            ).height
            total += ceil(outputHeight)
        }

        let rowHeight: CGFloat = Style.buttonRowHeight
        let rowSpacing: CGFloat = 10
        var rowCount: Int = 0

        if payload.approvalRequestId != nil {
            let approvalWidths = [
                measuredButtonWidth(title: "Approve", symbolName: "checkmark.circle", availableWidth: contentWidth),
                measuredButtonWidth(title: "Decline", symbolName: "xmark.circle", availableWidth: contentWidth)
            ]
            rowCount += wrappedRowCount(buttonWidths: approvalWidths, availableWidth: contentWidth, spacing: rowSpacing)
        }

        if !payload.permissionOptions.isEmpty {
            let optionWidths = payload.permissionOptions.map { option in
                measuredButtonWidth(
                    title: option.name.truncatedLabel(maxChars: 24),
                    symbolName: iconNameForPermissionKind(option.kind),
                    availableWidth: contentWidth
                )
            }
            rowCount += wrappedRowCount(buttonWidths: optionWidths, availableWidth: contentWidth, spacing: rowSpacing)
        }

        if rowCount > 0 {
            total += 10
            total += CGFloat(rowCount) * rowHeight
            total += CGFloat(max(0, rowCount - 1)) * rowSpacing
        }

        return max(total + bottomInset(for: payload), 58)
    }

    private func rebuildButtons(payload: Payload, availableWidth: CGFloat) {
        clearButtons()

        let rowAvailableWidth = max(0, availableWidth)
        if let approvalRequestId = payload.approvalRequestId {
            let approve = makeButton(
                title: "Approve",
                tint: Style.approveForeground,
                backgroundColor: Style.approveBackground,
                textColor: Style.approveForeground,
                symbolName: "checkmark.circle"
            ) { [weak self] in
                self?.onApprove?(approvalRequestId, nil)
            }
            let decline = makeButton(
                title: "Decline",
                tint: Style.declineForeground,
                backgroundColor: Style.declineBackground,
                textColor: Style.declineForeground,
                symbolName: "xmark.circle"
            ) { [weak self] in
                self?.onDecline?(approvalRequestId)
            }
            for row in makeWrappedRows(buttons: [approve, decline], availableWidth: rowAvailableWidth) {
                buttonStack.addArrangedSubview(row)
            }
        }

        if !payload.permissionOptions.isEmpty {
            var optionButtons: [UIButton] = []
            for option in payload.permissionOptions {
                let tint = foregroundColorForPermissionKind(option.kind)
                let backgroundColor = backgroundColorForPermissionKind(option.kind)
                let button = makeButton(
                    title: option.name.truncatedLabel(maxChars: 24),
                    tint: tint,
                    backgroundColor: backgroundColor,
                    textColor: foregroundColorForPermissionKind(option.kind),
                    symbolName: iconForPermissionKind(option.kind)
                ) { [weak self] in
                    guard let self else { return }
                    if let requestId = payload.acpPermissionRequestId {
                        self.onACPPermission?(requestId, option.optionId)
                    } else if let requestId = payload.permissionRequestId {
                        self.onJSONRPCPermission?(requestId, option.optionId)
                    }
                }
                optionButtons.append(button)
            }
            for row in makeWrappedRows(buttons: optionButtons, availableWidth: rowAvailableWidth) {
                buttonStack.addArrangedSubview(row)
            }
        }
    }

    private func clearButtons() {
        for view in buttonStack.arrangedSubviews {
            buttonStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func makeWrappedRows(buttons: [UIButton], availableWidth: CGFloat) -> [UIStackView] {
        guard !buttons.isEmpty else { return [] }
        guard availableWidth > 0 else {
            return buttons.map { button in
                let row = makeButtonRow()
                row.addArrangedSubview(button)
                return row
            }
        }

        var rows: [UIStackView] = []
        var currentRow = makeButtonRow()
        var currentRowWidth: CGFloat = 0
        let spacing: CGFloat = 10

        for button in buttons {
            button.titleLabel?.numberOfLines = 1
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.setContentHuggingPriority(.required, for: .horizontal)

            let measuredSize = button.systemLayoutSizeFitting(
                CGSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude),
                withHorizontalFittingPriority: .fittingSizeLevel,
                verticalFittingPriority: .fittingSizeLevel
            )
            let buttonWidth = min(max(ceil(measuredSize.width), 1), availableWidth)
            if currentRow.arrangedSubviews.isEmpty {
                currentRow.addArrangedSubview(button)
                currentRowWidth = buttonWidth
                continue
            }

            if currentRowWidth + spacing + buttonWidth <= availableWidth {
                currentRow.addArrangedSubview(button)
                currentRowWidth += spacing + buttonWidth
            } else {
                rows.append(currentRow)
                currentRow = makeButtonRow()
                currentRow.addArrangedSubview(button)
                currentRowWidth = buttonWidth
            }
        }

        if !currentRow.arrangedSubviews.isEmpty {
            rows.append(currentRow)
        }
        return rows
    }

    private func makeButtonRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .leading
        row.distribution = .fill
        return row
    }

    private func titleFont(for payload: Payload) -> UIFont {
        if payload.usesCompactStyle {
            if payload.isCommandLike {
                return isLikelyMultilineCompactCommand(payload.title)
                    ? Style.compactMultilineCommandTitleFont
                    : Style.compactCommandTitleFont
            }
            return Style.compactTitleFont
        }
        return Style.titleFont
    }

    private func isCompactMultiline(payload: Payload, width: CGFloat) -> Bool {
        let inset = contentInset(for: payload)
        let contentWidth = max(1, width - (inset * 2))
        let titleWidth = max(1, contentWidth - 24)
        let measuredHeight = ceil((payload.title as NSString).boundingRect(
            with: CGSize(width: titleWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: titleFont(for: payload)],
            context: nil
        ).height)
        return measuredHeight > ceil(titleFont(for: payload).lineHeight * 1.4)
    }

    private func isLikelyMultilineCompactCommand(_ title: String) -> Bool {
        title.contains("\n") || title.count > 72
    }

    private func contentInset(for payload: Payload?) -> CGFloat {
        payload?.usesCompactStyle == true ? Style.compactInset : Style.regularInset
    }

    private func measuredButtonStackHeight() -> CGFloat {
        let rowCount = buttonStack.arrangedSubviews.count
        guard rowCount > 0 else { return 0 }

        // Keep runtime row height deterministic to avoid stack compression artifacts.
        let rowHeight: CGFloat = Style.buttonRowHeight
        let spacingTotal = CGFloat(max(0, rowCount - 1)) * buttonStack.spacing
        return (CGFloat(rowCount) * rowHeight) + spacingTotal
    }

    private static func detailLines(for payload: Payload) -> [String] {
        var details: [String] = []
        if let reason = payload.approvalReason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            details.append("Reason: \(reason)")
        }
        if let command = payload.approvalCommand, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            details.append("Command: \(command)")
        }
        if let cwd = payload.approvalCwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            details.append("CWD: \(cwd)")
        }
        return details
    }

    private static func measuredButtonWidth(title: String, symbolName: String?, availableWidth: CGFloat) -> CGFloat {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = title
        config.image = symbolName.flatMap { UIImage(systemName: $0) }
        config.imagePadding = symbolName == nil ? 0 : 6
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: Style.buttonIconPointSize,
            weight: .regular
        )
        config.baseForegroundColor = .label
        config.baseBackgroundColor = .systemGray5
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        config.background.cornerRadius = 8
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Style.buttonFont
            return outgoing
        }
        button.configuration = config
        button.semanticContentAttribute = .forceLeftToRight
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.lineBreakMode = .byTruncatingTail

        let measuredSize = button.systemLayoutSizeFitting(
            CGSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel
        )
        return min(max(ceil(measuredSize.width), 1), availableWidth)
    }

    private static func wrappedRowCount(buttonWidths: [CGFloat], availableWidth: CGFloat, spacing: CGFloat) -> Int {
        guard !buttonWidths.isEmpty else { return 0 }
        guard availableWidth > 0 else { return buttonWidths.count }

        var rows = 1
        var rowWidth: CGFloat = 0
        for width in buttonWidths {
            let clamped = min(max(width, 1), availableWidth)
            if rowWidth == 0 {
                rowWidth = clamped
                continue
            }
            if rowWidth + spacing + clamped <= availableWidth {
                rowWidth += spacing + clamped
            } else {
                rows += 1
                rowWidth = clamped
            }
        }
        return rows
    }

    private static func bottomInset(for payload: Payload?) -> CGFloat {
        guard let payload else { return 14 }
        if payload.hasActions {
            return 8
        }
        if payload.hasOutput || payload.hasDetailLines {
            return 12
        }
        return 14
    }

    private func makeButton(
        title: String,
        tint: UIColor,
        backgroundColor: UIColor,
        textColor: UIColor,
        symbolName: String? = nil,
        action: @escaping () -> Void
    ) -> UIButton {
        let button = ActionButton(type: .system)
        button.action = action

        var config = UIButton.Configuration.filled()
        config.title = title
        config.image = symbolName.flatMap { UIImage(systemName: $0) }
        config.imagePadding = symbolName == nil ? 0 : 6
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: Style.buttonIconPointSize,
            weight: .regular
        )
        config.baseForegroundColor = tint
        config.baseBackgroundColor = backgroundColor
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        config.background.cornerRadius = 8
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Style.buttonFont
            outgoing.foregroundColor = textColor
            return outgoing
        }
        button.configuration = config
        button.semanticContentAttribute = .forceLeftToRight
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.lineBreakMode = .byTruncatingTail

        return button
    }

    private func backgroundColorForPermissionKind(_ kind: ACPPermissionOptionKind) -> UIColor {
        switch kind {
        case .allowOnce, .allowAlways:
            return Style.approveBackground
        case .rejectOnce, .rejectAlways:
            return Style.declineBackground
        case .unknown:
            return Style.unknownBackground
        }
    }

    private func foregroundColorForPermissionKind(_ kind: ACPPermissionOptionKind) -> UIColor {
        switch kind {
        case .allowOnce, .allowAlways:
            return Style.approveForeground
        case .rejectOnce, .rejectAlways:
            return Style.declineForeground
        case .unknown:
            return Style.unknownForeground
        }
    }

    private func iconForPermissionKind(_ kind: ACPPermissionOptionKind) -> String {
        Self.iconNameForPermissionKind(kind)
    }

    private static func iconNameForPermissionKind(_ kind: ACPPermissionOptionKind) -> String {
        switch kind {
        case .allowOnce, .allowAlways:
            return "checkmark.circle"
        case .rejectOnce, .rejectAlways:
            return "xmark.circle"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private func iconForToolKind(_ kind: String?) -> String {
        switch kind?.lowercased() {
        case "read": return "doc.text.magnifyingglass"
        case "edit": return "pencil"
        case "delete": return "trash"
        case "move": return "arrow.right.doc.on.clipboard"
        case "search": return "magnifyingglass"
        case "execute": return "terminal"
        case "think": return "brain"
        case "fetch": return "arrow.down.circle"
        default: return "wrench.and.screwdriver"
        }
    }

    private func colorForToolKind(_ kind: String?) -> UIColor {
        switch kind?.lowercased() {
        case "read": return .systemBlue
        case "edit": return .systemOrange
        case "delete": return .systemRed
        case "execute": return .systemPurple
        case "search": return .systemGreen
        case "think": return .systemIndigo
        case "fetch": return .systemCyan
        default: return .systemOrange
        }
    }
}
#endif
