import AppKit
import Sentry
import SwiftUI

/// What a problem report attaches on its own (ADR 0007): the details a crash report carries, plus
/// permission states. Shown to the person, line for line, before they send it.
struct ProblemReportDiagnostics: Equatable {
    var appVersion: String
    var macOSVersion: String
    var macModel: String
    var chip: String
    var memoryGB: Int
    var pluginsOn: [String]
    var permissions: [(name: String, state: String)]
    var sendsCrashReports: Bool

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.lines == rhs.lines }

    /// Exactly what the report window shows under "Included with your report".
    var lines: [String] {
        [
            appVersion,
            "macOS \(macOSVersion)",
            "\(macModel) · \(chip) · \(memoryGB) GB",
            "Plugins on: " + (pluginsOn.isEmpty ? "none" : pluginsOn.joined(separator: ", ")),
            "Permissions: " + permissions.map { "\($0.name) \($0.state.lowercased())" }.joined(separator: ", "),
            "Crash reports: " + (sendsCrashReports ? "on" : "off"),
        ]
    }
}

extension ProblemReportDiagnostics {
    @MainActor
    static func current(model: AppModel) -> ProblemReportDiagnostics {
        ProblemReportDiagnostics(
            appVersion: AppVersionDisplay.title(),
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
                .replacingOccurrences(of: "Version ", with: ""),
            macModel: sysctlString("hw.model") ?? "Unknown Mac",
            chip: sysctlString("machdep.cpu.brand_string") ?? "Unknown chip",
            memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            pluginsOn: CapabilityCatalog.descriptors
                .filter { model.preferences.enabledCapabilities.contains($0.capability) }
                .map(\.capability.title),
            permissions: MacPermission.allCases.map { ($0.title, model.permissions.state(for: $0).rawValue) },
            sendsCrashReports: model.preferences.sendsCrashReports
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// A problem someone describes in Report a Problem…, sent as an ordinary Sentry event so it passes
/// `CrashReportScrubber` like every other report. (Sentry's user-feedback API skips that hook.)
struct ProblemReport {
    var description: String
    var contactEmail: String
    var diagnostics: ProblemReportDiagnostics

    var canSend: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func event() -> Event {
        let event = Event(level: .info)
        event.message = SentryMessage(formatted: description.trimmingCharacters(in: .whitespacesAndNewlines))
        event.tags = ["report": "problem"]
        // Each report is its own issue: two people's descriptions never share a cause by wording.
        event.fingerprint = ["problem-report", event.eventId.sentryIdString]
        var report: [String: Any] = ["crash_reports": diagnostics.sendsCrashReports ? "on" : "off"]
        let email = contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.isEmpty { report["contact"] = email }
        event.context = [
            "report": report,
            "permissions": Dictionary(uniqueKeysWithValues: diagnostics.permissions.map { ($0.name, $0.state) }),
        ]
        return event
    }
}

enum ProblemReportCopy {
    static let note = "Keybumps sends your report to its developers through Sentry. It removes file paths, links, and email addresses from what you write, so add your email above if you'd like a reply."
    static let unavailable = "This build of Keybumps can't send reports. Email support@keybumps.app instead."
    static let sent = "Thanks. Your report is on its way."
}

@MainActor
protocol ProblemReportPresenting: AnyObject {
    func show(diagnostics: ProblemReportDiagnostics, send: @escaping (ProblemReport) -> Bool)
}

/// Report a Problem…, from the Help menu, the menu bar menu, and Settings › General. Closing the
/// window any way discards it, so the next report starts empty with fresh details.
@MainActor
final class ProblemReportWindowController: NSObject, ProblemReportPresenting, NSWindowDelegate {
    private var window: NSWindow?

    func show(diagnostics: ProblemReportDiagnostics, send: @escaping (ProblemReport) -> Bool) {
        if let window {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = ProblemReportView(
            diagnostics: diagnostics,
            canSend: CrashReporter.canSendProblemReports,
            send: send,
            close: { [weak self] in self?.window?.close() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Report a Problem"
        window.identifier = NSUserInterfaceItemIdentifier("problemReport")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

/// Never shows a window: unit tests.
@MainActor
final class InertProblemReportPresenter: ProblemReportPresenting {
    private(set) var shownDiagnostics: ProblemReportDiagnostics?
    func show(diagnostics: ProblemReportDiagnostics, send: @escaping (ProblemReport) -> Bool) {
        shownDiagnostics = diagnostics
    }
}

struct ProblemReportView: View {
    let diagnostics: ProblemReportDiagnostics
    let canSend: Bool
    let send: (ProblemReport) -> Bool
    let close: () -> Void
    @State private var description = ""
    @State private var email = ""
    @State private var isSent = false

    private var report: ProblemReport {
        ProblemReport(description: description, contactEmail: email, diagnostics: diagnostics)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isSent {
                Label(ProblemReportCopy.sent, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("problemReport.sent")
                HStack {
                    Spacer()
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                }
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder private var form: some View {
        Text("What happened?").font(.headline)
        TextEditor(text: $description)
            .font(.body)
            .frame(height: 140)
            // The border never takes clicks meant for the editor (#255).
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary).allowsHitTesting(false))
            .accessibilityIdentifier("problemReport.description")
        TextField("Your email (optional, for a reply)", text: $email)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("problemReport.email")
        Text(canSend ? ProblemReportCopy.note : ProblemReportCopy.unavailable)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        GroupBox("Included with your report") {
            Text(diagnostics.lines.joined(separator: "\n"))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("problemReport.included")
        }
        HStack {
            Spacer()
            Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            Button("Send Report") {
                isSent = send(report)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSend || !report.canSend)
            .accessibilityIdentifier("problemReport.send")
        }
    }
}
