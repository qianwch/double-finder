import AppKit

/// A grid of labelled colour wells that reflows to however many columns fit the
/// current width (1, 2, 3 …). Replaces the fixed `NSGridView` layout so the
/// Appearance pane uses whatever width the window has been given.
///
/// All geometry comes from `ColorGridLayout` (pure, unit tested); this view only
/// applies it. Height is published through `intrinsicContentSize`, so Auto
/// Layout re-flows the pane whenever the column count changes.
final class ColorWellGridView: NSView {
    private let labels: [NSTextField]
    private let wells: [NSColorWell]
    private let labelWidth: CGFloat

    private let wellWidth: CGFloat = 44
    private let wellHeight: CGFloat = 22
    private let labelGap: CGFloat = 8
    private let columnGap: CGFloat = 24
    private let rowHeight: CGFloat = 30

    /// Width one label+well pair occupies.
    private var cellWidth: CGFloat { labelWidth + labelGap + wellWidth }

    override var isFlipped: Bool { true }

    /// - Parameters:
    ///   - items: label text paired with the well to show for it.
    ///   - labelWidth: shared across every grid in the pane so separate grids
    ///     still line up with each other.
    init(items: [(String, NSColorWell)], labelWidth: CGFloat) {
        self.labelWidth = labelWidth
        self.wells = items.map { $0.1 }
        self.labels = items.map { item in
            let label = NSTextField(labelWithString: item.0)
            label.alignment = .right
            label.lineBreakMode = .byTruncatingTail
            return label
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for (label, well) in zip(labels, wells) {
            label.translatesAutoresizingMaskIntoConstraints = true
            well.translatesAutoresizingMaskIntoConstraints = true
            addSubview(label)
            addSubview(well)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var currentColumns: Int {
        ColorGridLayout.columns(count: wells.count, availableWidth: bounds.width,
                                cellWidth: cellWidth, gap: columnGap)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: ColorGridLayout.height(count: wells.count,
                                              columns: currentColumns,
                                              rowHeight: rowHeight))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let before = currentColumns
        super.setFrameSize(newSize)
        // Only the column count changes our height, so don't churn on every pixel.
        if currentColumns != before { invalidateIntrinsicContentSize() }
    }

    override func layout() {
        super.layout()
        let columns = currentColumns
        let rows = ColorGridLayout.rows(count: wells.count, columns: columns)
        for (index, well) in wells.enumerated() {
            let origin = ColorGridLayout.origin(index: index, rows: rows,
                                                cellWidth: cellWidth, gap: columnGap,
                                                rowHeight: rowHeight)
            let label = labels[index]
            let labelHeight = label.intrinsicContentSize.height
            label.frame = NSRect(x: origin.x,
                                 y: origin.y + (rowHeight - labelHeight) / 2,
                                 width: labelWidth, height: labelHeight)
            well.frame = NSRect(x: origin.x + labelWidth + labelGap,
                                y: origin.y + (rowHeight - wellHeight) / 2,
                                width: wellWidth, height: wellHeight)
        }
    }
}
