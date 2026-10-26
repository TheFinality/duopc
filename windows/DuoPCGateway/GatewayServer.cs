using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;

namespace DuoPCGateway;

/// The wire protocol, after a TLS 1.3 handshake on the gateway's certificate:
///   phone → PC   "DPC1" + 32-byte pairing token                  (VNC)
///             or "DPC2" + 32-byte pairing token + u8 channel     (1 = VNC, 2 = video stream)
///   PC → phone   0x00 accepted (from here on it's that channel's protocol, inside the TLS),
///                0x01 rejected (then closed), or 0x02 accepted but the channel is unavailable
public static class GatewayProtocol
{
    public static readonly byte[] Magic = "DPC1"u8.ToArray();
    public static readonly byte[] Magic2 = "DPC2"u8.ToArray();
    public const byte Accepted = 0x00;
    public const byte Rejected = 0x01;
    public const byte Unavailable = 0x02;
    public const byte ChannelVnc = 1, ChannelVideo = 2;
    public static int HelloLength => Magic.Length + GatewayStore.TokenLength;

    /// The token from a hello, or null if it isn't one.
    public static byte[]? ParseHello(ReadOnlySpan<byte> hello) => ParseHello(hello, out _);

    /// The token, and whether the hello is a DPC2 one (a channel byte follows).
    public static byte[]? ParseHello(ReadOnlySpan<byte> hello, out bool hasChannel)
    {
        hasChannel = false;
        if (hello.Length != HelloLength) return null;
        if (hello[..Magic.Length].SequenceEqual(Magic2)) hasChannel = true;
        else if (!hello[..Magic.Length].SequenceEqual(Magic)) return null;
        return hello[Magic.Length..].ToArray();
    }
}

/// Bans an address for an hour after 5 bad hellos within 15 minutes. TLS failures (port scanners,
/// the app's online check) don't count.
public sealed class BanList
{
    public int MaxFailures { get; init; } = 5;
    public TimeSpan Window { get; init; } = TimeSpan.FromMinutes(15);
    public TimeSpan BanTime { get; init; } = TimeSpan.FromHours(1);

    readonly Dictionary<IPAddress, (int Count, DateTimeOffset First, DateTimeOffset BannedUntil)> _entries = new();
    readonly object _lock = new();

    public bool IsBanned(IPAddress address, DateTimeOffset now)
    {
        lock (_lock) return _entries.TryGetValue(address, out var e) && e.BannedUntil > now;
    }

    /// Returns true when this failure starts a ban.
    public bool RecordFailure(IPAddress address, DateTimeOffset now)
    {
        lock (_lock)
        {
            if (_entries.Count > 10_000) Prune(now);
            (int Count, DateTimeOffset First, DateTimeOffset BannedUntil) e =
                _entries.TryGetValue(address, out var found) && now - found.First < Window ? found : (0, now, DateTimeOffset.MinValue);
            e.Count++;
            var banned = e.Count >= MaxFailures;
            if (banned) e = (0, now, now + BanTime);
            _entries[address] = e;
            return banned;
        }
    }

    void Prune(DateTimeOffset now)
    {
        foreach (var key in _entries.Where(kv => kv.Value.BannedUntil <= now && now - kv.Value.First >= Window).Select(kv => kv.Key).ToList())
            _entries.Remove(key);
    }
}

public sealed class GatewayServer
{
    static readonly TimeSpan HandshakeTimeout = TimeSpan.FromSeconds(10);
    const int MaxSessions = 8;

    readonly GatewayStore _store;
    readonly Log _log;
    readonly X509Certificate2 _certificate;
    readonly BanList _bans = new();
    readonly SemaphoreSlim _sessions = new(MaxSessions, MaxSessions);
    readonly StreamerLauncher _streamer;

    public GatewayServer(GatewayStore store, Log log)
    {
        _store = store;
        _log = log;
        _certificate = store.LoadOrCreateCertificate();
        _streamer = new StreamerLauncher { LogPath = Path.Combine(store.Directory, "streamer.log") };
    }

    public async Task RunAsync(CancellationToken cancel)
    {
        var config = _store.LoadConfig();
        TcpListener listener;
        if (string.IsNullOrEmpty(config.Listen))
        {
            listener = new TcpListener(IPAddress.IPv6Any, config.Port);
            listener.Server.DualMode = true;
        }
        else listener = new TcpListener(IPAddress.Parse(config.Listen), config.Port);
        listener.Start();
        _log.Info($"listening on port {config.Port}, forwarding to VNC on 127.0.0.1:{config.VncPort}, certificate {GatewayStore.Fingerprint(_certificate)}");
        try
        {
            while (!cancel.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(cancel);
                _ = Task.Run(() => HandleAsync(client, cancel), cancel);
            }
        }
        catch (OperationCanceledException) { }
        finally { listener.Stop(); }
    }

