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

    /// Which cell is under the point (-1 when none).
    public int IndexAt(Point p)
    {
        for (int i = 0; i < Cells.Count; i++) if (Rect(i, Bounds.Size).Contains(p)) return i;
        return -1;
    }

    public Rect CellRect(int i) => Rect(i, Bounds.Size);

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
    // Drag and drop to rearrange the grid.
    List<Feed> pageFeeds = new();
    Feed? dragFeed;
    Point dragStart;
    bool dragging;
    bool suppressTap;
    readonly Canvas dragLayer = new() { IsHitTestVisible = false };
    readonly Border dragGhost = new()
    {
        Background = new SolidColorBrush(Color.FromArgb(220, 10, 132, 255)), CornerRadius = new CornerRadius(8),
        Padding = new Thickness(10, 5), Child = new TextBlock { Foreground = Brushes.White, FontWeight = FontWeight.SemiBold },
    };
    readonly Border dropMarker = new()
    {
        BorderBrush = new SolidColorBrush(Color.Parse("#0a84ff")), BorderThickness = new Thickness(3), CornerRadius = new CornerRadius(6),
        Background = new SolidColorBrush(Color.FromArgb(50, 10, 132, 255)),
    };
    Button? prevButton, nextButton;

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
        cells.AddHandler(PointerPressedEvent, OnCellPressed, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        cells.PointerMoved += OnCellMoved;
        cells.PointerReleased += OnCellReleased;
        cells.PointerCaptureLost += (_, _) => EndDrag();
        dragLayer.Children.Add(dropMarker);
        dragLayer.Children.Add(dragGhost);
        Closing += (_, _) => { pip?.Close(); foreach (var t in tiles.Values) t.Stop(); focusedTile?.Stop(); };
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
            case "pip":
                OpenPip(null);
                break;
            case "remote":
                await new RemoteWindow(store, location, bridge).ShowDialog(this);
                break;
        }
    }

    // MARK: Feeds and pages

    List<Feed> OrderedFeeds => store.OrderedFeeds(settings.FeedOrder);

    void SetOrder(List<string> ids)
    {
        settings.FeedOrder = ids;
        settings.Save();
        Rebuild();
    }

    int PerPage => (int)settings.Layout;
    int PageCount => Math.Max(1, (OrderedFeeds.Count + PerPage - 1) / PerPage);

    void Rebuild()
    {
        if (focused != null) focused = store.Cameras.FirstOrDefault(c => c.Id == focused.Id);
        EndDrag();
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
        pageFeeds = feeds;

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
                tile.DoubleTapped += (_, _) => { if (!suppressTap) Open(feed); };
                tile.Tapped += (_, _) =>
                {
                    if (suppressTap) return;
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
    PipWindow? pip;

    /// Opens (or replaces) the Picture in Picture window: whole grid, or one camera.
    void OpenPip(Feed? single)
    {
        pip?.Close();
        pip = new PipWindow(store, settings, location, page, single, () => { Activate(); WindowState = WindowState.Normal; });
        pip.Closed += (_, _) => pip = null;
        pip.Show();
    }

    void StopTiles(List<string> keys)
    {
        foreach (var k in keys) { tiles[k].Stop(); tiles.Remove(k); }
    }

    ContextMenu TileMenu(Feed feed)
    {
        var open = new MenuItem { Header = feed.Camera.Ptz ? "Abrir e controlar" : "Ver em alta qualidade" };
        open.Click += (_, _) => Open(feed);
        var pipItem = new MenuItem { Header = "Picture in Picture" };
        pipItem.Click += (_, _) => OpenPip(feed);
        var feature = new MenuItem { Header = "Colocar em destaque" };
        feature.Click += (_, _) => { page = 0; SetOrder(FeedOrder.Insert(OrderedFeeds, feed.Id, 0)); };
        var edit = new MenuItem { Header = "Editar…" };
        edit.Click += async (_, _) => await EditCamera(feed.Camera);
        var remove = new MenuItem { Header = "Remover…" };
        remove.Click += async (_, _) =>
        {
            if (await Dialogs.Confirm(this, $"Remover {feed.Camera.Name}?", "Remover")) store.Remove(feed.Camera);
        };
        return new ContextMenu { Items = { open, pipItem, feature, edit, new Separator(), remove } };
    }

    void BuildPager()
    {
        pager.Children.Clear();
        var prev = new Button { Content = "‹", IsEnabled = page > 0, Padding = new Thickness(10, 0) };
        prev.Click += (_, _) => Go(-1);
        ToolTip.SetTip(prev, "Página anterior (solte uma câmera aqui pra mandar ela pra lá)");
        prevButton = prev;
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
        ToolTip.SetTip(next, "Próxima página (solte uma câmera aqui pra mandar ela pra lá)");
        nextButton = next;
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

    // MARK: Drag and drop

    void OnCellPressed(object? sender, PointerPressedEventArgs e)
    {
        suppressTap = false;
        dragFeed = null;
        if (focused != null || !e.GetCurrentPoint(cells).Properties.IsLeftButtonPressed) return;
        var pos = e.GetPosition(cells);
        int i = cells.IndexAt(pos);
        if (i < 0 || i >= pageFeeds.Count) return;
        dragFeed = pageFeeds[i];
        dragStart = pos;
    }

    void OnCellMoved(object? sender, PointerEventArgs e)
    {
        if (dragFeed == null) return;
        var pos = e.GetPosition(cells);
        if (!dragging)
        {
            if (!e.GetCurrentPoint(cells).Properties.IsLeftButtonPressed) { dragFeed = null; return; }
            if (Math.Abs(pos.X - dragStart.X) + Math.Abs(pos.Y - dragStart.Y) < 12) return;
            dragging = true;
            suppressTap = true;
            e.Pointer.Capture(cells);
            ((TextBlock)dragGhost.Child!).Text = "⠿ " + dragFeed.Title;
            if (TileFor(dragFeed) is { } t) t.Opacity = 0.4;
            if (!content.Children.Contains(dragLayer)) content.Children.Add(dragLayer);
            Cursor = new Cursor(StandardCursorType.DragMove);
        }

        var inContent = e.GetPosition(content);
        Canvas.SetLeft(dragGhost, inContent.X + 12);
        Canvas.SetTop(dragGhost, inContent.Y + 12);

        int target = cells.IndexAt(pos);
        var pagerTarget = PagerTargetAt(e);
        dropMarker.IsVisible = target >= 0 && pagerTarget == 0;
        if (dropMarker.IsVisible && cells.TranslatePoint(cells.CellRect(target).TopLeft, content) is { } tl)
        {
            var r = cells.CellRect(target);
            Canvas.SetLeft(dropMarker, tl.X);
            Canvas.SetTop(dropMarker, tl.Y);
            dropMarker.Width = r.Width;
            dropMarker.Height = r.Height;
        }
        if (prevButton != null) prevButton.Opacity = pagerTarget == -1 ? 0.5 : 1;
        if (nextButton != null) nextButton.Opacity = pagerTarget == 1 ? 0.5 : 1;
    }

    void OnCellReleased(object? sender, PointerReleasedEventArgs e)
    {
        if (!dragging || dragFeed is not { } feed) { dragFeed = null; return; }
        e.Handled = true;
        int target = cells.IndexAt(e.GetPosition(cells));
        int pagerTarget = PagerTargetAt(e);
        e.Pointer.Capture(null);
        EndDrag();

        if (pagerTarget != 0)
        {
            // Last spot of the previous page, or first spot of the next one.
            int index = pagerTarget < 0 ? page * PerPage - 1 : (page + 1) * PerPage;
            page += pagerTarget;
            SetOrder(FeedOrder.Insert(OrderedFeeds, feed.Id, index));
        }
        else if (target >= 0 && (target >= pageFeeds.Count || pageFeeds[target].Id != feed.Id))
        {
            SetOrder(FeedOrder.Swap(OrderedFeeds, feed.Id, page * PerPage + target));
        }
    }

    /// -1/1 when the pointer is over the pager's ‹ / › button (and it can be used), else 0.
    int PagerTargetAt(PointerEventArgs e)
    {
        if (!content.Children.Contains(pagerBox)) return 0;
        foreach (var (b, dir) in new[] { (prevButton, -1), (nextButton, 1) })
        {
            if (b is not { IsEnabled: true }) continue;
            var p = e.GetPosition(b);
            if (p.X >= -6 && p.Y >= -6 && p.X <= b.Bounds.Width + 6 && p.Y <= b.Bounds.Height + 6) return dir;
        }
        return 0;
    }

    VideoTile? TileFor(Feed feed) => tiles.Values.FirstOrDefault(t => t.Feed.Id == feed.Id);

    void EndDrag()
    {
        if (!dragging) { dragFeed = null; return; }
        dragging = false;
        if (dragFeed != null && TileFor(dragFeed) is { } t) t.Opacity = 1;
        dragFeed = null;
        content.Children.Remove(dragLayer);
        Cursor = Cursor.Default;
        if (prevButton != null) prevButton.Opacity = 1;
        if (nextButton != null) nextButton.Opacity = 1;
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
        if (OrderedFeeds.Count > 1)
        {
            grid.Children.Add(StepArrow("‹", "Câmera anterior (Ctrl+←)", HorizontalAlignment.Left, () => Step(-1)));
            grid.Children.Add(StepArrow("›", "Próxima câmera (Ctrl+→)", HorizontalAlignment.Right, () => Step(1)));
        }
        content.Children.Add(grid);
        Focus();
    }

    /// Full-window view: goes to the previous/next camera in grid order, wrapping around.
    void Step(int delta)
    {
        if (focused == null) return;
        var feeds = OrderedFeeds;
        if (feeds.Count < 2) return;
        var current = new Feed(focused, focusedLens).Id;
        int i = Math.Max(0, feeds.FindIndex(f => f.Id == current));
        var next = feeds[(i + delta + feeds.Count) % feeds.Count];
        ptzPad?.StopMove();
        focused = next.Camera;
        focusedLens = next.Lens;
        Rebuild();
    }

    /// Round ‹ / › button on the side of a single-camera view.
    internal static Button StepArrow(string glyph, string tip, HorizontalAlignment side, Action action, double size = 44)
    {
        var b = new Button
        {
            Content = glyph, Width = size, Height = size, Padding = new Thickness(0, 0, 0, size * 0.1),
            FontSize = size * 0.6, FontWeight = FontWeight.Bold,
            HorizontalAlignment = side, VerticalAlignment = VerticalAlignment.Center,
            HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center,
            Margin = new Thickness(size / 3, 0),
            Background = new SolidColorBrush(Color.FromArgb(130, 0, 0, 0)), Foreground = Brushes.White,
            BorderBrush = new SolidColorBrush(Color.FromArgb(50, 255, 255, 255)), BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(size / 2),
        };
        ToolTip.SetTip(b, tip);
        b.Click += (_, _) => action();
        return b;
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
            var focusedPip = new Button { Content = "⧉ PiP" };
            ToolTip.SetTip(focusedPip, "Abrir esta câmera numa janelinha por cima de tudo");
            var focusedFeed = new Feed(focused, focusedLens);
            focusedPip.Click += (_, _) => OpenPip(focusedFeed);
            toolbar.Children.Add(focusedPip);
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
                { page = 0; SetOrder(FeedOrder.Insert(OrderedFeeds, id, 0)); }
            };
            toolbar.Children.Add(featured);

            var gridPip = new Button { Content = "⧉ PiP" };
            ToolTip.SetTip(gridPip, "Abrir a grade numa janelinha por cima de tudo (duplo clique numa câmera mostra só ela)");
            gridPip.Click += (_, _) => OpenPip(null);
            toolbar.Children.Add(gridPip);
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
            // Ctrl+← → switch cameras, even with PTZ.
            if (e.KeyModifiers.HasFlag(KeyModifiers.Control) && e.Key is Key.Left or Key.Right)
            { Step(e.Key == Key.Left ? -1 : 1); e.Handled = true; return; }
            if (ptzPad == null)
            {
                // No PTZ: ← → switch cameras.
                if (e.Key == Key.Left) { Step(-1); e.Handled = true; }
                if (e.Key == Key.Right) { Step(1); e.Handled = true; }
                return;
            }
            (double x, double y)? dir = e.Key switch
            {
                Key.Up => (0, 0.5), Key.Down => (0, -0.5), Key.Left => (-0.5, 0), Key.Right => (0.5, 0), _ => null,
            };
            if (dir is { } d) { ptzPad.StartMove(d.x, d.y); e.Handled = true; }
            return;
        }
        if (e.Key == Key.Escape && dragging) { EndDrag(); e.Handled = true; return; }
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
