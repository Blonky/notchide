import SwiftUI
import NotchideKit

/// A `TestSummary` rendered as a **pass/fail grid** (DESIGN §14): a count row
/// (passed / failed / skipped + coverage delta), a heat grid of one cell per test,
/// and — when a run failed — the first failure spelled out.
///
/// The grid is capped so a huge suite stays glanceable; failed cells are drawn
/// first so red never hides below the fold.
public struct TestGridView: View {
    let summary: TestSummary

    public init(summary: TestSummary) {
        self.summary = summary
    }

    /// Ceiling on rendered cells; the rest collapse into a "+N more" tail.
    private let cellCap = 120

    private var total: Int { summary.passed + summary.failed + summary.skipped }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            countRow

            if total > 0 {
                cellGrid
            }

            if let failure = summary.firstFailure, !failure.isEmpty {
                firstFailure(failure)
            }
        }
    }

    // MARK: Count row

    private var countRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            StatChip(icon: "checkmark", text: "\(summary.passed) passed", tint: Theme.done, emphasized: summary.passed > 0)
            if summary.failed > 0 {
                StatChip(icon: "xmark", text: "\(summary.failed) failed", tint: Theme.error, emphasized: true)
            }
            if summary.skipped > 0 {
                StatChip(icon: "minus", text: "\(summary.skipped) skipped", tint: Theme.textTertiary)
            }
            Spacer(minLength: 0)
            if let delta = summary.coverageDelta {
                coverageChip(delta)
            }
        }
    }

    /// Coverage delta as a signed percentage-point chip, tinted by direction.
    private func coverageChip(_ delta: Double) -> some View {
        let points = delta * 100
        let sign = points >= 0 ? "+" : "−"
        let tint: Color = points > 0 ? Theme.done : (points < 0 ? Theme.error : Theme.textTertiary)
        let text = String(format: "%@%.1fpt cov", sign, abs(points))
        return StatChip(icon: "shield.lefthalf.filled", text: text, tint: tint, emphasized: points != 0)
    }

    // MARK: Cell grid

    private var cellGrid: some View {
        // Failed first (red never hides), then passed, then skipped.
        let shown = min(total, cellCap)
        let overflow = total - shown
        let cells = plannedCells(limit: shown)
        let columns = Array(repeating: GridItem(.fixed(12), spacing: 4), count: 16)

        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, color in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color)
                        .frame(width: 12, height: 12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(Theme.hairline, lineWidth: 0.5)
                        )
                }
            }
            if overflow > 0 {
                Text("+\(overflow) more")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .buildCard()
    }

    /// The colored cells to render, in failed→passed→skipped order, truncated to
    /// `limit`. Failures are guaranteed a slot before the cap bites.
    private func plannedCells(limit: Int) -> [Color] {
        var cells: [Color] = []
        for _ in 0..<summary.failed where cells.count < limit { cells.append(Theme.error) }
        for _ in 0..<summary.passed where cells.count < limit { cells.append(Theme.done) }
        for _ in 0..<summary.skipped where cells.count < limit { cells.append(Theme.textTertiary.opacity(0.5)) }
        return cells
    }

    // MARK: First failure

    private func firstFailure(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            SectionLabel(text: "FIRST FAILURE")
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.error)
                Text(text)
                    .font(Typo.monoSmall)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(Theme.Spacing.md)
            .buildCard(stroke: Theme.error.opacity(0.4))
        }
    }
}
