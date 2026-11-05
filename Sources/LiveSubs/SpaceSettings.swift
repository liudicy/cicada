import SwiftUI

/// Settings › 存储空间: what meetings take on disk, biggest first, with a per-meeting way to
/// drop just the recordings once the transcript and notes are enough.
struct SpaceSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SessionStore

    private var meetings: [Session] { store.sessions.sorted { store.totalSize($0.id) > store.totalSize($1.id) } }
    private var audioTotal: Int64 { store.sessions.reduce(0) { $0 + store.audioSize($1.id) } }
    private var grandTotal: Int64 { store.sessions.reduce(0) { $0 + store.totalSize($1.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                SettingsRow(title: L("会议记录"), detail: L("文字记录和纪要只占很少空间，大头是录音"),
                            divider: false) {
                    Text(L("共 \(sizeText(grandTotal))，其中录音 \(sizeText(audioTotal))"))
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }
            if !meetings.isEmpty {
                SettingsCard {
                    ForEach(Array(meetings.enumerated()), id: \.element.id) { i, s in
                        SettingsRow(title: s.title,
                                    detail: L("\(sizeText(store.totalSize(s.id)))，其中录音 \(sizeText(store.audioSize(s.id)))"),
                                    divider: i < meetings.count - 1) {
                            if s.id == store.liveID {
                                Text(L("正在记录")).font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                            } else if s.hasAudio {
                                Button { model.deleteAudio(s) } label: {
                                    Text(L("删除录音")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                        .padding(.horizontal, 10).frame(height: 24)
                                        .background(Capsule().fill(Palette.error)).contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            } else {
                                Text(L("无录音")).font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
