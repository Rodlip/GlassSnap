import AppKit
import SwiftUI

final class SwitcherState: ObservableObject {
    @Published var windows: [SwitcherWindow] = []
    @Published var thumbnails: [UUID: NSImage] = [:]
    @Published var selected = 0
    @Published var loading = true
    @Published var hasCaptureAccess = false
    @Published var hasAccessibility = false
    var columns = 4
    var pageSize = 8
    var cardWidth: CGFloat = 240
    var cardHeight: CGFloat = 182
    var page: Int { selected / pageSize }
    var pageCount: Int { max(1, (windows.count + pageSize - 1) / pageSize) }
    var pageEntries: [SwitcherWindow] { Array(windows.dropFirst(page * pageSize).prefix(pageSize)) }
    var rows: [[SwitcherWindow]] {
        let entries = pageEntries
        return stride(from: 0, to: entries.count, by: columns).map {
            Array(entries[$0..<min($0 + columns, entries.count)])
        }
    }
    var selectedEntry: SwitcherWindow? { windows.indices.contains(selected) ? windows[selected] : nil }
}

struct SwitcherView: View {
    @ObservedObject var state: SwitcherState
    var activate: (SwitcherWindow) -> Void
    var close: (SwitcherWindow) -> Void
    var permission: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            if !state.hasAccessibility {
                emptyState("Accessibility access needed", detail: "Enable access to select and close windows.", symbol: "hand.raised")
            } else if state.loading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.windows.isEmpty {
                emptyState("No open windows", detail: "Open a window in another app to see it here.", symbol: "macwindow")
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(state.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 12) {
                            ForEach(row) { entry in
                                WindowCard(entry: entry, thumbnail: state.thumbnails[entry.id], selected: state.selectedEntry?.id == entry.id,
                                           captureAllowed: state.hasCaptureAccess, width: state.cardWidth, height: state.cardHeight,
                                           activate: { activate(entry) }, close: { close(entry) })
                            }
                        }.frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            if !state.hasCaptureAccess || !state.hasAccessibility {
                Button(action: permission) {
                    Label(state.hasAccessibility ? "Enable previews" : "Enable access", systemImage: "lock.open")
                }.buttonStyle(.glass).font(.system(size: 11))
                    .frame(height: 28)
            }
            if state.pageCount > 1 {
                Text("\(state.page + 1) / \(state.pageCount)")
                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.tertiary).frame(height: 12)
                    .accessibilityLabel("Page \(state.page + 1) of \(state.pageCount)")
            }
        }.padding(16)
            .glassEffect(.regular, in: SwitcherOutline(
                rowWidths: state.hasAccessibility && !state.loading ? state.rows.map {
                    CGFloat($0.count) * state.cardWidth + CGFloat(max(0, $0.count - 1)) * 12 + 32
                } : [],
                rowHeight: state.cardHeight))
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
    private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 16, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WindowCard: View {
    let entry: SwitcherWindow
    let thumbnail: NSImage?
    let selected: Bool
    let captureAllowed: Bool
    let width: CGFloat
    let height: CGFloat
    var activate: () -> Void
    var close: () -> Void
    @State private var hovered = false
    @State private var closeHovered = false
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: activate) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 7) {
                        if let icon = entry.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                        Text(entry.appName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 24)
                    }
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.09))
                        if let thumbnail {
                            Image(nsImage: thumbnail).resizable().scaledToFit().padding(2)
                        } else {
                            VStack(spacing: 7) {
                                if let icon = entry.icon { Image(nsImage: icon).resizable().frame(width: 42, height: 42) }
                                Text(entry.minimized ? "Minimized" : (captureAllowed ? "Preview unavailable" : "Preview access needed"))
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(height: height - 78).clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(entry.title).font(.system(size: 11, weight: selected ? .medium : .regular)).lineLimit(1).truncationMode(.middle)
                }.padding(12).frame(width: width, height: height)
                    .contentShape(RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain).accessibilityLabel("\(entry.appName): \(entry.title)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(closeHovered ? Color.white : Color.secondary)
                    .frame(width: 23, height: 23)
                    .background(closeHovered ? Color.red : Color.primary.opacity(0.07), in: Circle())
            }.buttonStyle(.plain).padding(8).disabled(!entry.canClose)
                .opacity(entry.canClose ? 1 : 0.3)
                .onHover { closeHovered = $0 }
                .help("Close this window normally (⌘W)")
                .accessibilityLabel("Close \(entry.title)")
        }
        .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(hovered ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
        .onHover { hovered = $0 }
    }
}

/// One continuous glass surface whose silhouette follows the centered rows.
/// The shoulder sits at the padded bottom of each wider row, leaving the
/// unused lower corners transparent rather than filling a bounding rectangle.
struct SwitcherOutline: Shape {
    var rowWidths: [CGFloat]
    var rowHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        guard rowWidths.count > 1, let first = rowWidths.first,
              rowWidths.contains(where: { abs($0 - first) > 0.5 }) else {
            return Path(roundedRect: rect, cornerRadius: 24)
        }
        func left(_ index: Int) -> CGFloat { rect.midX - min(rect.width, rowWidths[index])/2 }
        func right(_ index: Int) -> CGFloat { rect.midX + min(rect.width, rowWidths[index])/2 }
        var points = [CGPoint(x: left(0), y: rect.minY), CGPoint(x: right(0), y: rect.minY)]
        for row in 0..<(rowWidths.count - 1) {
            let y = rect.minY + 32 + CGFloat(row + 1) * rowHeight + CGFloat(row) * 12
            if abs(rowWidths[row] - rowWidths[row + 1]) > 0.5 {
                points.append(CGPoint(x: right(row), y: y))
                points.append(CGPoint(x: right(row + 1), y: y))
            }
        }
        points.append(CGPoint(x: right(rowWidths.count - 1), y: rect.maxY))
        points.append(CGPoint(x: left(rowWidths.count - 1), y: rect.maxY))
        for row in stride(from: rowWidths.count - 2, through: 0, by: -1) {
            let y = rect.minY + 32 + CGFloat(row + 1) * rowHeight + CGFloat(row) * 12
            if abs(rowWidths[row] - rowWidths[row + 1]) > 0.5 {
                points.append(CGPoint(x: left(row + 1), y: y))
                points.append(CGPoint(x: left(row), y: y))
            }
        }
        let outline = CGMutablePath()
        let start = CGPoint(x: (points[0].x + points[1].x)/2, y: rect.minY)
        outline.move(to: start)
        for index in 1...points.count {
            let previous = points[(index - 1) % points.count]
            let corner = points[index % points.count]
            let next = points[(index + 1) % points.count]
            let before = hypot(corner.x - previous.x, corner.y - previous.y)
            let after = hypot(next.x - corner.x, next.y - corner.y)
            outline.addArc(tangent1End: corner, tangent2End: next, radius: min(24, min(before, after)/2))
        }
        outline.closeSubpath()
        return Path(outline)
    }
}
