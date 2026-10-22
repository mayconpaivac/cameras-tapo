using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;

namespace CamerasTapo;

/// Camera passwords travel to the Mac encrypted with the pairing code
/// (PBKDF2-SHA256 → AES-256-GCM; secret = nonce(12) | ciphertext | tag(16), base64).
/// Credentials of the PC's restream (go2rtc). The password derives from the pairing code,
/// so the Mac computes the same one without it ever being sent.
public static class Restream
{
    public const string User = "cameras";
    public const int Port = 8554;

    public static string Password(string pairingCode)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes("CamerasTapo.rtsp:" + PairingCrypto.Normalize(pairingCode)));
        return Convert.ToHexString(hash)[..24].ToLowerInvariant();
    }

    /// True while go2rtc answers on this PC (checked every 15 s).
    public static volatile bool LocalUp;
}

public static class PairingCrypto
{
    public const int Iterations = 200_000;
    const string Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O, 1/I

    public static string NewCode()
    {
        var chars = Enumerable.Range(0, 8).Select(_ => Alphabet[RandomNumberGenerator.GetInt32(Alphabet.Length)]).ToArray();
        return new string(chars, 0, 4) + "-" + new string(chars, 4, 4);
    }

    public static string Normalize(string code) => new(code.ToUpperInvariant().Where(char.IsLetterOrDigit).ToArray());

    public static byte[] Key(string code, byte[] salt) =>
        Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(Normalize(code)), salt, Iterations, HashAlgorithmName.SHA256, 32);

    public static string Encrypt(byte[] key, string plaintext)
    {
        var nonce = RandomNumberGenerator.GetBytes(12);
        var data = Encoding.UTF8.GetBytes(plaintext);
        var cipher = new byte[data.Length];
        var tag = new byte[16];
        using var gcm = new AesGcm(key, 16);
        gcm.Encrypt(nonce, data, cipher, tag);
        return Convert.ToBase64String(nonce.Concat(cipher).Concat(tag).ToArray());
    }
}

/// Writes C:\ProgramData\CamerasTapo\bridge.json whenever the cameras change.
/// The bridge service (installed by the setup) picks it up within a second and
/// serves it to the Mac. No passwords in clear text.
public sealed class BridgeConfig
{
    public static string Dir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "CamerasTapo");
    public static string File_ => Path.Combine(Dir, "bridge.json");
    static string ServiceScript => Path.Combine(Dir, "cameras-tapo.ps1");

    /// True when the bridge service is installed on this PC.
    public static bool Installed => OperatingSystem.IsWindows() && File.Exists(ServiceScript);

    static readonly byte[] LocalEntropy = Encoding.UTF8.GetBytes("CamerasTapo.bridge.v1");

    /// Encrypts for the bridge service (runs as SYSTEM on this PC): DPAPI, machine scope.
    static string? ForService(string text)
    {
        if (!OperatingSystem.IsWindows()) return null;
        var data = ProtectedData.Protect(Encoding.UTF8.GetBytes(text), LocalEntropy, DataProtectionScope.LocalMachine);
        return Convert.ToBase64String(data);
    }

    readonly CameraStore store;
    readonly Settings settings;
    public string Status { get; private set; } = "";
    public event Action? Updated;

    public BridgeConfig(CameraStore store, Settings settings)
    {
        this.store = store;
        this.settings = settings;
        if (string.IsNullOrEmpty(settings.PairingCode)) settings.PairingCode = PairingCrypto.NewCode();
        if (string.IsNullOrEmpty(settings.PairingSalt)) settings.PairingSalt = Convert.ToBase64String(RandomNumberGenerator.GetBytes(16));
        settings.Save();
        store.Changed += () => _ = Write();
        _ = Write();
        _ = WatchRestream();
    }

    /// Follows whether go2rtc is up, so the app watches through it (one connection per lens).
    async Task WatchRestream()
    {
        while (true)
        {
            bool up = Installed && await NetInfo.TcpOpen("127.0.0.1", Restream.Port, 1000);
            if (up != Restream.LocalUp)
            {
                Restream.LocalUp = up;
                RestreamChanged?.Invoke();
            }
            await Task.Delay(TimeSpan.FromSeconds(15));
        }
    }

    public event Action? RestreamChanged;

    public string PairingCode => settings.PairingCode;

    public void NewPairingCode()
    {
        settings.PairingCode = PairingCrypto.NewCode();
        settings.PairingSalt = Convert.ToBase64String(RandomNumberGenerator.GetBytes(16));
        settings.Save();
        _ = Write();
    }

    public async Task Write()
    {
        if (!Installed) { Status = "Ponte não instalada neste PC."; Updated?.Invoke(); return; }
        try
        {
            // Learn missing MAC addresses so the bridge can follow IP changes.
            var missing = store.Cameras.Where(c => string.IsNullOrEmpty(c.Mac)).ToList();
            var found = await Task.Run(() => missing.Select(c => (c.Id, mac: NetInfo.Mac(c.Host))).ToList());
            foreach (var (id, mac) in found) if (mac != null) store.SetMac(id, mac);

            var salt = Convert.FromBase64String(settings.PairingSalt);
            var key = await Task.Run(() => PairingCrypto.Key(settings.PairingCode, salt));
            var cams = new JsonArray();
            foreach (var c in store.Cameras)
            {
                cams.Add(new JsonObject
                {
                    ["id"] = c.Id.ToString(), ["name"] = c.Name, ["host"] = c.Host, ["port"] = c.Port,
                    ["username"] = c.Username, ["dualLens"] = c.DualLens, ["ptz"] = c.Ptz,
                    ["slot"] = c.Slot, ["mac"] = c.Mac, ["revision"] = c.Revision,
                    ["secret"] = PairingCrypto.Encrypt(key, store.Password(c)),
                    ["localSecret"] = ForService(store.Password(c)),
                });
            }
            var doc = new JsonObject
            {
                ["version"] = 2,
                ["restreamPort"] = Restream.Port,
                ["restreamSecret"] = ForService(Restream.Password(settings.PairingCode)),
                ["updated"] = DateTime.UtcNow.ToString("o"),
                ["subnet"] = store.Cameras.Count > 0 ? string.Join('.', store.Cameras[0].Host.Split('.').Take(3)) : "10.1.1",
                ["kdfSalt"] = settings.PairingSalt,
                ["kdfIterations"] = PairingCrypto.Iterations,
                ["cameras"] = cams,
            };
            var tmp = File_ + ".tmp";
            await File.WriteAllTextAsync(tmp, doc.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
            File.Move(tmp, File_, overwrite: true);
            Status = $"Ponte atualizada às {DateTime.Now:HH:mm} ({store.Cameras.Count} câmeras).";
        }
        catch (Exception e)
        {
            Status = "Não consegui atualizar a ponte: " + e.Message;
        }
        Updated?.Invoke();
    }

    /// This PC's Tailscale address, to type into the Mac app.
    public static string? TailscaleIp()
    {
        try
        {
            var exe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Tailscale", "tailscale.exe");
            if (!File.Exists(exe)) return null;
            var psi = new ProcessStartInfo(exe, "ip -4") { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
            using var p = Process.Start(psi)!;
            var ip = p.StandardOutput.ReadLine()?.Trim();
            p.WaitForExit(3000);
            return string.IsNullOrEmpty(ip) ? null : ip;
        }
        catch { return null; }
    }
}
