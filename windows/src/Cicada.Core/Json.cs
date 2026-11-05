using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Cicada;

/// How records are written: what Swift's JSONEncoder (pretty, sorted keys, ISO-8601) produces, as
/// far as the Mac app's decoder cares. Whitespace differs ("key": vs "key" :); the values and keys
/// don't, and Chinese stays readable rather than \u-escaped.
public static class Json
{
    public static readonly JsonSerializerOptions Options = Make(indented: true);
    public static readonly JsonSerializerOptions Compact = Make(indented: false);

    static JsonSerializerOptions Make(bool indented)
    {
        var o = new JsonSerializerOptions
        {
            WriteIndented = indented,
            IndentSize = 2,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            NumberHandling = JsonNumberHandling.AllowReadingFromString,
        };
        o.Converters.Add(new Iso8601());
        return o;
    }

    public static string Write<T>(T value) => JsonSerializer.Serialize(value, Options);
    public static T? Read<T>(string text) => JsonSerializer.Deserialize<T>(text, Options);

    /// Whole seconds, UTC, "Z": what `.iso8601` writes (and expects back).
    sealed class Iso8601 : JsonConverter<DateTimeOffset>
    {
        public override DateTimeOffset Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options) =>
            DateTimeOffset.Parse(reader.GetString()!, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal);

        public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));
    }
}
