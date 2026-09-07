import AppKit
import QuartzCore

// One compact block at the leading edge of a background-visible application bar.
final class CompactTouchBar: NSObject, NSTouchBarDelegate {
    let item = NSCustomTouchBarItem(identifier: .init("local.mytouchbar.codex"))
    let openCodeItem = NSCustomTouchBarItem(identifier: .init("local.mytouchbar.opencode"))
    private var presented: NSTouchBar?
    private var openCodeVisible = false

    private var identifiers: [NSTouchBarItem.Identifier] {
        [item.identifier] + (openCodeVisible ? [openCodeItem.identifier] : []) + [.flexibleSpace]
    }

    func show() -> Bool {
        let cls = NSTouchBar.self as AnyObject
        let selector = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        guard cls.responds(to: selector) else { return false }
        hide()
        let bar = NSTouchBar()
        bar.delegate = self
        // Trailing flexible space keeps the fixed-width quota block on the LEFT.
        // Future blocks belong before flexibleSpace; do not stretch the quota view.
        bar.defaultItemIdentifiers = identifiers
        _ = cls.perform(selector, with: bar, with: nil)
        presented = bar
        return true
    }

    func setOpenCodeVisible(_ visible: Bool) {
        guard visible != openCodeVisible else { return }
        openCodeVisible = visible
        presented?.defaultItemIdentifiers = identifiers
    }

    func hide() {
        guard let bar = presented else { return }
        let cls = NSTouchBar.self as AnyObject
        let selector = NSSelectorFromString("dismissSystemModalTouchBar:")
        if cls.responds(to: selector) { _ = cls.perform(selector, with: bar) }
        presented = nil
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        identifier == item.identifier ? item : identifier == openCodeItem.identifier ? openCodeItem : nil
    }
}

final class QuotaView: NSButton {
    static let blockSize = NSSize(width: 198, height: 30)
    var fiveHour: RateLimitWindow?
    var weekly: RateLimitWindow?
    var stale = false
    var onTap: (() -> Void)?
    private let border = CAShapeLayer()
    var activity: TaskActivity = .idle { didSet { updateBorder() } }
    static let icon = NSImage(contentsOfFile: "/Applications/ChatGPT.app/Contents/Resources/icon-chatgpt.png")
        ?? NSImage(contentsOfFile: "/Applications/ChatGPT.app/Contents/Resources/icon-chatgpt.icns")
        ?? NSImage(systemSymbolName: "bubble.left", accessibilityDescription: "ChatGPT")

    static func quotaHue(for remainingPercent: Double) -> CGFloat {
        CGFloat(max(0, min(100, remainingPercent)) / 300)
    }

    private func quotaColor(for window: RateLimitWindow?) -> NSColor {
        guard !stale, let remaining = window?.remainingPercent else {
            return stale ? .systemOrange : .white
        }
        return NSColor(calibratedHue: Self.quotaHue(for: remaining), saturation: 0.82, brightness: 1, alpha: 1)
    }

    private func updateBorder() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.removeAnimation(forKey: "breathe")
        border.strokeColor = (activity == .unread ? NSColor.systemRed : NSColor(calibratedRed: 0.55, green: 0.8, blue: 1, alpha: 1)).cgColor
        border.opacity = activity == .idle ? 0 : activity == .unread ? 0.9 : 0.5
        if activity == .running && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0.2
            animation.toValue = 0.65
            animation.duration = 1.6
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            border.add(animation, forKey: "breathe")
        }
        CATransaction.commit()
        updateAccessibility()
    }
    @objc private func motionChanged() { updateBorder() }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.blockSize))
        title = ""
        isBordered = false
        target = self
        action = #selector(tapped)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.blockSize.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.blockSize.height).isActive = true
        wantsLayer = true
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 5, cornerHeight: 5, transform: nil)
        border.fillColor = NSColor.clear.cgColor
        border.lineWidth = 1.5
        border.opacity = 0
        layer?.addSublayer(border)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Codex 额度，点击打开任务")
    }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { Self.blockSize }
    @objc private func tapped() { onTap?() }

    func updateAccessibility() {
        setAccessibilityHelp(activity == .unread ? "有未读消息" : activity == .running ? "有任务进行中" : "没有运行中或未读任务")
        setAccessibilityValue("5h 剩余 \(fiveHour?.remaining ?? "--")，\(fiveHour?.reset ?? "--")；7d 剩余 \(weekly?.remaining ?? "--")，\(weekly?.reset ?? "--")\(stale ? "；旧数据，刷新失败" : "")")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        let rows = [("5h", fiveHour), ("7d", weekly)]
        let color = NSColor.white
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color
        ]
        let textWidth = { (text: String) in ceil((text as NSString).size(withAttributes: attributes).width) }
        let titleWidth = rows.map { textWidth($0.0) }.max() ?? 0
        let remainingWidth = rows.map { textWidth($0.1?.remaining ?? "--") }.max() ?? 0
        let resetWidth = rows.map { textWidth($0.1?.reset ?? "--") }.max() ?? 0
        let contentWidth = 22 + 6 + titleWidth + 8 + remainingWidth + 10 + resetWidth
        let startX = floor((bounds.width - contentWidth) / 2)
        let titleX = startX + 28
        let remainingX = titleX + titleWidth + 8
        let resetX = remainingX + remainingWidth + 10

        Self.icon?.draw(in: NSRect(x: startX, y: 4, width: 22, height: 22))
        for (index, row) in rows.enumerated() {
            let y: CGFloat = index == 0 ? 15 : 1
            let entries: [(String, CGFloat, CGFloat, NSColor)] = [
                (row.0, titleX, titleWidth, color),
                (row.1?.remaining ?? "--", remainingX, remainingWidth, quotaColor(for: row.1)),
                (row.1?.reset ?? "--", resetX, resetWidth, color)
            ]
            for (text, x, width, textColor) in entries {
                (text as NSString).draw(in: NSRect(x: x, y: y, width: width, height: 14),
                    withAttributes: attributes.merging([.foregroundColor: textColor]) { _, new in new })
            }
        }
    }
}

func quotaColorSelfTest() {
    precondition(QuotaView.quotaHue(for: -1) == 0)
    precondition(QuotaView.quotaHue(for: 50) > 0.16 && QuotaView.quotaHue(for: 50) < 0.17)
    precondition(QuotaView.quotaHue(for: 101) > 0.33 && QuotaView.quotaHue(for: 101) < 0.34)
    print("PASS: quota color clamps and transitions red → yellow → green")
}