    async Task HandleAsync(TcpClient client, CancellationToken cancel)
    {
        using var _ = client;
        var remote = client.Client.RemoteEndPoint is IPEndPoint ep ? Normalize(ep.Address) : IPAddress.None;
        if (_bans.IsBanned(remote, DateTimeOffset.Now)) return;
        if (!await _sessions.WaitAsync(0, cancel)) { _log.Info($"{remote}: turned away, {MaxSessions} sessions already open"); return; }
        try
        {
            client.NoDelay = true;
            // Keep the send buffer small: screen updates waiting in it arrive late.
            client.SendBufferSize = 256 * 1024;
            using var tls = new SslStream(client.GetStream(), leaveInnerStreamOpen: false);
            using (var handshake = CancellationTokenSource.CreateLinkedTokenSource(cancel))
            {
                handshake.CancelAfter(HandshakeTimeout);
                try
                {
                    await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
                    {
                        ServerCertificate = _certificate,
                        EnabledSslProtocols = SslProtocols.Tls13,
                        ClientCertificateRequired = false,
                        CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
                    }, handshake.Token);
                }
                catch (Exception e) when (e is AuthenticationException or IOException or OperationCanceledException)
                {
                    return;   // scanners and online checks; not worth a log line each
                }

                var hello = new byte[GatewayProtocol.HelloLength];
                try { await tls.ReadExactlyAsync(hello, handshake.Token); }
                catch (Exception e) when (e is IOException or OperationCanceledException or EndOfStreamException)
                {
                    return;   // hung up or went quiet without trying a token: a probe, not a guess
                }
                var token = GatewayProtocol.ParseHello(hello, out var hasChannel);
                var device = token is null ? null : _store.FindDevice(token);
                var channel = GatewayProtocol.ChannelVnc;
                if (device is not null && hasChannel)
                {
                    var channelByte = new byte[1];
                    try { await tls.ReadExactlyAsync(channelByte, handshake.Token); }
                    catch (Exception e) when (e is IOException or OperationCanceledException or EndOfStreamException) { return; }
                    channel = channelByte[0];
                }

                if (device is null)
                {
                    var banned = _bans.RecordFailure(remote, DateTimeOffset.Now);
                    _log.Info($"{remote}: rejected (not a paired device){(banned ? "; blocked for an hour" : "")}");
                    try { await tls.WriteAsync(new[] { GatewayProtocol.Rejected }, cancel); } catch (IOException) { }
                    return;
                }

                if (channel == GatewayProtocol.ChannelVideo)
                {
                    await RunVideoAsync(tls, remote, device, handshake.Token, cancel);
                    return;
                }
                if (channel != GatewayProtocol.ChannelVnc)
                {
                    try { await tls.WriteAsync(new[] { GatewayProtocol.Unavailable }, cancel); } catch (IOException) { }
                    return;
                }

                var vncPort = _store.LoadConfig().VncPort;
                using var upstream = new TcpClient { NoDelay = true };
                try { await upstream.ConnectAsync(IPAddress.Loopback, vncPort, handshake.Token); }
                catch (Exception e) when (e is SocketException or OperationCanceledException)
                {
                    _log.Info($"{remote}: {device.Name} accepted, but nothing answers on 127.0.0.1:{vncPort}. Is TightVNC running?");
                    return;
                }

                await tls.WriteAsync(new[] { GatewayProtocol.Accepted }, cancel);
                await tls.FlushAsync(cancel);
                _log.Info($"{remote}: {device.Name} connected");
                var started = DateTimeOffset.Now;
                await PumpAsync(tls, upstream.GetStream(), cancel);
                _log.Info($"{remote}: {device.Name} disconnected after {(DateTimeOffset.Now - started):hh\\:mm\\:ss}");
            }
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            _log.Info($"{remote}: session ended with an error: {e.GetType().Name}: {e.Message}");
        }
        finally
        {
            _sessions.Release();
        }
    }

    /// The video channel: start DuoPC Streamer in the user's session and connect the phone to it.
    async Task RunVideoAsync(SslStream tls, IPAddress remote, PairedDevice device, CancellationToken startTimeout, CancellationToken cancel)
    {
        StreamerLauncher.Running running;
        try { running = await _streamer.StartAsync(startTimeout); }
        catch (Exception e) when (e is not OperationCanceledException || !cancel.IsCancellationRequested)
        {
            _log.Info($"{remote}: {device.Name} asked for video, but the streamer didn't start: {e.Message}");
            try { await tls.WriteAsync(new[] { GatewayProtocol.Unavailable }, cancel); } catch (IOException) { }
            return;
        }
        await using (running)
        {
            await tls.WriteAsync(new[] { GatewayProtocol.Accepted }, cancel);
            await tls.FlushAsync(cancel);
            _log.Info($"{remote}: {device.Name} connected (video)");
            var started = DateTimeOffset.Now;
            await PumpAsync(tls, running.Stream, cancel);
            _log.Info($"{remote}: {device.Name} video ended after {(DateTimeOffset.Now - started):hh\\:mm\\:ss}");
        }
    }

    /// Copies both ways until either side closes.
    static async Task PumpAsync(Stream phone, Stream vnc, CancellationToken cancel)
    {
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        var toVnc = Copy(phone, vnc, stop.Token);
        var toPhone = Copy(vnc, phone, stop.Token);
        await Task.WhenAny(toVnc, toPhone);
        stop.Cancel();
        try { await Task.WhenAll(toVnc, toPhone); } catch { }
    }

    static async Task Copy(Stream from, Stream to, CancellationToken cancel)
    {
        var buffer = new byte[64 * 1024];
        try
        {
            int n;
            while ((n = await from.ReadAsync(buffer, cancel)) > 0)
            {
                await to.WriteAsync(buffer.AsMemory(0, n), cancel);
                await to.FlushAsync(cancel);
            }
        }
        catch (Exception e) when (e is IOException or OperationCanceledException or ObjectDisposedException) { }
    }

    static IPAddress Normalize(IPAddress address) => address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address;
}
