import AppKit
import ApplicationServices
import Foundation
import Observation

struct WindowDragActivityTracker {
    private(set) var isActive = false

    mutating func setActive(_ active: Bool) -> Bool {
        guard isActive != active else { return false }
        isActive = active
        return true
    }
}

@MainActor
@Observable
final class WindowManagementService {
    private struct WindowKey: Hashable {
        let pid: pid_t
        let token: CFHashCode
    }

    private struct DragTarget {
        let pid: pid_t
        let window: AXUIElement
        let startingFrame: CGRect
    }

    private(set) var lastError: String?
    private var originalFrames: [WindowKey: CGRect] = [:]
    private var lastAction: WindowAction?
    private var lastAppliedFrame: CGRect?
    private var dragMonitor: Any?
    private var dragTarget: DragTarget?
    private var sawWindowDrag = false
    private var dragActivity = WindowDragActivityTracker()
    var onDragActivityChange: ((Bool) -> Void)?

    var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    func startDragSnapping() {
        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            Task { @MainActor in self?.receiveDragEvent(event) }
        }
    }

    func stop() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor); self.dragMonitor = nil }
        dragTarget = nil
        sawWindowDrag = false
        updateDragActivity(false)
    }

    func requestAccessibility() {
        _ = AXIsProcessTrusted()
    }

    func perform(_ action: WindowAction) {
        guard isAccessibilityGranted else { lastError = "Accessibility permission is required."; return }
        guard let target = focusedWindow(), let current = frame(of: target.window) else { lastError = "No resizable focused window was found."; return }
        let key = windowKey(for: target)
        let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        guard let index = screenIndex(containing: current, screens: screens) else { return }
        if originalFrames[key] == nil { originalFrames[key] = current }

        if action == .restore, let original = originalFrames[key] {
            setFrame(original, on: target.window); originalFrames[key] = nil; return
        }
        if action == .nextDisplay || action == .previousDisplay {
            let delta = action == .nextDisplay ? 1 : -1
            move(current, from: screens[index], to: screens[(index + delta + screens.count) % screens.count], window: target.window)
            return
        }
        if (action == .left || action == .right), lastAction == action, let lastAppliedFrame, approximatelyEqual(current, lastAppliedFrame), screens.count > 1 {
            let delta = action == .right ? 1 : -1
            let next = screens[(index + delta + screens.count) % screens.count]
            let result = WindowGeometry.frame(for: action, in: next.visibleFrame, current: current)
            setFrame(result, on: target.window); self.lastAppliedFrame = result; return
        }
        let result = WindowGeometry.frame(for: action, in: screens[index].visibleFrame, current: current)
        setFrame(result, on: target.window)
        lastAction = action
        lastAppliedFrame = result
        lastError = nil
    }

    private func receiveDragEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            guard isAccessibilityGranted,
                  let target = focusedWindow(),
                  let startingFrame = frame(of: target.window) else {
                dragTarget = nil
                sawWindowDrag = false
                updateDragActivity(false)
                return
            }
            dragTarget = DragTarget(pid: target.pid, window: target.window, startingFrame: startingFrame)
            sawWindowDrag = false
            updateDragActivity(true)
        case .leftMouseDragged:
            guard let target = dragTarget, let current = frame(of: target.window) else {
                dragTarget = nil
                sawWindowDrag = false
                updateDragActivity(false)
                return
            }
            sawWindowDrag = !approximatelyEqual(current, target.startingFrame)
        case .leftMouseUp:
            defer {
                dragTarget = nil
                sawWindowDrag = false
                updateDragActivity(false)
            }
            guard sawWindowDrag, let target = dragTarget, let current = frame(of: target.window) else { return }
            snap(target: target, current: current, at: NSEvent.mouseLocation)
        default:
            break
        }
    }

    private func updateDragActivity(_ active: Bool) {
        guard dragActivity.setActive(active) else { return }
        onDragActivityChange?(active)
    }

    private func snap(target: DragTarget, current: CGRect, at point: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        let f = screen.visibleFrame, margin: CGFloat = 18
        let action: WindowAction?
        if point.y >= f.maxY - margin {
            if point.x <= f.minX + 120 { action = .upperLeft }
            else if point.x >= f.maxX - 120 { action = .upperRight }
            else { action = .maximize }
        } else if point.y <= f.minY + margin {
            if point.x <= f.minX + 120 { action = .lowerLeft }
            else if point.x >= f.maxX - 120 { action = .lowerRight }
            else { action = nil }
        } else if point.x <= f.minX + margin { action = .left }
        else if point.x >= f.maxX - margin { action = .right }
        else { action = nil }

        let key = WindowKey(pid: target.pid, token: CFHash(target.window))
        if let action {
            if originalFrames[key] == nil { originalFrames[key] = target.startingFrame }
            setFrame(WindowGeometry.frame(for: action, in: f, current: current), on: target.window)
            lastAction = action
            lastAppliedFrame = WindowGeometry.frame(for: action, in: f, current: current)
        } else if let original = originalFrames.removeValue(forKey: key) {
            setFrame(CGRect(origin: current.origin, size: original.size), on: target.window)
        }
    }

    private func focusedWindow() -> (pid: pid_t, window: AXUIElement)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (app.processIdentifier, unsafeDowncast(value, to: AXUIElement.self))
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size) else { return nil }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: position.x, y: top - position.y - size.height, width: size.width, height: size.height)
    }

    private func setFrame(_ frame: CGRect, on window: AXUIElement) {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        var position = CGPoint(x: frame.minX, y: top - frame.maxY)
        var size = frame.size
        guard let pv = AXValueCreate(.cgPoint, &position), let sv = AXValueCreate(.cgSize, &size) else { return }
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pv)
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sv)
    }

    private func screenIndex(containing frame: CGRect, screens: [NSScreen]) -> Int? {
        screens.indices.max(by: { screens[$0].frame.intersection(frame).area < screens[$1].frame.intersection(frame).area })
    }

    private func move(_ frame: CGRect, from: NSScreen, to: NSScreen, window: AXUIElement) {
        let xRatio = (frame.minX - from.visibleFrame.minX) / max(1, from.visibleFrame.width)
        let yRatio = (frame.minY - from.visibleFrame.minY) / max(1, from.visibleFrame.height)
        let result = CGRect(x: to.visibleFrame.minX + xRatio * to.visibleFrame.width, y: to.visibleFrame.minY + yRatio * to.visibleFrame.height, width: min(frame.width, to.visibleFrame.width), height: min(frame.height, to.visibleFrame.height))
        setFrame(result, on: window)
    }

    private func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX-b.minX)<3 && abs(a.minY-b.minY)<3 && abs(a.width-b.width)<3 && abs(a.height-b.height)<3
    }

    private func windowKey(for target: (pid: pid_t, window: AXUIElement)) -> WindowKey {
        WindowKey(pid: target.pid, token: CFHash(target.window))
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
