using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;

namespace CamerasTapo;

/// One video source with its own player.
public sealed class VideoTile : Border
{
    public Feed Feed { get; }
    readonly StreamPlayer player;
    readonly Image image = new() { Stretch = Stretch.Uniform };
    readonly TextBlock status = new()
    {
        Foreground = Brushes.White, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap,
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        Margin = new Thickness(12), FontSize = 12, Opacity = 0.85,
    };

    public VideoTile(Feed feed, bool highQuality, Endpoint endpoint, string password, bool compact = false)
    {
        Feed = feed;
        Background = Brushes.Black;
        CornerRadius = new CornerRadius(6);
        ClipToBounds = true;

        var label = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(140, 0, 0, 0)),
            CornerRadius = new CornerRadius(6),
            Padding = compact ? new Thickness(4, 1) : new Thickness(8, 3),
            Margin = new Thickness(compact ? 3 : 8),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Bottom,
            Child = new TextBlock
            {
                Text = feed.Title + (feed.Camera.Ptz ? "  ✥" : ""),
                Foreground = Brushes.White, FontWeight = FontWeight.SemiBold, FontSize = compact ? 9 : 13,
            },
        };
        Child = new Grid { Children = { image, status, label } };

        player = new StreamPlayer(feed.Camera.RtspUrl(password, feed.Lens, highQuality, endpoint), feed.Camera.Host);
        player.FrameShown += () =>
        {
            if (image.Source != player.Bitmap) image.Source = player.Bitmap;
            image.InvalidateVisual();
        };
        player.StateChanged += UpdateStatus;
        UpdateStatus();
    }

    /// Blue frame around the camera selected in the grid.
    public bool Selected
    {
        set
        {
            BorderBrush = value ? new SolidColorBrush(Color.Parse("#0a84ff")) : null;
            BorderThickness = new Thickness(value ? 3 : 0);
        }
    }

    // The window decides when a stream runs (tiles are re-parented when the grid is rebuilt).
    public void Start() => player.Start();
    public void Stop() => player.Stop();

    void UpdateStatus()
    {
        status.IsVisible = player.State != PlayerState.Playing;
        status.Text = player.State switch
        {
            PlayerState.Connecting => player.Message == "" ? "Conectando…" : player.Message,
            PlayerState.Failed => $"⚠ {player.Message}\nTentando de novo…",
            _ => "",
        };
    }
}

/// Pan/tilt pad for the full-window view. Hold an arrow to move, release to stop.
public sealed class PtzPad : StackPanel
{
    readonly OnvifClient client;
    readonly TextBlock error = new() { Foreground = Brushes.White, FontSize = 12, TextWrapping = TextWrapping.Wrap, MaxWidth = 220 };
    readonly Border errorBox;
    readonly ComboBox presets = new() { PlaceholderText = "Posições", MinWidth = 150, IsVisible = false };
    bool moving;
    const double Speed = 0.5;

    public PtzPad(OnvifClient client)
    {
        this.client = client;
        Spacing = 10;
        Margin = new Thickness(16);
        HorizontalAlignment = HorizontalAlignment.Right;
        VerticalAlignment = VerticalAlignment.Bottom;

        var pad = new Grid { Width = 132, Height = 132 };
        pad.Children.Add(new Border { CornerRadius = new CornerRadius(66), Background = new SolidColorBrush(Color.FromArgb(115, 0, 0, 0)), BorderBrush = new SolidColorBrush(Color.FromArgb(64, 255, 255, 255)), BorderThickness = new Thickness(1) });
        pad.Children.Add(Arrow("▲", 0, Speed, HorizontalAlignment.Center, VerticalAlignment.Top));
        pad.Children.Add(Arrow("▼", 0, -Speed, HorizontalAlignment.Center, VerticalAlignment.Bottom));
        pad.Children.Add(Arrow("◀", -Speed, 0, HorizontalAlignment.Left, VerticalAlignment.Center));
        pad.Children.Add(Arrow("▶", Speed, 0, HorizontalAlignment.Right, VerticalAlignment.Center));

        presets.SelectionChanged += async (_, _) =>
        {
            if (presets.SelectedItem is ComboBoxItem { Tag: PtzPreset p })
            {
                await Do(() => client.GoTo(p));
                presets.SelectedIndex = -1;
            }
        };
        errorBox = new Border { Background = new SolidColorBrush(Color.FromArgb(180, 200, 40, 40)), CornerRadius = new CornerRadius(6), Padding = new Thickness(6), Child = error, IsVisible = false };

        Children.Add(presets);
        Children.Add(pad);
        Children.Add(errorBox);
        _ = LoadPresets();
    }

    async Task LoadPresets()
    {
        try
        {
            var list = await client.Presets();
            foreach (var p in list) presets.Items.Add(new ComboBoxItem { Content = p.Name, Tag = p });
            presets.IsVisible = list.Count > 0;
        }
        catch (Exception e) { ShowError(e.Message); }
    }

    Control Arrow(string glyph, double x, double y, HorizontalAlignment h, VerticalAlignment v)
    {
        var b = new Border
        {
            Width = 44, Height = 44, HorizontalAlignment = h, VerticalAlignment = v, Background = Brushes.Transparent,
            Cursor = new Cursor(StandardCursorType.Hand),
            Child = new TextBlock { Text = glyph, FontSize = 20, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
        };
        ToolTip.SetTip(b, "Segure pra mover (ou use as setas do teclado)");
        b.PointerPressed += (_, e) => { e.Pointer.Capture(b); StartMove(x, y); };
        b.PointerReleased += (_, e) => { e.Pointer.Capture(null); StopMove(); };
        b.PointerCaptureLost += (_, _) => StopMove();
        return b;
    }

    public void StartMove(double x, double y)
    {
        if (moving) return;
        moving = true;
        _ = Do(() => client.Move(x, y));
    }

    public void StopMove()
    {
        if (!moving) return;
        moving = false;
        _ = Do(() => client.Stop());
    }

    async Task Do(Func<Task> op)
    {
        try { await op(); errorBox.IsVisible = false; }
        catch (Exception e) { ShowError(e.Message); }
    }

    void ShowError(string msg) { error.Text = msg; errorBox.IsVisible = true; }
}
