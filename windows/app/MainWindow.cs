using System;
using System.Collections.Generic;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;

namespace CamerasTapo;

/// Positions children by fractional rectangles (0…1) with a small gap.
sealed class CellPanel : Panel
{
    public List<(double X, double Y, double W, double H)> Cells { get; set; } = new();
    const double Gap = 4;

    protected override Size MeasureOverride(Size available)
    {
        for (int i = 0; i < Children.Count && i < Cells.Count; i++)
            Children[i].Measure(Rect(i, available).Size);
        return available;
    }

    protected override Size ArrangeOverride(Size final)
    {
        for (int i = 0; i < Children.Count; i++)
            Children[i].Arrange(i < Cells.Count ? Rect(i, final) : default);
        return final;
    }

    Rect Rect(int i, Size size)
    {
        var (x, y, w, h) = Cells[i];
        double iw = size.Width - Gap, ih = size.Height - Gap;
        return new Rect(x * iw + Gap, y * ih + Gap, Math.Max(0, w * iw - Gap), Math.Max(0, h * ih - Gap));
    }
}

public sealed class MainWindow : Window
{
    readonly CameraStore store = new();
    readonly Settings settings = Settings.Load();
    readonly NetworkLocation location;
    readonly BridgeConfig bridge;

    readonly Panel content = new();
    readonly CellPanel cells = new();
    readonly StackPanel pager = new() { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 12) };
    readonly Border pagerBox;
    readonly StackPanel toolbar = new() { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
    readonly TextBlock title = new() { FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0) };

    readonly Dictionary<string, VideoTile> tiles = new();
    int page;
    Camera? focused;
    int focusedLens;
    PtzPad? ptzPad;
    VideoTile? focusedTile;
    // Camera selected in the grid, and its PTZ pad (kept while the same camera stays selected).
    string? selectedFeedId;
    PtzPad? gridPad;
    string gridPadKey = "";
    double wheelX;

    public MainWindow()
    {
        Title = "Câmeras";
        Width = 1280; Height = 800; MinWidth = 640; MinHeight = 400;
        Background = Brushes.Black;
        try { Icon = new WindowIcon(AssetLoader.Open(new Uri("avares://CamerasTapo/Assets/icon.png"))); } catch { }

        location = new NetworkLocation(settings);
        bridge = new BridgeConfig(store, settings);
        bridge.RestreamChanged += () => Avalonia.Threading.Dispatcher.UIThread.Post(Rebuild);
        location.Changed += Rebuild;
        store.Changed += Rebuild;

        pagerBox = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(160, 0, 0, 0)), CornerRadius = new CornerRadius(16),
            Padding = new Thickness(14, 6), HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 12), Child = pager,
        };

        var top = new DockPanel { Height = 44, Background = new SolidColorBrush(Color.Parse("#1c1c1e")) };
        DockPanel.SetDock(title, Dock.Left);
        top.Children.Add(title);
        top.Children.Add(new Border { Padding = new Thickness(0, 0, 8, 0), Child = toolbar });

        var root = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        root.Children.Add(top);
        root.Children.Add(content);
        Content = root;

        KeyDown += OnKeyDown;
        KeyUp += OnKeyUp;
        content.PointerWheelChanged += OnWheel;
        Closing += (_, _) => { foreach (var t in tiles.Values) t.Stop(); focusedTile?.Stop(); };
        Opened += (_, _) => ShowScreenshotScene();
        Rebuild();
    }

    /// README screenshots only: start with `--screenshot-scene ptz|remote`.
    async void ShowScreenshotScene()
    {
        var args = Environment.GetCommandLineArgs();
        int i = Array.IndexOf(args, "--screenshot-scene");
        if (i < 0 || i + 1 >= args.Length) return;
        await System.Threading.Tasks.Task.Delay(1500);
        switch (args[i + 1])
        {
            case "ptz":
                selectedFeedId = OrderedFeeds.FirstOrDefault(f => f.Camera.Ptz)?.Id;
                UpdateSelection();
                break;
            case "remote":
                await new RemoteWindow(store, location, bridge).ShowDialog(this);
                break;
        }
    }

    // MARK: Feeds and pages

    List<Feed> OrderedFeeds
    {
        get
        {
            var feeds = store.Feeds.ToList();
            int i = feeds.FindIndex(f => f.Id == settings.FeaturedFeed);
            if (i > 0) { var f = feeds[i]; feeds.RemoveAt(i); feeds.Insert(0, f); }
            return feeds;
        }
    }

    int PerPage => (int)settings.Layout;
    int PageCount => Math.Max(1, (OrderedFeeds.Count + PerPage - 1) / PerPage);

    void Rebuild()
    {
        if (focused != null) focused = store.Cameras.FirstOrDefault(c => c.Id == focused.Id);
        BuildToolbar();
        content.Children.Clear();
        ptzPad?.StopMove();
        ptzPad = null;
        focusedTile?.Stop();
        focusedTile = null;

        if (focused != null || store.Cameras.Count == 0)
        {
            StopTiles(tiles.Keys.ToList()); // grid streams stop while one camera is open
            if (focused != null) BuildFocused(focused); else BuildEmpty();
            return;
        }

        page = Math.Clamp(page, 0, PageCount - 1);
        var cellList = Layouts.Cells(settings.Layout, settings.FiveStyle);
        var feeds = OrderedFeeds.Skip(page * PerPage).Take(PerPage).ToList();

        var keep = new Dictionary<string, VideoTile>();
        cells.Children.Clear();
        for (int i = 0; i < cellList.Count; i++)
        {
            if (i >= feeds.Count)
            {
                cells.Children.Add(new Border { Background = new SolidColorBrush(Color.FromArgb(8, 255, 255, 255)), CornerRadius = new CornerRadius(6) });
                continue;
            }
            var feed = feeds[i];
            var c = cellList[i];
            const bool hq = true; // always full quality (stream1/stream6)
            string key = $"{feed.Id}-{feed.Camera.Revision}-{hq}-{location.RouteKey}";
            if (!tiles.TryGetValue(key, out var tile))
            {
                tile = new VideoTile(feed, hq, location.EndpointFor(feed.Camera), store.Password(feed.Camera));
                tile.DoubleTapped += (_, _) => Open(feed);
                tile.Tapped += (_, _) =>
                {
                    selectedFeedId = selectedFeedId == feed.Id ? null : feed.Id;
                    UpdateSelection();
                    Focus();
                };
                tile.ContextMenu = TileMenu(feed);
                tile.Start();
            }
            keep[key] = tile;
            cells.Children.Add(tile);
        }
        StopTiles(tiles.Keys.Where(k => !keep.ContainsKey(k)).ToList());
        tiles.Clear();
        foreach (var kv in keep) tiles[kv.Key] = kv.Value;
        cells.Cells = cellList;

        content.Children.Add(cells);
        BuildPager();
        if (PageCount > 1) content.Children.Add(pagerBox);
        title.Text = "Câmeras";
        UpdateSelection();
    }

    /// Frames the selected tile and shows the PTZ pad for it over the grid.
    void UpdateSelection()
    {
        var feed = tiles.Values.Select(t => t.Feed).FirstOrDefault(f => f.Id == selectedFeedId);
        if (feed == null) selectedFeedId = null;
        foreach (var t in tiles.Values) t.Selected = t.Feed.Id == selectedFeedId;

        if (gridPanel != null) content.Children.Remove(gridPanel);
        gridPanel = null;
        if (feed == null || !feed.Camera.Ptz)
        {
            gridPad?.StopMove();
            gridPad = null;
            gridPadKey = "";
            return;
        }

        var cam = feed.Camera;
        var ep = location.EndpointFor(cam);
        string key = $"{cam.Id}-{cam.Revision}-{ep}";
        if (gridPad == null || gridPadKey != key)
        {
            gridPad?.StopMove();
            gridPad = new PtzPad(new OnvifClient(ep.PtzHost, ep.OnvifPort, cam.Username, store.Password(cam)));
            gridPadKey = key;
        }
        (gridPad.Parent as Panel)?.Children.Remove(gridPad);

        var close = new Button { Content = "✕", Padding = new Thickness(6, 0), Background = Brushes.Transparent };
        ToolTip.SetTip(close, "Tirar a seleção (Esc)");
        close.Click += (_, _) => { selectedFeedId = null; UpdateSelection(); };
        var header = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(160, 0, 0, 0)), CornerRadius = new CornerRadius(12),
            Padding = new Thickness(10, 2, 2, 2), Margin = new Thickness(0, 0, 16, -8), HorizontalAlignment = HorizontalAlignment.Right,
            Child = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children =
            {
                new TextBlock { Text = "✥ " + cam.Name, Foreground = Brushes.White, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center },
                close,
            } },
        };
        gridPanel = new StackPanel
        {
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 0, PageCount > 1 ? 44 : 0),
            Children = { header, gridPad },
        };
        content.Children.Add(gridPanel);
    }

    StackPanel? gridPanel;

    void StopTiles(List<string> keys)
    {
        foreach (var k in keys) { tiles[k].Stop(); tiles.Remove(k); }
    }

    ContextMenu TileMenu(Feed feed)
    {
        var open = new MenuItem { Header = feed.Camera.Ptz ? "Abrir e controlar" : "Ver em alta qualidade" };
        open.Click += (_, _) => Open(feed);
        var feature = new MenuItem { Header = "Colocar em destaque" };
        feature.Click += (_, _) => { settings.FeaturedFeed = feed.Id; settings.Save(); page = 0; Rebuild(); };
        var edit = new MenuItem { Header = "Editar…" };
        edit.Click += async (_, _) => await EditCamera(feed.Camera);
        var remove = new MenuItem { Header = "Remover…" };
        remove.Click += async (_, _) =>
        {
            if (await Dialogs.Confirm(this, $"Remover {feed.Camera.Name}?", "Remover")) store.Remove(feed.Camera);
        };
        return new ContextMenu { Items = { open, feature, edit, new Separator(), remove } };
    }

    void BuildPager()
    {
        pager.Children.Clear();
        var prev = new Button { Content = "‹", IsEnabled = page > 0, Padding = new Thickness(10, 0) };
        prev.Click += (_, _) => Go(-1);
        pager.Children.Add(prev);
        for (int i = 0; i < PageCount; i++)
        {
            int target = i;
            var dot = new Border { Width = 8, Height = 8, CornerRadius = new CornerRadius(4), VerticalAlignment = VerticalAlignment.Center, Background = new SolidColorBrush(Colors.White, i == page ? 0.95 : 0.35), Cursor = new Cursor(StandardCursorType.Hand) };
            dot.PointerPressed += (_, _) => { page = target; Rebuild(); };
            pager.Children.Add(dot);
        }
        pager.Children.Add(new TextBlock { Text = $"{page + 1}/{PageCount}", Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center });
        var next = new Button { Content = "›", IsEnabled = page < PageCount - 1, Padding = new Thickness(10, 0) };
        next.Click += (_, _) => Go(1);
        pager.Children.Add(next);
    }

    void Go(int delta)
    {
        int t = Math.Clamp(page + delta, 0, PageCount - 1);
        if (t == page) return;
        page = t;
        Rebuild();
    }

    void BuildEmpty()
    {
        title.Text = "Câmeras";
        var scan = new Button { Content = "Escanear rede", Classes = { "accent" } };
        scan.Click += async (_, _) => await Scan();
        var add = new Button { Content = "Adicionar manualmente" };
        add.Click += async (_, _) => await EditCamera(null);
        content.Children.Add(new StackPanel
        {
            Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                new TextBlock { Text = "📹", FontSize = 44, HorizontalAlignment = HorizontalAlignment.Center },
                new TextBlock { Text = "Nenhuma câmera ainda", FontSize = 22, HorizontalAlignment = HorizontalAlignment.Center },
                new TextBlock { Text = "Adicione o IP e a conta da câmera criada no app Tapo\n(Configurações avançadas → Conta da câmera).", TextAlignment = TextAlignment.Center, Opacity = 0.7 },
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, Children = { scan, add } },
            },
        });
    }

    // MARK: Full-window camera

    void Open(Feed feed)
    {
        selectedFeedId = null;
        gridPad?.StopMove();
        gridPad = null;
        gridPadKey = "";
        focused = feed.Camera;
        focusedLens = feed.Lens;
        Rebuild();
    }

    void CloseFocused()
    {
        ptzPad?.StopMove();
        focused = null;
        Rebuild();
    }

    void BuildFocused(Camera cam)
    {
        var endpoint = location.EndpointFor(cam);
        var feed = new Feed(cam, focusedLens);
        title.Text = feed.Title;
        var tile = new VideoTile(feed, true, endpoint, store.Password(cam));
        tile.DoubleTapped += (_, _) => CloseFocused();
        focusedTile = tile;
        tile.Start();
        var grid = new Grid { Children = { tile } };
        if (cam.Ptz)
        {
            ptzPad = new PtzPad(new OnvifClient(endpoint.PtzHost, endpoint.OnvifPort, cam.Username, store.Password(cam)));
            grid.Children.Add(ptzPad);
        }
        content.Children.Add(grid);
        Focus();
    }

    // MARK: Toolbar

    void BuildToolbar()
    {
        toolbar.Children.Clear();
        if (focused != null)
        {
            var back = new Button { Content = "▦  Voltar" };
            ToolTip.SetTip(back, "Voltar pra grade (Esc)");
            back.Click += (_, _) => CloseFocused();
            toolbar.Children.Add(back);
            if (focused.DualLens)
            {
                foreach (var (lens, name) in new[] { (0, "Grande-angular"), (1, "Zoom") })
                {
                    var b = new ToggleButton { Content = name, IsChecked = focusedLens == lens };
                    b.Click += (_, _) => { focusedLens = lens; Rebuild(); };
                    toolbar.Children.Add(b);
                }
            }
        }
        else if (store.Cameras.Count > 0)
        {
            var layouts = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
            foreach (GridLayout l in Enum.GetValues<GridLayout>())
            {
                var b = new ToggleButton { Content = ((int)l).ToString(), IsChecked = settings.Layout == l, MinWidth = 32, Padding = new Thickness(8, 4) };
                b.Click += (_, _) => { settings.Layout = l; settings.Save(); Rebuild(); };
                layouts.Children.Add(b);
            }
            ToolTip.SetTip(layouts, "Câmeras por tela. Troque de página com ← → ou nos botões embaixo.");
            toolbar.Children.Add(layouts);

            if (settings.Layout == GridLayout.Five)
            {
                var styles = new ComboBox { VerticalAlignment = VerticalAlignment.Center };
                foreach (FiveStyle s in Enum.GetValues<FiveStyle>()) styles.Items.Add(new ComboBoxItem { Content = Layouts.Title(s), Tag = s });
                styles.SelectedIndex = (int)settings.FiveStyle;
                styles.SelectionChanged += (_, _) =>
                {
                    if (styles.SelectedItem is ComboBoxItem { Tag: FiveStyle s } && s != settings.FiveStyle)
                    { settings.FiveStyle = s; settings.Save(); Rebuild(); }
                };
                toolbar.Children.Add(styles);
            }

            var featured = new ComboBox { VerticalAlignment = VerticalAlignment.Center, MinWidth = 180 };
            var feeds = store.Feeds.ToList();
            var first = OrderedFeeds.FirstOrDefault();
            foreach (var f in feeds) featured.Items.Add(new ComboBoxItem { Content = "★ " + f.Title, Tag = f.Id });
            featured.SelectedIndex = first == null ? -1 : feeds.FindIndex(f => f.Id == first.Id);
            ToolTip.SetTip(featured, "Câmera em destaque (a primeira, ou a grande)");
            featured.SelectionChanged += (_, _) =>
            {
                if (featured.SelectedItem is ComboBoxItem { Tag: string id } && id != OrderedFeeds.FirstOrDefault()?.Id)
                { settings.FeaturedFeed = id; settings.Save(); page = 0; Rebuild(); }
            };
            toolbar.Children.Add(featured);
        }

        var where = new Button { Content = location.IsHome ? "🏠 Em casa" : "🌐 Fora" };
        ToolTip.SetTip(where, location.IsHome ? "Conectando direto nas câmeras. Clique pra configurar o acesso de fora."
                                              : "Conectando pelo PC de casa (Tailscale). Clique pra configurar.");
        where.Click += async (_, _) => { await new RemoteWindow(store, location, bridge).ShowDialog(this); Rebuild(); };
        toolbar.Children.Add(where);

        var scan = new Button { Content = "Escanear" };
        scan.Click += async (_, _) => await Scan();
        toolbar.Children.Add(scan);
        var add = new Button { Content = "+" };
        ToolTip.SetTip(add, "Adicionar câmera");
        add.Click += async (_, _) => await EditCamera(null);
        toolbar.Children.Add(add);
    }

    async System.Threading.Tasks.Task EditCamera(Camera? cam, string? prefillHost = null)
    {
        var form = new CameraForm(store, cam, prefillHost);
        await form.ShowDialog(this);
    }

    async System.Threading.Tasks.Task Scan()
    {
        await new ScanWindow(store, settings).ShowDialog(this);
    }

    // MARK: Keyboard and wheel

    void OnKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Source is TextBox) return;
        if (focused != null)
        {
            if (e.Key == Key.Escape) { CloseFocused(); e.Handled = true; return; }
            if (ptzPad == null) return;
            (double x, double y)? dir = e.Key switch
            {
                Key.Up => (0, 0.5), Key.Down => (0, -0.5), Key.Left => (-0.5, 0), Key.Right => (0.5, 0), _ => null,
            };
            if (dir is { } d) { ptzPad.StartMove(d.x, d.y); e.Handled = true; }
            return;
        }
        if (e.Key == Key.Escape && selectedFeedId != null) { selectedFeedId = null; UpdateSelection(); e.Handled = true; return; }
        if (gridPad != null)
        {
            (double x, double y)? move = e.Key switch
            {
                Key.Up => (0, 0.5), Key.Down => (0, -0.5), Key.Left => (-0.5, 0), Key.Right => (0.5, 0), _ => null,
            };
            if (move is { } m) { gridPad.StartMove(m.x, m.y); e.Handled = true; }
            return;
        }
        if (e.Key == Key.Left) { Go(-1); e.Handled = true; }
        if (e.Key == Key.Right) { Go(1); e.Handled = true; }
    }

    void OnKeyUp(object? sender, KeyEventArgs e)
    {
        var pad = focused != null ? ptzPad : gridPad;
        if (pad != null && e.Key is Key.Up or Key.Down or Key.Left or Key.Right)
        { pad.StopMove(); e.Handled = true; }
    }

    void OnWheel(object? sender, PointerWheelEventArgs e)
    {
        if (focused != null || Math.Abs(e.Delta.X) <= Math.Abs(e.Delta.Y)) return;
        wheelX += e.Delta.X;
        if (wheelX > 3) { wheelX = 0; Go(-1); }
        else if (wheelX < -3) { wheelX = 0; Go(1); }
    }
}
