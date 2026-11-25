namespace Cicada;

/// 保存会议录音: what was heard goes into `system.m4a` beside session.json, as on the Mac
/// (AudioFiles.swift). While the meeting runs it is written as ADTS (`system.aac`), which stays
/// readable up to its last frame if the app is killed; when the meeting ends it is rewrapped into
/// the .m4a, and a partial file left by a crash is rewrapped at the next launch. The encoder is
/// the app's (Media Foundation); Core only decides what goes in and when.
public interface IAudioFiles
{
    /// An AAC (ADTS) file at `path` for 16 kHz mono; null when this PC can't encode.
    IAudioWriter? Open(string path);
    /// `from` (ADTS) into the .m4a `to`, the first `until` seconds only when given. False on failure.
    bool Rewrap(string from, string to, double? until);
}

public interface IAudioWriter
{
    void Write(ReadOnlySpan<short> pcm);
    /// Writes what is buffered and closes the file.
    void Close();
}

/// 电脑和会议室 keeps one recording, as the Mac does: the room side's samples are added into the
/// PC's at the same place on the meeting's clock (each side counts the samples it gave, gaps
/// filled). The PC's audio waits `Delay` before it is written, so a room buffer that arrives a
/// little after the PC's is still mixed in; what the room says after the PC's last sample follows.
public sealed class RoomMix(IAudioWriter writer) : IAudioWriter
{
    const int Delay = Segmenter.Rate; // 1 s
    const int Limit = 30 * Segmenter.Rate; // the PC's audio stalled: older room audio goes
    readonly object gate = new();
    readonly List<short> pc = [], room = [];
    long at, roomAt; // where on the clock pc[0] and room[0] are (everything before `at` is written)
    bool closed;

    /// The PC's audio (the main side), in order.
    public void Write(ReadOnlySpan<short> pcm)
    {
        short[] output;
        lock (gate)
        {
            if (closed) return;
            pc.AddRange(pcm);
            output = Take(pc.Count - Delay);
        }
        if (output.Length > 0) writer.Write(output);
    }

    /// The room side's audio; `start`: its first sample's place on the clock.
    public void Room(ReadOnlySpan<short> pcm, long start)
    {
        lock (gate)
        {
            if (closed) return;
            var end = roomAt + room.Count;
            if (room.Count == 0) roomAt = start;
            else if (start > end) room.AddRange(new short[start - end]); // the room side stopped a while
            else if (start < end) pcm = pcm[(int)Math.Min(end - start, pcm.Length)..];
            room.AddRange(pcm);
            Drop(at);
            if (room.Count > Limit) { roomAt += room.Count - Limit; room.RemoveRange(0, room.Count - Limit); }
        }
    }

    /// Everything still held goes into the file, then the file closes.
    public void Close()
    {
        List<short> output;
        lock (gate)
        {
            if (closed) return;
            closed = true;
            output = [.. Take(pc.Count)];
            if (room.Count > 0 && roomAt >= at)
            {
                output.AddRange(new short[roomAt - at]);
                output.AddRange(room);
                room.Clear();
            }
        }
        if (output.Count > 0) writer.Write(output.ToArray());
        writer.Close();
    }

    /// Room audio for a place already written: too late to mix.
    void Drop(long upto)
    {
        var late = (int)Math.Min(room.Count, upto - roomAt);
        if (late <= 0) return;
        room.RemoveRange(0, late);
        roomAt += late;
    }

    /// The next `n` samples of the PC's audio with the room's added.
    short[] Take(int n)
    {
        if (n <= 0) return [];
        var output = pc.GetRange(0, n).ToArray();
        pc.RemoveRange(0, n);
        var start = at;
        at += n;
        Drop(start);
        if (room.Count > 0 && roomAt < at)
        {
            var off = (int)(roomAt - start);
            var k = (int)Math.Min(room.Count, at - roomAt);
            for (int i = 0; i < k; i++) output[off + i] = (short)Math.Clamp(output[off + i] + room[i], short.MinValue, short.MaxValue);
            room.RemoveRange(0, k);
            roomAt += k;
        }
        return output;
    }
}

public static class Recording
{
    public static string SystemAudio(string sessionId) => Path.Combine(Paths.Sessions, sessionId, "system.m4a");
    public static string Partial(string m4a) => Path.ChangeExtension(m4a, ".aac");

    /// The file a record plays: its own recording, or an imported file's where it still is.
    public static string? Playable(Session s)
    {
        var own = SystemAudio(s.Id);
        if (File.Exists(own)) return own;
        if (s.SourcePath is { Length: > 0 } p && File.Exists(p)) return p;
        return null;
    }

    /// Samples of silence that go in before a buffer so the recording keeps the meeting's clock:
    /// loopback capture sends nothing while the PC is silent (SystemAudioTap fills only what it
    /// notices), a source switch leaves a gap, and a line's `t` is its time since the meeting began.
    /// `at`: meeting seconds when the buffer arrived; `fed`: samples already given; `count`: the
    /// buffer's. Nothing while the stream is within LoopbackGap.Late of the clock, so a packet that
    /// is merely late never puts a gap in a sentence.
    public static int Behind(double at, long fed, int count)
    {
        var lag = at - (fed + count) / (double)Segmenter.Rate;
        return lag >= LoopbackGap.Late ? (int)(lag * Segmenter.Rate) : 0;
    }
}
