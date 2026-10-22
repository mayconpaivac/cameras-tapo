using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CamerasTapo;

/// Where to reach a camera: directly at home, or through the home PC when away.
/// RestreamPassword set = video comes from the home PC's go2rtc (rtsp://host:port/cam<slot>_<lens>).
public record Endpoint(string Host, int RtspPort, int OnvifPort, string? OnvifHost = null, string? RestreamPassword = null)
{
    public string PtzHost => OnvifHost ?? Host;
}

public class Camera
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string Host { get; set; } = "";
    public int Port { get; set; } = 554;
    public string Username { get; set; } = "";
    /// Two video sources (e.g. C245D): lens 0 = stream1/2, lens 1 = stream6/7.
    public bool DualLens { get; set; }
    /// Pan/tilt through ONVIF.
    public bool Ptz { get; set; }
    /// Bumped on every edit so open players reconnect.
    public int Revision { get; set; }
    /// Hardware address, used by the bridge to find the camera when its IP changes.
    public string? Mac { get; set; }
    /// Fixed number for this camera's ports on the bridge (RTSP 5540+slot, ONVIF 20200+slot).
    public int Slot { get; set; }
    /// DPAPI-protected (Windows) password, base64.
    public string? Secret { get; set; }

    public const int OnvifPort = 2020;

    [JsonIgnore] public int[] Lenses => DualLens ? new[] { 0, 1 } : new[] { 0 };
    [JsonIgnore] public Endpoint LocalEndpoint => new(Host, Port, OnvifPort);
    [JsonIgnore] public int BridgeRtspPort => 5540 + Slot;
    [JsonIgnore] public int BridgeOnvifPort => 20200 + Slot;

    public string? LensName(int lens) => DualLens ? (lens == 0 ? "Grande-angular" : "Zoom") : null;

    /// High quality = stream1/stream6, light = stream2/stream7.
    public string RtspUrl(string password, int lens, bool highQuality, Endpoint? via = null)
    {
        var target = via ?? LocalEndpoint;
        if (target.RestreamPassword is { } rp) // restreamed by the home PC: always full quality
            return $"rtsp://{Restream.User}:{Uri.EscapeDataString(rp)}@{target.Host}:{target.RtspPort}/cam{Slot}_{lens}";
        string path = lens == 0 ? (highQuality ? "stream1" : "stream2") : (highQuality ? "stream6" : "stream7");
        return $"rtsp://{Uri.EscapeDataString(Username)}:{Uri.EscapeDataString(password)}@{target.Host}:{target.RtspPort}/{path}";
    }

    public Camera Copy() => (Camera)MemberwiseClone();
}

/// One video source on screen: a camera plus which lens.
public record Feed(Camera Camera, int Lens)
{
    public string Id => $"{Camera.Id}-{Lens}";
    public string Title => Camera.LensName(Lens) is { } lens ? $"{Camera.Name} · {lens}" : Camera.Name;
}

/// Camera passwords. Windows: DPAPI (tied to this Windows user). Elsewhere (dev only): base64.
public static class Secrets
{
    static readonly byte[] Entropy = Encoding.UTF8.GetBytes("CamerasTapo.v1");

    public static string Protect(string password)
    {
        var data = Encoding.UTF8.GetBytes(password);
        if (OperatingSystem.IsWindows())
            data = ProtectedData.Protect(data, Entropy, DataProtectionScope.CurrentUser);
        return Convert.ToBase64String(data);
    }

