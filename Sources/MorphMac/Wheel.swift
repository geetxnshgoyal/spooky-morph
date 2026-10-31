import AppKit
import Carbon.HIToolbox
import SwiftUI
import MorphCore

// MARK: - Geometry

/// The wheel's measurements, shared by the panel (to centre the wheel on the cursor) and the view.
enum WheelMetrics {
    static let width: CGFloat = 440
    static let height: CGFloat = 496
    /// Centre of the ring, from the panel's top-left; the wheel bar hangs below the ring.
    static let center = CGPoint(x: 220, y: 220)
    static let outerRadius: CGFloat = 168
    static let innerRadius: CGFloat = 88
    static let hubRadius: CGFloat = 76
    /// Neighbouring petals are this far apart all the way out.
    static let gapWidth: CGFloat = 7
    /// How far a highlighted petal grows outward.
    static let lift: CGFloat = 12
    /// Square the ring is drawn in, with room for a lifted petal.
    static let side: CGFloat = (outerRadius + lift + 12) * 2
    static let labelRadius: CGFloat = (innerRadius + outerRadius) / 2 + 2
}

// MARK: - Wheel window

@MainActor
final class WheelPanel: NSPanel {
    private var monitor: Any?
    let model: WheelModel

    init(files: [URL], dropMode: Bool = false, group: Action.Group? = nil) {
        model = WheelModel(files: files, dropMode: dropMode, group: group)
        super.init(contentRect: NSRect(x: 0, y: 0, width: WheelMetrics.width, height: WheelMetrics.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        model.dismiss = { [weak self] in self?.close() }
        let host = NSHostingView(rootView: WheelView(model: model))
        host.frame = contentRect(forFrameRect: frame)
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    func present(at point: NSPoint) {
        // Centre the ring (not the panel) under the cursor, keeping the whole panel on the cursor's screen.
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        var origin = NSPoint(x: point.x - WheelMetrics.center.x,
                             y: point.y - (WheelMetrics.height - WheelMetrics.center.y))
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - WheelMetrics.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - WheelMetrics.height)
        }
        setFrameOrigin(origin)
        alphaValue = 0
        if model.dropMode {
            // Activating now would cancel the drag in progress.
            orderFrontRegardless()
        } else {
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // The folder permission panel runs in another process; clicking it isn't clicking away.
            MainActor.assumeIsolated { if !FolderAccess.isAsking { self?.close() } }
        }
    }

    /// Scrolling and keys steer the wheel before SwiftUI sees them.
    override func sendEvent(_ event: NSEvent) {
        guard case .choosing = model.phase else { return super.sendEvent(event) }
        switch event.type {
        case .scrollWheel:
            model.scroll(event)
            return
        case .keyDown:
            switch Int(event.keyCode) {
            case kVK_RightArrow, kVK_DownArrow: model.step(1); return
            case kVK_LeftArrow, kVK_UpArrow: model.step(-1); return
            case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: model.runHighlighted(); return
            case kVK_Tab: model.cycleGroup(event.modifierFlags.contains(.shift) ? -1 : 1); return
            case kVK_Escape: close(); return
            default: break
            }
        default: break
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) { close() }

    /// Closing melts the wheel back into a drop (unless Reduce Motion is on) before the window goes.
    override func close() {
        guard !isClosing else { return }
        isClosing = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return super.close() }
        model.closing = true
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.24; animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { super.close() }
        }
    }

    private var isClosing = false
}

// MARK: - Wheel model

@MainActor
final class WheelModel: ObservableObject {
    enum Phase { case choosing, running(Action, done: Int, total: Int), finished(Action, RunResult) }

    /// Petals per ring; more actions than this page around with a turn of the wheel.
    static let perPage = 8

    private(set) var files: [URL]
    let actions: [Action]
    let dropMode: Bool
    @Published private(set) var group: Action.Group
    @Published private(set) var page = 0
    @Published var phase: Phase = .choosing
    /// The window is going away: the view plays the wheel's exit.
    @Published var closing = false
    @Published var hovered: String? {
        didSet { if hovered != oldValue, hovered != nil { Feedback.shared.tick() } }
    }
    var dismiss: () -> Void = {}
    private var scrollAccumulator: CGFloat = 0

