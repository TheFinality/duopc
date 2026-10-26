using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;
using DuoPCStreamer;

// DuoPC Streamer: runs in the signed-in user's Windows session (started by DuoPC Gateway for each
// video connection), captures and encodes the screen, and injects the phone's input.
//
//   DuoPCStreamer --connect 127.0.0.1:PORT --secret HEX   (how the gateway starts it)
//   DuoPCStreamer --listen PORT [--software]              (testing: one client on 127.0.0.1)
string? Option(string name)
{
    var i = Array.IndexOf(args, name);
    return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
}

var log = new Log(Option("--log"));
var ffmpeg = VideoEncoder.FindFfmpeg(Option("--ffmpeg"));
// The CPU encoder, for testing on a PC without a usable NVIDIA encoder.
var software = args.Contains("--software") || Environment.GetEnvironmentVariable("DUOPC_STREAMER_SOFTWARE") == "1";

Stream stream;
TcpClient client;
if (Option("--connect") is { } target && Option("--secret") is { } secretHex)
{
    var parts = target.Split(':');
    // A small send buffer: video waiting in it is video arriving late.
    client = new TcpClient { NoDelay = true, SendBufferSize = 256 * 1024 };
    await client.ConnectAsync(IPAddress.Parse(parts[0]), int.Parse(parts[1]));
    stream = client.GetStream();
    await stream.WriteAsync(Convert.FromHexString(secretHex));
}
else if (int.TryParse(Option("--listen"), out var port))
{
    var listener = new TcpListener(IPAddress.Loopback, port);
    listener.Start();
    log.Info($"listening on 127.0.0.1:{port}");
    client = await listener.AcceptTcpClientAsync();
    client.NoDelay = true;
    client.SendBufferSize = 256 * 1024;
    listener.Stop();
    stream = client.GetStream();
}
else
{
    Console.Error.WriteLine("usage: DuoPCStreamer --connect 127.0.0.1:PORT --secret HEX | --listen PORT [--software] [--ffmpeg PATH]");
    return 2;
}

using var cancel = new CancellationTokenSource();
using var input = new InputInjector(log);
var writeLock = new SemaphoreSlim(1, 1);
var pacer = new Pacer();
var bitrateKbps = 20_000;
var fps = 60;
VideoEncoder? encoder = null;
Task? encoderLoop = null;

async Task SendAsync(byte type, byte[] payload)
{
    var message = StreamProtocol.Message(type, payload);
    await writeLock.WaitAsync(cancel.Token);
    try { await stream.WriteAsync(message, cancel.Token); }
    finally { writeLock.Release(); }
}

async Task RunEncoderAsync(CancellationToken stop)
{
    var started = DateTimeOffset.UtcNow;
    while (!stop.IsCancellationRequested)
    {
        using var current = new VideoEncoder(ffmpeg, VideoEncoder.Arguments(bitrateKbps, fps, software), log);
        encoder = current;
        var frames = 0;
        try
        {
            await current.RunAsync(
                onConfig: async config =>
                {
                    input.Post(() => input.SetVideoSize(config.Width, config.Height));
                    var payload = new byte[11 + config.HvcC.Length];
                    BinaryPrimitives.WriteUInt32LittleEndian(payload, (uint)config.Width);
                    BinaryPrimitives.WriteUInt32LittleEndian(payload.AsSpan(4), (uint)config.Height);
                    BinaryPrimitives.WriteUInt16LittleEndian(payload.AsSpan(8), (ushort)config.Fps);
                    payload[10] = StreamProtocol.CodecHevc;
                    config.HvcC.CopyTo(payload.AsSpan(11));
                    await SendAsync(StreamProtocol.Config, payload);
                    log.Info($"video {config.Width}x{config.Height} at up to {config.Fps} fps, {bitrateKbps} kbps{(software ? " (software)" : "")}");
                },
                onFrame: async (sample, keyframe) =>
                {
                    frames++;
                    var now = Environment.TickCount64;
                    if (pacer.ShouldSend(keyframe, now))
                    {
                        var time = (ulong)(DateTimeOffset.UtcNow - started).Ticks / 10;
                        var payload = new byte[9 + sample.Length];
                        payload[0] = keyframe ? (byte)1 : (byte)0;
                        BinaryPrimitives.WriteUInt64LittleEndian(payload.AsSpan(1), time);
                        sample.CopyTo(payload.AsSpan(9));
                        pacer.Sent(time, sample.Length, now);
                        await SendAsync(StreamProtocol.Frame, payload);
                    }
                    if (pacer.Report(now) is { } stats)
                    {
                        var report = new byte[10];
                        BinaryPrimitives.WriteUInt16LittleEndian(report, (ushort)stats.Fps);
                        BinaryPrimitives.WriteUInt16LittleEndian(report.AsSpan(2), (ushort)Math.Min(stats.Skipped, ushort.MaxValue));
                        BinaryPrimitives.WriteUInt32LittleEndian(report.AsSpan(4), (uint)stats.Kbps);
                        BinaryPrimitives.WriteUInt16LittleEndian(report.AsSpan(8), (ushort)Math.Min(stats.RttMs, ushort.MaxValue));
                        await SendAsync(StreamProtocol.Stats, report);
                    }
                },
                fps, stop);
        }
        catch (Exception e) when (e is IOException or InvalidDataException)
        {
            log.Info($"encoder: {e.Message}");
        }
        if (stop.IsCancellationRequested) return;
        // FFmpeg stopped: usually the capture was lost (lock screen, admin prompt, display change).
        var message = frames == 0 ? "The PC's screen can't be captured right now (lock screen, an admin prompt, or no NVIDIA encoder)." : "Capture restarted.";
        try { await SendAsync(StreamProtocol.Status, [StreamProtocol.StatusCaptureUnavailable, .. Encoding.UTF8.GetBytes(message)]); }
        catch (Exception e) when (e is IOException or OperationCanceledException) { return; }
        await Task.Delay(frames == 0 ? 1000 : 100, stop).ContinueWith(_ => { });
    }
}

