using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Avalonia;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;

namespace CamerasTapo;

/// P/Invoke into tcengine (FFmpeg linked in statically).
static class Engine
{
    const string Lib = "tcengine";

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr tce_open(byte[] url, int timeoutSec, IntPtr cancel, byte[] err, int errLen);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int tce_read(IntPtr s, out IntPtr data, out int width, out int height, out int stride,
                                      byte[] err, int errLen);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int tce_hardware(IntPtr s);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void tce_abort(IntPtr s);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void tce_close(IntPtr s);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void tce_set_log_file(byte[] path);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void tce_stats(IntPtr s, byte[] buf, int len);

    public static string LogPath => System.IO.Path.Combine(AppPaths.Dir, "engine.log");

    /// Engine messages go to %APPDATA%\CamerasTapo\engine.log (rewritten at each start).
    public static void StartLog()
    {
        try { tce_set_log_file(Utf8Z(LogPath)); } catch { }
    }

    public static string Stats(IntPtr s)
    {
        var buf = new byte[512];
        tce_stats(s, buf, buf.Length);
        return Message(buf);
    }

    public static byte[] Utf8Z(string s) => Encoding.UTF8.GetBytes(s + "\0");

    public static string Message(byte[] err)
    {
        int n = Array.IndexOf(err, (byte)0);
        return Encoding.UTF8.GetString(err, 0, n < 0 ? err.Length : n);
    }

    /// Opens and immediately closes a stream: used to detect a second lens.
    public static bool CanOpen(string url, int timeoutSec)
    {
        var err = new byte[256];
        var s = tce_open(Utf8Z(url), timeoutSec, IntPtr.Zero, err, err.Length);
        if (s == IntPtr.Zero) return false;
        tce_close(s);
        return true;
    }
}

/// Smooths Wi-Fi bursts: shows frames at a steady pace measured from arrivals.
/// (Tapo timestamps are unreliable, so they are not used.)
class JitterBuffer
{
    const double TargetBacklog = 0.3, MaxBacklog = 1.0;
    double interval = 1.0 / 15;
    double? lastArrival, lastShow;

    public void Reset() { lastArrival = null; lastShow = null; }

    public double Schedule(double now)
    {
        if (lastArrival is double la)
        {
            double gap = Math.Min(now - la, 1.0);
            interval += (gap - interval) * 0.02;
            interval = Math.Clamp(interval, 1.0 / 60, 0.5);
        }
        lastArrival = now;
        if (lastShow is not double last || now - last >= 2) { lastShow = now; return now; }
        double show = last + interval;
        if (show - now > TargetBacklog) show -= interval * 0.15;
        if (show < now) show = now;
        if (show - now > MaxBacklog) show = now + TargetBacklog;
        lastShow = show;
        return show;
    }
}

public enum PlayerState { Connecting, Playing, Failed }

/// One RTSP stream: decodes on a background thread, frames are shown by the shared Presenter.
public sealed class StreamPlayer : IDisposable
{
    sealed class Frame { public byte[] Data = Array.Empty<byte>(); public int W, H, Stride; public double ShowAt; }

    readonly string url;
    readonly string hostKey;
    readonly object gate = new();
    readonly Queue<Frame> queue = new();
    readonly Stack<Frame> pool = new();
    readonly JitterBuffer jitter = new();
    volatile bool running;
    IntPtr current;
    Thread? thread;

    public WriteableBitmap? Bitmap { get; private set; }
    public PlayerState State { get; private set; } = PlayerState.Connecting;
    public string Message { get; private set; } = "";
    public event Action? FrameShown;
    public event Action? StateChanged;

    static readonly Stopwatch Clock = Stopwatch.StartNew();
    static double Now => Clock.Elapsed.TotalSeconds;

    // Tapo refuses simultaneous logins to one camera (both lenses at once): connect one at a time per host.
    static readonly Dictionary<string, object> HostLocks = new();

    // Set to 1 on stop so a connection still being opened gives up immediately.
    readonly IntPtr cancelFlag = Marshal.AllocHGlobal(4);

    /// `lockKey` identifies the camera (its LAN address): logins to one camera are made one at a time.
    public StreamPlayer(string url, string lockKey)
    {
        this.url = url;
        hostKey = lockKey;
        Marshal.WriteInt32(cancelFlag, 0);
    }

    ~StreamPlayer() => Marshal.FreeHGlobal(cancelFlag);

    public void Start()
    {
        if (running) return;
        running = true;
        Marshal.WriteInt32(cancelFlag, 0);
        Presenter.Add(this);
        thread = new Thread(Loop) { IsBackground = true, Name = "rtsp" };
        thread.Start();
    }

    public void Stop()
    {
        running = false;
        Marshal.WriteInt32(cancelFlag, 1);
        Presenter.Remove(this);
        lock (gate) { if (current != IntPtr.Zero) Engine.tce_abort(current); }
    }

    public void Dispose() => Stop();