    init(files: [URL], dropMode: Bool = false, group: Action.Group? = nil) {
        self.files = files
        self.dropMode = dropMode
        // Work on a local copy: closures can't read `self` until every property is set.
        let available = Library.actions(for: files) + FileActions.actions(for: files)
        actions = available
        let fallback: Action.Group = available.contains { $0.group == .convert } ? .convert : .tool
        self.group = group.flatMap { g in available.contains { $0.group == g } ? g : nil } ?? fallback
    }

    var groups: [Action.Group] {
        Preferences.wheels.filter { g in actions.contains { $0.group == g } }
    }

    var visible: [Action] { actions.filter { $0.group == group } }
    var pages: Int { max(1, (visible.count + Self.perPage - 1) / Self.perPage) }
    var pageItems: [Action] { Array(visible.dropFirst(page * Self.perPage).prefix(Self.perPage)) }

    var summary: String {
        let kinds = Set(files.map { FileKind(url: $0) })
        let noun = kinds.count == 1 ? kinds.first!.rawValue : "file"
        return files.count == 1 ? files[0].lastPathComponent : "\(files.count) \(noun)s"
    }

    /// Centre of petal `index`, in degrees: the first points straight up, the rest follow clockwise.
    static func angle(of index: Int, count: Int) -> Double {
        Double(index) / Double(max(count, 1)) * 360 - 90
    }

    /// The petal under `point` (relative to the ring's centre), or nil over the hub or far outside the ring.
    static func slot(at point: CGPoint, count: Int) -> Int? {
        let distance = hypot(point.x, point.y)
        guard count > 0, distance >= WheelMetrics.hubRadius,
              distance <= WheelMetrics.outerRadius + WheelMetrics.lift + 24 else { return nil }
        let sector = 360 / Double(count)
        var degrees = atan2(point.y, point.x) * 180 / .pi + 90
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        return Int((degrees + sector / 2) / sector) % count
    }

    var motion: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82)
    }

    // MARK: Navigation

    func select(_ newGroup: Action.Group) {
        guard newGroup != group, groups.contains(newGroup) else { return }
        withAnimation(motion) {
            group = newGroup
            page = 0
            hovered = nil
        }
        Feedback.shared.tick()
    }

    func cycleGroup(_ delta: Int) {
        guard let i = groups.firstIndex(of: group), groups.count > 1 else { return }
        select(groups[(i + delta + groups.count) % groups.count])
    }

    /// Highlights the petal under `point`, as the pointer or a drag moves over the ring.
    func hover(at point: CGPoint) {
        let items = pageItems
        hovered = Self.slot(at: point, count: items.count).map { items[$0].id }
    }

    func action(at point: CGPoint) -> Action? {
        let items = pageItems
        return Self.slot(at: point, count: items.count).map { items[$0] }
    }

    /// Moves the highlight around the ring, turning to the next page at the ends.
    func step(_ delta: Int) {
        let items = pageItems
        guard !items.isEmpty else { return }
        guard let id = hovered, let i = items.firstIndex(where: { $0.id == id }) else {
            hovered = (delta >= 0 ? items.first : items.last)?.id
            return
        }
        let j = i + delta
        if j >= items.count || j < 0 {
            if pages > 1 {
                turnPage(j < 0 ? -1 : 1)
                hovered = (j < 0 ? pageItems.last : pageItems.first)?.id
            } else {
                hovered = items[(j + items.count) % items.count].id
            }
            return
        }
        hovered = items[j].id
    }

    func turnPage(_ delta: Int) {
        guard pages > 1 else { return }
        withAnimation(motion) { page = (page + delta + pages) % pages }
    }

    /// Mouse wheel: one notch per step. Trackpad: a step every few points of travel.
    func scroll(_ event: NSEvent) {
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : -event.scrollingDeltaX
        guard delta != 0 else { return }
        guard event.hasPreciseScrollingDeltas else { step(delta < 0 ? 1 : -1); return }
        scrollAccumulator += delta
        let threshold: CGFloat = 16
        while abs(scrollAccumulator) >= threshold {
            step(scrollAccumulator < 0 ? 1 : -1)
            scrollAccumulator -= scrollAccumulator < 0 ? -threshold : threshold
        }
        if event.phase == .ended || event.momentumPhase == .ended { scrollAccumulator = 0 }
    }

    /// Takes the files from a drop on the wheel. The App Store build can't read a dragged file until it's dropped
    /// on Morph, so the paths seen mid-drag only pick the actions; the drop itself brings the access.
    func takeDropped(_ pasteboard: NSPasteboard) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { files = urls.map(\.standardizedFileURL) }
    }

    func runHighlighted() {
        if let action = pageItems.first(where: { $0.id == hovered }) { run(action) }
    }

    // MARK: Running

    func run(_ action: Action) {
        let files = files
        let prefs = Preferences.shared
        if action.group == .file {
            // Acts on the files themselves and may open its own window, so get out of the way first.
            dismiss()
            Task {
                do { _ = try await action.run(files, Options()) } catch { FileActions.report(error) }
            }
            return
        }
        guard let options = prefs.options(for: files) else { dismiss(); return }
        phase = .running(action, done: 0, total: files.count)
        Task {
            let result = await Runner.run(action, inputs: files, options: options) { done, total in
                Task { @MainActor in
                    if case .running = self.phase { self.phase = .running(action, done: done, total: total) }
                }
            }
            phase = .finished(action, result)
            if result.failures.isEmpty {
                Feedback.shared.done()
                if prefs.revealWhenDone, !result.outputs.isEmpty { reveal(result); return }
                // Long enough to read "171 KB → 144 KB".
                try? await Task.sleep(for: .seconds(3.5))
                if case .finished = phase { dismiss() }
            } else {
                Feedback.shared.failed()
            }
        }
    }

    func reveal(_ result: RunResult) {
        NSWorkspace.shared.activateFileViewerSelecting(result.outputs)
        dismiss()
    }
}

