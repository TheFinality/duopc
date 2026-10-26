using System.Runtime.InteropServices;

namespace DuoPCStreamer;

/// Injects the phone's pointer and keyboard with SendInput. Keys arrive as X11 keysyms (what the app
/// already uses for VNC). Typed characters go in as Unicode, so they come out right whatever the PC's
/// keyboard layout; while Ctrl, Alt or Windows is held they go in as virtual keys instead, so
/// shortcuts like Ctrl+C work.
public sealed class InputInjector : IDisposable
{
    readonly Log _log;
    // Everything is injected from one thread: switching to the input desktop is per thread.
    readonly System.Collections.Concurrent.BlockingCollection<Action> _queue = new();
    readonly Thread _thread;
    IntPtr _desktop;
    readonly HashSet<ushort> _heldModifiers = new();
    (int Left, int Top, int Width, int Height) _monitor;
    (int Width, int Height) _video = (1, 1);
    int _lastX, _lastY;

    public InputInjector(Log log)
    {
        _log = log;
        _monitor = PrimaryMonitor();
        _thread = new Thread(() => { foreach (var action in _queue.GetConsumingEnumerable()) action(); })
        {
            IsBackground = true,
            Name = "input",
        };
        _thread.Start();
    }

    /// Queues an input action; they run in order on the input thread.
    public void Post(Action action)
    {
        if (!_queue.IsAddingCompleted) _queue.Add(action);
    }

    public void Dispose()
    {
        Post(ReleaseAll);
        _queue.CompleteAdding();
        _thread.Join(TimeSpan.FromSeconds(1));
    }

    /// The video's size, so pointer positions (video pixels) can be mapped onto the monitor.
    public void SetVideoSize(int width, int height)
    {
        _video = (Math.Max(width, 1), Math.Max(height, 1));
        _monitor = PrimaryMonitor();
    }

    public void MovePointer(int x, int y)
    {
        _lastX = x; _lastY = y;
        Send(MouseInput(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, 0, x, y));
    }

    public void Button(byte button, bool down)
    {
        var flags = (button, down) switch
        {
            (1, true) => MOUSEEVENTF_LEFTDOWN, (1, false) => MOUSEEVENTF_LEFTUP,
            (2, true) => MOUSEEVENTF_MIDDLEDOWN, (2, false) => MOUSEEVENTF_MIDDLEUP,
            (3, true) => MOUSEEVENTF_RIGHTDOWN, (3, false) => MOUSEEVENTF_RIGHTUP,
            _ => 0u,
        };
        if (flags == 0) return;
        Send(MouseInput(flags | MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, 0, _lastX, _lastY));
    }

    /// dy > 0 scrolls up (away from the user), as a wheel does; 120 is one notch.
    public void Scroll(int dx, int dy)
    {
        if (dy != 0) Send(MouseInput(MOUSEEVENTF_WHEEL, dy, _lastX, _lastY, absolutePosition: false));
        if (dx != 0) Send(MouseInput(MOUSEEVENTF_HWHEEL, dx, _lastX, _lastY, absolutePosition: false));
    }

    public void Key(uint keysym, bool down)
    {
        if (SpecialKeys.TryGetValue(keysym, out var special))
        {
            if (IsModifier(special.Vk)) { if (down) _heldModifiers.Add(special.Vk); else _heldModifiers.Remove(special.Vk); }
            Send(KeyInput(special.Vk, 0, (special.Extended ? KEYEVENTF_EXTENDEDKEY : 0) | (down ? 0 : KEYEVENTF_KEYUP)));
            return;
        }

        var codePoint = keysym switch
        {
            >= 0x20 and <= 0x7E or >= 0xA0 and <= 0xFF => (int)keysym,
            >= 0x0100_0000 and <= 0x0110_FFFF => (int)(keysym - 0x0100_0000),
            _ => -1,
        };
        if (codePoint < 0) return;

        if (ShortcutHeld && codePoint <= 0xFFFF)
        {
            var scan = VkKeyScanW((char)codePoint);
            if (scan != -1)
            {
                Send(KeyInput((ushort)(scan & 0xFF), 0, down ? 0 : KEYEVENTF_KEYUP));
                return;
            }
        }
        foreach (var unit in char.ConvertFromUtf32(codePoint))
            Send(KeyInput(0, unit, KEYEVENTF_UNICODE | (down ? 0 : KEYEVENTF_KEYUP)));
    }

