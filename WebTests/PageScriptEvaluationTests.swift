import Foundation
import Testing
@testable import Web

@MainActor
struct PageScriptEvaluationTests {
    @Test func lateCallbackAfterTimeoutIsIgnored() async throws {
        var callback: PageScriptEvaluation.Completion?
        do {
            _ = try await PageScriptEvaluation.run(timeout: .zero) { callback = $0 }
            Issue.record("A missing WebKit callback must time out.")
        } catch {
            #expect(error is ContextError)
        }
        // This exact ordering caused a checked-continuation crash in the app.
        callback?(.success("late page"))
        callback?(.failure(URLError(.cancelled)))
    }

    @Test func firstCallbackWinsWithoutWaitingForTimeout() async throws {
        var callback: PageScriptEvaluation.Completion?
        let result = try await PageScriptEvaluation.run(timeout: .seconds(60)) { complete in
            callback = complete
            complete(.success("page"))
        }
        #expect(result as? String == "page")
        callback?(.failure(URLError(.badServerResponse)))
    }

    @Test func cancellationCompletesBeforeALateCallback() async throws {
        let ready = AsyncStream<Void>.makeStream()
        var callback: PageScriptEvaluation.Completion?
        let task = Task { @MainActor in
            try await PageScriptEvaluation.run(timeout: .seconds(60)) {
                callback = $0
                ready.continuation.yield(())
                ready.continuation.finish()
            }
        }
        for await _ in ready.stream { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        callback?(.success("stale page"))
    }

    @Test func cancelledRequestNeverStartsJavaScript() async throws {
        var started = false
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PageScriptEvaluation.run(timeout: .seconds(60)) { _ in started = true }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!started)
    }
}