// MARK: - Wheel view

/// A ring of glass petals around a glass hub, with a bar below for switching wheels. Each wheel (Convert,
/// Tools, Recipes, Actions) uses the same layout; the bar shows the keys that summon each one mid-drag.
struct WheelView: View {
    @ObservedObject var model: WheelModel
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Open and not on its way out: drives the hub's drop-like entrance and exit.
    private var present: Bool { appeared && !model.closing }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                // Liquid Glass leaves the window's own pixels clear, and macOS hands clicks and drops on clear
                // pixels to the window behind. A fill too faint to see keeps the ring, gaps included, ours.
                Circle().fill(.black.opacity(0.01))
                if case .choosing = model.phase {
                    PetalRing(model: model, items: model.pageItems)
                        .id("\(model.group)-\(model.page)")
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
                WheelHub(model: model)
                    .scaleEffect(present ? 1 : 0.3)
                    .blur(radius: present ? 0 : 12)
                    .opacity(present ? 1 : 0)
            }
            .frame(width: WheelMetrics.side, height: WheelMetrics.side)
            .position(WheelMetrics.center)

            if case .choosing = model.phase, model.groups.count > 1 {
                WheelBar(model: model)
                    .scaleEffect(present ? 1 : 0.85)
                    .opacity(present ? 1 : 0)
                    .position(x: WheelMetrics.center.x, y: WheelMetrics.center.y + WheelMetrics.outerRadius + WheelMetrics.lift + 42)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if Palette.current.isSpooky {
                CornerWeb(present: present).allowsHitTesting(false)
            }
        }
        .frame(width: WheelMetrics.width, height: WheelMetrics.height)
        // In: the hub springs out of a drop. Out: everything is pulled back into it.
        .animation(reduceMotion ? nil : model.closing ? .easeIn(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.6),
                   value: present)
        .onAppear { appeared = true }
    }
}

/// The petals of one page. Every petal blooms out of the hub when the ring appears, so switching wheel or
/// page replays the opening; hover, click and drop all find their petal by position, gaps included.
private struct PetalRing: View {
    @ObservedObject var model: WheelModel
    let items: [Action]
    @State private var bloomed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, action in
                PetalView(action: action, index: index, count: items.count,
                          highlighted: model.hovered == action.id, bloomed: bloomed)
                    .animation(reduceMotion ? nil : model.closing ? .easeIn(duration: 0.18)
                        : .spring(response: 0.48, dampingFraction: 0.74).delay(Double(index) * 0.022), value: bloomed)
                    .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.68),
                               value: model.hovered == action.id)
            }
        }
        .frame(width: WheelMetrics.side, height: WheelMetrics.side)
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location): model.hover(at: centered(location))
            case .ended: model.hovered = nil
            }
        }
        .onTapGesture(coordinateSpace: .local) { location in
            if let action = model.action(at: centered(location)) { model.run(action) }
        }
        // Dropping the dragged files on a petal runs it.
        .onDrop(of: [.fileURL], delegate: RingDropDelegate(model: model, centered: centered))
        .onAppear { bloomed = true }
        .onChange(of: model.closing) { _, closing in if closing { bloomed = false } }
    }

    private func centered(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - WheelMetrics.side / 2, y: point.y - WheelMetrics.side / 2)
    }
}

