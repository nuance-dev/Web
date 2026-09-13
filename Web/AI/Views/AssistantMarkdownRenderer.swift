import Combine
import Foundation

@MainActor
final class AssistantMarkdownRenderer: ObservableObject {
    struct Input: Equatable, Sendable {
        let content: String
        let isStreaming: Bool
    }

    @Published private(set) var document = AssistantMarkdownDocument()
    private var latest: Input?
    private var rendered: Input?
    private var task: Task<Void, Never>?
    private var workerID = UUID()
    private let interval: Duration
    private let parse: @Sendable (String) -> AssistantMarkdownDocument

    init(interval: Duration = .milliseconds(80),
         parse: @escaping @Sendable (String) -> AssistantMarkdownDocument = AssistantMarkdownDocument.parse) {
        self.interval = interval
        self.parse = parse
    }

    func update(_ input: Input) {
        guard input != latest else { return }
        latest = input
        // Completion and Stop must bypass any pending streaming interval.
        if !input.isStreaming {
            task?.cancel()
            task = nil
        }
        guard task == nil else { return }
        let id = UUID()
        workerID = id
        task = Task { [weak self] in await self?.renderUpdates(worker: id) }
    }

    func cancel() {
        workerID = UUID()
        task?.cancel()
        task = nil
        latest = nil
    }

    private func renderUpdates(worker id: UUID) async {
        while !Task.isCancelled, id == workerID, let input = latest {
            guard input != rendered else { task = nil; return }
            let parser = parse
            let parsing = Task.detached(priority: .userInitiated) { parser(input.content) }
            let result = await withTaskCancellationHandler {
                await parsing.value
            } onCancel: {
                parsing.cancel()
            }
            guard !Task.isCancelled, id == workerID else { return }
            document = result
            rendered = input
            if !input.isStreaming { task = nil; return }

            // Keep this worker alive between updates. New tokens replace `latest`
            // without restarting the clock, so a continuous stream cannot starve it.
            do { try await Task.sleep(for: interval) }
            catch { return }
        }
        if id == workerID { task = nil }
    }
}
