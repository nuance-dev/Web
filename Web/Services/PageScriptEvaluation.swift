import Foundation
import WebKit

/// A WebKit callback may arrive after timeout or cancellation. Only one result wins.
@MainActor
enum PageScriptEvaluation {
    typealias Completion = @MainActor (Result<Any?, Error>) -> Void

    static func evaluate(_ script: String, in webView: WKWebView,
                         timeout: Duration = .seconds(10)) async throws -> Any? {
        try await run(timeout: timeout) { complete in
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                complete(result.map { Optional($0) })
            }
        }
    }

    static func run(timeout: Duration,
                    start: (@escaping Completion) -> Void) async throws -> Any? {
        let pending = PendingEvaluation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending.continuation = continuation
                pending.timeoutTask = Task { @MainActor [weak pending] in
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    pending?.finish(.failure(ContextError.extractionTimeout))
                }
                start { result in pending.finish(result) }
            }
        } onCancel: {
            Task { @MainActor in pending.finish(.failure(CancellationError())) }
        }
    }

    private final class PendingEvaluation {
        var continuation: CheckedContinuation<Any?, Error>?
        var timeoutTask: Task<Void, Never>?

        func finish(_ result: Result<Any?, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation.resume(with: result)
        }
    }
}