private struct RingDropDelegate: DropDelegate {
    let model: WheelModel
    let centered: (CGPoint) -> CGPoint

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated { model.hover(at: centered(info.location)) }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { model.hovered = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let action = model.action(at: centered(info.location)) else { return false }
            model.takeDropped(NSPasteboard(name: .drag))
            model.run(action)
            return true
        }
    }
}

/// One action: a glass wedge with a light rim, its icon and its name. Highlighted, it lifts outward and fills with
/// Teal Ink.
private struct PetalView: View {
    let action: Action
    let index: Int
    let count: Int
    let highlighted: Bool
    let bloomed: Bool

    private typealias M = WheelMetrics

    var body: some View {
        let angle = WheelModel.angle(of: index, count: count)
        let shape = PetalShape(centerAngle: angle, sectorAngle: 360 / Double(count), gapWidth: M.gapWidth,
                               innerRadius: highlighted ? M.innerRadius - 3 : M.innerRadius,
                               outerRadius: !bloomed ? M.innerRadius + 6 : highlighted ? M.outerRadius + M.lift : M.outerRadius)
        let radians = angle * .pi / 180
        let labelRadius = M.labelRadius + (highlighted ? M.lift / 2 : 0)

        ZStack {
            Color.clear.wheelGlass(in: shape)
            shape.fill(highlighted ? Theme.brand : Color.clear)
            // The rim is brighter on the highlighted petal so it stands off dark backgrounds too.
            shape.stroke(LinearGradient(colors: [.white.opacity(highlighted ? 0.55 : 0.5), .white.opacity(highlighted ? 0.25 : 0.06)],
                                        startPoint: .top, endPoint: .bottom), lineWidth: highlighted ? 1.5 : 1)
                .opacity(bloomed ? 1 : 0)

            VStack(spacing: 3) {
                Image(systemName: action.symbol).font(.system(size: highlighted ? 19 : 17, weight: .medium))
                Text(action.title).font(Theme.font(10.5, .semibold))
                    .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.75)
            }
            .frame(width: labelWidth)
            .foregroundStyle(highlighted ? Theme.onBrand : Color.primary)
            .offset(x: cos(radians) * labelRadius, y: sin(radians) * labelRadius)
            .opacity(bloomed ? 1 : 0)
        }
        .frame(width: M.side, height: M.side)
        .opacity(bloomed ? 1 : 0)
        .allowsHitTesting(false)
    }

    /// Wide enough to use the petal, narrow enough to stay inside it.
    private var labelWidth: CGFloat {
        let chord = 2 * M.labelRadius * sin(.pi / Double(max(count, 2))) - M.gapWidth - 14
        return min(92, max(54, chord))
    }
}

/// The glass hub: names the highlighted action (or the files), shows progress while running and the result after.
private struct WheelHub: View {
    @ObservedObject var model: WheelModel

    private let diameter = WheelMetrics.hubRadius * 2

