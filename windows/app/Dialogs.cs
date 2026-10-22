using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Input.Platform;
using Avalonia.Media;
using Avalonia.Platform.Storage;

namespace CamerasTapo;

static class Dialogs
{
    public static Window Make(string title, double width) => new()
    {
        Title = title, Width = width, SizeToContent = SizeToContent.Height, CanResize = false,
        WindowStartupLocation = WindowStartupLocation.CenterOwner,
    };

    public static TextBlock Caption(string text) => new() { Text = text, FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
    public static TextBlock Heading(string text) => new() { Text = text, FontSize = 20, FontWeight = FontWeight.Bold };

    public static async Task<bool> Confirm(Window owner, string question, string action)
    {
        var w = Make(question, 360);
        bool result = false;
        var ok = new Button { Content = action, Classes = { "accent" } };
        ok.Click += (_, _) => { result = true; w.Close(); };
        var cancel = new Button { Content = "Cancelar" };
        cancel.Click += (_, _) => w.Close();
        w.Content = new StackPanel
        {
            Margin = new Thickness(20), Spacing = 16,
            Children =
            {
                new TextBlock { Text = question, TextWrapping = TextWrapping.Wrap },
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel, ok } },
            },
        };
        await w.ShowDialog(owner);
        return result;
    }

    public static Control Row(string label, Control field) => new DockPanel
    {
        Children = { new TextBlock { Text = label, Width = 90, VerticalAlignment = VerticalAlignment.Center }, field },
    };
}

/// Add / edit a camera.
public sealed class CameraForm : Window
{
    readonly CameraStore store;
    readonly Camera? camera;
    readonly TextBox name = new() { PlaceholderText = "Sala" };
    readonly TextBox host = new() { PlaceholderText = "10.1.1.50" };
    readonly TextBox port = new() { Text = "554" };
    readonly TextBox user = new() { PlaceholderText = "Conta da câmera" };
    readonly TextBox pass = new() { PasswordChar = '•' };
    readonly CheckBox dual = new() { Content = "Duas lentes (C245D, C240D…)" };
    readonly CheckBox ptz = new() { Content = "Movimento PTZ (C206, C245D, C200…)" };
    readonly TextBlock detectResult = Dialogs.Caption("");
    readonly Button detect = new() { Content = "Detectar automaticamente" };
    readonly Button save = new() { Content = "Salvar", Classes = { "accent" }, IsDefault = true };

    public CameraForm(CameraStore store, Camera? camera, string? prefillHost)
    {
        this.store = store;
        this.camera = camera;
        Title = camera == null ? "Nova câmera" : "Editar câmera";
        Width = 460; SizeToContent = SizeToContent.Height; CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        if (camera != null)
        {
            name.Text = camera.Name; host.Text = camera.Host; port.Text = camera.Port.ToString();
            user.Text = camera.Username; dual.IsChecked = camera.DualLens; ptz.IsChecked = camera.Ptz;
            pass.PlaceholderText = "Deixe vazio pra manter";
        }
        else if (prefillHost != null) host.Text = prefillHost;

        detect.Click += async (_, _) => await Detect();
        save.Click += (_, _) => Save();
        var cancel = new Button { Content = "Cancelar", IsCancel = true };
        cancel.Click += (_, _) => Close();
        foreach (var tb in new[] { name, host, port, user, pass }) tb.TextChanged += (_, _) => Validate();
        Validate();

        Content = new StackPanel
        {
            Margin = new Thickness(20), Spacing = 10,
            Children =
            {
                Dialogs.Heading(Title),
                Dialogs.Row("Nome", name), Dialogs.Row("IP", host), Dialogs.Row("Porta", port),
                Dialogs.Row("Usuário", user), Dialogs.Row("Senha", pass),
                dual, ptz,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { detect, detectResult } },
                Dialogs.Caption("Use a conta criada no app Tapo em Configurações avançadas → Conta da câmera. Não é sua conta TP-Link."),
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel, save } },
            },
        };
    }

    string Host => (host.Text ?? "").Trim();
    string EffectivePassword => !string.IsNullOrEmpty(pass.Text) ? pass.Text! : camera != null ? store.Password(camera) : "";

    void Validate()
    {
        save.IsEnabled = !string.IsNullOrWhiteSpace(name.Text) && Host != "" && !string.IsNullOrEmpty(user.Text)
                         && int.TryParse(port.Text, out _) && (camera != null || !string.IsNullOrEmpty(pass.Text));
        detect.IsEnabled = Host != "" && !string.IsNullOrEmpty(user.Text) && EffectivePassword != "";
    }

    /// PTZ: asks ONVIF for a PTZ profile. Second lens: tries to open stream7.
    async Task Detect()
    {
        detect.IsEnabled = false;
        detectResult.Text = "Detectando…";
        var probe = new Camera { Host = Host, Port = int.TryParse(port.Text, out var p) ? p : 554, Username = user.Text ?? "", DualLens = true };
        var password = EffectivePassword;
        string? problem = null;
        bool hasPtz = false;
        try { hasPtz = await new OnvifClient(probe.Host, Camera.OnvifPort, probe.Username, password).HasPtz(); }
        catch (Exception e) { problem = e.Message; }
        var url = probe.RtspUrl(password, 1, false);
        bool second = await Task.Run(() => Engine.CanOpen(url, 6));
        ptz.IsChecked = hasPtz;
        dual.IsChecked = second;
        var found = new List<string>();
        if (second) found.Add("duas lentes");
        if (hasPtz) found.Add("PTZ");
        detectResult.Text = problem != null ? $"Erro: {problem}" : found.Count == 0 ? "Lente única, sem PTZ" : "Encontrado: " + string.Join(" + ", found);
        Validate();
    }

    void Save()
    {
        var cam = camera?.Copy() ?? new Camera();
        cam.Name = (name.Text ?? "").Trim();
        cam.Host = Host;
        cam.Port = int.TryParse(port.Text, out var p) ? p : 554;
        cam.Username = user.Text ?? "";
        cam.DualLens = dual.IsChecked == true;
        cam.Ptz = ptz.IsChecked == true;
        store.Save(cam, string.IsNullOrEmpty(pass.Text) ? null : pass.Text);
        Close();
    }
}

