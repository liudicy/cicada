import SwiftUI

// The pieces the design canvas (知了 iOS 设计) is built from: white cards on the grey ground,
// grey section labels, a grey pill switch, hairlines, and Liquid Glass for what floats.

/// A white card, the design's 22 pt corners.
struct Card<Content: View>: View {
    var radius: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// The grey label above a card ("今天", "AI 服务").
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 8)
    }
}

/// The 0.5 pt line between rows in a card, inset like the design's.
struct Hairline: View {
    var inset: CGFloat = 16

    var body: some View {
        Rectangle().fill(Ink.line).frame(height: 0.5).padding(.leading, inset)
    }
}

/// The design's two-way switch: a grey track, the picked side a white pill with a soft shadow.
struct PillSwitch<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, LocalizedStringKey)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                let on = selection == value
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = value }
                } label: {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(on ? Ink.ink : Ink.secondary)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background {
                            if on {
                                Capsule().fill(Color.white).shadow(color: Ink.ink.opacity(0.12), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Ink.ground, in: Capsule())
    }
}

/// A row's trailing chevron.
struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Ink.tertiary)
            .accessibilityHidden(true)
    }
}

/// The design's round glass buttons (back, import, the trailing pair on a record): 44 pt, ink icon.
struct GlassIcon: View {
    let systemName: String
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Ink.ink)
            .frame(width: size, height: size)
            .glassEffect(.regular.interactive(), in: Circle())
    }
}

/// Lays out chips left to right and wraps, so every voice shows without scrolling sideways.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + s.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + s.width
            r.height = max(r.height, s.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}