    var body: some View {
        ZStack {
            Color.clear.wheelGlass(in: Circle())
                .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05)],
                                                              startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 14)
            if Palette.current.isSpooky {
                HubWeb().stroke(Color.primary.opacity(0.13), lineWidth: 0.7)
                    .frame(width: diameter - 6, height: diameter - 6)
            }
            content.frame(width: diameter - 26)
        }
        .frame(width: diameter, height: diameter)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .choosing:
            VStack(spacing: 5) {
                Text(hoverTitle ?? model.summary)
                    .font(Theme.font(14, .semibold))
                    .lineLimit(2).multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.12), value: model.hovered)
                Text(caption).font(Theme.font(11)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                if model.pages > 1 {
                    HStack(spacing: 4) {
                        ForEach(0..<model.pages, id: \.self) { i in
                            Capsule().fill(i == model.page ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                                .frame(width: i == model.page ? 12 : 5, height: 5)
                        }
                    }
                    .padding(.top, 2)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.page)
                }
            }
        case let .running(action, done, total):
            VStack(spacing: 8) {
                MorphLoader(size: 58)
                Text(action.title).font(Theme.font(14, .semibold))
                if total > 1 { Text("\(done) of \(total)").font(.caption).foregroundStyle(.secondary) }
            }
        case let .finished(action, result):
            // Nothing made and nothing failed: every file was already as small as it can usefully get.
            let unchanged = result.outputs.isEmpty && result.failures.isEmpty && !result.notes.isEmpty
            VStack(spacing: 5) {
                Image(systemName: !result.failures.isEmpty ? "exclamationmark.triangle.fill"
                      : unchanged ? "equal.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(result.failures.isEmpty ? Theme.brandText : Color.red)
                Text(!result.failures.isEmpty ? "\(result.failures.count) failed" : unchanged ? "Already small" : "Done")
                    .font(Theme.font(14, .semibold))
                if action.reportsSize, let sizes = result.sizeSummary, let change = result.sizeChange {
                    Text(sizes).font(Theme.font(12, .semibold)).monospacedDigit()
                    Text(change).font(Theme.font(11)).foregroundStyle(.secondary)
                } else if unchanged {
                    Text("Any smaller would look worse").font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if let first = result.failures.first {
                    Text(first).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                        .multilineTextAlignment(.center)
                }
                if !result.outputs.isEmpty {
                    Button("Show in Finder") { model.reveal(result) }.buttonStyle(SoftButtonStyle())
                }
            }
        }
    }

    private var caption: String {
        if model.actions.isEmpty { return "Nothing fits these files" }
        if model.hovered != nil { return model.dropMode ? "Release to run" : "Click to run" }
        if Palette.current.isSpooky { return "Trick or treat?" }
        return model.dropMode ? "Drop on an action" : model.group.label
    }

    private var hoverTitle: String? {
        model.hovered.flatMap { id in model.actions.first { $0.id == id } }.map { action in
            action.group == .convert ? "Convert to \(action.title)" : action.title
        }
    }
}