/// Finds cameras on the network.
public sealed class ScanWindow : Window
{
    readonly CameraStore store;
    readonly Settings settings;
    readonly TextBox prefix = new() { Width = 110 };
    readonly ProgressBar progress = new() { Minimum = 0, Maximum = 1, IsVisible = false };
    readonly StackPanel results = new() { Spacing = 4 };
    readonly Button scan = new() { Content = "Escanear", Classes = { "accent" }, IsDefault = true };
    List<ScanResult> last = new();
    bool busy;

    public ScanWindow(CameraStore store, Settings settings)
    {
        this.store = store;
        this.settings = settings;
        Title = "Escanear rede";
        Width = 540; Height = 520; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        prefix.Text = settings.ScanPrefix != "" ? settings.ScanPrefix : NetInfo.LocalPrefixes().FirstOrDefault() ?? "192.168.0";
        scan.Click += async (_, _) => await Run();
        var close = new Button { Content = "Fechar", IsCancel = true };
        close.Click += (_, _) => Close();

        var bottom = new StackPanel { Spacing = 8, Margin = new Thickness(0, 10, 0, 0), Children =
        {
            Dialogs.Caption("De fora de casa, digite a rede de casa (precisa do Tailscale ligado)."),
            new StackPanel { HorizontalAlignment = HorizontalAlignment.Right, Children = { close } },
        } };
        var top = new StackPanel { Spacing = 10, Margin = new Thickness(0, 0, 0, 10), Children =
        {
            Dialogs.Heading("Escanear rede"),
            Dialogs.Caption("Procura aparelhos com vídeo RTSP (porta 554). As câmeras precisam ter a Conta da câmera criada no app Tapo pra aparecerem."),
            new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children =
            {
                new TextBlock { Text = "Rede", VerticalAlignment = VerticalAlignment.Center }, prefix,
                new TextBlock { Text = ".1 – .254", Opacity = 0.6, VerticalAlignment = VerticalAlignment.Center }, scan,
            } },
            progress,
        } };
        var dock = new DockPanel { Margin = new Thickness(20) };
        DockPanel.SetDock(top, Dock.Top);
        DockPanel.SetDock(bottom, Dock.Bottom);
        dock.Children.Add(top);
        dock.Children.Add(bottom);
        dock.Children.Add(new ScrollViewer { Content = results });
        Content = dock;
        Opened += async (_, _) => await Run();
    }

    async Task Run()
    {
        var p = (prefix.Text ?? "").Trim();
        var parts = p.Split('.');
        if (busy || parts.Length != 3 || !parts.All(x => byte.TryParse(x, out _))) return;
        busy = true; scan.IsEnabled = false; progress.IsVisible = true; progress.Value = 0;
        settings.ScanPrefix = p; settings.Save();
        results.Children.Clear();
        last = await NetInfo.Scan(p, new Progress<double>(v => progress.Value = v));
        ShowResults();
        busy = false; scan.IsEnabled = true; progress.IsVisible = false;
    }

    void ShowResults()
    {
        results.Children.Clear();
        foreach (var r in last) results.Children.Add(Row(r));
        if (last.Count == 0)
            results.Children.Add(Dialogs.Caption("Nada encontrado nessa rede. Confira se a Conta da câmera foi criada e se o PC está na mesma rede."));
    }

    Control Row(ScanResult r)
    {
        var added = store.Cameras.FirstOrDefault(c => c.Host == r.Ip);
        Control action;
        if (added != null) action = new TextBlock { Text = "✓ " + added.Name, Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center };
        else
        {
            var b = new Button { Content = "Adicionar" };
            b.Click += async (_, _) =>
            {
                await new CameraForm(store, null, r.Ip).ShowDialog(this);
                ShowResults();
            };
            action = b;
        }
        string kind = r.IsTapo ? "Câmera Tapo / TP-Link" : r.HasOnvif ? "Provável câmera (RTSP + ONVIF)" : "Aparelho com RTSP";
        var row = new DockPanel { Margin = new Thickness(0, 2) };
        DockPanel.SetDock(action, Dock.Right);
        row.Children.Add(action);
        row.Children.Add(new StackPanel { Children =
        {
            new TextBlock { Text = (r.IsTapo ? "📹  " : "🖧  ") + r.Ip, FontFamily = new FontFamily("Consolas, Menlo, monospace") },
            Dialogs.Caption(kind),
        } });
        return new Border { Padding = new Thickness(8), CornerRadius = new CornerRadius(6), Background = new SolidColorBrush(Color.FromArgb(18, 255, 255, 255)), Child = row };
    }
}

