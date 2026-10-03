import AppKit

/// The sidebar cell for one worktree row and for its detail lines.
///
/// Deliberately a sibling of `RowCell`/`PRChipStrip` rather than an extension of
/// them: the same three width rules, applied to a row whose chips are counts and
/// sizes rather than PR numbers. Those rules were found by screenshotting the real
/// sidebar at its real ~220pt width, not by reading the code:
///
/// 1. **A chip that clips lies.** A `#1026` clipped to `#102` is a real PR number
///    pointing at the wrong work; a `⬢10` clipped to `⬢1` is a wrong container
///    count. Chips resist compression at `.required` and never shrink.
/// 2. **The name floor is a preference** (`.defaultHigh`), not a guarantee —
///    otherwise it forces the clipping in rule 1.
/// 3. **The leading stack hugs at `.defaultLow`**, or the name sits at its floor
///    while free space goes unused, truncating with a visible gap before the chip.

/// One trailing pill — a count, an age, a size. Text only: unlike a PR chip there
/// is nothing to click through to, so this is a label rather than a button.
final class WorktreeMetricChipView: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        isSelectable = false
        drawsBackground = false
        translatesAutoresizingMaskIntoConstraints = false
        lineBreakMode = .byClipping
        maximumNumberOfLines = 1
        // Rule 1: never yield. A short branch name is recoverable; a clipped count
        // is a different number.
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ chip: WorktreeChip) {
        let color: NSColor = chip.tone == .warning ? .systemOrange : .secondaryLabelColor
        attributedStringValue = NSAttributedString(
            string: chip.text,
            attributes: [.foregroundColor: color,
                         .font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
        toolTip = chip.tooltip
    }
}

/// The chips on one worktree row. Bounded by content (`maxChips`) as well as by the
/// priority ladder, so the strip can never grow without limit.
final class WorktreeChipStrip: NSView {
    /// Four is what fits beside a readable branch name at 220pt: `work`, `⬢10`,
    /// `1d`, `1.9 GB`. Measured, not guessed.
    static let maxChips = 4

    private let stack = NSStackView()
    private let chips: [WorktreeMetricChipView]

    init() {
        chips = (0..<Self.maxChips).map { _ in WorktreeMetricChipView() }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.required, for: .horizontal)
        for c in chips { stack.addArrangedSubview(c) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        configure([])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ list: [WorktreeChip]) {
        // `chips(work:now:)` never yields more than `maxChips`; the prefix is a
        // backstop that keeps the `work` warning, which comes first.
        let shown = Array(list.prefix(Self.maxChips))
        for (i, chip) in chips.enumerated() {
            if i < shown.count {
                chip.configure(shown[i])
                chip.isHidden = false
            } else {
                chip.isHidden = true
            }
        }
        isHidden = shown.isEmpty
    }
}

/// A worktree row: the branch (which is what distinguishes these rows), the
/// directory name behind it in muted text, and the chips.
final class WorktreeRowCell: NSTableCellView {
    /// The branch never shrinks below this. Same reasoning as `RowCell`: identity
    /// outranks metadata, and a four-character branch name is indistinguishable
    /// from any other four-character branch name.
    static let minLabelWidth: CGFloat = 110

    let label = NSTextField(labelWithString: "")
    let chipStrip = WorktreeChipStrip()

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        // Rule 1's other half: the name yields before a chip does.
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        // Rule 3: grow into whatever the chips don't use.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(label)
        addSubview(chipStrip)
        textField = label

        // Rule 2: a strong preference, so a row too narrow for both truncates the
        // branch rather than clipping a count into a different count.
        let nameFloor = label.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Self.minLabelWidth)
        nameFloor.priority = .defaultHigh
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: chipStrip.leadingAnchor, constant: -6),
            chipStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chipStrip.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameFloor,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(entry: WorktreeEntry, work: WorktreeWork, metrics: WorktreeMetrics, now: Date) {
        // The branch, and only the branch. The directory on this line cost the
        // branch the room it needed — `fix/competitor-operator` rendered as `fix/`.
        // The detail line below shows the full path, and the tooltip carries it.
        label.stringValue = WorktreeMetrics.branchLabel(entry: entry)
        label.textColor = .labelColor
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        chipStrip.configure(metrics.chips(work: work, now: now))

        let state: String
        switch work {
        case .unknown: state = "unique work not checked yet"
        case .none: state = "no uncommitted or unpushed work"
        case .unique: state = "holds work that exists nowhere else"
        }
        toolTip = "\(entry.path)\n\(entry.kind.rawValue) worktree, no session — \(state)"
    }
}

/// One detail line under an expanded worktree row.
///
/// Paths truncate from the HEAD. `/Users/me/.treehouse/acme-app-monorepo-80d…`
/// throws away the only part that identifies the tree; `…-80d837/10/acme-app-monorepo`
/// keeps it.
final class WorktreeDetailCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 1
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 10)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ text: String) {
        label.lineBreakMode = text.hasPrefix("/") ? .byTruncatingHead : .byTruncatingTail
        label.stringValue = text
        toolTip = text
    }
}
