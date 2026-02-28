import Foundation

@MainActor
final class MutationScheduler {
    private let maxPendingMutations: Int
    private var pendingMutations: [() async -> Void] = []
    private var pendingMutationIndex = 0
    private var isProcessingMutations = false

    init(maxPendingMutations: Int) {
        self.maxPendingMutations = maxPendingMutations
        pendingMutations.reserveCapacity(8)
    }

    func enqueue(
        _ mutation: @escaping () async -> Void,
        onOverflow: () -> Void
    ) {
        let queuedMutationCount = pendingMutations.count - pendingMutationIndex
        guard queuedMutationCount < maxPendingMutations else {
            onOverflow()
            return
        }

        pendingMutations.append(mutation)
        guard !isProcessingMutations else { return }
        isProcessingMutations = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.pendingMutationIndex < self.pendingMutations.count {
                let next = self.pendingMutations[self.pendingMutationIndex]
                self.pendingMutations[self.pendingMutationIndex] = {}
                self.pendingMutationIndex += 1
                await next()
            }

            self.pendingMutations.removeAll(keepingCapacity: true)
            self.pendingMutationIndex = 0
            self.isProcessingMutations = false
        }
    }
}
