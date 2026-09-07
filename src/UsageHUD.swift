import AppKit

// MARK: - Model

struct Gauge {
    var title: String
    var detail: String
    var pct: Double?
    var stale = false
    var severity: Int? = nil   // 0 ok / 1 warn / 2 crit — overrides the pct colour
}

struct Session {
    var name: String
    var cwd: String
    var state: String
    var age: Double?
    var mem: Double?       // MB
    var pid: Int32 = 0
    var killable = false   // verified to actually be a Claude Code process
}

struct MemApp {
    var name: String
    var mb: Double
    var maxMb: Double
    var count: Int
}

struct Summary {
    var active = 0
    var total = 0
    var claudeLeft: Double? = nil    // %
    var codexLeft: Double? = nil     // %
    var ramFree: Double? = nil       // GB
    var diskFree: Double? = nil      // GB
}

struct Snapshot {
    var gauges: [Gauge]
    var sessions: [Session]
    var summary = Summary()
    var topMemory: [MemApp] = []
    static let placeholder = Snapshot(
        gauges: [Gauge(title: "Claude", detail: "loading…", pct: nil),
                 Gauge(title: "Codex",  detail: "loading…", pct: nil),
                 Gauge(title: "RAM",    detail: "loading…", pct: nil),
                 Gauge(title: "Disk",   detail: "loading…", pct: nil)],
        sessions: [])
}

// MARK: - Layout constants

enum L {
    static let width: CGFloat = 336
    static let padX: CGFloat = 14
    static let padTop: CGFloat = 12
    static let gaugeH: CGFloat = 30      // 15 label + 9 bar + 6 gap
    static let sepBlock: CGFloat = 26    // separator + SESSIONS header
    static let sessionH: CGFloat = 16
    static let padBottom: CGFloat = 8

    static let compactWidth: CGFloat = 292
    static let compactHeight: CGFloat = 30

    static func height(gauges: Int, sessions: Int) -> CGFloat {
        return padTop + CGFloat(gauges) * gaugeH + sepBlock
             + CGFloat(max(sessions, 1)) * sessionH + padBottom
    }
}

// MARK: - Drawing

final class HUDView: NSView {
    var snapshot = Snapshot.placeholder { didSet { needsDisplay = true } }
    var compact = false { didSet { needsDisplay = true } }
    var onToggle: (() -> Void)?

    /// Clickable area for the collapse / expand chevron.
    func toggleRect() -> NSRect {
        return compact
            ? NSRect(x: bounds.width - 22, y: bounds.height / 2 - 9, width: 18, height: 18)
            : NSRect(x: bounds.width - 26, y: bounds.height - 24, width: 18, height: 18)
    }

    /// Which gauge row sits under this point (0-based), if any.
    func gaugeIndex(at p: NSPoint) -> Int? {
        guard !compact else { return nil }
        let top = bounds.height - L.padTop
        guard p.y <= top else { return nil }
        let idx = Int((top - p.y) / L.gaugeH)
        return (idx >= 0 && idx < snapshot.gauges.count) ? idx : nil
    }

    /// Top edge of the session list, mirroring the draw() layout.
    private func sessionsTop() -> CGFloat {
        return bounds.height - L.padTop
             - CGFloat(snapshot.gauges.count) * L.gaugeH - L.sepBlock
    }

    /// Which session row sits under this point, if any.
    func sessionIndex(at p: NSPoint) -> Int? {
        guard !compact, !snapshot.sessions.isEmpty, p.y <= sessionsTop() else { return nil }
        let idx = Int((sessionsTop() - p.y) / L.sessionH)
        return (idx >= 0 && idx < snapshot.sessions.count) ? idx : nil
    }

