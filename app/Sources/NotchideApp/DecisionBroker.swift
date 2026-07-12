import Foundation
import NotchideKit

/// The crux of the async decision round-trip.
///
/// The socket server's handler, on a `wantsDecision` envelope, suspends on
/// `awaitDecision(id:timeout:)`. The UI's Approve/Deny/redirect actions call
/// `resolve(id:decision:)`, which resumes the suspended handler with the
/// `DecisionMessage`; that message is then written back down the still-open
/// socket to `notchide-hook`.
///
/// A per-request timeout is a backstop so a connection thread never hangs
/// indefinitely even if the UI never answers — resolving to `nil` makes the
/// server send nothing, and the sidecar's own hard timeout then fails open.
///
/// Correlation is by envelope `UUID`; a continuation is resumed exactly once —
/// whichever of {UI decision, timeout} fires first wins, the other is a no-op.
public actor DecisionBroker {
    private var pending: [UUID: CheckedContinuation<DecisionMessage?, Never>] = [:]

    /// Upper bound on concurrently-suspended gates. A misbehaving (or hostile)
    /// same-user process could otherwise open unbounded connections and pin
    /// unbounded continuations; past the cap we fail open (resolve `nil`).
    private let maxPending: Int

    public init(maxPending: Int = 64) {
        self.maxPending = max(1, maxPending)
    }

    /// Suspends until a decision for `id` is produced, or `timeout` elapses.
    public func awaitDecision(id: UUID, timeout: TimeInterval) async -> DecisionMessage? {
        // Arm a timeout that resolves to `nil` if the human never answers.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            await self?.resolve(id: id, decision: nil)
        }
        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<DecisionMessage?, Never>) in
            // A duplicate UUID must not orphan the first continuation (that would
            // wedge the earlier hook forever). Fail the old one open first.
            if let existing = pending.removeValue(forKey: id) {
                existing.resume(returning: nil)
            }
            // Cap concurrent gates: past the ceiling, fail this one open rather
            // than accumulate suspended continuations without bound.
            guard pending.count < maxPending else {
                continuation.resume(returning: nil)
                return
            }
            pending[id] = continuation
        }
        timeoutTask.cancel()
        return decision
    }

    /// Resolves a pending decision. No-op if `id` is unknown or already resolved.
    public func resolve(id: UUID, decision: DecisionMessage?) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(returning: decision)
    }

    /// Whether a decision for `id` is still outstanding (for diagnostics/tests).
    public func isPending(_ id: UUID) -> Bool {
        pending[id] != nil
    }
}
