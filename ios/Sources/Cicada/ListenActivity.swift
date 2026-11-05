import ActivityKit
import Foundation

/// 正在听 on the lock screen and in the Dynamic Island. Compiled into the app and into the
/// CicadaLive extension (ios/LiveActivity), which draws it; the app only starts, feeds and ends it.
struct ListenActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The newest translated line and what was said.
        var line: String
        var source: String
        /// Distinct voices so far.
        var people: Int
    }

    var startedAt: Date
    /// "英 → 中".
    var pair: String
}
