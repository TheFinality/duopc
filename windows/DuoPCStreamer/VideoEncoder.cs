using System.Buffers.Binary;
using System.Diagnostics;
using System.Text;

namespace DuoPCStreamer;

public sealed record VideoConfig(int Width, int Height, int Fps, byte[] HvcC);

/// Captures the desktop (Desktop Duplication) and encodes it to HEVC with FFmpeg, out as AVI: each
/// frame is one chunk with its size up front, written the moment it's encoded. (Fragmented MP4 holds
/// every frame back until the next one exists, since it needs the frame's duration: a frame of delay.)
public sealed class VideoEncoder : IDisposable
{
    readonly Process _process;
    readonly Log _log;

    public static string FindFfmpeg(string? explicitPath)
    {
        if (!string.IsNullOrEmpty(explicitPath)) return explicitPath;
        if (Environment.GetEnvironmentVariable("DUOPC_FFMPEG") is { Length: > 0 } fromEnvironment) return fromEnvironment;
        var beside = Path.Combine(AppContext.BaseDirectory, "ffmpeg", "ffmpeg.exe");
        if (File.Exists(beside)) return beside;
        return "ffmpeg.exe";   // on PATH (development)
    }

    public static string[] Arguments(int bitrateKbps, int fps, bool software)
    {
        // No pointer in the video: the app draws its own, which moves the instant the finger does.
        // Frames keep coming on a still screen (dup_frames): a few hundred bytes each, and a
        // heartbeat for the stall watchdog.
        var grab = $"ddagrab=output_idx=0:framerate={fps}:draw_mouse=0:dup_frames=1";
        var common = new[] { "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i", grab };
        // Short buffer: about two frames' worth, so a burst can't queue up latency.
        var buffer = Math.Max(bitrateKbps * 2 / Math.Max(fps, 1), 500);
        string[] codec = software
            ? ["-vf", "hwdownload,format=bgra,scale=1280:-2,format=yuv420p",
               "-c:v", "libx265", "-preset", "ultrafast", "-tune", "zerolatency",
               "-x265-params", $"keyint={fps * 60}:bframes=0:log-level=error", "-b:v", $"{bitrateKbps}k"]
            : ["-c:v", "hevc_nvenc", "-preset", "p1", "-tune", "ull", "-zerolatency", "1", "-delay", "0",
               // Constant quality capped at the bitrate, not CBR: CBR pads every repeated frame up to
               // the full rate, keeping the link saturated while nothing changes.
               "-rc", "vbr", "-cq", "23", "-b:v", "0", "-maxrate", $"{bitrateKbps}k", "-bufsize", $"{buffer}k",
               // Keyframes only at the start: a restart (see Pacer) is the repair, and P-frames are
               // much smaller than rolling-refresh frames, so the picture is sharper per bit.
               "-bf", "0", "-g", $"{fps * 60}"];
        string[] output = ["-f", "avi", "-flush_packets", "1", "pipe:1"];
        return [.. common, .. codec, .. output];
    }

    public VideoEncoder(string ffmpeg, IEnumerable<string> arguments, Log log)
    {
        _log = log;
        var info = new ProcessStartInfo(ffmpeg)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var a in arguments) info.ArgumentList.Add(a);
        _process = Process.Start(info) ?? throw new InvalidOperationException("couldn't start FFmpeg");
        _process.ErrorDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) _log.Info($"ffmpeg: {e.Data}"); };
        _process.BeginErrorReadLine();
    }

    /// Reads the AVI from FFmpeg: the config from the first keyframe's parameter sets, then one
    /// frame per chunk, converted to length-prefixed NAL units for VideoToolbox. Returns when FFmpeg exits.
    public async Task RunAsync(Func<VideoConfig, Task> onConfig, Func<byte[], bool, Task> onFrame, int fps, CancellationToken cancel)
    {
        var stream = _process.StandardOutput.BaseStream;
        var header = new byte[12];
        try { await stream.ReadExactlyAsync(header, cancel); }   // RIFF size AVI
        catch (EndOfStreamException) { return; }
        if (Encoding.ASCII.GetString(header, 0, 4) != "RIFF") throw new InvalidDataException("FFmpeg's output isn't AVI");
        var configured = false;
        while (!cancel.IsCancellationRequested)
        {
            try { await stream.ReadExactlyAsync(header.AsMemory(0, 8), cancel); }
            catch (EndOfStreamException) { return; }
            var id = Encoding.ASCII.GetString(header, 0, 4);
            var size = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4));
            if (id is "RIFF" or "LIST")
            {
                // hdrl is skipped whole; movi (and the RIFF AVIX that continue past 1 GB) hold the frames.
                await stream.ReadExactlyAsync(header.AsMemory(8, 4), cancel);
                var form = Encoding.ASCII.GetString(header, 8, 4);
                if (form is "movi" or "AVIX") continue;
                await SkipAsync(stream, (long)size - 4 + (size & 1), cancel);
                continue;
            }
            if (size > StreamProtocol.MaxMessage) throw new InvalidDataException($"bad AVI chunk {id} ({size} bytes)");
            var body = new byte[size];
            await stream.ReadExactlyAsync(body, cancel);
            if ((size & 1) == 1) await SkipAsync(stream, 1, cancel);
            if (size == 0 || !id.EndsWith("dc", StringComparison.Ordinal)) continue;   // empty: a repeat FFmpeg dropped

            var nals = Hevc.SplitAnnexB(body);
            var keyframe = Hevc.IsKeyframe(nals);
            if (!configured)
            {
                byte[]? Find(int type) => nals.FirstOrDefault(n => Hevc.NalType(n) == type) is { Count: > 0 } n ? n.ToArray() : null;
                if (!keyframe || Find(Hevc.Vps) is not { } vps || Find(Hevc.Sps) is not { } sps || Find(Hevc.Pps) is not { } pps) continue;
                var config = Hevc.Config(vps, sps, pps) ?? throw new InvalidDataException("couldn't read the encoder's SPS");
                await onConfig(new VideoConfig(config.Width, config.Height, fps, config.HvcC));
                configured = true;
            }
            await onFrame(Hevc.LengthPrefixed(nals), keyframe);
        }
    }

    static async Task SkipAsync(Stream stream, long count, CancellationToken cancel)
    {
        var buffer = new byte[Math.Min(count, 64 * 1024)];
        while (count > 0)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(0, (int)Math.Min(count, buffer.Length)), cancel);
            if (read == 0) throw new EndOfStreamException();
            count -= read;
        }
    }

    public void Dispose()
    {
        try { if (!_process.HasExited) _process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
        _process.Dispose();
    }
}
