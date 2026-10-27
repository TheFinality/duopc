using System.Runtime.InteropServices;

namespace DuoPCStreamer;

/// Records what the PC is playing (WASAPI loopback on the default output device), on its own thread.
/// While nothing plays, Windows delivers nothing; silence is filled in so the encoder never sits on
/// the end of a sound waiting for more.
public sealed class AudioCapture : IDisposable
{
    public int SampleRate { get; }
    public int Channels { get; }
    /// "f32le" or "s16le": the samples' format, as FFmpeg names it.
    public string SampleFormat { get; }
    int BytesPerFrame { get; }

    readonly IAudioClient _client;
    readonly IAudioCaptureClient _capture;
    readonly Thread _thread;
    readonly Action<byte[]> _onSamples;
    readonly Log _log;
    volatile bool _stop;

    public AudioCapture(Action<byte[]> onSamples, Log log)
    {
        _onSamples = onSamples;
        _log = log;
        var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
        enumerator.GetDefaultAudioEndpoint(EDataFlowRender, ERoleConsole, out var device);
        var clientId = typeof(IAudioClient).GUID;
        device.Activate(ref clientId, ClsctxAll, IntPtr.Zero, out var clientObject);
        _client = (IAudioClient)clientObject;
        _client.GetMixFormat(out var format);
        try
        {
            var tag = (ushort)Marshal.ReadInt16(format);
            Channels = Marshal.ReadInt16(format, 2);
            SampleRate = Marshal.ReadInt32(format, 4);
            BytesPerFrame = Marshal.ReadInt16(format, 12);
            var bits = Marshal.ReadInt16(format, 14);
            var isFloat = tag == WaveFormatIeeeFloat
                          || (tag == WaveFormatExtensible && Marshal.PtrToStructure<Guid>(format + 24) == FloatSubformat);
            SampleFormat = (isFloat, bits) switch
            {
                (true, 32) => "f32le",
                (false, 16) => "s16le",
                (false, 32) => "s32le",
                _ => throw new NotSupportedException($"the PC's audio format ({bits}-bit, tag {tag:X}) isn't supported"),
            };
            _client.Initialize(ShareModeShared, StreamFlagsLoopback, 2_000_000 /* 200 ms */, 0, format, IntPtr.Zero);
        }
        finally
        {
            Marshal.FreeCoTaskMem(format);
        }
        var captureId = typeof(IAudioCaptureClient).GUID;
        _client.GetService(ref captureId, out var captureObject);
        _capture = (IAudioCaptureClient)captureObject;
        _thread = new Thread(Run) { IsBackground = true, Name = "audio" };
    }

    public void Start()
    {
        _client.Start();
        _thread.Start();
    }

    void Run()
    {
        var lastData = Environment.TickCount64;
        long silentSince = -1, silentFrames = 0;
        try
        {
            while (!_stop)
            {
                Thread.Sleep(10);
                var got = false;
                _capture.GetNextPacketSize(out var packet);
                while (packet > 0)
                {
                    _capture.GetBuffer(out var data, out var frames, out var flags, out _, out _);
                    var bytes = new byte[frames * BytesPerFrame];
                    if ((flags & BufferFlagsSilent) == 0) Marshal.Copy(data, bytes, 0, bytes.Length);
                    _capture.ReleaseBuffer(frames);
                    _onSamples(bytes);
                    got = true;
                    _capture.GetNextPacketSize(out packet);
                }
                var now = Environment.TickCount64;
                if (got) { lastData = now; silentSince = -1; continue; }
                // Nothing playing: keep time with silence, by the clock (sleeps are coarse), after a
                // short wait so a late packet isn't doubled up.
                if (now - lastData < 40) continue;
                if (silentSince < 0) { silentSince = lastData; silentFrames = 0; }
                var due = (now - silentSince) * SampleRate / 1000 - silentFrames;
                if (due <= 0) continue;
                _onSamples(new byte[due * BytesPerFrame]);
                silentFrames += due;
            }
        }
        catch (Exception e) when (e is COMException or IOException or InvalidOperationException)
        {
            _log.Info($"audio capture stopped: {e.Message}");
        }
    }

    public void Dispose()
    {
        _stop = true;
        if (_thread.IsAlive) _thread.Join(TimeSpan.FromSeconds(1));
        try { _client.Stop(); } catch (COMException) { }
        Marshal.ReleaseComObject(_capture);
        Marshal.ReleaseComObject(_client);
    }

    const int EDataFlowRender = 0, ERoleConsole = 0, ShareModeShared = 0;
    const uint ClsctxAll = 0x17, StreamFlagsLoopback = 0x00020000, BufferFlagsSilent = 0x2;
    const ushort WaveFormatIeeeFloat = 3, WaveFormatExtensible = 0xFFFE;
    static readonly Guid FloatSubformat = new("00000003-0000-0010-8000-00aa00389b71");

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumerator;

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        void EnumAudioEndpoints(int dataFlow, uint stateMask, out IntPtr devices);
        void GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        void Activate(ref Guid iid, uint clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient
    {
        void Initialize(int shareMode, uint streamFlags, long bufferDuration, long periodicity, IntPtr format, IntPtr sessionGuid);
        void GetBufferSize(out uint frames);
        void GetStreamLatency(out long latency);
        void GetCurrentPadding(out uint frames);
        void IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
        void GetMixFormat(out IntPtr format);
        void GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        void Start();
        void Stop();
        void Reset();
        void SetEventHandle(IntPtr handle);
        void GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }

    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioCaptureClient
    {
        void GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);
        void ReleaseBuffer(uint frames);
        void GetNextPacketSize(out uint frames);
    }
}
