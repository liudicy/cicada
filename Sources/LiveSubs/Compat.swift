import AppKit
import SwiftUI

/// SwiftUI that macOS 14 lacks, with what it gets instead.
extension View {
    /// The pointing hand over something clickable.
    @ViewBuilder func linkPointer() -> some View {
        if #available(macOS 15, *) {
            pointerStyle(.link)
        } else {
            onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
    }

    /// Where a scroll view's content sits against its bottom edge (15 and later; 14 has
    /// `onLegacyBottomDistance` below).
    @ViewBuilder func onScrollEdgeChange(_ action: @escaping (ScrollEdge, ScrollEdge) -> Void) -> some View {
        if #available(macOS 15, *) {
            onScrollGeometryChange(for: ScrollEdge.self) { g in
                ScrollEdge(distance: g.contentSize.height - g.contentOffset.y - g.containerSize.height,
                           height: g.contentSize.height, container: g.containerSize.height)
            } action: { old, new in action(old, new) }
        } else {
            self
        }
    }

    /// The content scrolled (macOS 15 and later).
    @ViewBuilder func onScrolled(_ action: @escaping () -> Void) -> some View {
        if #available(macOS 15, *) {
            onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, _ in action() }
        } else {
            self
        }
    }
}

extension View {
    /// macOS 14: how far `bottomMarker` (the content's last view) is below the visible area,
    /// measured by geometry since `onScrollGeometryChange` is 15 and later. Does nothing on 15+.
    @ViewBuilder func onLegacyBottomDistance(_ action: @escaping (CGFloat) -> Void) -> some View {
        if #available(macOS 15, *) {
            self
        } else {
            coordinateSpace(name: LegacyScrollEdge.space)
                .background(GeometryReader { g in
                    Color.clear.preference(key: LegacyScrollEdge.Container.self, value: g.size.height)
                })
                .onPreferenceChange(LegacyScrollEdge.Container.self) { LegacyScrollEdge.container = $0 }
                // The lazy stack doesn't draw a marker scrolled far out of view: that's far from the bottom.
                .onPreferenceChange(LegacyScrollEdge.Bottom.self) { y in
                    action(y < 0 ? .greatestFiniteMagnitude : y - LegacyScrollEdge.container)
                }
        }
    }

    /// Put on the content's last view (macOS 14, with `onLegacyBottomDistance` on the scroll view).
    @ViewBuilder func bottomMarker() -> some View {
        if #available(macOS 15, *) {
            self
        } else {
            background(GeometryReader { g in
                Color.clear.preference(key: LegacyScrollEdge.Bottom.self,
                                       value: g.frame(in: .named(LegacyScrollEdge.space)).maxY)
            })
        }
    }
}

enum LegacyScrollEdge {
    static let space = "cicada.scroll"
    nonisolated(unsafe) static var container: CGFloat = 0
    struct Container: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
    /// -1 while the marker isn't drawn.
    struct Bottom: PreferenceKey {
        static let defaultValue: CGFloat = -1
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}

/// How far the content's bottom is below the visible area, the content's height and the view's.
struct ScrollEdge: Equatable {
    var distance: CGFloat
    var height: CGFloat
    var container: CGFloat
}