    /// Right-clicking a session row opens that session's menu; elsewhere, the panel menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        if let i = sessionIndex(at: p), let build = sessionMenu {
            return build(snapshot.sessions[i])
        }
        return super.menu(for: event)
    }

    var sessionMenu: ((Session) -> NSMenu)?
    var onGaugeClick: ((String, NSEvent) -> Void)?
    private var hoverIndex: Int? { didSet { if oldValue != hoverIndex { needsDisplay = true } } }
    private var hoverGauge: Int? { didSet { if oldValue != hoverGauge { needsDisplay = true } } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverIndex = sessionIndex(at: p)
        let g = gaugeIndex(at: p)
        hoverGauge = (g != nil && snapshot.gauges[g!].title == "RAM") ? g : nil
    }

    override func mouseExited(with event: NSEvent) { hoverIndex = nil; hoverGauge = nil }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if toggleRect().insetBy(dx: -4, dy: -4).contains(p) {
            onToggle?()
            return
        }
        if let i = gaugeIndex(at: p), snapshot.gauges[i].title == "RAM" {
            onGaugeClick?(snapshot.gauges[i].title, event)
            return
        }
        window?.performDrag(with: event)      // keep the panel draggable
    }

    private func drawToggle() {
        let r = toggleRect()
        let glyph = compact ? "▸" : "▾"
        let f = NSFont.systemFont(ofSize: 10, weight: .bold)
        let a: [NSAttributedString.Key: Any] = [.font: f,
            .foregroundColor: NSColor.white.withAlphaComponent(0.45)]
        let str = NSAttributedString(string: glyph, attributes: a)
        str.draw(at: NSPoint(x: r.midX - str.size().width / 2,
                             y: r.midY - str.size().height / 2))
    }

    private func chipColor(_ v: Double?, warn: Double, crit: Double) -> NSColor {
        guard let v else { return NSColor.white.withAlphaComponent(0.5) }
        if v <= crit { return NSColor(calibratedRed: 0.95, green: 0.42, blue: 0.40, alpha: 1) }
        if v <= warn { return NSColor(calibratedRed: 0.97, green: 0.76, blue: 0.31, alpha: 1) }
        return NSColor.white.withAlphaComponent(0.88)
    }

    private func drawCompact() {
        let s = snapshot.summary
        let y = bounds.height / 2 - 6
        var x = L.padX - 2

        func chip(_ label: String, _ value: String, _ color: NSColor) {
            let lw = text(label, x: x, y: y + 1, size: 8.5, weight: .semibold, alpha: 0.34)
            x += lw + 3
            let vw = text(value, x: x, y: y, size: 11, weight: .medium, alpha: 1, color: color)
            x += vw + 8
        }

        let busy = NSColor(calibratedRed: 0.36, green: 0.80, blue: 0.51, alpha: 1)
        chip("S", "\(s.active)/\(s.total)",
             s.active > 0 ? busy : NSColor.white.withAlphaComponent(0.6))
        chip("C", s.claudeLeft.map { String(format: "%.0f%%", $0) } ?? "–",
             chipColor(s.claudeLeft, warn: 25, crit: 10))
        chip("X", s.codexLeft.map { String(format: "%.0f%%", $0) } ?? "–",
             chipColor(s.codexLeft, warn: 25, crit: 10))
        chip("R", s.ramFree.map { String(format: "%.1fG", $0) } ?? "–",
             chipColor(s.ramFree, warn: 2, crit: 1))
        chip("D", s.diskFree.map { String(format: "%.0fG", $0) } ?? "–",
             chipColor(s.diskFree, warn: 20, crit: 8))
        drawToggle()
    }

    private func barColor(_ pct: Double) -> NSColor {
        switch pct {
        case ..<60: return NSColor(calibratedRed: 0.36, green: 0.80, blue: 0.51, alpha: 1)
        case ..<85: return NSColor(calibratedRed: 0.97, green: 0.76, blue: 0.31, alpha: 1)
        default:    return NSColor(calibratedRed: 0.95, green: 0.42, blue: 0.40, alpha: 1)
        }
    }

    private func stateColor(_ s: String) -> NSColor {
        switch s {
        case "working":   return NSColor(calibratedRed: 0.36, green: 0.80, blue: 0.51, alpha: 1)
        case "running":   return NSColor(calibratedRed: 0.42, green: 0.66, blue: 0.95, alpha: 1)
        case "slow":      return NSColor(calibratedRed: 0.97, green: 0.62, blue: 0.26, alpha: 1)
        case "attention": return NSColor(calibratedRed: 0.97, green: 0.80, blue: 0.31, alpha: 1)
        case "error", "stuck":
                          return NSColor(calibratedRed: 0.95, green: 0.36, blue: 0.34, alpha: 1)
        default:          return NSColor.white.withAlphaComponent(0.30)
        }
    }

    private func isProblem(_ s: String) -> Bool {
        return ["slow", "attention", "error", "stuck"].contains(s)
    }

    private func stateLabel(_ s: String) -> String {
        switch s {
        case "working":   return "작업 중"
        case "running":   return "실행 중"
        case "slow":      return "지연"
        case "attention": return "승인 대기?"
        case "error":     return "API 오류"
        case "stuck":     return "응답 없음"
        default:          return "유휴"
        }
    }

    @discardableResult
    private func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat,
                      weight: NSFont.Weight = .regular, alpha: CGFloat = 1,
                      color: NSColor = .white, rightEdge: CGFloat? = nil,
                      maxWidth: CGFloat? = nil) -> CGFloat {
        var body = s
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        let attrs: [NSAttributedString.Key: Any] =
            [.font: font, .foregroundColor: color.withAlphaComponent(alpha)]
        var str = NSAttributedString(string: body, attributes: attrs)
        if let mw = maxWidth, str.size().width > mw {
            while body.count > 1, str.size().width > mw {
                body.removeLast()
                str = NSAttributedString(string: body + "…", attributes: attrs)
            }
        }
        var origin = NSPoint(x: x, y: y)
        if let r = rightEdge { origin.x = r - str.size().width }
        str.draw(at: origin)
        return str.size().width
    }

    private static func ageString(_ a: Double?) -> String {
        guard let a else { return "–" }
        if a < 60 { return String(format: "%.0fs", a) }
        if a < 3600 { return String(format: "%.0fm", a / 60) }
        return String(format: "%.1fh", a / 3600)
    }

    override func draw(_ dirtyRect: NSRect) {
        if compact { drawCompact(); return }
        drawToggle()
        let w = bounds.width
        let right = w - L.padX
        var y = bounds.height - L.padTop

        // ---- gauges
        for (gi, g) in snapshot.gauges.enumerated() {
            if gi == hoverGauge {
                let band = NSRect(x: L.padX - 5, y: y - L.gaugeH + 6,
                                  width: w - (L.padX - 5) * 2, height: L.gaugeH - 2)
                NSColor.white.withAlphaComponent(0.07).setFill()
                NSBezierPath(roundedRect: band, xRadius: 4, yRadius: 4).fill()
            }
            y -= 15
            let dim: CGFloat = g.stale ? 0.45 : 1.0
            text(g.title, x: L.padX, y: y, size: 11.5, weight: .semibold, alpha: 0.92 * dim)
            text(g.detail, x: 0, y: y, size: 11, alpha: 0.62 * dim, rightEdge: right)
            y -= 9
            let track = NSRect(x: L.padX, y: y, width: w - L.padX * 2, height: 4)
            NSColor.white.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            if let pct = g.pct {
                let frac = max(0.02, min(pct / 100.0, 1.0))
                let fill = NSRect(x: L.padX, y: y, width: track.width * frac, height: 4)
                let c = g.severity.map { [0: 59.0, 1: 70.0, 2: 95.0][$0] ?? 59.0 } ?? pct
                barColor(c).withAlphaComponent(dim).setFill()
                NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
            }
            y -= 6
        }

        // ---- separator + session header
        y -= 8
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(rect: NSRect(x: L.padX, y: y + 4, width: w - L.padX * 2, height: 1)).fill()
        let problems = snapshot.sessions.filter { isProblem($0.state) }.count
        let busy = snapshot.sessions.filter { $0.state == "working" || $0.state == "running" }.count
        let totalMem = snapshot.sessions.compactMap { $0.mem }.reduce(0, +)
        let memLabel = totalMem > 0 ? String(format: " · %.1fGB", totalMem / 1024) : ""
        text("SESSIONS \(snapshot.sessions.count)\(memLabel)", x: L.padX, y: y - 8, size: 9,
             weight: .semibold, alpha: 0.38)
        if problems > 0 {
            text("확인 \(problems)", x: 0, y: y - 8, size: 9, weight: .semibold,
                 alpha: 0.95, color: stateColor("stuck"), rightEdge: right)
        } else if busy > 0 {
            text("작업 \(busy)", x: 0, y: y - 8, size: 9, weight: .semibold,
                 alpha: 0.75, color: stateColor("working"), rightEdge: right)
        }
        y -= L.sepBlock - 8

        // ---- sessions
        if snapshot.sessions.isEmpty {
            text("실행 중인 세션 없음", x: L.padX, y: y - 10, size: 10.5, alpha: 0.35)
            y -= L.sessionH
        }
        for (i, s) in snapshot.sessions.enumerated() {
            y -= L.sessionH
            if i == hoverIndex {
                let band = NSRect(x: L.padX - 5, y: y - 3, width: w - (L.padX - 5) * 2,
                                  height: L.sessionH)
                NSColor.white.withAlphaComponent(0.07).setFill()
                NSBezierPath(roundedRect: band, xRadius: 4, yRadius: 4).fill()
            }
            let dotR = NSRect(x: L.padX + 1, y: y + 4, width: 6, height: 6)
            stateColor(s.state).setFill()
            NSBezierPath(ovalIn: dotR).fill()

            // idle rows show only the age — the grey dot already says "idle"
            let label = s.state == "idle"
                ? Self.ageString(s.age)
                : stateLabel(s.state) + "  " + Self.ageString(s.age)
            let labelW = NSAttributedString(
                string: label,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)]
            ).size().width
            let nameAlpha: CGFloat = s.state == "idle" ? 0.55 : (isProblem(s.state) ? 1.0 : 0.92)
            text(s.name, x: L.padX + 13, y: y, size: 10.5, weight: .medium, alpha: nameAlpha,
                 maxWidth: w - L.padX * 2 - 13 - labelW - 8)
            text(label, x: 0, y: y, size: 10,
                 alpha: s.state == "idle" ? 0.35 : 0.80,
                 color: s.state == "idle" ? .white : stateColor(s.state),
                 rightEdge: right)
        }
    }
}

