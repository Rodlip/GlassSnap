import Foundation

/// Selection is kept separate from asynchronous window discovery so a quick
/// press-and-release still selects the intended window when discovery finishes.
public struct WindowSelection {
    public private(set) var index = 0
    public private(set) var loading = true
    private var pendingSteps = 0
    private var commitRequested = false
    private var count = 0

    public init(advance: Int = 0) { pendingSteps = advance }

    public mutating func move(by steps: Int) {
        if loading { pendingSteps += steps }
        else { index = wrapped(index + steps) }
    }
    /// Returns true when the user's release/Enter arrived before the list.
    public mutating func loaded(count: Int) -> Bool {
        self.count = max(0, count)
        index = wrapped(pendingSteps)
        loading = false
        return commitRequested && count > 0
    }
    /// Returns true if a selection can be committed now.
    public mutating func requestCommit() -> Bool {
        commitRequested = true
        return !loading && count > 0
    }
    public mutating func updateCount(_ count: Int) {
        self.count = max(0, count)
        index = min(index, max(0, count - 1))
    }
    private func wrapped(_ value: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((value % count) + count) % count
    }
}
