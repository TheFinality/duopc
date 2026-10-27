namespace DuoPCStreamer;

/// Automatic quality: the bitrate cap drops when the network can't carry it (frames had to be
/// skipped) and climbs back towards the phone's chosen quality once things have been clear for a
/// while. Each change restarts the encoder (a short pause), so it climbs slowly, and more slowly
/// still if the last climb was too far.
public sealed class AutoBitrate
{
    public const int FloorKbps = 3_000;
    static readonly TimeSpan BaseWait = TimeSpan.FromSeconds(20), MaxWait = TimeSpan.FromSeconds(160);

    public int CeilingKbps { get; private set; }
    public int CurrentKbps { get; private set; }
    long _lastChange = long.MinValue / 2, _lastRaise = long.MinValue / 2;
    TimeSpan _wait = BaseWait;

    public AutoBitrate(int ceilingKbps) => Reset(ceilingKbps);

    /// The phone chose a quality: that's the ceiling, and where to start.
    public void Reset(int ceilingKbps)
    {
        CeilingKbps = CurrentKbps = ceilingKbps;
        _wait = BaseWait;
    }

    /// Frames had to be skipped. Returns the lower bitrate, or null if it's already at the floor.
    public int? Congested(long nowTicks)
    {
        if (nowTicks - _lastRaise < 10_000) _wait = TimeSpan.FromTicks(Math.Min(_wait.Ticks * 2, MaxWait.Ticks));
        _lastChange = nowTicks;
        if (CurrentKbps <= FloorKbps) return null;
        CurrentKbps = Math.Max(FloorKbps, CurrentKbps * 6 / 10);
        return CurrentKbps;
    }

    /// Called about once a second. Returns a higher bitrate when it's time to climb, else null.
    public int? Clear(long nowTicks)
    {
        if (CurrentKbps >= CeilingKbps || nowTicks - _lastChange < _wait.TotalMilliseconds) return null;
        CurrentKbps = Math.Min(CeilingKbps, CurrentKbps * 7 / 5);
        _lastChange = _lastRaise = nowTicks;
        return CurrentKbps;
    }
}