// MARK: - Panel

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Killing from outside makes the owning window report the exit as a failure.
    /// It is SIGTERM's normal code (128+15) and the session still archives cleanly.
    static let exitCodeNote = "종료 뒤 그 창에 \"exited with code 143\" 이 뜹니다 — SIGTERM 의 정상 코드이고, 세션은 정상적으로 보관됩니다."
    private var panel: HUDPanel!
    private var view: HUDView!
    private var timer: Timer?
    private var sessionCount = 0
    private var compact = false
    private let scriptURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Applications/UsageHUD/stats.py")

    func applicationDidFinishLaunching(_ note: Notification) {
        let size = NSSize(width: L.width, height: L.height(gauges: 4, sessions: 0))
        let rect = NSRect(origin: .zero, size: size)

        panel = HUDPanel(contentRect: rect,
                         styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
                         backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary,
                                    .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        panel.appearance = NSAppearance(named: .darkAqua)

        let blur = NSVisualEffectView(frame: rect)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        blur.autoresizingMask = [.width, .height]

        view = HUDView(frame: rect)
        view.autoresizingMask = [.width, .height]
        compact = UserDefaults.standard.bool(forKey: "hudCompact")
        view.compact = compact
        view.onToggle = { [weak self] in self?.toggleCompact() }
        view.sessionMenu = { [weak self] s in self?.buildSessionMenu(s) ?? NSMenu() }
        view.onGaugeClick = { [weak self] title, event in
            guard title == "RAM" else { return }
            self?.showMemoryBreakdown(event)
        }
        blur.addSubview(view)
        panel.contentView = blur

        panel.menu = buildMenu()
        panel.menu?.delegate = self
        view.menu = panel.menu

        applySize(animated: false)
        restoreFrame(size: panel.frame.size)
        panel.orderFrontRegardless()

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.saveFrame() }
    }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "새로고침", action: #selector(refresh), keyEquivalent: "r").target = self
        let ci = m.addItem(withTitle: "작은 화면", action: #selector(toggleCompact),
                           keyEquivalent: "m")
        ci.target = self
        ci.tag = 800
        m.addItem(.separator())
        let cleanItem = m.addItem(withTitle: "유휴 세션 정리", action: nil, keyEquivalent: "")
        cleanItem.tag = 900
        m.setSubmenu(NSMenu(), for: cleanItem)
        m.addItem(.separator())
        let opacity = NSMenu()
        for v in [100, 85, 70, 55, 40] {
            let it = opacity.addItem(withTitle: "\(v)%", action: #selector(setOpacity(_:)),
                                     keyEquivalent: "")
            it.target = self
            it.tag = v
        }
        let oi = m.addItem(withTitle: "투명도", action: nil, keyEquivalent: "")
        m.setSubmenu(opacity, for: oi)
        m.addItem(.separator())
        m.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)),
                  keyEquivalent: "q")
        return m
    }

    /// Rebuild the cleanup submenu from the current snapshot each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 800)?.state = compact ? .on : .off
        guard let item = menu.item(withTag: 900), let sub = item.submenu else { return }
        sub.removeAllItems()
        var any = false
        for hours in [1.0, 3.0, 5.0] {
            let victims = idleSessions(olderThan: hours)
            let mb = victims.compactMap { $0.mem }.reduce(0, +)
            let title = victims.isEmpty
                ? String(format: "%.0f시간 이상 — 없음", hours)
                : String(format: "%.0f시간 이상 — %d개, %.0fMB", hours, victims.count, mb)
            let it = sub.addItem(withTitle: title,
                                 action: victims.isEmpty ? nil : #selector(cleanSessions(_:)),
                                 keyEquivalent: "")
            if !victims.isEmpty {
                it.target = self
                it.representedObject = hours
                any = true
            }
        }
        _ = any
    }

    private func idleSessions(olderThan hours: Double) -> [Session] {
        return view.snapshot.sessions.filter {
            $0.state == "idle" && ($0.age ?? 0) > hours * 3600 && $0.pid > 0 && $0.killable
        }
    }

    @objc private func cleanSessions(_ sender: NSMenuItem) {
        guard let hours = sender.representedObject as? Double else { return }
        let victims = idleSessions(olderThan: hours)
        guard !victims.isEmpty else { return }
        let mb = victims.compactMap { $0.mem }.reduce(0, +)

        let alert = NSAlert()
        alert.messageText = String(format: "유휴 세션 %d개를 종료할까요?", victims.count)
        let list = victims.prefix(12).map {
            String(format: "  • %@  (%.1fh, %.0fMB)", $0.name, ($0.age ?? 0) / 3600, $0.mem ?? 0)
        }.joined(separator: "\n")
        let more = victims.count > 12 ? "\n  … 외 \(victims.count - 12)개" : ""
        alert.informativeText = list + more
            + String(format: "\n\n약 %.0fMB를 회수합니다.\n대화 기록은 지워지지 않습니다 — claude --resume 으로 이어서 할 수 있습니다.\n", mb)
            + Self.exitCodeNote
        alert.alertStyle = .warning
        alert.addButton(withTitle: "종료")
        alert.addButton(withTitle: "취소")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var killed = 0
        for v in victims where kill(v.pid, SIGTERM) == 0 { killed += 1 }
        refresh()

        let done = NSAlert()
        done.messageText = String(format: "%d개 세션을 종료했습니다", killed)
        done.informativeText = String(format: "약 %.0fMB 회수됨", mb)
        done.addButton(withTitle: "확인")
        done.runModal()
    }

    /// Clicking the RAM row opens the per-app breakdown behind the number.
    private func showMemoryBreakdown(_ event: NSEvent) {
        let apps = view.snapshot.topMemory
        let m = NSMenu()
        let head = m.addItem(withTitle: "메모리 상위", action: nil, keyEquivalent: "")
        head.attributedTitle = NSAttributedString(string: "메모리 상위", attributes:
            [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])

        if apps.isEmpty {
            m.addItem(withTitle: "데이터 없음", action: nil, keyEquivalent: "")
        }
        for a in apps {
            let size = a.mb >= 1024 ? String(format: "%.2f GB", a.mb / 1024)
                                    : String(format: "%.0f MB", a.mb)
            /* 긴 프로세스 이름(com.apple.WebKit.WebContent 등)이 열을 밀지 않게 자른다. */
            let name = a.name.count > 22 ? String(a.name.prefix(21)) + "…" : a.name
            var line = String(format: "%-22@ %8@", name as NSString, size as NSString)
            /* 한 프로세스가 그룹의 절반을 넘으면 그게 원인일 확률이 높다.
               탭 30개가 조금씩 쓰는 것과 확장 하나가 새는 것은 대응이 다르다. */
            if a.count > 1 && a.maxMb > a.mb * 0.5 {
                line += String(format: "  (한 프로세스가 %.0fMB)", a.maxMb)
            } else if a.count > 1 {
                line += String(format: "  (%d개)", a.count)
            }
            let it = m.addItem(withTitle: line, action: nil, keyEquivalent: "")
            it.attributedTitle = NSAttributedString(string: line, attributes:
                [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
        }

        m.addItem(.separator())
        if let g = view.snapshot.gauges.first(where: { $0.title == "RAM" }) {
            m.addItem(withTitle: g.detail, action: nil, keyEquivalent: "")
        }
        m.popUp(positioning: nil, at: event.locationInWindow, in: view.superview)
    }

    private func buildSessionMenu(_ s: Session) -> NSMenu {
        let m = NSMenu()
        let head = m.addItem(withTitle: s.name, action: nil, keyEquivalent: "")
        head.attributedTitle = NSAttributedString(string: s.name, attributes:
            [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        let age = s.age.map { $0 < 3600 ? String(format: "%.0f분", $0 / 60)
                                        : String(format: "%.1f시간", $0 / 3600) } ?? "–"
        let mem = s.mem.map { String(format: " · %.0fMB", $0) } ?? ""
        m.addItem(withTitle: "PID \(s.pid) · \(age) 전\(mem)", action: nil, keyEquivalent: "")
        m.addItem(.separator())

        if s.killable {
            let kill = m.addItem(withTitle: "이 세션 종료", action: #selector(killOne(_:)),
                                 keyEquivalent: "")
            kill.target = self
            kill.representedObject = s
        } else {
            m.addItem(withTitle: "종료 불가 — 프로세스 확인 실패", action: nil, keyEquivalent: "")
        }
        return m
    }

    @objc private func killOne(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Session, s.killable, s.pid > 0 else { return }

        let alert = NSAlert()
        alert.messageText = "이 세션을 종료할까요?"
        var body = "\(s.name)\nPID \(s.pid)"
        if s.state != "idle" {
            body += "\n\n⚠ 지금 작업 중입니다. 진행 중인 내용이 중단됩니다."
            alert.alertStyle = .critical
        } else {
            alert.alertStyle = .warning
        }
        body += "\n\n대화 기록은 지워지지 않습니다 — claude --resume 으로 이어서 할 수 있습니다."
        body += "\n" + Self.exitCodeNote
        alert.informativeText = body
        alert.addButton(withTitle: "종료")
        alert.addButton(withTitle: "취소")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        kill(s.pid, SIGTERM)
        refresh()
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        let a = CGFloat(sender.tag) / 100.0
        panel.alphaValue = a
        UserDefaults.standard.set(Double(a), forKey: "hudAlpha")
    }

    private func restoreFrame(size: NSSize) {
        let d = UserDefaults.standard
        if let alpha = d.object(forKey: "hudAlpha") as? Double { panel.alphaValue = CGFloat(alpha) }
        if let s = d.string(forKey: "hudTopLeft") {
            let p = NSPointFromString(s)     // stored as top-left
            let f = NSRect(x: p.x, y: p.y - size.height, width: size.width, height: size.height)
            panel.setFrame(f, display: false)
            if NSScreen.screens.contains(where: { $0.frame.intersects(panel.frame) }) { return }
        }
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - size.width - 18, y: v.maxY - size.height - 18))
        }
    }

    private func saveFrame() {
        let f = panel.frame
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: f.minX, y: f.maxY)),
                                  forKey: "hudTopLeft")
    }

    private func targetSize() -> NSSize {
        return compact
            ? NSSize(width: L.compactWidth, height: L.compactHeight)
            : NSSize(width: L.width, height: L.height(gauges: 4, sessions: sessionCount))
    }

    /// Resize around the top-left corner so the panel never walks up the screen.
    private func applySize(animated: Bool) {
        let t = targetSize()
        let f = panel.frame
        guard abs(f.width - t.width) > 0.5 || abs(f.height - t.height) > 0.5 else { return }
        panel.setFrame(NSRect(x: f.minX, y: f.maxY - t.height, width: t.width, height: t.height),
                       display: true, animate: animated)
    }

    private func resize(sessions: Int) {
        guard sessions != sessionCount else { return }
        sessionCount = sessions
        applySize(animated: false)
    }

    @objc private func toggleCompact() {
        compact.toggle()
        view.compact = compact
        UserDefaults.standard.set(compact, forKey: "hudCompact")
        applySize(animated: false)
        saveFrame()
    }

    // MARK: data

    @objc private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snap = self.collect()
            DispatchQueue.main.async {
                self.resize(sessions: snap.sessions.count)
                self.view.snapshot = snap
            }
        }
    }

    private func collect() -> Snapshot {
        let proc = Process()
        // GUI apps do not inherit the shell PATH, so resolve python explicitly.
        let py = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
        proc.executableURL = URL(fileURLWithPath: py)
        proc.arguments = [scriptURL.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch {
            return Snapshot(gauges: [Gauge(title: "오류", detail: "stats.py 실행 실패", pct: nil)], sessions: [])
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Snapshot(gauges: [Gauge(title: "오류", detail: "데이터 파싱 실패", pct: nil)], sessions: [])
        }
        return parse(json)
    }

    private func parse(_ json: [String: Any]) -> Snapshot {
        var gauges: [Gauge] = []

        if let c = json["claude"] as? [String: Any],
           let pct = c["pct"] as? Double, let value = c["value"] as? Double,
           let budget = c["budget"] as? Double {
            let measured = c["measured"] as? Bool ?? false
            let detail: String
            if measured {
                let weekly = (c["weekly"] as? Double).map { String(format: " · 주 %.0f%%", $0) } ?? ""
                detail = String(format: "5h %.0f%%", pct) + weekly
            } else {
                detail = String(format: "5h ~%.0f%%  ($%.0f/%.0f)", pct, value, budget)
            }
            gauges.append(Gauge(title: "Claude", detail: detail, pct: pct))
        } else {
            gauges.append(Gauge(title: "Claude", detail: "데이터 없음", pct: nil))
        }

        if let x = json["codex"] as? [String: Any], x["expired"] as? Bool == true {
            /* 5시간 창이 이미 여러 번 리셋된 값이라 숫자를 보여주면 거짓말이 된다. */
            let age = Date().timeIntervalSince1970 - ((x["as_of"] as? Double) ?? 0)
            gauges.append(Gauge(title: "Codex",
                                detail: String(format: "만료 (%.0f시간 전 기록)", age / 3600),
                                pct: nil, stale: true))
        } else if let x = json["codex"] as? [String: Any], let p = x["primary_pct"] as? Double {
            let weekly = (x["secondary_pct"] as? Double).map { String(format: " · 주 %.0f%%", $0) } ?? ""
            let age = Date().timeIntervalSince1970 - ((x["as_of"] as? Double) ?? 0)
            gauges.append(Gauge(title: "Codex", detail: String(format: "5h %.0f%%", p) + weekly,
                                pct: p, stale: age > 3 * 3600))
        } else {
            gauges.append(Gauge(title: "Codex", detail: "데이터 없음", pct: nil))
        }

        if let m = json["memory"] as? [String: Any], let pct = m["pct"] as? Double,
           let used = m["used"] as? Double, let total = m["total"] as? Double {
            let gb = 1024.0 * 1024 * 1024
            let sev = m["severity"] as? Int ?? 0
            var detail = String(format: "%.1f / %.0fGB", used / gb, total / gb)
            /* 스왑 total 은 macOS 가 동적으로 조절하므로 비율 대신 절대량만 쓴다. */
            if let sw = m["swap_used"] as? Double, sw > 0.2 * gb {
                detail += String(format: "  스왑 %.1fG", sw / gb)
            }
            gauges.append(Gauge(title: "RAM", detail: detail, pct: pct, severity: sev))
        } else {
            gauges.append(Gauge(title: "RAM", detail: "데이터 없음", pct: nil))
        }

        if let d = json["disk"] as? [String: Any], let pct = d["pct"] as? Double,
           let free = d["free"] as? Double, let total = d["total"] as? Double {
            let gb = 1024.0 * 1024 * 1024
            gauges.append(Gauge(title: "Disk",
                                detail: String(format: "%.0fGB free / %.0fGB", free / gb, total / gb),
                                pct: pct))
        } else {
            gauges.append(Gauge(title: "Disk", detail: "데이터 없음", pct: nil))
        }

        var sessions: [Session] = []
        for raw in (json["sessions"] as? [[String: Any]] ?? []) {
            sessions.append(Session(name: raw["name"] as? String ?? "?",
                                    cwd: raw["cwd"] as? String ?? "",
                                    state: raw["state"] as? String ?? "idle",
                                    age: raw["age"] as? Double,
                                    mem: raw["mem"] as? Double,
                                    pid: Int32((raw["pid"] as? Int) ?? 0),
                                    killable: raw["killable"] as? Bool ?? false))
        }

        var sum = Summary()
        sum.total = sessions.count
        sum.active = sessions.filter { $0.state != "idle" }.count
        if let c = json["claude"] as? [String: Any], let p = c["pct"] as? Double {
            sum.claudeLeft = max(0, 100 - p)
        }
        if let x = json["codex"] as? [String: Any], let p = x["primary_pct"] as? Double {
            sum.codexLeft = max(0, 100 - p)
        }
        let gb = 1024.0 * 1024 * 1024
        if let m = json["memory"] as? [String: Any], let f = m["free"] as? Double {
            sum.ramFree = f / gb
        }
        if let d = json["disk"] as? [String: Any], let f = d["free"] as? Double {
            sum.diskFree = f / gb
        }
        var top: [MemApp] = []
        for raw in (json["top_memory"] as? [[String: Any]] ?? []) {
            top.append(MemApp(name: raw["name"] as? String ?? "?",
                              mb: raw["mb"] as? Double ?? 0,
                              maxMb: raw["max"] as? Double ?? 0,
                              count: raw["count"] as? Int ?? 0))
        }
        return Snapshot(gauges: gauges, sessions: sessions, summary: sum, topMemory: top)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
