namespace DuoPCStreamer;

/// Keeps the video from queueing up in the network without leaving the phone a stale picture.
///
/// The phone acknowledges every frame it decodes. Only when the oldest unacknowledged frame has been
/// out far longer than the round trip normally takes is the link backed up; then new frames are
/// skipped instead of joining the queue. Frames after a skip would decode wrong (their references
/// are missing), and a screen that then goes still produces no more frames to fix it, so once the
/// backlog clears the encoder restarts: a fresh keyframe of the screen as it is now.
public sealed class Pacer
{
    public enum Decision { Send, Skip, Restart }

    readonly object _lock = new();
    readonly LinkedList<(ulong Time, long SentTicks, int Bytes)> _inFlight = new();
    readonly Queue<(long Ticks, double RttMs)> _rttSamples = new();
    bool _acksSeen;
    long? _skippingSince;
    // Stats since the last report.
    int _sent, _skipped;
    long _bytes;
    long _lastReport = Environment.TickCount64;

    static readonly TimeSpan RttWindow = TimeSpan.FromSeconds(10);
    /// Skipping only starts this far past the best recent round trip (and at 3× it): short Wi-Fi
    /// hiccups are ridden out rather than skipped over.
    public static readonly TimeSpan Slack = TimeSpan.FromMilliseconds(250);
    /// Skip for at most this long before restarting anyway (e.g. acks stopped arriving).
    public static readonly TimeSpan MaxSkip = TimeSpan.FromSeconds(2);

    public Decision Decide(bool keyframe, long nowTicks)
    {
        lock (_lock)
        {
            if (keyframe)
            {
                _skippingSince = null;   // a keyframe is a clean start anyway
                return Decision.Send;
            }
            var backedUp = _acksSeen && _inFlight.First is { } oldest && nowTicks - oldest.Value.SentTicks > ThresholdMs;
            if (backedUp)
            {
                _skippingSince ??= nowTicks;
                _skipped++;
                if (nowTicks - _skippingSince.Value <= MaxSkip.TotalMilliseconds) return Decision.Skip;
            }
            if (_skippingSince is not null)
            {
                _skippingSince = null;
                return Decision.Restart;
            }
            return Decision.Send;
        }
    }

    public void Sent(ulong time, int bytes, long nowTicks)
    {
        lock (_lock)
        {
            _inFlight.AddLast((time, nowTicks, bytes));
            if (_inFlight.Count > 600) _inFlight.RemoveFirst();   // a phone that never acks
            _sent++;
            _bytes += bytes;
        }
    }

    /// The phone decoded the frame stamped `time` (and so everything sent before it).
    public void Acked(ulong time, long nowTicks)
    {
        lock (_lock)
        {
            _acksSeen = true;
            while (_inFlight.First is { } first && first.Value.Time <= time)
            {
                if (first.Value.Time == time) AddRtt(nowTicks - first.Value.SentTicks, nowTicks);
                _inFlight.RemoveFirst();
            }
        }
    }

    /// A new encoder starts its frame times again: forget what's in flight from the old one.
    public void EncoderRestarted()
    {
        lock (_lock) _inFlight.Clear();
    }

    /// Stats once a second: (frames sent, frames skipped, kbps, best round trip ms), or null if not due.
    public (int Fps, int Skipped, int Kbps, int RttMs)? Report(long nowTicks)
    {
        lock (_lock)
        {
            var elapsed = nowTicks - _lastReport;
            if (elapsed < 1000) return null;
            var result = ((int)(_sent * 1000 / elapsed), _skipped, (int)(_bytes * 8 / elapsed), (int)MinRttMs);
            _sent = 0; _skipped = 0; _bytes = 0; _lastReport = nowTicks;
            return result;
        }
    }

    double MinRttMs => _rttSamples.Count == 0 ? 100 : _rttSamples.Min(s => s.RttMs);
    double ThresholdMs => Math.Max(MinRttMs * 3, MinRttMs + Slack.TotalMilliseconds);

    void AddRtt(long rttMs, long nowTicks)
    {
        _rttSamples.Enqueue((nowTicks, rttMs));
        while (_rttSamples.Count > 0 && nowTicks - _rttSamples.Peek().Ticks > RttWindow.TotalMilliseconds) _rttSamples.Dequeue();
    }
}
