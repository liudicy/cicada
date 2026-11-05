package cicada

/// Decides when a meeting is over, so one nobody ended doesn't run on for hours and pull the next
/// video into its notes. A port of the Mac's MeetingEndWatch (MeetingEnd.swift), same rules and
/// tests; times are seconds.
///
/// Two signals on the Mac. The main one, a meeting app letting go of the microphone (hanging up),
/// Android can't see: no app may know what another one records, and calls can't be captured
/// anyway. So the app passes no calls and `followApps` off, which leaves the fallback: nothing was
/// recognised for a while. "Nothing recognised" counts words, not sound, so background music
/// doesn't keep a meeting alive. Pure; the app ticks it every 2 s.
class MeetingEndWatch(var config: Config, start: Double) {
    enum class Silence(val key: String) {
        Prompt("prompt"), End("end"), Off("off");
        companion object { fun of(key: String) = values().firstOrNull { it.key == key } ?: Prompt }
    }

    data class Config(
        val followApps: Boolean = true,
        val silence: Silence = Silence.Prompt,
        val silenceAfter: Double = 600.0,
        /// How long the "没人说话" prompt waits before ending.
        val countdown: Double = 60.0,
        /// How long after a hang-up before ending: a device switch drops the mic for a moment.
        val appGrace: Double = 30.0,
    )

    sealed class Reason {
        /// The meeting app (by name) hung up.
        data class AppLeft(val name: String) : Reason()
        object Silence : Reason() { override fun toString() = "silence" }
        /// Nobody spoke at all: there is nothing to keep, so it just stops, without a countdown.
        object NobodySpoke : Reason() { override fun toString() = "nobodySpoke" }
    }

    data class Pending(val reason: Reason, val deadline: Double)

    /// The meeting ends at `deadline` unless someone keeps it going.
    var pending: Pending? = null; private set
    var lastSpeech: Double = start; private set
    /// Meeting apps seen in a call during this meeting (id → name).
    var inCall: Map<String, String> = emptyMap(); private set

    /// Words were recognised (theirs or mine): a silence countdown stops. A hang-up doesn't: the
    /// next video would talk over it.
    fun heard(now: Double) {
        lastSpeech = now
        if (pending?.reason == Reason.Silence) pending = null
    }

    /// "继续记录": forget the hang-up and start counting silence again.
    fun keepGoing(now: Double) {
        pending = null
        lastSpeech = now
        inCall = emptyMap()
    }

    /// `calls`: meeting apps reading a microphone now. `said`: the meeting has lines. One without
    /// keeps listening for the silence time (the subtitles stay ready), then stops quietly: a
    /// forgotten switch shouldn't listen to an empty room for hours. A call that ended before anyone
    /// spoke doesn't count. Returns why the meeting ends now, if it does.
    fun tick(now: Double, calls: Map<String, String>, said: Boolean): Reason? {
        if (!said) {
            inCall = if (config.followApps) calls else emptyMap()
            pending = null
            val inACall = config.followApps && calls.isNotEmpty()
            if (config.silence != Silence.Off && !inACall && now - lastSpeech >= config.silenceAfter) return Reason.NobodySpoke
            return null
        }
        if (config.followApps) {
            inCall = inCall + calls
            val hungUp = inCall.isNotEmpty() && inCall.keys.all { calls[it] == null }
            if (pending?.reason is Reason.AppLeft && !hungUp) pending = null // rejoined
            if (hungUp && (pending == null || pending?.reason == Reason.Silence)) {
                val name = inCall.toSortedMap().values.firstOrNull() ?: ""
                pending = Pending(Reason.AppLeft(name), now + config.appGrace)
            }
        } else if (pending?.reason is Reason.AppLeft) {
            pending = null
        }
        val inACall = config.followApps && calls.isNotEmpty()
        if (pending == null && config.silence != Silence.Off && !inACall && now - lastSpeech >= config.silenceAfter) {
            if (config.silence == Silence.End) return Reason.Silence
            pending = Pending(Reason.Silence, now + config.countdown)
        }
        if ((config.silence == Silence.Off || inACall) && pending?.reason == Reason.Silence) pending = null
        val p = pending
        if (p != null && now >= p.deadline) {
            pending = null
            return p.reason
        }
        return null
    }
}
