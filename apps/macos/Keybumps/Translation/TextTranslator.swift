import SwiftUI
import Translation

/// Why a translation didn't come back.
enum TranslateFailure: Error, Equatable {
    /// Translation can't go between these two languages.
    case unsupportedPair
    /// A language isn't downloaded yet. Keybumps never shows the system's download prompt, which
    /// can't stay up over the palette; the tab sends people to Translation Languages instead.
    case notDownloaded
    /// Anything else.
    case failed
}

/// Translates text on this Mac: Apple's Translation framework in the app (`SystemTextTranslator`),
/// and a stand-in under unit and UI tests (`InertTextTranslator`), so no test downloads a language
/// or translates anything.
@MainActor
protocol TextTranslating: AnyObject {
    /// `text`, from `source` into `target` (identifiers such as `en` or `zh-Hant`). Throws a
    /// `TranslateFailure`, or `CancellationError` once its task is cancelled.
    func translate(_ text: String, from source: String, to target: String) async throws -> String
    /// The Translate tab's view, as the translator needs it. On macOS 15 Apple's Translation hands
    /// out sessions only to a SwiftUI view, so the system translator runs its sessions in this one,
    /// and its download prompt comes from it.
    func hostingSessions(in view: AnyView) -> AnyView
}

extension TextTranslating {
    func hostingSessions(in view: AnyView) -> AnyView { view }
}

/// Translates nothing: under unit tests and in the UI-test composition, every translation fails.
@MainActor
final class InertTextTranslator: TextTranslating {
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        throw TranslateFailure.failed
    }
}

enum TextTranslatorFactory {
    /// Apple's Translation on macOS 15 and later; nil before, where the Translation plugin can't be
    /// turned on. Inert under the unit-test host.
    @MainActor
    static func makeDefault() -> (any TextTranslating)? {
        if UnitTestHost.isActive { return InertTextTranslator() }
        if #available(macOS 15.0, *) { return SystemTextTranslator() }
        return nil
    }
}

@available(macOS 15.0, *)
enum TranslationModels {
    /// A session's languages, pinned to Translation's standard models: never Apple Intelligence's
    /// `highFidelity`, which rewrites more freely (#322).
    static func configuration(source: Locale.Language, target: Locale.Language) -> TranslationSession.Configuration {
        if #available(macOS 26.4, *) {
            return TranslationSession.Configuration(source: source, target: target, preferredStrategy: .lowLatency)
        }
        return TranslationSession.Configuration(source: source, target: target)
    }

    /// Which languages the standard models offer, and whether a pair needs a download.
    static func availability() -> LanguageAvailability {
        if #available(macOS 26.4, *) { return LanguageAvailability(preferredStrategy: .lowLatency) }
        return LanguageAvailability()
    }
}

/// Apple's Translation, on this Mac. Each translation asks the Translate tab's view
/// (`hostingSessions`) for a session in its languages, only once both are installed, so the
/// system's download prompt never shows. A new translation, or cancelling the task that asked,
/// ends the one before.
@available(macOS 15.0, *)
@MainActor
@Observable
final class SystemTextTranslator: TextTranslating {
    /// The languages the session host asks a session for; nil asks for none.
    private(set) var configuration: TranslationSession.Configuration?
    @ObservationIgnored private var current: Request?

    private struct Request {
        let id: UUID
        let text: String
        let source: Locale.Language
        let target: Locale.Language
        let continuation: CheckedContinuation<String, any Error>
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        let status = await TranslationModels.availability().status(from: sourceLanguage, to: targetLanguage)
        guard status != .unsupported else { throw TranslateFailure.unsupportedPair }
        // A session for a pair that isn't installed would show the system's download prompt.
        guard status == .installed else { throw TranslateFailure.notDownloaded }
        try Task.checkCancellation()
        let id = UUID()
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    start(Request(id: id, text: text, source: sourceLanguage, target: targetLanguage, continuation: continuation))
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel(id) }
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if Self.isUnsupported(error) { throw TranslateFailure.unsupportedPair }
            throw TranslateFailure.failed
        }
    }

    func hostingSessions(in view: AnyView) -> AnyView {
        AnyView(view.modifier(TranslationSessionHost(translator: self)))
    }

    /// Replaces the request before, which ends as cancelled, and asks the host for a session.
    private func start(_ request: Request) {
        if let current { resume(current.id, with: .failure(CancellationError())) }
        current = request
        if configuration?.source == request.source, configuration?.target == request.target {
            configuration?.invalidate()
        } else {
            configuration = TranslationModels.configuration(source: request.source, target: request.target)
        }
    }

    /// The task that asked was cancelled: its request ends, and so does the session.
    private func cancel(_ id: UUID) {
        guard current?.id == id else { return }
        configuration = nil
        resume(id, with: .failure(CancellationError()))
    }

    /// Runs in the session host's `.translationTask`, with a session for the configuration it had.
    /// A session for languages the current request no longer wants leaves it alone.
    func run(_ session: TranslationSession) async {
        guard let request = current,
              session.sourceLanguage.map({ $0.isEquivalent(to: request.source) }) ?? true,
              session.targetLanguage.map({ $0.isEquivalent(to: request.target) }) ?? true else { return }
        do {
            let response = try await session.translate(request.text)
            resume(request.id, with: .success(response.targetText))
        } catch {
            resume(request.id, with: .failure(error))
        }
    }

    /// Resumes a request once, if it's still the current one.
    private func resume(_ id: UUID, with result: Result<String, any Error>) {
        guard let request = current, request.id == id else { return }
        current = nil
        request.continuation.resume(with: result)
    }

    private static func isUnsupported(_ error: any Error) -> Bool {
        switch error {
        case TranslationError.unsupportedLanguagePairing, TranslationError.unsupportedSourceLanguage,
             TranslationError.unsupportedTargetLanguage:
            true
        default:
            false
        }
    }
}

/// Where `SystemTextTranslator` gets its sessions: the Translate tab's view, as Dictation's
/// Translate gets them from its own.
@available(macOS 15.0, *)
private struct TranslationSessionHost: ViewModifier {
    let translator: SystemTextTranslator

    func body(content: Content) -> some View {
        content.translationTask(translator.configuration) { session in
            await translator.run(session)
        }
    }
}