    void SetState(PlayerState s, string msg = "")
    {
        Dispatcher.UIThread.Post(() =>
        {
            if (State == s && Message == msg) return;
            State = s; Message = msg;
            StateChanged?.Invoke();
        });
    }

    void Loop()
    {
        var err = new byte[512];
        double retry = 1;
        while (running)
        {
            SetState(PlayerState.Connecting);
            object hostLock;
            lock (HostLocks) { if (!HostLocks.TryGetValue(hostKey, out hostLock!)) HostLocks[hostKey] = hostLock = new object(); }
            IntPtr s;
            lock (hostLock) s = running ? Engine.tce_open(Engine.Utf8Z(url), 10, cancelFlag, err, err.Length) : IntPtr.Zero;
            if (!running) break;
            if (s == IntPtr.Zero)
            {
                SetState(PlayerState.Failed, Engine.Message(err));
                SleepWhileRunning(retry);
                retry = Math.Min(retry * 2, 15);
                continue;
            }
            lock (gate) { current = s; if (!running) Engine.tce_abort(s); }
            SetState(PlayerState.Connecting, "Conectado, aguardando imagem…");
            jitter.Reset();
            bool gotFrame = false;
            bool stuck = false;
            // Watchdog: connected but no image for 20 s → reconnect instead of waiting forever.
            using var watchdog = new Timer(_ =>
            {
                if (Volatile.Read(ref gotFrame)) return;
                stuck = true;
                Engine.tce_abort(s);
            }, null, 20000, Timeout.Infinite);
            while (running)
            {
                int r = Engine.tce_read(s, out var data, out int w, out int h, out int stride, err, err.Length);
                if (r < 0) break;
                if (r == 0 || data == IntPtr.Zero) continue;
                if (!gotFrame) { Volatile.Write(ref gotFrame, true); retry = 1; SetState(PlayerState.Playing); }
                Enqueue(data, w, h, stride);
            }
            watchdog.Change(Timeout.Infinite, Timeout.Infinite);
            lock (gate) current = IntPtr.Zero;
            Engine.tce_close(s);
            if (running)
            {
                SetState(PlayerState.Failed, stuck
                    ? "Conectou, mas nenhuma imagem em 20 s. Detalhes em engine.log (rode --diagnostico)."
                    : Engine.Message(err));
                SleepWhileRunning(retry);
                retry = Math.Min(retry * 2, 15);
            }
        }
    }

    void SleepWhileRunning(double seconds)
    {
        var end = Now + seconds;
        while (running && Now < end) Thread.Sleep(100);
    }

    void Enqueue(IntPtr data, int w, int h, int stride)
    {
        Frame f;
        lock (gate) f = pool.Count > 0 ? pool.Pop() : new Frame();
        int size = stride * h;
        if (f.Data.Length != size) f.Data = new byte[size];
        Marshal.Copy(data, f.Data, 0, size);
        f.W = w; f.H = h; f.Stride = stride;
        f.ShowAt = jitter.Schedule(Now);
        lock (gate)
        {
            queue.Enqueue(f);
            while (queue.Count > 30) pool.Push(queue.Dequeue()); // never pile up more than ~2s
        }
    }

    /// Called on the UI thread by the Presenter: shows the newest frame that is due.
    internal void Present()
    {
        Frame? due = null;
        double now = Now;
        lock (gate)
        {
            while (queue.Count > 0 && queue.Peek().ShowAt <= now)
            {
                if (due != null) pool.Push(due);
                due = queue.Dequeue();
            }
        }
        if (due == null) return;

        if (Bitmap == null || Bitmap.PixelSize.Width != due.W || Bitmap.PixelSize.Height != due.H)
            Bitmap = new WriteableBitmap(new PixelSize(due.W, due.H), new Vector(96, 96), PixelFormat.Bgra8888, AlphaFormat.Opaque);
        using (var fb = Bitmap.Lock())
        {
            int row = due.W * 4;
            for (int y = 0; y < due.H; y++)
                Marshal.Copy(due.Data, y * due.Stride, fb.Address + y * fb.RowBytes, row);
        }
        lock (gate) pool.Push(due);
        FrameShown?.Invoke();
    }
}

/// One UI timer that hands due frames to every visible player.
static class Presenter
{
    static readonly List<StreamPlayer> Players = new();
    static DispatcherTimer? timer;

    public static void Add(StreamPlayer p)
    {
        Dispatcher.UIThread.VerifyAccess();
        if (!Players.Contains(p)) Players.Add(p);
        if (timer == null)
        {
            timer = new DispatcherTimer(TimeSpan.FromMilliseconds(8), DispatcherPriority.Render, (_, _) =>
            {
                foreach (var player in Players.ToArray()) player.Present();
            });
            timer.Start();
        }
    }

    public static void Remove(StreamPlayer p)
    {
        Dispatcher.UIThread.Post(() => Players.Remove(p));
    }
}