    public static string Unprotect(string? secret)
    {
        if (string.IsNullOrEmpty(secret)) return "";
        try
        {
            var data = Convert.FromBase64String(secret);
            if (OperatingSystem.IsWindows())
                data = ProtectedData.Unprotect(data, Entropy, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(data);
        }
        catch { return ""; }
    }
}

public static class AppPaths
{
    public static string Dir
    {
        get
        {
            // CAMERASTAPO_DATA_DIR overrides the folder (portable use, demo screenshots).
            var dir = Environment.GetEnvironmentVariable("CAMERASTAPO_DATA_DIR") is { Length: > 0 } custom
                ? custom
                : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CamerasTapo");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }
}

public class CameraStore
{
    readonly string file = Path.Combine(AppPaths.Dir, "cameras.json");
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public List<Camera> Cameras { get; private set; } = new();
    public event Action? Changed;

    public CameraStore()
    {
        try
        {
            if (File.Exists(file))
                Cameras = JsonSerializer.Deserialize<List<Camera>>(File.ReadAllText(file), Json) ?? new();
        }
        catch { Cameras = new(); }
        if (Cameras.Any(c => c.Slot == 0))
        {
            foreach (var c in Cameras.Where(c => c.Slot == 0)) c.Slot = NextSlot();
            Persist();
        }
    }

    public IEnumerable<Feed> Feeds => Cameras.SelectMany(c => c.Lenses.Select(l => new Feed(c, l)));

    public string Password(Camera c) => Secrets.Unprotect(c.Secret);

    public void Save(Camera camera, string? password)
    {
        camera.Revision++;
        if (camera.Slot == 0) camera.Slot = NextSlot();
        if (password != null) camera.Secret = Secrets.Protect(password);
        int i = Cameras.FindIndex(c => c.Id == camera.Id);
        if (i >= 0) Cameras[i] = camera; else Cameras.Add(camera);
        Persist();
        Changed?.Invoke();
    }

    public void Remove(Camera camera)
    {
        Cameras.RemoveAll(c => c.Id == camera.Id);
        Persist();
        Changed?.Invoke();
    }

    public void SetMac(Guid id, string mac)
    {
        var cam = Cameras.FirstOrDefault(c => c.Id == id);
        if (cam == null || cam.Mac == mac) return;
        cam.Mac = mac;
        Persist();
    }

    int NextSlot() => (Cameras.Count == 0 ? 0 : Cameras.Max(c => c.Slot)) + 1;

    void Persist() => File.WriteAllText(file, JsonSerializer.Serialize(Cameras, Json));
}

public enum GridLayout { One = 1, Two = 2, Four = 4, Five = 5, Six = 6, Eight = 8 }
public enum FiveStyle { BigLeft, BigTop, ThreeTwo }
public enum LocationMode { Auto, Home, Away }

/// Small app preferences (grid, featured camera, remote access).
public class Settings
{
    public GridLayout Layout { get; set; } = GridLayout.Four;
    public FiveStyle FiveStyle { get; set; } = FiveStyle.ThreeTwo;
    public string FeaturedFeed { get; set; } = "";
    public string ScanPrefix { get; set; } = "";
    public LocationMode Mode { get; set; } = LocationMode.Auto;
    public string BridgeHost { get; set; } = "";
    public string? HomeRouterMac { get; set; }
    /// Shown on the home PC and typed once on the Mac; encrypts the passwords sent to the Mac.
    public string PairingCode { get; set; } = "";
    public string PairingSalt { get; set; } = "";

    static string File_ => Path.Combine(AppPaths.Dir, "settings.json");
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, Converters = { new JsonStringEnumConverter() } };

    public static Settings Load()
    {
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(File_), Json) ?? new(); }
        catch { return new(); }
    }

    public void Save()
    {
        try { File.WriteAllText(File_, JsonSerializer.Serialize(this, Json)); } catch { }
    }
}

public static class Layouts
{
    /// Where each camera goes, as fractions of the page. The first one is the featured spot.
    public static List<(double X, double Y, double W, double H)> Cells(GridLayout layout, FiveStyle five)
    {
        switch (layout)
        {
            case GridLayout.One: return Rows(1);
            case GridLayout.Two: return Rows(2);
            case GridLayout.Four: return Rows(2, 2);
            case GridLayout.Six: return Rows(3, 3);
            case GridLayout.Eight: return Rows(4, 4);
        }
        switch (five)
        {
            case FiveStyle.BigLeft:
                var l = new List<(double, double, double, double)> { (0, 0, 0.5, 1) };
                foreach (var (x, y) in new[] { (0.5, 0.0), (0.75, 0.0), (0.5, 0.5), (0.75, 0.5) }) l.Add((x, y, 0.25, 0.5));
                return l;
            case FiveStyle.BigTop:
                const double top = 0.7;
                var t = new List<(double, double, double, double)> { (0, 0, 1, top) };
                for (int i = 0; i < 4; i++) t.Add((i * 0.25, top, 0.25, 1 - top));
                return t;
            default:
                return Rows(3, 2);
        }
    }

    static List<(double, double, double, double)> Rows(params int[] counts)
    {
        var cells = new List<(double, double, double, double)>();
        double h = 1.0 / counts.Length;
        for (int r = 0; r < counts.Length; r++)
            for (int c = 0; c < counts[r]; c++)
                cells.Add(((double)c / counts[r], r * h, 1.0 / counts[r], h));
        return cells;
    }

    public static string Title(FiveStyle s) => s switch
    {
        FiveStyle.BigLeft => "1 grande + 4 à direita",
        FiveStyle.BigTop => "1 grande + 4 embaixo",
        _ => "3 em cima + 2 embaixo",
    };
}