/// Glass bar of the wheels these files have, each labelled with the keys that summon it mid-drag. Clicking,
/// Tab, or hovering a drag over one switches to it.
private struct WheelBar: View {
    @ObservedObject var model: WheelModel
    @ObservedObject private var prefs = Preferences.shared
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.groups, id: \.self) { group in
                let selected = group == model.group
                let keys = prefs.dragKeys(for: group)
                Button { model.select(group) } label: {
                    HStack(spacing: 5) {
                        if !keys.isEmpty {
                            Text(keys.symbols).font(Theme.font(11, .bold)).opacity(selected ? 0.85 : 0.5)
                        }
                        Text(group.label).font(Theme.font(12, .semibold))
                    }
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .foregroundStyle(selected ? Theme.onBrand : Color.primary)
                    .background {
                        if selected { Capsule().fill(Theme.brand).matchedGeometryEffect(id: "pill", in: pill) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(keys.isEmpty ? group.label : "\(group.label): tap \(keys.symbols) while dragging")
                // Spring-loaded: hovering a drag over a wheel switches to it.
                .onDrop(of: [.fileURL], isTargeted: Binding(get: { false }, set: { if $0 { model.select(group) } })) { _ in false }
            }
        }
        .padding(4)
        .background(Capsule().fill(.black.opacity(0.01)))
        .wheelGlass(in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}

private extension View {
    /// Liquid Glass that follows the system's Clear or Tinted setting; frosted material before macOS 26.
    func wheelGlass(in shape: some Shape, tint: Color? = nil) -> some View {
        modifier(MorphGlass(shape: shape, tint: tint))
    }
}

/// An annular wedge whose sides run parallel to the boundary between petals, so the gap to each neighbour keeps
/// the same width from hub to rim, with softly rounded corners. Animatable, so a petal can bloom out of the hub
/// and lift when highlighted. Angles are in degrees, clockwise from three o'clock.
struct PetalShape: Shape {
    var centerAngle: Double
    var sectorAngle: Double
    var gapWidth: CGFloat
    var innerRadius: CGFloat
    var outerRadius: CGFloat
    var cornerRadius: CGFloat = 9

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(centerAngle, sectorAngle), AnimatablePair(innerRadius, outerRadius)) }
        set {
            centerAngle = newValue.first.first
            sectorAngle = newValue.first.second
            innerRadius = newValue.second.first
            outerRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        guard outerRadius > innerRadius, innerRadius > 0 else { return path }

        // A lone petal is the whole ring.
        if sectorAngle >= 359.9 {
            path.addArc(center: c, radius: outerRadius, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            path.closeSubpath()
            path.move(to: CGPoint(x: c.x + innerRadius, y: c.y))
            path.addArc(center: c, radius: innerRadius, startAngle: .zero, endAngle: .degrees(-360), clockwise: true)
            path.closeSubpath()
            return path
        }

        let mid = centerAngle * .pi / 180
        // Half the petal's angle at radius r, after giving half the gap to each side.
        func half(_ r: CGFloat) -> Double { sectorAngle * .pi / 360 - Double(asin(min(1, gapWidth / 2 / r))) }
        let ho = half(outerRadius), hi = half(innerRadius)
        guard ho > 0, hi > 0 else { return path }

        func point(_ r: CGFloat, _ a: Double) -> CGPoint { CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)) }
        // Direction of travel along a circle at angle a, toward larger angles.
        func ahead(_ a: Double) -> CGVector { CGVector(dx: -sin(a), dy: cos(a)) }
        func offset(_ p: CGPoint, _ v: CGVector, _ d: CGFloat) -> CGPoint { CGPoint(x: p.x + v.dx * d, y: p.y + v.dy * d) }

        let r = min(cornerRadius, (outerRadius - innerRadius) / 3)
        let outerStart = point(outerRadius, mid - ho), outerEnd = point(outerRadius, mid + ho)
        let innerEnd = point(innerRadius, mid + hi), innerStart = point(innerRadius, mid - hi)

        // Start partway up the leading side, then fillet each corner into the arc beside it.
        path.move(to: CGPoint(x: (innerStart.x + outerStart.x) / 2, y: (innerStart.y + outerStart.y) / 2))
        path.addArc(tangent1End: outerStart, tangent2End: offset(outerStart, ahead(mid - ho), r * 2), radius: r)
        path.addArc(center: c, radius: outerRadius, startAngle: .radians(mid - ho + Double(r / outerRadius)),
                    endAngle: .radians(mid + ho - Double(r / outerRadius)), clockwise: false)
        path.addArc(tangent1End: outerEnd, tangent2End: innerEnd, radius: r)
        path.addArc(tangent1End: innerEnd, tangent2End: offset(innerEnd, ahead(mid + hi), -r * 2), radius: r)
        path.addArc(center: c, radius: innerRadius, startAngle: .radians(mid + hi - Double(r / innerRadius)),
                    endAngle: .radians(mid - hi + Double(r / innerRadius)), clockwise: true)
        path.addArc(tangent1End: innerStart, tangent2End: outerStart, radius: r)
        path.closeSubpath()
        return path
    }
}

extension Action.Group {
    var label: String {
        switch self {
        case .convert: "Convert"
        case .tool: "Tools"
        case .recipe: "Recipes"
        case .file: "Actions"
        }
    }
}

// MARK: - Halloween

/// A web spun in the top-right corner of the wheel's window, with a spider letting itself down on a thread,
/// for the Pumpkin colour. Drawn, not an image, so it stays sharp and follows the motion settings.
private struct CornerWeb: View {
    let present: Bool
    @State private var lowered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let size: CGFloat = 104
    private let spiderX: CGFloat = 26

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Cobweb()
                .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
                .shadow(color: .black.opacity(0.55), radius: 0.6)
                .frame(width: size, height: size)
            // The spider hangs from the web's outer ring, near the window's edge, clear of the petals.
            let drop: CGFloat = lowered ? 92 : 64
            ZStack(alignment: .top) {
                Rectangle().fill(.white.opacity(0.7)).frame(width: 0.7, height: drop)
                Spider().frame(width: 26, height: 22).offset(y: drop - 6)
            }
            .frame(width: 26, height: drop + 22, alignment: .top)
            .offset(x: -spiderX + 13, y: 18)
        }
        .frame(width: size + 10, height: 200, alignment: .topTrailing)
        .opacity(present ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: present)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { lowered = true }
        }
    }
}

