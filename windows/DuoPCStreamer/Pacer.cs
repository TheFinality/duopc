namespace DuoPCStreamer;

/// Keeps the video from queueing up in the network. The phone acknowledges every frame it decodes;
/// when the oldest frame still unacknowledged has been out much longer than the round trip normally
/// takes, the link is backed up, and new frames are skipped instead of joining the queue. The
/// encoder uses rolling intra refresh, so the picture repairs itself within half a second of a skip.
public sealed class Pacer
{
    readonly object _lock = new();
    readonly LinkedList<(ulong Time, long SentTicks, int Bytes)> _inFlight = new();
    readonly Queue<(long Ticks, double RttMs)> _rttSamples = new();
    bool _acksSeen;
    long _lastSentTicks;
    // Stats since the last report.
    int _sent, _skipped;
    long _bytes;
    long _lastReport = Environment.TickCount64;

    /// The extra delay allowed on top of the best recent round trip before frames are skipped.
    public static readonly TimeSpan Slack = TimeSpan.FromMilliseconds(80);
    static readonly TimeSpan RttWindow = TimeSpan.FromSeconds(10);
    /// Never go longer than this without sending a frame, so a lost ack can't freeze the picture.
    public static readonly TimeSpan MaxGap = TimeSpan.FromMilliseconds(500);

    /// Whether to send this frame. Keyframes always go (nothing can be decoded without them).
    public bool ShouldSend(bool keyframe, long nowTicks)
    {
        lock (_lock)
        {
            if (keyframe || !_acksSeen || _inFlight.First is null) return true;
            if (nowTicks - _lastSentTicks > MaxGap.TotalMilliseconds) return true;
            var oldestAge = TimeSpan.FromMilliseconds(nowTicks - _inFlight.First.Value.SentTicks);
            var backedUp = oldestAge > MinRtt + Slack;
            if (backedUp) _skipped++;
            return !backedUp;
        }
    }

    public void Sent(ulong time, int bytes, long nowTicks)
    {
        lock (_lock)
        {
            _inFlight.AddLast((time, nowTicks, bytes));
            _lastSentTicks = nowTicks;
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

    /// Stats once a second: (frames sent, frames skipped, kbps, best round trip ms), or null if not due.
    public (int Fps, int Skipped, int Kbps, int RttMs)? Report(long nowTicks)
    {
        lock (_lock)
        {
            var elapsed = nowTicks - _lastReport;
            if (elapsed < 1000) return null;
            var result = ((int)(_sent * 1000 / elapsed), _skipped, (int)(_bytes * 8 / elapsed), (int)MinRtt.TotalMilliseconds);
            _sent = 0; _skipped = 0; _bytes = 0; _lastReport = nowTicks;
            return result;
        }
    }

    TimeSpan MinRtt => _rttSamples.Count == 0 ? TimeSpan.FromMilliseconds(100) : TimeSpan.FromMilliseconds(_rttSamples.Min(s => s.RttMs));

    void AddRtt(long rttMs, long nowTicks)
    {
        _rttSamples.Enqueue((nowTicks, rttMs));
        while (_rttSamples.Count > 0 && nowTicks - _rttSamples.Peek().Ticks > RttWindow.TotalMilliseconds) _rttSamples.Dequeue();
    }
}
