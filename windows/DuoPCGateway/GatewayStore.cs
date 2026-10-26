using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace DuoPCGateway;

/// One paired phone. Only a hash of its token is kept, so the file can't be used to connect.
public sealed class PairedDevice
{
    public string Name { get; set; } = "";
    public string TokenSha256 { get; set; } = "";
    public DateTimeOffset Paired { get; set; }
}

public sealed class GatewayConfig
{
    /// The port the gateway listens on (forward this one on the router).
    public int Port { get; set; } = 5960;
    /// TightVNC's port, reached on 127.0.0.1 only.
    public int VncPort { get; set; } = 5900;
    /// Listen on one address only (e.g. "127.0.0.1" for testing). Empty = every address, IPv4 and IPv6.
    public string? Listen { get; set; }
    public List<PairedDevice> Devices { get; set; } = new();
    /// TightVNC's password, DPAPI-encrypted for this machine, so pairing codes can carry it.
    public string? ProtectedVncPassword { get; set; }
}

/// The gateway's files: gateway.json (ports, paired devices), gateway.pfx (its TLS identity) and
/// gateway.log. They live in %ProgramData%\DuoPC, readable only by SYSTEM and Administrators.
public sealed class GatewayStore
{
    public const int TokenLength = 32;

    static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    public string Directory { get; }
    public string ConfigPath => Path.Combine(Directory, "gateway.json");
    public string CertificatePath => Path.Combine(Directory, "gateway.pfx");
    public string LogPath => Path.Combine(Directory, "gateway.log");

    readonly object _lock = new();
    GatewayConfig? _cached;
    DateTime _cachedStamp;

    public GatewayStore(string? directory = null)
    {
        var overridden = directory ?? Environment.GetEnvironmentVariable("DUOPC_GATEWAY_DIR");
        Directory = overridden ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "DuoPC");
        EnsureDirectory(lockDown: overridden is null);
    }

    void EnsureDirectory(bool lockDown)
    {
        var info = new DirectoryInfo(Directory);
        if (info.Exists) return;
        info.Create();
        if (!lockDown) return;
        // ProgramData is readable by every user by default; the certificate's private key isn't for them.
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        foreach (var sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
        {
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid, null), FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        }
        info.SetAccessControl(security);
    }

    /// Re-read when the file changes, so `pair` and `revoke` apply to a running service.
    public GatewayConfig LoadConfig()
    {
        lock (_lock)
        {
            if (!File.Exists(ConfigPath)) return _cached = new GatewayConfig();
            var stamp = File.GetLastWriteTimeUtc(ConfigPath);
            if (_cached is not null && stamp == _cachedStamp) return _cached;
            _cached = JsonSerializer.Deserialize<GatewayConfig>(File.ReadAllText(ConfigPath), JsonOptions) ?? new GatewayConfig();
            _cachedStamp = stamp;
            return _cached;
        }
    }

    public void SaveConfig(GatewayConfig config)
    {
        lock (_lock)
        {
            var temp = ConfigPath + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(config, JsonOptions));
            File.Move(temp, ConfigPath, overwrite: true);
            _cached = null;
        }
    }

    /// Adds a device and returns its new token. The token itself is shown once and never stored.
    public byte[] AddDevice(string name)
    {
        var token = RandomNumberGenerator.GetBytes(TokenLength);
        var config = LoadConfig();
        config.Devices.Add(new PairedDevice { Name = name, TokenSha256 = Convert.ToHexString(SHA256.HashData(token)), Paired = DateTimeOffset.Now });
        SaveConfig(config);
        return token;
    }

    /// The paired device this token belongs to, compared in constant time.
    public PairedDevice? FindDevice(ReadOnlySpan<byte> token)
    {
        if (token.Length != TokenLength) return null;
        Span<byte> hash = stackalloc byte[32];
        SHA256.HashData(token, hash);
        PairedDevice? match = null;
        foreach (var device in LoadConfig().Devices)
        {
            byte[] stored;
            try { stored = Convert.FromHexString(device.TokenSha256); } catch (FormatException) { continue; }
            if (stored.Length == 32 && CryptographicOperations.FixedTimeEquals(hash, stored)) match = device;
        }
        return match;
    }

    /// The TLS certificate, made on first use: a self-signed P-256 key, valid for 20 years. The app
    /// pins its SHA-256, so it never needs a certificate authority.
    public X509Certificate2 LoadOrCreateCertificate()
    {
        lock (_lock)
        {
            if (!File.Exists(CertificatePath))
            {
                using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
                var request = new CertificateRequest($"CN=DuoPC Gateway ({Environment.MachineName})", key, HashAlgorithmName.SHA256);
                request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
                request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
                request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new Oid("1.3.6.1.5.5.7.3.1") }, false));
                using var created = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(20));
                File.WriteAllBytes(CertificatePath, created.Export(X509ContentType.Pfx));
            }
            // Schannel needs the key in a key store, not an ephemeral one.
            return new X509Certificate2(CertificatePath, (string?)null, X509KeyStorageFlags.UserKeySet);
        }
    }

    public void SetVncPassword(string? password)
    {
        var config = LoadConfig();
        config.ProtectedVncPassword = string.IsNullOrEmpty(password) ? null
            : Convert.ToBase64String(ProtectedData.Protect(System.Text.Encoding.UTF8.GetBytes(password), null, DataProtectionScope.LocalMachine));
        SaveConfig(config);
    }

    public string? VncPassword()
    {
        var stored = LoadConfig().ProtectedVncPassword;
        if (string.IsNullOrEmpty(stored)) return null;
        try { return System.Text.Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(stored), null, DataProtectionScope.LocalMachine)); }
        catch (Exception e) when (e is CryptographicException or FormatException) { return null; }
    }

    public static string Fingerprint(X509Certificate2 certificate) =>
        Convert.ToHexString(SHA256.HashData(certificate.RawData)).ToLowerInvariant();
}
