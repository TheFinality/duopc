using System.Diagnostics;

namespace DuoPCStreamer;

/// Encodes the PC's sound to AAC-LC (48 kHz stereo) with FFmpeg: raw samples in on stdin, ADTS
/// frames out on stdout, each written as soon as it's encoded. The phone decodes AAC in hardware.
public sealed class AudioEncoder : IDisposable
{
    readonly Process _process;
    readonly Log _log;

    public AudioEncoder(string ffmpeg, string sampleFormat, int sampleRate, int channels, Log log)
    {
        _log = log;
        var info = new ProcessStartInfo(ffmpeg)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var a in Arguments(sampleFormat, sampleRate, channels)) info.ArgumentList.Add(a);
        _process = Process.Start(info) ?? throw new InvalidOperationException("couldn't start FFmpeg for audio");
        _process.ErrorDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) _log.Info($"ffmpeg audio: {e.Data}"); };
        _process.BeginErrorReadLine();
    }

    public static string[] Arguments(string sampleFormat, int sampleRate, int channels) =>
        // No probing: by default FFmpeg reads 5 MB of input (half a minute of sound) before it starts.
        ["-hide_banner", "-loglevel", "error", "-probesize", "32", "-analyzeduration", "0",
         "-f", sampleFormat, "-ar", $"{sampleRate}", "-ac", $"{channels}", "-i", "pipe:0",
         "-ac", "2", "-ar", "48000", "-c:a", "aac", "-b:a", "128k",
         "-f", "adts", "-flush_packets", "1", "pipe:1"];

    public void Write(byte[] samples)
    {
        try
        {
            _process.StandardInput.BaseStream.Write(samples);
            _process.StandardInput.BaseStream.Flush();
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or InvalidOperationException) { }
    }

    /// Reads ADTS frames until FFmpeg exits.
    public async Task RunAsync(Func<byte[], Task> onFrame, CancellationToken cancel)
    {
        var stream = _process.StandardOutput.BaseStream;
        var header = new byte[7];
        while (!cancel.IsCancellationRequested)
        {
            try { await stream.ReadExactlyAsync(header, cancel); }
            catch (EndOfStreamException) { return; }
            if (header[0] != 0xFF || (header[1] & 0xF0) != 0xF0) throw new InvalidDataException("lost the ADTS sync");
            var length = ((header[3] & 0x03) << 11) | (header[4] << 3) | (header[5] >> 5);
            if (length < 7) throw new InvalidDataException("bad ADTS frame");
            var frame = new byte[length];
            header.CopyTo(frame, 0);
            await stream.ReadExactlyAsync(frame.AsMemory(7), cancel);
            await onFrame(frame);
        }
    }

    public void Dispose()
    {
        try { if (!_process.HasExited) _process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
        _process.Dispose();
    }
}
