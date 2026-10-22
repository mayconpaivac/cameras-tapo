using System;
using System.Collections.Generic;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace CamerasTapo;

/// Picture in Picture: a small window that stays above all others.
/// Shows the same grid as the main window, or a single camera (double-click switches).
public sealed class PipWindow : Window
{
    readonly CameraStore store;
    readonly Settings settings;
    readonly NetworkLocation location;
    readonly CellPanel cells = new();
    readonly StackPanel controls = new() { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(8), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top };
    readonly List<VideoTile> tiles = new();
    readonly Action returnToApp;
    string? singleFeedId;
    int page;

    public PipWindow(CameraStore store, Settings settings, NetworkLocation location, int page, Feed? single, Action returnToApp)
    {
        this.store = store;
        this.settings = settings;
        this.location = location;
        this.page = page;
        this.returnToApp = returnToApp;
        singleFeedId = single?.Id;

        Title = "Câmeras — Picture in Picture";
        Topmost = true;
        Width = 480; Height = 270; MinWidth = 240; MinHeight = 135;
        Background = Brushes.Black;
        ShowInTaskbar = true;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Icon = (Application.Current?.ApplicationLifetime as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)?.MainWindow?.Icon;

        controls.IsVisible = false;
        var root = new Grid { Children = { cells, controls } };
        root.PointerEntered += (_, _) => controls.IsVisible = true;
        root.PointerExited += (_, _) => controls.IsVisible = false;
        Content = root;

        store.Changed += Rebuild;
        location.Changed += Rebuild;
        Closed += (_, _) =>
        {
            store.Changed -= Rebuild;
            location.Changed -= Rebuild;
            StopTiles();
        };
        Opened += (_, _) => PlaceBottomRight();
        Rebuild();
    }

    void PlaceBottomRight()
    {
        if (Screens.ScreenFromWindow(this) is not { } screen) return;
        var area = screen.WorkingArea;
        var scale = screen.Scaling;
        Position = new PixelPoint(area.Right - (int)((Width + 20) * scale), area.Bottom - (int)((Height + 20) * scale));
    }

    List<Feed> Feeds => store.OrderedFeeds(settings.FeaturedFeed);
    int PerPage => (int)settings.Layout;
    int PageCount => Math.Max(1, (Feeds.Count + PerPage - 1) / PerPage);

    void StopTiles()
    {
        foreach (var t in tiles) t.Stop();
        tiles.Clear();
    }

    void Rebuild()
    {
        StopTiles();
        cells.Children.Clear();
        var feeds = Feeds;
        var single = feeds.FirstOrDefault(f => f.Id == singleFeedId);
        if (single == null) singleFeedId = null;

        List<Feed> shown;
        if (single != null)
        {
            cells.Cells = Layouts.Cells(GridLayout.One, settings.FiveStyle);
            shown = new() { single };
        }
        else
        {
            page = Math.Clamp(page, 0, PageCount - 1);
            cells.Cells = Layouts.Cells(settings.Layout, settings.FiveStyle);
            shown = feeds.Skip(page * PerPage).Take(PerPage).ToList();
        }

        for (int i = 0; i < cells.Cells.Count; i++)
        {
            if (i >= shown.Count)
            {
                cells.Children.Add(new Border { Background = new SolidColorBrush(Color.FromArgb(8, 255, 255, 255)) });
                continue;
            }
            var feed = shown[i];
            var tile = new VideoTile(feed, true, location.EndpointFor(feed.Camera), store.Password(feed.Camera), compact: single == null);
            tile.DoubleTapped += (_, _) => { singleFeedId = singleFeedId == null ? feed.Id : null; Rebuild(); };
            tile.Start();
            tiles.Add(tile);
            cells.Children.Add(tile);
        }
        BuildControls(single != null);
    }

    void BuildControls(bool single)
    {
        controls.Children.Clear();
        if (single) controls.Children.Add(Control("▦", "Ver todas as câmeras", () => { singleFeedId = null; Rebuild(); }));
        else if (PageCount > 1)
        {
            controls.Children.Add(Control("‹", "Página anterior", () => { page = Math.Max(page - 1, 0); Rebuild(); }));
            controls.Children.Add(new TextBlock { Text = $"{page + 1}/{PageCount}", Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center });
            controls.Children.Add(Control("›", "Próxima página", () => { page = Math.Min(page + 1, PageCount - 1); Rebuild(); }));
        }
        controls.Children.Add(Control("⤢", "Voltar ao app", () => { Close(); returnToApp(); }));
        controls.Children.Add(Control("✕", "Fechar", Close));
    }

    static Button Control(string glyph, string tip, Action action)
    {
        var b = new Button
        {
            Content = glyph, Width = 30, Height = 30, Padding = new Thickness(0),
            HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center,
            Background = new SolidColorBrush(Color.FromArgb(160, 0, 0, 0)), Foreground = Brushes.White,
            CornerRadius = new CornerRadius(15),
        };
        ToolTip.SetTip(b, tip);
        b.Click += (_, _) => action();
        return b;
    }
}