/// A corner web: threads fanning out from the top-right corner, joined by rings that sag toward it.
private struct Cobweb: Shape {
    var threads = 6
    var rings: [CGFloat] = [0.22, 0.4, 0.58, 0.76, 0.94]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corner = CGPoint(x: rect.maxX, y: rect.minY)
        let reach = min(rect.width, rect.height)
        // Angles run from straight left (along the top edge) to straight down (along the right edge).
        let angles = (0..<threads).map { Double.pi / 2 * Double($0) / Double(threads - 1) }
        func point(_ angle: Double, _ r: CGFloat) -> CGPoint {
            CGPoint(x: corner.x - r * CGFloat(cos(angle)), y: corner.y + r * CGFloat(sin(angle)))
        }
        for a in angles {
            path.move(to: corner)
            path.addLine(to: point(a, reach))
        }
        for (k, ring) in rings.enumerated() {
            // Hand-spun: each ring a touch uneven, each span sagging toward the corner.
            let r = reach * ring
            for i in 0..<(threads - 1) {
                let wobble = CGFloat((i + k) % 3) * 0.012 * reach
                let a = point(angles[i], r + wobble), b = point(angles[i + 1], r - wobble)
                let mid = point((angles[i] + angles[i + 1]) / 2, r * 0.82)
                if i == 0 { path.move(to: a) }
                path.addQuadCurve(to: b, control: mid)
            }
        }
        return path
    }
}

/// A round web for the hub: spokes from the centre and rings that sag between them.
private struct HubWeb: Shape {
    var spokes = 10
    var rings: [CGFloat] = [0.18, 0.36, 0.55, 0.74, 0.93]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        func point(_ i: Int, _ r: CGFloat) -> CGPoint {
            let a = Double(i) / Double(spokes) * 2 * .pi - .pi / 2
            return CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
        }
        for i in 0..<spokes {
            path.move(to: c)
            path.addLine(to: point(i, radius))
        }
        for ring in rings {
            let r = radius * ring
            path.move(to: point(0, r))
            for i in 0..<spokes {
                let next = (i + 1) % spokes
                let a0 = Double(i) / Double(spokes) * 2 * .pi - .pi / 2
                let a1 = a0 + 2 * .pi / Double(spokes)
                let mid = (a0 + a1) / 2
                let control = CGPoint(x: c.x + r * 0.86 * CGFloat(cos(mid)), y: c.y + r * 0.86 * CGFloat(sin(mid)))
                path.addQuadCurve(to: point(next, r), control: control)
            }
        }
        return path
    }
}

/// A small spider seen from above: eight jointed legs, a round abdomen and head, and two eyes in the accent.
private struct Spider: View {
    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            var legs = Path()
            // Four legs a side, each bending at the knee: forward pair reaching up, back pair reaching down.
            let reaches: [(knee: CGVector, foot: CGVector)] = [
                (CGVector(dx: 6, dy: -6), CGVector(dx: 11, dy: -2)),
                (CGVector(dx: 7, dy: -2), CGVector(dx: 12, dy: 2)),
                (CGVector(dx: 7, dy: 2), CGVector(dx: 12, dy: 7)),
                (CGVector(dx: 6, dy: 5), CGVector(dx: 9, dy: 10)),
            ]
            for side in [-1.0, 1.0] {
                for leg in reaches {
                    legs.move(to: CGPoint(x: c.x, y: c.y))
                    legs.addLine(to: CGPoint(x: c.x + side * leg.knee.dx, y: c.y + leg.knee.dy))
                    legs.addLine(to: CGPoint(x: c.x + side * leg.foot.dx, y: c.y + leg.foot.dy))
                }
            }
            context.stroke(legs, with: .color(Color(white: 0.08)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            let abdomen = CGRect(x: c.x - 4.5, y: c.y - 1, width: 9, height: 10)
            let head = CGRect(x: c.x - 3, y: c.y - 6, width: 6, height: 6)
            context.fill(Path(ellipseIn: abdomen), with: .color(Color(white: 0.08)))
            context.fill(Path(ellipseIn: head), with: .color(Color(white: 0.08)))
            for dx in [-1.3, 1.3] {
                context.fill(Path(ellipseIn: CGRect(x: c.x + dx - 0.8, y: c.y - 4.6, width: 1.6, height: 1.6)), with: .color(Theme.brand))
            }
        }
        .shadow(color: .white.opacity(0.35), radius: 0.8)
    }
}