/// Remote access. On the home PC: bridge status, Tailscale address and pairing code for the Mac.
/// On another Windows computer: home/away mode and the home PC's address.
public sealed class RemoteWindow : Window
{
    readonly CameraStore store;
    readonly NetworkLocation location;
    readonly BridgeConfig bridge;
    readonly TextBlock where = new() { FontWeight = FontWeight.Bold };
    readonly TextBlock homeInfo = Dialogs.Caption("");
    readonly StackPanel cams = new() { Spacing = 4 };
    readonly TextBlock bridgeStatus = new() { TextWrapping = TextWrapping.Wrap };
    readonly TextBlock tailscale = new() { FontFamily = new FontFamily("Consolas, Menlo, monospace"), FontSize = 18, FontWeight = FontWeight.Bold };
    readonly TextBlock code = new() { FontFamily = new FontFamily("Consolas, Menlo, monospace"), FontSize = 22, FontWeight = FontWeight.Bold, Foreground = Brushes.Orange };

    public RemoteWindow(CameraStore store, NetworkLocation location, BridgeConfig bridge)
    {
        this.store = store;
        this.location = location;
        this.bridge = bridge;
        Title = "Acesso remoto";
        Width = 620; SizeToContent = SizeToContent.Height; CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var copyCode = new Button { Content = "Copiar" };
        copyCode.Click += async (_, _) => { if (Clipboard != null) await Clipboard.SetTextAsync(bridge.PairingCode); };
        var newCode = new Button { Content = "Gerar outro código" };
        newCode.Click += async (_, _) =>
        {
            if (await Dialogs.Confirm(this, "Gerar outro código? O Mac vai precisar do código novo pra sincronizar as senhas.", "Gerar")) { bridge.NewPairingCode(); Refresh(); }
        };
        var copyIp = new Button { Content = "Copiar" };
        copyIp.Click += async (_, _) => { if (Clipboard != null && BridgeConfig.TailscaleIp() is { } ip) await Clipboard.SetTextAsync(ip); };

        var mode = new ComboBox();
        foreach (var (m, label) in new[] { (LocationMode.Auto, "Automático"), (LocationMode.Home, "Sempre em casa"), (LocationMode.Away, "Sempre fora (pelo PC)") })
            mode.Items.Add(new ComboBoxItem { Content = label, Tag = m });
        mode.SelectedIndex = (int)location.Mode;
        mode.SelectionChanged += (_, _) => { if (mode.SelectedItem is ComboBoxItem { Tag: LocationMode m }) { location.Mode = m; Refresh(); } };
        var markHome = new Button { Content = "Esta rede é minha casa" };
        markHome.Click += (_, _) => { location.MarkCurrentAsHome(); Refresh(); };
        var bridgeHost = new TextBox { Text = location.BridgeHost, PlaceholderText = "100.x.y.z (só se este NÃO for o PC de casa)" };
        bridgeHost.LostFocus += (_, _) => location.BridgeHost = bridgeHost.Text ?? "";

        var close = new Button { Content = "Fechar", IsDefault = true };
        close.Click += (_, _) => { location.BridgeHost = bridgeHost.Text ?? ""; Close(); };

        var thisPc = new StackPanel { Spacing = 10, Children =
        {
            bridgeStatus,
            new StackPanel { Spacing = 2, Children =
            {
                Dialogs.Caption("Endereço deste PC no Tailscale (coloque no app do Mac):"),
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { tailscale, copyIp } },
            } },
            new StackPanel { Spacing = 2, Children =
            {
                Dialogs.Caption("Código de pareamento (digite uma vez no Mac; protege as senhas):"),
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { code, copyCode, newCode } },
            } },
            cams,
        } };

        var elsewhere = new StackPanel { Spacing = 8, Children =
        {
            where, mode,
            new DockPanel { Children = { WithDock(markHome, Dock.Right), homeInfo } },
            Dialogs.Row("PC de casa", bridgeHost),
        } };

        Content = new StackPanel
        {
            Margin = new Thickness(20), Spacing = 12,
            Children =
            {
                Dialogs.Heading("Acesso remoto"),
                Dialogs.Caption("Este PC fica em casa e serve de ponte: as câmeras que você adiciona aqui aparecem sozinhas no app do Mac, que vê tudo de fora pelo Tailscale."),
                Group("Este PC é a ponte", thisPc),
                Group("Se este Windows não fica em casa", elsewhere),
                new DockPanel { Children = { WithDock(close, Dock.Right) } },
            },
        };
        bridge.Updated += () => Avalonia.Threading.Dispatcher.UIThread.Post(Refresh);
        Opened += (_, _) => Refresh();
    }

    static Control WithDock(Control c, Dock d) { DockPanel.SetDock(c, d); return c; }

    static Control Group(string title, Control body) => new StackPanel { Spacing = 6, Children =
    {
        new TextBlock { Text = title, FontWeight = FontWeight.SemiBold },
        new Border { Padding = new Thickness(10), CornerRadius = new CornerRadius(8), Background = new SolidColorBrush(Color.FromArgb(18, 255, 255, 255)), Child = body },
    } };

    void Refresh()
    {
        bridgeStatus.Text = BridgeConfig.Installed
            ? "✅ Ponte instalada. " + bridge.Status
            : "⚠ A ponte não está instalada neste PC. Rode o instalador de novo com a opção \"Ponte de acesso remoto\" marcada.";
        tailscale.Text = BridgeConfig.TailscaleIp() ?? "Tailscale não encontrado";
        code.Text = bridge.PairingCode;

        where.Text = location.IsHome ? "🏠 Em casa: conexão direta com as câmeras" : "🌐 Fora: conexão pelo PC de casa";
        homeInfo.Text = location.HomeRouterMac == null ? "Casa ainda não definida (tudo é tratado como casa)."
            : location.CurrentRouterMac == location.HomeRouterMac ? "Roteador desta rede = roteador de casa."
            : $"Roteador desta rede é outro (casa: {location.HomeRouterMac}).";

        cams.Children.Clear();
        foreach (var c in store.Cameras)
        {
            cams.Children.Add(new TextBlock
            {
                Text = $"{c.Name,-14} {c.Host,-15} {c.Mac ?? "MAC desconhecido",-18} vídeo cam{c.Slot}_* · PTZ {c.BridgeOnvifPort}",
                FontFamily = new FontFamily("Consolas, Menlo, monospace"), FontSize = 12,
                Foreground = c.Mac == null ? Brushes.Orange : Brushes.White,
            });
        }
    }
}