    /// Types text exactly as given (Unicode), e.g. Paste to PC. Line breaks become Return.
    public void Type(string text)
    {
        foreach (var rune in text.EnumerateRunes())
        {
            if (rune.Value == '\n') { Key(0xFF0D, true); Key(0xFF0D, false); continue; }
            if (rune.Value == '\r') continue;
            if (rune.Value == '\t') { Key(0xFF09, true); Key(0xFF09, false); continue; }
            foreach (var unit in rune.ToString())
            {
                Send(KeyInput(0, unit, KEYEVENTF_UNICODE));
                Send(KeyInput(0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
            }
        }
    }

    /// Lets go of anything still held (the connection ended mid-shortcut).
    public void ReleaseAll()
    {
        foreach (var vk in _heldModifiers.ToList()) Send(KeyInput(vk, 0, KEYEVENTF_KEYUP));
        _heldModifiers.Clear();
    }

    bool ShortcutHeld => _heldModifiers.Any(vk => vk is VK_LCONTROL or VK_RCONTROL or VK_LMENU or VK_RMENU or VK_LWIN or VK_RWIN);

    static bool IsModifier(ushort vk) => vk is VK_LSHIFT or VK_RSHIFT or VK_LCONTROL or VK_RCONTROL or VK_LMENU or VK_RMENU or VK_LWIN or VK_RWIN;

    // MARK: - Sending

    void Send(INPUT input)
    {
        FollowInputDesktop();
        var inputs = new[] { input };
        if (SendInput(1, inputs, Marshal.SizeOf<INPUT>()) != 1)
            _log.Info($"SendInput failed ({Marshal.GetLastWin32Error()})");
    }

    /// The lock screen and admin prompts are on another desktop; input has to be sent from a thread
    /// on whichever desktop is receiving input now (this works when running as SYSTEM).
    void FollowInputDesktop()
    {
        var desktop = OpenInputDesktop(0, false, GENERIC_ALL);
        if (desktop == IntPtr.Zero) return;
        if (SetThreadDesktop(desktop))
        {
            if (_desktop != IntPtr.Zero) CloseDesktop(_desktop);
            _desktop = desktop;
        }
        else CloseDesktop(desktop);
    }

    INPUT MouseInput(uint flags, int data, int x, int y, bool absolutePosition = true)
    {
        var input = new INPUT { type = INPUT_MOUSE };
        input.u.mi.dwFlags = flags;
        input.u.mi.mouseData = data;
        if (absolutePosition)
        {
            // Video pixels → monitor pixels → 0..65535 across the whole virtual desktop.
            var px = _monitor.Left + (long)x * _monitor.Width / _video.Width;
            var py = _monitor.Top + (long)y * _monitor.Height / _video.Height;
            var vx = GetSystemMetrics(SM_XVIRTUALSCREEN); var vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
            var vw = Math.Max(GetSystemMetrics(SM_CXVIRTUALSCREEN) - 1, 1); var vh = Math.Max(GetSystemMetrics(SM_CYVIRTUALSCREEN) - 1, 1);
            input.u.mi.dx = (int)((px - vx) * 65535 / vw);
            input.u.mi.dy = (int)((py - vy) * 65535 / vh);
        }
        return input;
    }

    static INPUT KeyInput(ushort vk, ushort unicode, uint flags)
    {
        var input = new INPUT { type = INPUT_KEYBOARD };
        input.u.ki.wVk = vk;
        input.u.ki.wScan = unicode;
        input.u.ki.dwFlags = flags;
        if (vk != 0 && (flags & KEYEVENTF_UNICODE) == 0) input.u.ki.wScan = (ushort)MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
        return input;
    }

    static (int, int, int, int) PrimaryMonitor()
    {
        var monitor = MonitorFromPoint(new POINT { x = 0, y = 0 }, MONITOR_DEFAULTTOPRIMARY);
        var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        if (!GetMonitorInfoW(monitor, ref info)) return (0, 0, GetSystemMetrics(0), GetSystemMetrics(1));
        var r = info.rcMonitor;
        return (r.left, r.top, r.right - r.left, r.bottom - r.top);
    }

    // X11 keysym → (virtual key, extended).
    static readonly Dictionary<uint, (ushort Vk, bool Extended)> SpecialKeys = new()
    {
        [0xFF08] = (0x08, false), [0xFF09] = (0x09, false), [0xFF0D] = (0x0D, false), [0xFF1B] = (0x1B, false),
        [0xFFFF] = (0x2E, true), [0xFF63] = (0x2D, true), [0xFF50] = (0x24, true), [0xFF57] = (0x23, true),
        [0xFF55] = (0x21, true), [0xFF56] = (0x22, true),
        [0xFF51] = (0x25, true), [0xFF52] = (0x26, true), [0xFF53] = (0x27, true), [0xFF54] = (0x28, true),
        [0xFFE1] = (VK_LSHIFT, false), [0xFFE2] = (VK_RSHIFT, false),
        [0xFFE3] = (VK_LCONTROL, false), [0xFFE4] = (VK_RCONTROL, true),
        [0xFFE9] = (VK_LMENU, false), [0xFFEA] = (VK_RMENU, true), [0xFFE7] = (VK_LWIN, true), [0xFFE8] = (VK_RWIN, true),
        [0xFFEB] = (VK_LWIN, true), [0xFFEC] = (VK_RWIN, true),
        [0xFFE5] = (0x14, false), [0xFF13] = (0x13, false), [0xFF61] = (0x2C, true), [0xFF14] = (0x91, false),
        [0x0020] = (0x20, false),
        [0xFF8D] = (0x0D, true), [0xFFAA] = (0x6A, false), [0xFFAB] = (0x6B, false), [0xFFAD] = (0x6D, false),
        [0xFFAE] = (0x6E, false), [0xFFAF] = (0x6F, true),
        [0xFFBE] = (0x70, false), [0xFFBF] = (0x71, false), [0xFFC0] = (0x72, false), [0xFFC1] = (0x73, false),
        [0xFFC2] = (0x74, false), [0xFFC3] = (0x75, false), [0xFFC4] = (0x76, false), [0xFFC5] = (0x77, false),
        [0xFFC6] = (0x78, false), [0xFFC7] = (0x79, false), [0xFFC8] = (0x7A, false), [0xFFC9] = (0x7B, false),
    };

    // MARK: - Win32

    const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
    const uint MOUSEEVENTF_MOVE = 0x0001, MOUSEEVENTF_LEFTDOWN = 0x0002, MOUSEEVENTF_LEFTUP = 0x0004,
        MOUSEEVENTF_RIGHTDOWN = 0x0008, MOUSEEVENTF_RIGHTUP = 0x0010, MOUSEEVENTF_MIDDLEDOWN = 0x0020,
        MOUSEEVENTF_MIDDLEUP = 0x0040, MOUSEEVENTF_WHEEL = 0x0800, MOUSEEVENTF_HWHEEL = 0x1000,
        MOUSEEVENTF_VIRTUALDESK = 0x4000, MOUSEEVENTF_ABSOLUTE = 0x8000;
    const uint KEYEVENTF_EXTENDEDKEY = 0x0001, KEYEVENTF_KEYUP = 0x0002, KEYEVENTF_UNICODE = 0x0004;
    const ushort VK_LSHIFT = 0xA0, VK_RSHIFT = 0xA1, VK_LCONTROL = 0xA2, VK_RCONTROL = 0xA3, VK_LMENU = 0xA4, VK_RMENU = 0xA5,
        VK_LWIN = 0x5B, VK_RWIN = 0x5C;
    const int SM_XVIRTUALSCREEN = 76, SM_YVIRTUALSCREEN = 77, SM_CXVIRTUALSCREEN = 78, SM_CYVIRTUALSCREEN = 79;
    const uint MAPVK_VK_TO_VSC = 0, MONITOR_DEFAULTTOPRIMARY = 1, GENERIC_ALL = 0x10000000;

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public int mouseData; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public InputUnion u; }

    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern short VkKeyScanW(char ch);
    [DllImport("user32.dll")] static extern uint MapVirtualKeyW(uint code, uint mapType);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfoW(IntPtr monitor, ref MONITORINFO info);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetThreadDesktop(IntPtr desktop);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
}
