import Foundation

@MainActor
final class MutationScheduler {
    private struct MutationEntry {
        let key: String?
        let operation: () async -> Void
    }

    private let maxPendingMutations: Int
    private var pendingMutations: [MutationEntry] = []
    private var pendingMutationIndex = 0
    private var isProcessingMutations = false
    private var processingTask: Task<Void, Never>?

    init(maxPendingMutations: Int) {
        self.maxPendingMutations = maxPendingMutations
        pendingMutations.reserveCapacity(8)
    }

    deinit {
        processingTask?.cancel()
    }

    func enqueue(
        key: String? = nil,
        _ mutation: @escaping () async -> Void,
        onOverflow: () -> Void
    ) {
        if let key, pendingMutationIndex < pendingMutations.count {
            for index in stride(from: pendingMutations.count - 1, through: pendingMutationIndex, by: -1) {
                guard pendingMutations[index].key == key else { continue }
                pendingMutations[index] = MutationEntry(key: key, operation: mutation)
                return
            }
        }

        let queuedMutationCount = pendingMutations.count - pendingMutationIndex
        guard queuedMutationCount < maxPendingMutations else {
            onOverflow()
            return
        }

        pendingMutations.append(MutationEntry(key: key, operation: mutation))
        guard !isProcessingMutations else { return }
        isProcessingMutations = true

        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                pendingMutations.removeAll(keepingCapacity: true)
                pendingMutationIndex = 0
                isProcessingMutations = false
                processingTask = nil
            }

            while self.pendingMutationIndex < self.pendingMutations.count {
                if Task.isCancelled { return }

                let next = self.pendingMutations[self.pendingMutationIndex].operation
                self.pendingMutations[self.pendingMutationIndex] = MutationEntry(key: nil, operation: {})
                self.pendingMutationIndex += 1
                await next()
            }
        }
    }

    func cancelAll() {
        processingTask?.cancel()
        processingTask = nil
        pendingMutations.removeAll(keepingCapacity: true)
        pendingMutationIndex = 0
        isProcessingMutations = false
    }
}
