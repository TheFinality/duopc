using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;

namespace DuoPCGateway;

/// Starts DuoPC Streamer for one video connection and hands back a stream to it.
///
/// The gateway service runs as SYSTEM in session 0, which can't see anyone's screen, so the streamer
/// is started in the signed-in user's session, still as SYSTEM (as TightVNC and Sunshine do), so it
/// can capture the screen and send input to elevated windows too. It connects back over loopback and
/// proves it's the process we started with a one-time secret.
public sealed class StreamerLauncher
{
    static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(10);

    public string StreamerPath { get; init; } =
        Environment.GetEnvironmentVariable("DUOPC_STREAMER") is { Length: > 0 } path ? path : Path.Combine(AppContext.BaseDirectory, "DuoPCStreamer.exe");
    public string? LogPath { get; init; }

    public sealed class Running : IAsyncDisposable
    {
        public required Stream Stream { get; init; }
        public required TcpClient Client { get; init; }
        public required Process? Process { get; init; }

        public ValueTask DisposeAsync()
        {
            Client.Dispose();
            try { if (Process is { HasExited: false }) Process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            Process?.Dispose();
            return ValueTask.CompletedTask;
        }
    }

    public async Task<Running> StartAsync(CancellationToken cancel)
    {
        if (!File.Exists(StreamerPath)) throw new FileNotFoundException("DuoPC Streamer isn't installed", StreamerPath);
        var secret = RandomNumberGenerator.GetBytes(32);
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        Process? process = null;
        try
        {
            var port = ((IPEndPoint)listener.LocalEndpoint).Port;
            var arguments = $"--connect 127.0.0.1:{port} --secret {Convert.ToHexString(secret)}";
            if (LogPath is not null) arguments += $" --log \"{LogPath}\"";
            process = IsSystem() ? StartInActiveSession(StreamerPath, arguments) : Process.Start(new ProcessStartInfo(StreamerPath, arguments) { UseShellExecute = false, CreateNoWindow = true });

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            timeout.CancelAfter(ConnectTimeout);
            while (true)
            {
                var client = await listener.AcceptTcpClientAsync(timeout.Token);
                client.NoDelay = true;
                var stream = client.GetStream();
                var proof = new byte[secret.Length];
                try { await stream.ReadExactlyAsync(proof, timeout.Token); }
                catch (Exception e) when (e is IOException or EndOfStreamException) { client.Dispose(); continue; }
                if (CryptographicOperations.FixedTimeEquals(proof, secret))
                    return new Running { Stream = stream, Client = client, Process = process };
                client.Dispose();   // something else on loopback; keep waiting for ours
            }
        }
        catch
        {
            try { if (process is { HasExited: false }) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            process?.Dispose();
            throw;
        }
        finally
        {
            listener.Stop();
        }
    }

    static bool IsSystem() => WindowsIdentity.GetCurrent().IsSystem;

    /// CreateProcessAsUser with our own (SYSTEM) token, moved to the console session's desktop.
    static Process StartInActiveSession(string exe, string arguments)
    {
        var session = WTSGetActiveConsoleSessionId();
        if (session == 0xFFFFFFFF) throw new InvalidOperationException("nobody is signed in at the PC");
        IntPtr token = IntPtr.Zero, primary = IntPtr.Zero, environment = IntPtr.Zero;
        try
        {
            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ALL_ACCESS, out token)) throw new Win32Exception();
            if (!DuplicateTokenEx(token, MAXIMUM_ALLOWED, IntPtr.Zero, 2 /* impersonation */, 1 /* primary */, out primary)) throw new Win32Exception();
            if (!SetTokenInformation(primary, 12 /* TokenSessionId */, ref session, sizeof(uint))) throw new Win32Exception();
            CreateEnvironmentBlock(out environment, primary, false);
            var startup = new STARTUPINFO { cb = Marshal.SizeOf<STARTUPINFO>(), lpDesktop = @"winsta0\default" };
            var commandLine = $"\"{exe}\" {arguments}";
            if (!CreateProcessAsUserW(primary, exe, commandLine, IntPtr.Zero, IntPtr.Zero, false,
                    CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW, environment, Path.GetDirectoryName(exe), ref startup, out var info))
                throw new Win32Exception();
            CloseHandle(info.hThread);
            CloseHandle(info.hProcess);
            return Process.GetProcessById(info.dwProcessId);
        }
        finally
        {
            if (environment != IntPtr.Zero) DestroyEnvironmentBlock(environment);
            if (primary != IntPtr.Zero) CloseHandle(primary);
            if (token != IntPtr.Zero) CloseHandle(token);
        }
    }

    const uint TOKEN_ALL_ACCESS = 0xF01FF, MAXIMUM_ALLOWED = 0x02000000;
    const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400, CREATE_NO_WINDOW = 0x08000000;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb; public string? lpReserved; public string? lpDesktop; public string? lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll")] static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool DuplicateTokenEx(IntPtr token, uint access, IntPtr attributes, int impersonation, int type, out IntPtr newToken);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool SetTokenInformation(IntPtr token, int infoClass, ref uint info, int length);
    [DllImport("userenv.dll", SetLastError = true)] static extern bool CreateEnvironmentBlock(out IntPtr environment, IntPtr token, bool inherit);
    [DllImport("userenv.dll", SetLastError = true)] static extern bool DestroyEnvironmentBlock(IntPtr environment);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessAsUserW(IntPtr token, string application, string commandLine, IntPtr processAttributes, IntPtr threadAttributes,
        bool inherit, uint flags, IntPtr environment, string? directory, ref STARTUPINFO startup, out PROCESS_INFORMATION info);
}
