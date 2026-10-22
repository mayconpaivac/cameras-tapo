using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace CamerasTapo;

public record ScanResult(string Ip, bool HasOnvif, bool IsTapo);

public static class NetInfo
{
    /// "10.1.1" style prefixes of this computer's IPv4 LAN networks.
    public static List<string> LocalPrefixes() =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up
                     && n.NetworkInterfaceType is NetworkInterfaceType.Ethernet or NetworkInterfaceType.Wireless80211
                     && !n.Description.Contains("Tailscale", StringComparison.OrdinalIgnoreCase))
            .SelectMany(n => n.GetIPProperties().UnicastAddresses)
            .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a.Address))
            .Select(a => string.Join('.', a.Address.ToString().Split('.').Take(3)))
            .Distinct().ToList();

    public static string? DefaultGateway() =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up)
            .SelectMany(n => n.GetIPProperties().GatewayAddresses)
            .Select(g => g.Address)
            .FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork && !a.Equals(IPAddress.Any))
            ?.ToString();

    /// MAC address ("aa:bb:cc:dd:ee:ff") of a host on the local network.
    public static string? Mac(string ip)
    {
        try
        {
            if (OperatingSystem.IsWindows())
            {
                var dest = BitConverter.ToInt32(IPAddress.Parse(ip).GetAddressBytes(), 0);
                var mac = new byte[6];
                int len = mac.Length;
                if (SendARP(dest, 0, mac, ref len) != 0 || len != 6) return null;
                return string.Join(':', mac.Select(b => b.ToString("x2")));
            }
            // macOS / Linux (development): read the ARP table.
            TcpOpen(ip, 554, 800).Wait();
            var psi = new ProcessStartInfo("arp", $"-n {ip}") { RedirectStandardOutput = true, UseShellExecute = false };
            using var p = Process.Start(psi)!;
            var output = p.StandardOutput.ReadToEnd();
            var m = Regex.Match(output, @" at ([0-9a-fA-F:]+) ");
            if (!m.Success) return null;
            var parts = m.Groups[1].Value.Split(':');
            return parts.Length == 6 ? string.Join(':', parts.Select(x => x.PadLeft(2, '0').ToLowerInvariant())) : null;
        }
        catch { return null; }
    }

    [DllImport("iphlpapi.dll", ExactSpelling = true)]
    static extern int SendARP(int destIp, int srcIp, byte[] macAddr, ref int physicalAddrLen);

    public static async Task<bool> TcpOpen(string ip, int port, int timeoutMs)
    {
        using var client = new TcpClient();
        using var cts = new CancellationTokenSource(timeoutMs);
        try { await client.ConnectAsync(ip, port, cts.Token); return true; }
        catch { return false; }
    }

    /// Asks the RTSP server who it is. TP-Link cameras answer realm "TP-Link IP-Camera".
    static async Task<string?> RtspRealm(string ip)
    {
        try
        {
            using var client = new TcpClient();
            using var cts = new CancellationTokenSource(2500);
            await client.ConnectAsync(ip, 554, cts.Token);
            var stream = client.GetStream();
            var req = Encoding.ASCII.GetBytes($"DESCRIBE rtsp://{ip}:554/stream1 RTSP/1.0\r\nCSeq: 1\r\n\r\n");
            await stream.WriteAsync(req, cts.Token);
            var buf = new byte[2048];
            int n = await stream.ReadAsync(buf, cts.Token);
            var m = Regex.Match(Encoding.UTF8.GetString(buf, 0, n), "realm=\"([^\"]*)\"");
            return m.Success ? m.Groups[1].Value : null;
        }
        catch { return null; }
    }

    /// Scans prefix.1 … prefix.254 for RTSP (554) and ONVIF (2020).
    public static async Task<List<ScanResult>> Scan(string prefix, IProgress<double> progress)
    {
        var ips = Enumerable.Range(1, 254).Select(i => $"{prefix}.{i}").ToList();
        var open = new List<string>();
        int done = 0;
        foreach (var batch in ips.Chunk(64)) // stay under open-file limits
        {
            var results = await Task.WhenAll(batch.Select(async ip => (ip, ok: await TcpOpen(ip, 554, 1200))));
            open.AddRange(results.Where(r => r.ok).Select(r => r.ip));
            done += batch.Length;
            progress.Report(0.8 * done / ips.Count);
        }
        var found = await Task.WhenAll(open.Select(async ip =>
        {
            var onvif = TcpOpen(ip, 2020, 1200);
            var realm = RtspRealm(ip);
            return new ScanResult(ip, await onvif, (await realm)?.Contains("TP-Link") == true);
        }));
        progress.Report(1);
        return found.OrderBy(r => r.IsTapo ? 0 : r.HasOnvif ? 1 : 2)
                    .ThenBy(r => int.Parse(r.Ip.Split('.')[3])).ToList();
    }
}

/// Home or away. The office also uses 10.1.1.x, so "home" is recognised by the router's MAC.
public sealed class NetworkLocation
{
    readonly Settings settings;
    public string? CurrentRouterMac { get; private set; }
    public event Action? Changed;

    public NetworkLocation(Settings settings)
    {
        this.settings = settings;
        NetworkChange.NetworkAddressChanged += (_, _) => _ = Refresh(2);
        _ = Refresh();
    }

    public LocationMode Mode
    {
        get => settings.Mode;
        set { settings.Mode = value; settings.Save(); Changed?.Invoke(); }
    }

    public string BridgeHost
    {
        get => settings.BridgeHost;
        set { settings.BridgeHost = value.Trim(); settings.Save(); Changed?.Invoke(); }
    }

    public string? HomeRouterMac => settings.HomeRouterMac;

    public bool IsHome => Mode switch
    {
        LocationMode.Home => true,
        LocationMode.Away => false,
        _ => settings.HomeRouterMac == null || CurrentRouterMac == settings.HomeRouterMac,
    };

    public string RouteKey => Restream.LocalUp ? "restream" : IsHome ? "home" : $"away-{BridgeHost}";

    public Endpoint EndpointFor(Camera c)
    {
        // On the home PC: watch through the local go2rtc, so each camera has one connection per lens.
        if (Restream.LocalUp)
            return new Endpoint("127.0.0.1", Restream.Port, Camera.OnvifPort, c.Host, Restream.Password(settings.PairingCode));
        return IsHome || string.IsNullOrWhiteSpace(BridgeHost)
            ? c.LocalEndpoint
            : new Endpoint(BridgeHost, c.BridgeRtspPort, c.BridgeOnvifPort);
    }

    public void MarkCurrentAsHome()
    {
        if (CurrentRouterMac == null) return;
        settings.HomeRouterMac = CurrentRouterMac;
        settings.Save();
        Changed?.Invoke();
    }

    public async Task Refresh(double delaySeconds = 0)
    {
        if (delaySeconds > 0) await Task.Delay(TimeSpan.FromSeconds(delaySeconds));
        var mac = await Task.Run(() => NetInfo.DefaultGateway() is { } gw ? NetInfo.Mac(gw) : null);
        if (mac == CurrentRouterMac) return;
        var wasHome = IsHome;
        CurrentRouterMac = mac;
        Avalonia.Threading.Dispatcher.UIThread.Post(() => Changed?.Invoke());
    }
}
