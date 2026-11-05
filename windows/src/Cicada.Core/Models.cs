using System.Text.Json.Serialization;

namespace Cicada;

// The meeting record, field for field the Mac app's `session.json` (SessionStore.swift, Notes.swift),
// so a record moves between the two unchanged. Properties are declared in ordinal key order because
// the Mac writes sorted keys; nulls are left out, as Swift leaves out nil optionals.

public sealed class TranscriptLine
{
    [JsonPropertyName("dst")] public string? Dst { get; set; }
    [JsonPropertyName("dstLang")] public string DstLang { get; set; } = "";
    /// "h<n>-<segment>" for heard lines, "m<n>" for the user's own.
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    /// "them" (system audio) or "me" (microphone).
    [JsonPropertyName("speaker")] public string Speaker { get; set; } = "them";
    [JsonPropertyName("src")] public string Src { get; set; } = "";
    [JsonPropertyName("srcLang")] public string SrcLang { get; set; } = "";
    /// Seconds from the start of the session.
    [JsonPropertyName("t")] public double T { get; set; }
    /// Experimental voice id on the Mac; Windows doesn't tell voices apart yet.
    [JsonPropertyName("voice")] public int? Voice { get; set; }

    public TranscriptLine Copy() => (TranscriptLine)MemberwiseClone();
}

public sealed class VoiceGuess
{
    [JsonPropertyName("evidence")] public string Evidence { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
}

public sealed class Session
{
    [JsonPropertyName("endedAt")] public DateTimeOffset? EndedAt { get; set; }
    [JsonPropertyName("hasAudio")] public bool HasAudio { get; set; }
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    /// Mac: an imported file still being transcribed. Kept so a Mac record round-trips.
    [JsonPropertyName("importing")] public bool? Importing { get; set; }
    [JsonPropertyName("lines")] public List<TranscriptLine> Lines { get; set; } = [];
    [JsonPropertyName("notes")] public MeetingNotes? Notes { get; set; }
    [JsonPropertyName("renamed")] public bool? Renamed { get; set; }
    /// Mac: heard through the microphone (会议室模式). Windows doesn't record rooms yet.
    [JsonPropertyName("room")] public bool? Room { get; set; }
    /// Mac: the imported file's name, and where its audio is; Windows doesn't import yet.
    [JsonPropertyName("sourceFile")] public string? SourceFile { get; set; }
    [JsonPropertyName("sourcePath")] public string? SourcePath { get; set; }
    [JsonPropertyName("startedAt")] public DateTimeOffset StartedAt { get; set; }
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("voiceGuesses")] public Dictionary<string, VoiceGuess>? VoiceGuesses { get; set; }
    [JsonPropertyName("voiceNames")] public Dictionary<string, string>? VoiceNames { get; set; }

    /// Keys a newer Mac (or port) added that this version doesn't know: written back as read, so
    /// opening a record here never loses them. They go after the known keys rather than in order.
    [JsonExtensionData] public Dictionary<string, System.Text.Json.JsonElement>? Unknown { get; set; }

    [JsonIgnore] public TimeSpan Duration => (EndedAt ?? DateTimeOffset.Now) - StartedAt;
}

/// Written by Ling while the meeting runs, rewritten over the whole transcript when it ends.
public sealed class MeetingNotes
{
    [JsonPropertyName("conclusions")] public List<NoteItem> Conclusions { get; set; } = [];
    /// How many transcript lines these notes cover.
    [JsonPropertyName("covered")] public int Covered { get; set; }
    [JsonPropertyName("final")] public bool Final { get; set; }
    [JsonPropertyName("summary")] public string Summary { get; set; } = "";
    [JsonPropertyName("terms")] public List<NoteTerm> Terms { get; set; } = [];
    [JsonPropertyName("title")] public string? Title { get; set; }
    [JsonPropertyName("todos")] public List<NoteItem> Todos { get; set; } = [];
    [JsonPropertyName("topics")] public List<NoteTopic> Topics { get; set; } = [];
    [JsonPropertyName("updatedAt")] public DateTimeOffset? UpdatedAt { get; set; }

    [JsonIgnore] public bool IsEmpty => Summary.Length == 0 && Topics.Count == 0;
}

public sealed class NoteTopic
{
    [JsonPropertyName("fishbone")] public Fishbone? Fishbone { get; set; }
    /// When each point was said (its first evidence line), parallel to Points.
    [JsonPropertyName("pointTimes")] public List<double?>? PointTimes { get; set; }
    [JsonPropertyName("points")] public List<string> Points { get; set; } = [];
    [JsonPropertyName("start")] public double Start { get; set; }
    [JsonPropertyName("summary")] public string Summary { get; set; } = "";
    [JsonPropertyName("title")] public string Title { get; set; } = "";

    public double? PointTime(int i) => PointTimes is { } p && i < p.Count ? p[i] : null;
}

public sealed class Fishbone
{
    [JsonPropertyName("branches")] public List<FishboneBranch> Branches { get; set; } = [];
    [JsonPropertyName("question")] public string Question { get; set; } = "";
}

public sealed class FishboneBranch
{
    [JsonPropertyName("detail")] public string Detail { get; set; } = "";
    [JsonPropertyName("label")] public string Label { get; set; } = "";
    /// How many transcript lines back this branch; 0 is shown as weak.
    [JsonPropertyName("support")] public int Support { get; set; }
    [JsonPropertyName("t")] public double? T { get; set; }
}

public sealed class NoteItem
{
    [JsonPropertyName("owner")] public string? Owner { get; set; }
    [JsonPropertyName("support")] public int Support { get; set; }
    /// When it was said (first evidence line).
    [JsonPropertyName("t")] public double? T { get; set; }
    [JsonPropertyName("text")] public string Text { get; set; } = "";
}

/// A name or term as the notes settled on it, and how speech recognition heard it.
public sealed class NoteTerm
{
    [JsonPropertyName("heard")] public List<string> Heard { get; set; } = [];
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("note")] public string Note { get; set; } = "";

    /// Corrected spellings first: what a reader can't work out alone.
    public static List<NoteTerm> Ordered(IEnumerable<NoteTerm> terms)
    {
        var list = terms.ToList();
        return [.. list.Where(t => t.Heard.Count > 0), .. list.Where(t => t.Heard.Count == 0)];
    }
}
