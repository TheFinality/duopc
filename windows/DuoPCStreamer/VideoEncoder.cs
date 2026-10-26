using System.Buffers.Binary;
using System.Diagnostics;
using System.Text;

namespace DuoPCStreamer;

public sealed record VideoConfig(int Width, int Height, int Fps, byte[] HvcC);

/// Captures the desktop (Desktop Duplication) and encodes it to HEVC with FFmpeg, out as fragmented
/// MP4 with one fragment per frame. Each fragment's mdat is exactly one frame of length-prefixed NAL
/// units, ready for VideoToolbox, and it's written the moment the frame is encoded (no waiting for
/// the next frame to find the boundary).
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
        var grab = $"ddagrab=output_idx=0:framerate={fps}:draw_mouse=0:dup_frames=0";
        var common = new[] { "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i", grab };
        // Short buffer: about two frames' worth, so a burst can't queue up latency.
        var buffer = Math.Max(bitrateKbps * 2 / Math.Max(fps, 1), 500);
        string[] codec = software
            ? ["-vf", "hwdownload,format=bgra,scale=1280:-2,format=yuv420p",
               "-c:v", "libx265", "-preset", "ultrafast", "-tune", "zerolatency",
               "-x265-params", $"keyint={fps * 10}:bframes=0:log-level=error", "-b:v", $"{bitrateKbps}k"]
            : ["-c:v", "hevc_nvenc", "-preset", "p1", "-tune", "ull", "-zerolatency", "1", "-delay", "0",
               "-rc", "cbr", "-b:v", $"{bitrateKbps}k", "-maxrate", $"{bitrateKbps}k", "-bufsize", $"{buffer}k",
               "-bf", "0", "-g", $"{fps * 10}", "-forced-idr", "1"];
        string[] output = ["-f", "mp4", "-movflags", "empty_moov+default_base_moof+frag_every_frame",
                           "-flush_packets", "1", "pipe:1"];
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

    /// Reads the fragmented MP4 from FFmpeg: the config once (from the moov), then one frame per mdat.
    /// Returns when FFmpeg exits.
    public async Task RunAsync(Func<VideoConfig, Task> onConfig, Func<byte[], bool, Task> onFrame, int fps, CancellationToken cancel)
    {
        var stream = _process.StandardOutput.BaseStream;
        var header = new byte[8];
        while (!cancel.IsCancellationRequested)
        {
            try { await stream.ReadExactlyAsync(header, cancel); }
            catch (EndOfStreamException) { return; }
            long size = BinaryPrimitives.ReadUInt32BigEndian(header);
            var type = Encoding.ASCII.GetString(header, 4, 4);
            var headerLength = 8;
            if (size == 1)
            {
                var large = new byte[8];
                await stream.ReadExactlyAsync(large, cancel);
                size = (long)BinaryPrimitives.ReadUInt64BigEndian(large);
                headerLength = 16;
            }
            var bodyLength = size - headerLength;
            if (bodyLength < 0 || bodyLength > StreamProtocol.MaxMessage) throw new InvalidDataException($"bad MP4 box {type} ({size} bytes)");
            var body = new byte[bodyLength];
            await stream.ReadExactlyAsync(body, cancel);

            switch (type)
            {
                case "moov":
                    var config = ParseConfig(body, fps) ?? throw new InvalidDataException("no HEVC track in FFmpeg's output");
                    await onConfig(config);
                    break;
                case "mdat":
                    await onFrame(body, ContainsIdr(body));
                    break;
            }
        }
    }

    /// Width, height and the hvcC record from the sample entry ('hvc1' or 'hev1') inside the moov.
    public static VideoConfig? ParseConfig(byte[] moov, int fps)
    {
        var entry = IndexOf(moov, "hvc1"u8);
        if (entry < 0) entry = IndexOf(moov, "hev1"u8);
        if (entry < 4) return null;
        // VisualSampleEntry: after the 8-byte box header, 6 reserved + 2 index + 16 predefined, then width, height.
        var boxStart = entry - 4;
        var width = BinaryPrimitives.ReadUInt16BigEndian(moov.AsSpan(boxStart + 32));
        var height = BinaryPrimitives.ReadUInt16BigEndian(moov.AsSpan(boxStart + 34));
        var hvcc = IndexOf(moov, "hvcC"u8, entry);
        if (hvcc < 4) return null;
        var hvccSize = (int)BinaryPrimitives.ReadUInt32BigEndian(moov.AsSpan(hvcc - 4));
        if (hvccSize < 8 || hvcc - 4 + hvccSize > moov.Length) return null;
        return new VideoConfig(width, height, fps, moov.AsSpan(hvcc + 4, hvccSize - 8).ToArray());
    }

    /// True if a sample (4-byte length-prefixed NAL units) contains an IDR or CRA slice.
    public static bool ContainsIdr(ReadOnlySpan<byte> sample)
    {
        var offset = 0;
        while (offset + 5 <= sample.Length)
        {
            var length = (int)BinaryPrimitives.ReadUInt32BigEndian(sample[offset..]);
            if (length <= 0 || offset + 4 + length > sample.Length) return false;
            var nalType = (sample[offset + 4] >> 1) & 0x3F;
            if (nalType is >= 16 and <= 21) return true;   // BLA, IDR, CRA
            offset += 4 + length;
        }
        return false;
    }

    static int IndexOf(byte[] haystack, ReadOnlySpan<byte> needle, int start = 0)
    {
        var found = haystack.AsSpan(start).IndexOf(needle);
        return found < 0 ? -1 : start + found;
    }

    public void Dispose()
    {
        try { if (!_process.HasExited) _process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
        _process.Dispose();
    }
}