CancellationTokenSource? encoderStop = null;
void RestartEncoder()
{
    encoderStop?.Cancel();
    encoder?.Dispose();
    encoderStop = CancellationTokenSource.CreateLinkedTokenSource(cancel.Token);
    var token = encoderStop.Token;
    encoderLoop = Task.Run(() => RunEncoderAsync(token));
}

try
{
    while (await StreamProtocol.ReadAsync(stream, cancel.Token) is { } message)
    {
        var p = message.Payload;
        switch (message.Type)
        {
            case StreamProtocol.Start when p.Length >= 6:
                bitrateKbps = Math.Clamp((int)BinaryPrimitives.ReadUInt32LittleEndian(p), 1_000, 150_000);
                fps = Math.Clamp((int)BinaryPrimitives.ReadUInt16LittleEndian(p.AsSpan(4)), 10, 120);
                RestartEncoder();
                break;
            case StreamProtocol.SetBitrate when p.Length >= 4:
                bitrateKbps = Math.Clamp((int)BinaryPrimitives.ReadUInt32LittleEndian(p), 1_000, 150_000);
                RestartEncoder();
                break;
            case StreamProtocol.PointerMove when p.Length >= 8:
                var x = BinaryPrimitives.ReadInt32LittleEndian(p);
                var y = BinaryPrimitives.ReadInt32LittleEndian(p.AsSpan(4));
                input.Post(() => input.MovePointer(x, y));
                break;
            case StreamProtocol.Button when p.Length >= 2:
                var (button, down) = (p[0], p[1] != 0);
                input.Post(() => input.Button(button, down));
                break;
            case StreamProtocol.Scroll when p.Length >= 4:
                var dx = BinaryPrimitives.ReadInt16LittleEndian(p);
                var dy = BinaryPrimitives.ReadInt16LittleEndian(p.AsSpan(2));
                input.Post(() => input.Scroll(dx, dy));
                break;
            case StreamProtocol.Key when p.Length >= 5:
                var keysym = BinaryPrimitives.ReadUInt32LittleEndian(p);
                var keyDown = p[4] != 0;
                input.Post(() => input.Key(keysym, keyDown));
                break;
            case StreamProtocol.FrameAck when p.Length >= 8:
                pacer.Acked(BinaryPrimitives.ReadUInt64LittleEndian(p), Environment.TickCount64);
                break;
            case StreamProtocol.Text:
                var text = Encoding.UTF8.GetString(p);
                input.Post(() => input.Type(text));
                break;
        }
    }
}
catch (Exception e) when (e is IOException or OperationCanceledException or InvalidDataException or SocketException)
{
    log.Info($"connection: {e.Message}");
}
finally
{
    cancel.Cancel();
    encoder?.Dispose();
    client.Dispose();
    log.Info("ended");
}
return 0;

/// Appends to a log file (if given) and the console. Never logs typed text or screen contents.
public sealed class Log(string? path)
{
    readonly object _lock = new();
    public void Info(string message)
    {
        var line = $"{DateTimeOffset.Now:HH:mm:ss.fff}  {message}";
        lock (_lock)
        {
            Console.Error.WriteLine(line);
            if (path is null) return;
            try { File.AppendAllText(path, line + Environment.NewLine); } catch (IOException) { }
        }
    }
}
