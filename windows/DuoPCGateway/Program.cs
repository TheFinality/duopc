using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using DuoPCGateway;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

const string Usage = """
DuoPC Gateway: an encrypted front door to TightVNC, for the DuoPC iPhone app.

  DuoPCGateway run                  Run the gateway (this is what the Windows service runs).
  DuoPCGateway pair [options]       Pair a phone: shows a QR code to scan in DuoPC.
      --host NAME                   Address the phone uses: your DDNS name or public IP for use away from
                                    home (default: this PC's local IP, which works only at home).
      --port N                      Port the phone uses, if your router forwards a different outside port.
      --name NAME                   Name shown in the app (default: this PC's name).
      --device NAME                 Name for this phone in `devices` (default: "Phone 1", "Phone 2", ...).
      --vnc-password PW             The VNC password to put in the code (default: the one set with config).
      --png FILE                    Also save the QR code as a PNG (it contains the pairing secret).
  DuoPCGateway devices              List paired phones.
  DuoPCGateway revoke NAME|--all    Unpair a phone (it can no longer connect).
  DuoPCGateway config [--port N] [--vnc-port N] [--listen ADDRESS|any] [--vnc-password PW]
                                    --vnc-password keeps TightVNC's password (encrypted for this PC) for
                                    pairing codes, so the app needs nothing typed.
  DuoPCGateway fingerprint          Print the certificate's SHA-256 (the app shows the start of it).
""";

var command = args.Length > 0 ? args[0].ToLowerInvariant() : "help";
string? Option(string name)
{
    var i = Array.FindIndex(args, a => a.Equals(name, StringComparison.OrdinalIgnoreCase));
    return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
}

try
{
    switch (command)
    {
        case "run":
        {
            var builder = Host.CreateApplicationBuilder();
            builder.Services.AddWindowsService(o => o.ServiceName = "DuoPCGateway");
            builder.Services.AddHostedService<GatewayService>();
            await builder.Build().RunAsync();
            return 0;
        }
        case "pair":
        {
            Console.OutputEncoding = Encoding.UTF8;
            var store = new GatewayStore();
            using var certificate = store.LoadOrCreateCertificate();
            var config = store.LoadConfig();
            var host = Option("--host") ?? LocalAddress() ?? Environment.MachineName;
            var port = int.TryParse(Option("--port"), out var p) && p is > 0 and < 65536 ? p : config.Port;
            var name = Option("--name") ?? Environment.MachineName;
            var device = Option("--device") ?? $"Phone {config.Devices.Count + 1}";
            var token = store.AddDevice(device);
            var uri = Pairing.BuildUri(name, host, port, GatewayStore.Fingerprint(certificate), token,
                                       Option("--vnc-password") ?? store.VncPassword());

            Console.WriteLine();
            Console.WriteLine(Pairing.ConsoleQr(uri));
            Console.WriteLine($"In DuoPC: tap +, then Scan pairing code. (Paired as \"{device}\".)");
            Console.WriteLine($"The phone will connect to {host}:{port}.");
            if (Option("--png") is { } png)
            {
                File.WriteAllBytes(png, Pairing.PngQr(uri));
                Console.WriteLine($"Saved the QR code to {png}. Delete it once you've scanned it.");
            }
            Console.WriteLine();
            Console.WriteLine("Can't scan it? Copy this whole line to the phone and use Paste pairing code:");
            Console.WriteLine(uri);
            Console.WriteLine();
            Console.WriteLine("This code is like a password. Don't share or screenshot it; clear the window when done.");
            return 0;
        }
        case "devices":
        {
            var config = new GatewayStore().LoadConfig();
            if (config.Devices.Count == 0) Console.WriteLine("No phones paired. Run: DuoPCGateway pair");
            foreach (var d in config.Devices) Console.WriteLine($"{d.Name,-20} paired {d.Paired:yyyy-MM-dd HH:mm}");
            return 0;
        }
        case "revoke":
        {
            var store = new GatewayStore();
            var config = store.LoadConfig();
            var target = args.Length > 1 ? args[1] : throw new ArgumentException("Say which phone: revoke NAME, or revoke --all.");
            var removed = target == "--all" ? config.Devices.RemoveAll(_ => true)
                                            : config.Devices.RemoveAll(d => d.Name.Equals(target, StringComparison.OrdinalIgnoreCase));
            store.SaveConfig(config);
            Console.WriteLine(removed == 0 ? $"No paired phone called \"{target}\"." : $"Unpaired {removed} phone(s).");
            return removed == 0 ? 1 : 0;
        }
        case "config":
        {
            var store = new GatewayStore();
            var config = store.LoadConfig();
            if (int.TryParse(Option("--port"), out var port)) config.Port = port;
            if (int.TryParse(Option("--vnc-port"), out var vncPort)) config.VncPort = vncPort;
            if (Option("--listen") is { } listen) config.Listen = listen == "any" ? null : IPAddress.Parse(listen).ToString();
            store.SaveConfig(config);
            if (Option("--vnc-password") is { } vncPassword) store.SetVncPassword(vncPassword);
            Console.WriteLine($"port {config.Port}, VNC port {config.VncPort}, listening on {config.Listen ?? "every address"}" +
                              $"{(store.VncPassword() is null ? "" : ", VNC password kept for pairing")}. Restart the service to apply: Restart-Service DuoPCGateway");
            return 0;
        }
        case "fingerprint":
        {
            using var certificate = new GatewayStore().LoadOrCreateCertificate();
            Console.WriteLine(GatewayStore.Fingerprint(certificate));
            return 0;
        }
        default:
            Console.WriteLine(Usage);
            return command is "help" or "-h" or "--help" or "/?" ? 0 : 1;
    }
}
catch (UnauthorizedAccessException)
{
    Console.Error.WriteLine("Access denied. Run this from PowerShell opened with \"Run as administrator\".");
    return 1;
}
catch (Exception e) when (e is ArgumentException or IOException)
{
    Console.Error.WriteLine(e.Message);
    return 1;
}

// The IPv4 address of the interface with a default gateway (the home network), if any.
static string? LocalAddress() =>
    NetworkInterface.GetAllNetworkInterfaces()
        .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
        .Select(n => n.GetIPProperties())
        .Where(p => p.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any)))
        .SelectMany(p => p.UnicastAddresses)
        .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
        .Select(a => a.Address.ToString())
        .FirstOrDefault();

sealed class GatewayService(IHostApplicationLifetime lifetime) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var store = new GatewayStore();
        var log = new Log(store.LogPath);
        try
        {
            await new GatewayServer(store, log).RunAsync(stoppingToken);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            log.Info($"stopped: {e.GetType().Name}: {e.Message}");
            Environment.ExitCode = 1;
            lifetime.StopApplication();
        }
    }
}
