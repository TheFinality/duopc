using System.Text;
using QRCoder;

namespace DuoPCGateway;

/// The pairing code the app scans:
///   duopc://pair?v=1&n=NAME&h=HOST&p=PORT&fp=CERT_SHA256_HEX&t=TOKEN_BASE64URL[&pw=VNC_PASSWORD]
/// It holds the token (and the VNC password, if given), so it's shown on screen only.
public static class Pairing
{
    public static string BuildUri(string name, string host, int port, string fingerprint, byte[] token, string? vncPassword)
    {
        var query = new List<string>
        {
            "v=1",
            "n=" + Uri.EscapeDataString(name),
            "h=" + Uri.EscapeDataString(host),
            "p=" + port,
            "fp=" + fingerprint,
            "t=" + Base64Url(token),
        };
        if (!string.IsNullOrEmpty(vncPassword)) query.Add("pw=" + Uri.EscapeDataString(vncPassword));
        return "duopc://pair?" + string.Join("&", query);
    }

    public static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    /// Light modules as full blocks: right for a dark console, where the background is the dark part.
    public static string ConsoleQr(string text)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(text, QRCodeGenerator.ECCLevel.M);
        return new AsciiQRCode(data).GetGraphicSmall(drawQuietZones: true, invert: false, endOfLine: Environment.NewLine);
    }

    public static byte[] PngQr(string text)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(text, QRCodeGenerator.ECCLevel.M);
        return new PngByteQRCode(data).GetGraphic(12);
    }
}

/// Appends to gateway.log (and the console when there is one). Never logs tokens or passwords.
public sealed class Log
{
    readonly string? _path;
    readonly object _lock = new();
    const long MaxBytes = 1_000_000;
    static readonly Encoding NoBom = new UTF8Encoding(false);

    public Log(string? path) => _path = path;

    public void Info(string message)
    {
        var line = $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss}  {message}";
        lock (_lock)
        {
            if (Environment.UserInteractive) Console.WriteLine(line);
            if (_path is null) return;
            try
            {
                var file = new FileInfo(_path);
                if (file.Exists && file.Length > MaxBytes) File.Move(_path, _path + ".old", overwrite: true);
                File.AppendAllText(_path, line + Environment.NewLine, NoBom);
            }
            catch (IOException) { }
        }
    }
}
