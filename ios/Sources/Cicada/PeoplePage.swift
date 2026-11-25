import SwiftUI

/// 记住的人, as the Mac's 人员库 (SpeakerLibraryView, AppModel.rememberSpeaker): a voice in a
/// meeting is remembered only when the user asks and confirms (voiceprints are biometric data),
/// from the meeting's own recording; later meetings name it as soon as it is heard. Everything stays
/// on this phone and every row can be deleted.
extension AppModel {
    /// The confirmation's question, and then the voiceprint built from the meeting's recording.
    func rememberSpeaker(session id: String, voice: Int, name: String) {
        guard let s = store.session(id) else { return }
        let chosen = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chosen.isEmpty else { speakerProblem = (L("先给这个人起个名字"), L("在“是谁”里输入名字后，再记住这个声音。")); return }
        // An imported file's own audio, else the meeting's recording (still partial while it goes on).
        let fm = FileManager.default
        let audio = store.systemAudioURL(s.id), partial = AudioFileWriter.partial(audio)
        let source = s.sourceFile != nil ? s.sourcePath.map(Self.inThisContainer) : nil
        let url = [source, audio, partial].compactMap { $0 }.first { fm.fileExists(atPath: $0.path) }
        guard let url else {
            speakerProblem = (L("没有可用的录音"), L("打开“保存会议录音”，或用导入的录音文件建立声纹。"))
            return
        }
        speakerMemoryBusy = true
        Task {
            defer { speakerMemoryBusy = false }
            do {
                let result = try await SpeakerEnrollment.build(session: s, voice: voice, audioURL: url)
                let existing = s.voiceProfiles?[String(voice)]?.id
                var profile: SpeakerProfile?
                if let existing, profiles.updateEmbedding(id: existing, embedding: result.embedding) {
                    _ = profiles.rename(id: existing, to: chosen)
                    profile = profiles.snapshot().first { $0.id == existing }
                } else {
                    profile = profiles.remember(name: chosen, embedding: result.embedding)
                }
                guard let profile else {
                    speakerProblem = (L("这个声音还不够清楚"), L("换一段更长、更安静的发言再试。"))
                    return
                }
                store.setVoiceProfile(id, voice: voice, ref: VoiceProfileRef(id: profile.id, name: profile.name, similarity: 1))
                profiles.markSeen(id: profile.id)
                if id == store.liveID { room.bind(voice: voice, profile: profile) }
                speakerProfiles = profiles.all()
                debugLog("voice profiles: remembered \(chosen) from \(result.clips) clips / \(Int(result.seconds)) s")
            } catch {
                speakerProblem = (L("没记住这个声音"), error.localizedDescription)
            }
        }
    }

    /// An imported file's stored path under the app's container as it is now: the container's folder
    /// changes when the app is reinstalled (and can on an update), the part inside it doesn't.
    static func inThisContainer(_ path: String) -> URL {
        let marker = "/Library/Application Support/"
        guard !FileManager.default.fileExists(atPath: path), let r = path.range(of: marker) else { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: NSHomeDirectory() + marker + path[r.upperBound...])
    }

    func forgetProfile(_ id: UUID) {
        profiles.delete(id: id)
        speakerProfiles = profiles.all()
        debugLog("voice profiles: deleted one, \(speakerProfiles.count) left")
    }

    func forgetAllProfiles() {
        profiles.deleteAll()
        speakerProfiles = []
        debugLog("voice profiles: deleted all")
    }
}

/// 设置 › 人员库: who is remembered, a note for each (公司、职位、下次要记住的事), delete one or all.
struct PeoplePage: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmAll = false
    @State private var editing: SpeakerProfile?
    @State private var noteDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if model.speakerProfiles.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("还没有记住的人").font(.headline).foregroundStyle(Ink.ink)
                            Text("在会议里点一个说话人，选“记住这个声音”，下次就会自动认出。")
                                .font(.footnote).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 12)
                } else {
                    Card {
                        ForEach(Array(model.speakerProfiles.enumerated()), id: \.element.id) { i, p in
                            if i > 0 { Hairline() }
                            row(p)
                        }
                    }
                    .padding(.top, 12)
                }
                Text("声纹只保存在这台手机；可以写备注，也可以删除。")
                    .font(.footnote).foregroundStyle(Ink.secondary).padding(.horizontal, 4).padding(.top, 10)
                if !model.speakerProfiles.isEmpty {
                    Button("全部删除", role: .destructive) { confirmAll = true }
                        .font(.subheadline).padding(.horizontal, 4).padding(.top, 14)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 120)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background(Ink.ground)
        .navigationTitle(Text("人员库"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.speakerProfiles = model.profiles.all() }
        .confirmationDialog(Text("全部删除"), isPresented: $confirmAll, titleVisibility: .visible) {
            Button("全部删除", role: .destructive) { model.forgetAllProfiles() }
        } message: {
            Text("之后所有会议都不会再自动认出人；已有记录保持原样。")
        }
        .alert(Text(verbatim: editing?.name ?? ""), isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField(L("备注（公司、职位、下次要记住的事）"), text: $noteDraft)
            Button("保存") {
                if let p = editing { _ = model.profiles.setNotes(id: p.id, noteDraft); model.speakerProfiles = model.profiles.all() }
                editing = nil
            }
            Button("取消", role: .cancel) { editing = nil }
        }
    }

    private func row(_ p: SpeakerProfile) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: String(p.name.prefix(1)).uppercased()).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(Ink.ink, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: p.name).font(.body.weight(.semibold)).foregroundStyle(Ink.ink)
                Text(verbatim: p.notes?.isEmpty == false ? p.notes! : seen(p)).font(.caption).foregroundStyle(Ink.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Menu {
                Button { noteDraft = p.notes ?? ""; editing = p } label: { Label(L("备注（公司、职位、下次要记住的事）"), systemImage: "note.text") }
                Button(role: .destructive) { model.forgetProfile(p.id) } label: { Label(L("删除"), systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(Ink.secondary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(Text(verbatim: p.name))
        }
        .padding(.leading, 16).padding(.trailing, 6).frame(minHeight: 60)
    }

    private func seen(_ p: SpeakerProfile) -> String {
        guard let at = p.lastSeenAt, at > p.createdAt.addingTimeInterval(60) else { return L("还没在新会议里出现") }
        return dateText(at, "MMMd")
    }
}
