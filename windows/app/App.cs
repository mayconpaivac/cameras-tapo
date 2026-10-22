using System;
using System.Linq;
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Styling;
using Avalonia.Themes.Fluent;

namespace CamerasTapo;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        Engine.StartLog();
        if (args.Contains("--diagnostico")) return Diagnostics.Run().GetAwaiter().GetResult();
        return AppBuilder.Configure<App>().UsePlatformDetect().StartWithClassicDesktopLifetime(args);
    }
}

/// `CamerasTapo --diagnostico`: tests video and ONVIF for every saved camera, without opening windows.
static class Diagnostics
{
    public static async System.Threading.Tasks.Task<int> Run()
    {
        if (OperatingSystem.IsWindows()) AttachConsole(-1);
        var store = new CameraStore();
        var settings = Settings.Load();
        var location = new NetworkLocation(settings);
        await location.Refresh();
        Restream.LocalUp = BridgeConfig.Installed && await NetInfo.TcpOpen("127.0.0.1", Restream.Port, 1500);
        Console.WriteLine($"Retransmissão do PC (go2rtc): {(Restream.LocalUp ? "ativa" : "não encontrada")}");
        Console.WriteLine($"Local: {(location.IsHome ? "em casa" : "fora")} (roteador {location.CurrentRouterMac ?? "?"})");
        int failures = 0;
        foreach (var cam in store.Cameras)
        {
            var ep = location.EndpointFor(cam);
            var pw = store.Password(cam);
            foreach (var lens in cam.Lenses)
            {
                var err = new byte[256];
                var sw = System.Diagnostics.Stopwatch.StartNew();
                var s = Engine.tce_open(Engine.Utf8Z(cam.RtspUrl(pw, lens, true, ep)), 8, IntPtr.Zero, err, err.Length);
                string result;
                if (s == IntPtr.Zero) { result = "FALHOU: " + Engine.Message(err); failures++; }
                else
                {
                    Console.WriteLine($"{cam.Name} lente {lens}: conectou em {sw.ElapsedMilliseconds} ms, esperando imagem…");
                    int r = 0, w = 0, h = 0;
                    var handle = s;
                    var reader = System.Threading.Tasks.Task.Run(() =>
                    {
                        int rr;
                        do rr = Engine.tce_read(handle, out _, out w, out h, out _, err, err.Length); while (rr == 0);
                        return rr;
                    });
                    if (!reader.Wait(TimeSpan.FromSeconds(15))) { Engine.tce_abort(s); reader.Wait(5000); r = 0; }
                    else r = reader.Result;
                    string decoder = Engine.tce_hardware(s) == 1 ? "GPU" : "CPU";
                    Console.WriteLine("    " + Engine.Stats(s));
                    result = r > 0 ? $"ok {w}x{h} ({decoder}, {sw.ElapsedMilliseconds} ms)"
                           : r == 0 ? $"FALHOU: conectou mas nenhuma imagem em 15 s ({decoder})"
                           : "FALHOU: " + Engine.Message(err);
                    if (r <= 0) failures++;
                    Engine.tce_close(s);
                }
                Console.WriteLine($"{cam.Name} lente {lens} via {ep.Host}:{ep.RtspPort}{(ep.RestreamPassword != null ? " (go2rtc)" : "")}: {result}");
            }
            if (cam.Ptz)
            {
                try
                {
                    var presets = await new OnvifClient(ep.PtzHost, ep.OnvifPort, cam.Username, pw).Presets();
                    Console.WriteLine($"{cam.Name} PTZ via {ep.PtzHost}:{ep.OnvifPort}: ok, posições: {string.Join(", ", presets.Select(p => p.Name))}");
                }
                catch (Exception e) { Console.WriteLine($"{cam.Name} PTZ: FALHOU: {e.Message}"); failures++; }
            }
        }
        Console.WriteLine();
        Console.WriteLine($"Log detalhado: {Engine.LogPath}");
        return failures == 0 ? 0 : 1;
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    static extern bool AttachConsole(int processId);
}

public sealed class App : Application
{
    public override void Initialize()
    {
        Styles.Add(new FluentTheme());
        RequestedThemeVariant = ThemeVariant.Dark;
        Name = "Câmeras";
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
            desktop.MainWindow = new MainWindow();
        base.OnFrameworkInitializationCompleted();
    }
}
