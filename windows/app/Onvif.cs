using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace CamerasTapo;

public record PtzPreset(string Token, string Name);

/// Minimal ONVIF client for Tapo cameras: pan/tilt and saved positions.
public sealed class OnvifClient
{
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(8) };

    readonly string host, username, password;
    readonly int port;
    string? servicePath, profileToken;
    readonly SemaphoreSlim order = new(1, 1); // commands run in order

    public OnvifClient(string host, int port, string username, string password)
    {
        this.host = host; this.port = port; this.username = username; this.password = password;
    }

    public async Task<bool> HasPtz()
    {
        try { await PtzProfile(); return true; }
        catch (OnvifException e) when (e.NoPtz) { return false; }
    }

    public Task Move(double x, double y) => Run(async () =>
    {
        var t = await PtzProfile();
        await Call($"<tptz:ContinuousMove><tptz:ProfileToken>{t}</tptz:ProfileToken><tptz:Velocity><tt:PanTilt x=\"{F(x)}\" y=\"{F(y)}\"/></tptz:Velocity></tptz:ContinuousMove>");
    });

    public Task Stop() => Run(async () =>
    {
        var t = await PtzProfile();
        await Call($"<tptz:Stop><tptz:ProfileToken>{t}</tptz:ProfileToken><tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>false</tptz:Zoom></tptz:Stop>");
    });

    public Task GoTo(PtzPreset p) => Run(async () =>
    {
        var t = await PtzProfile();
        await Call($"<tptz:GotoPreset><tptz:ProfileToken>{t}</tptz:ProfileToken><tptz:PresetToken>{p.Token}</tptz:PresetToken></tptz:GotoPreset>");
    });

    public async Task<List<PtzPreset>> Presets()
    {
        var t = await PtzProfile();
        var xml = await Call($"<tptz:GetPresets><tptz:ProfileToken>{t}</tptz:ProfileToken></tptz:GetPresets>");
        return Regex.Matches(xml, "<tptz:Preset token=\"([^\"]+)\"[^>]*>\\s*<tt:Name>([^<]*)</tt:Name>")
            .Select(m => new PtzPreset(m.Groups[1].Value, WebUtility.HtmlDecode(m.Groups[2].Value).Trim())).ToList();
    }

    async Task Run(Func<Task> op)
    {
        await order.WaitAsync();
        try { await op(); } finally { order.Release(); }
    }

    static string F(double v) => v.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);

    async Task<string> ServicePath()
    {
        if (servicePath != null) return servicePath;
        var xml = await Call("<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>", "/onvif/device_service");
        var addr = Regex.Match(xml, "<tt:PTZ>\\s*<tt:XAddr>([^<]+)").Groups[1].Value;
        if (addr == "") addr = Regex.Match(xml, "<tt:Media>\\s*<tt:XAddr>([^<]+)").Groups[1].Value;
        // Use only the path: the advertised host is the camera's LAN IP, unreachable through the bridge.
        servicePath = Uri.TryCreate(addr, UriKind.Absolute, out var u) && u.AbsolutePath.Length > 1 ? u.AbsolutePath : "/onvif/service";
        return servicePath;
    }

    async Task<string> PtzProfile()
    {
        if (profileToken != null) return profileToken;
        var xml = await Call("<trt:GetProfiles/>");
        foreach (var block in xml.Split("<trt:Profiles ").Skip(1))
        {
            if (!block.Contains("PTZConfiguration")) continue;
            var m = Regex.Match(block, "token=\"([^\"]+)\"");
            if (m.Success) return profileToken = m.Groups[1].Value;
        }
        throw new OnvifException("Câmera sem PTZ", noPtz: true);
    }

    async Task<string> Call(string body, string? path = null)
    {
        path ??= await ServicePath();
        var content = new StringContent(Envelope(body), Encoding.UTF8, "application/soap+xml");
        using var resp = await Http.PostAsync($"http://{host}:{port}{path}", content);
        var text = await resp.Content.ReadAsStringAsync();
        if (resp.StatusCode == HttpStatusCode.Unauthorized || text.Contains("NotAuthorized"))
            throw new OnvifException("Usuário ou senha errados");
        if (text.Contains("Fault>"))
        {
            var reason = Regex.Match(text, "<(?:\\w+:)?Text[^>]*>([^<]+)<").Groups[1].Value;
            throw new OnvifException(reason == "" ? "A câmera recusou o comando" : reason);
        }
        if (!resp.IsSuccessStatusCode) throw new OnvifException($"Erro HTTP {(int)resp.StatusCode}");
        return text;
    }

    /// SOAP envelope with WS-Security UsernameToken (password digest).
    string Envelope(string body)
    {
        var nonce = RandomNumberGenerator.GetBytes(16);
        var created = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
        var digest = SHA1.HashData(nonce.Concat(Encoding.UTF8.GetBytes(created)).Concat(Encoding.UTF8.GetBytes(password)).ToArray());
        return "<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\" "
             + "xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\" xmlns:tptz=\"http://www.onvif.org/ver20/ptz/wsdl\" "
             + "xmlns:tt=\"http://www.onvif.org/ver10/schema\"><s:Header>"
             + "<Security s:mustUnderstand=\"1\" xmlns=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd\">"
             + $"<UsernameToken><Username>{WebUtility.HtmlEncode(username)}</Username>"
             + "<Password Type=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest\">"
             + Convert.ToBase64String(digest) + "</Password>"
             + "<Nonce EncodingType=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary\">"
             + Convert.ToBase64String(nonce) + "</Nonce>"
             + $"<Created xmlns=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd\">{created}</Created>"
             + $"</UsernameToken></Security></s:Header><s:Body>{body}</s:Body></s:Envelope>";
    }
}

public sealed class OnvifException : Exception
{
    public bool NoPtz { get; }
    public OnvifException(string message, bool noPtz = false) : base(message) { NoPtz = noPtz; }
}
