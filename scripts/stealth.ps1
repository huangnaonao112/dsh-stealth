# dsh-stealth — Win32 core.
#
# Operates on DeepSeek Harness's own top-level windows inside the current user
# session, with no injection into any other process:
#   - hide/show: ShowWindow(SW_HIDE/SW_SHOW) on every visible top-level window
#     of the target process. With no visible top-level window the app also
#     leaves the Task Manager "Apps" group (it stays as a background process).
#   - toolwindow: adds WS_EX_TOOLWINDOW to visible top-level windows. The
#     windows stay on screen and usable, but the taskbar button and the
#     Alt-Tab entry disappear.
#   - listen: registers a global hotkey and toggles hide/show while running;
#     exits by itself once the target process is gone.
#
# State is one key=value file shared with the Host half (Node):
#   hidden=0|1, windows=<hwnd list>, toolwindow=0|1, styles=<hwnd:exstyle>,
#   hotkey=<spec>, updated=<iso>

param(
    [Parameter(Mandatory = $true)][string]$Action,   # check | hide | show | toggle | toolwindow-on | toolwindow-off | listen
    [string]$ProcessName = 'DeepSeek Harness',
    [string]$StateFile = '',
    [string]$Hotkey = 'Ctrl+Alt+B'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

if ([string]::IsNullOrEmpty($StateFile)) {
    $StateFile = Join-Path $env:USERPROFILE '.dsh\dsh-stealth.state'
}

Add-Type -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing', 'System.Core', 'System') -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace DshStealth
{
    public static class Core
    {
        private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
        private static EnumProc _keptEnumProc;

        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int cmd);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
        [DllImport("user32.dll", EntryPoint = "GetWindowLong")] private static extern int GetWindowLong32(IntPtr hWnd, int index);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")] private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLong")] private static extern int SetWindowLong32(IntPtr hWnd, int index, int value);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")] private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int index, IntPtr value);
        [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        private const int GWL_EXSTYLE = -20;
        private const int WS_EX_TOOLWINDOW = 0x80;
        private const uint GA_ROOT = 2;
        private const int SW_HIDE = 0;
        private const int SW_SHOW = 5;
        private const int SW_SHOWNA = 8;
        private const int SW_RESTORE = 9;

        private static IntPtr GetExStyle(IntPtr hWnd)
        {
            if (IntPtr.Size == 8) return GetWindowLongPtr64(hWnd, GWL_EXSTYLE);
            return (IntPtr)GetWindowLong32(hWnd, GWL_EXSTYLE);
        }

        private static IntPtr SetExStyle(IntPtr hWnd, IntPtr value)
        {
            if (IntPtr.Size == 8) return SetWindowLongPtr64(hWnd, GWL_EXSTYLE, value);
            return (IntPtr)SetWindowLong32(hWnd, GWL_EXSTYLE, (int)value);
        }

        private static string ProcessNameOf(uint pid)
        {
            if (pid == 0) return null;
            try
            {
                Process p = Process.GetProcessById((int)pid);
                if (p == null) return null;
                return p.ProcessName;
            }
            catch { return null; }
        }

        private static bool NameMatches(string name, List<string> names)
        {
            foreach (string n in names)
            {
                if (string.Equals(n, name, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        /// All top-level windows whose owning process matches one of the names.
        private static List<IntPtr> TopWindows(List<string> names, bool visibleOnly)
        {
            List<IntPtr> found = new List<IntPtr>();
            _keptEnumProc = delegate(IntPtr hWnd, IntPtr lParam)
            {
                if (GetAncestor(hWnd, GA_ROOT) != hWnd) return true;
                if (visibleOnly && !IsWindowVisible(hWnd)) return true;
                uint pid;
                GetWindowThreadProcessId(hWnd, out pid);
                string name = ProcessNameOf(pid);
                if (name != null && NameMatches(name, names)) found.Add(hWnd);
                return true;
            };
            EnumWindows(_keptEnumProc, IntPtr.Zero);
            return found;
        }

        public static string Title(IntPtr hWnd)
        {
            StringBuilder sb = new StringBuilder(260);
            GetWindowText(hWnd, sb, 260);
            return sb.ToString();
        }

        private static string Class(IntPtr hWnd)
        {
            StringBuilder sb = new StringBuilder(260);
            GetClassName(hWnd, sb, 260);
            return sb.ToString();
        }

        public static int ProcessCount(List<string> names)
        {
            int count = 0;
            foreach (string n in names)
            {
                try { count += Process.GetProcessesByName(n).Length; } catch {}
            }
            return count;
        }

        public static List<IntPtr> VisibleTops(List<string> names) { return TopWindows(names, true); }

        /// SW_HIDE every visible top-level window; returns the remembered handles.
        public static List<IntPtr> HideAll(List<string> names)
        {
            List<IntPtr> hidden = new List<IntPtr>();
            foreach (IntPtr hWnd in VisibleTops(names))
            {
                ShowWindow(hWnd, SW_HIDE);
                if (!IsWindowVisible(hWnd)) hidden.Add(hWnd);
            }
            return hidden;
        }

        /// Restore remembered handles, falling back to titled main windows.
        public static int ShowAll(List<string> names, List<IntPtr> remembered)
        {
            int shown = 0;
            IntPtr foreground = IntPtr.Zero;
            foreach (IntPtr hWnd in remembered)
            {
                if (!IsWindow(hWnd)) continue;
                ShowWindow(hWnd, IsIconic(hWnd) ? SW_RESTORE : SW_SHOW);
                if (IsWindowVisible(hWnd)) { shown++; if (foreground == IntPtr.Zero) foreground = hWnd; }
            }
            if (shown == 0)
            {
                foreach (IntPtr hWnd in TopWindows(names, false))
                {
                    string cls = Class(hWnd);
                    if (cls != "Chrome_WidgetWin_1") continue;
                    if (Title(hWnd).Length == 0) continue;
                    ShowWindow(hWnd, IsIconic(hWnd) ? SW_RESTORE : SW_SHOW);
                    if (IsWindowVisible(hWnd)) { shown++; if (foreground == IntPtr.Zero) foreground = hWnd; }
                }
            }
            if (foreground != IntPtr.Zero) SetForegroundWindow(foreground);
            return shown;
        }

        /// Add WS_EX_TOOLWINDOW to visible tops; returns "hwnd:oldstyle,..." pairs.
        /// The taskbar re-evaluates the button only when the window visibility
        /// flips, so every changed window is hidden and re-shown right after.
        public static string ApplyToolWindow(List<string> names)
        {
            StringBuilder sb = new StringBuilder();
            foreach (IntPtr hWnd in VisibleTops(names))
            {
                IntPtr old = GetExStyle(hWnd);
                if (((long)old & WS_EX_TOOLWINDOW) != 0) continue;
                SetExStyle(hWnd, (IntPtr)((long)old | WS_EX_TOOLWINDOW));
                ShowWindow(hWnd, SW_HIDE);
                ShowWindow(hWnd, SW_SHOWNA);
                if (sb.Length > 0) sb.Append(',');
                sb.Append(hWnd.ToInt64().ToString()).Append(':').Append(((long)old).ToString());
            }
            return sb.ToString();
        }

        /// Restore the recorded exstyles; returns how many windows were restored.
        public static int RestoreToolWindow(List<KeyValuePair<long, long>> pairs)
        {
            int count = 0;
            foreach (KeyValuePair<long, long> pair in pairs)
            {
                IntPtr hWnd = new IntPtr(pair.Key);
                if (!IsWindow(hWnd)) continue;
                SetExStyle(hWnd, (IntPtr)pair.Value);
                ShowWindow(hWnd, SW_HIDE);
                ShowWindow(hWnd, SW_SHOWNA);
                count++;
            }
            return count;
        }

        public static List<KeyValuePair<long, long>> ParseStyles(string text)
        {
            List<KeyValuePair<long, long>> pairs = new List<KeyValuePair<long, long>>();
            if (string.IsNullOrEmpty(text)) return pairs;
            foreach (string chunk in text.Split(','))
            {
                int colon = chunk.IndexOf(':');
                if (colon <= 0) continue;
                long hwnd, style;
                if (long.TryParse(chunk.Substring(0, colon), out hwnd) && long.TryParse(chunk.Substring(colon + 1), out style))
                {
                    pairs.Add(new KeyValuePair<long, long>(hwnd, style));
                }
            }
            return pairs;
        }

        public static List<IntPtr> ParseHandles(string text)
        {
            List<IntPtr> handles = new List<IntPtr>();
            if (string.IsNullOrEmpty(text)) return handles;
            foreach (string chunk in text.Split(','))
            {
                long value;
                if (long.TryParse(chunk.Trim(), out value) && value != 0) handles.Add(new IntPtr(value));
            }
            return handles;
        }

        public static string ReadStateValue(string stateFile, string key)
        {
            try
            {
                if (!File.Exists(stateFile)) return null;
                foreach (string line in File.ReadAllLines(stateFile))
                {
                    int eq = line.IndexOf('=');
                    if (eq <= 0) continue;
                    if (line.Substring(0, eq) == key) return line.Substring(eq + 1);
                }
            }
            catch {}
            return null;
        }

        public static void WriteState(string stateFile, string hidden, string windows, string toolwindow, string styles, string hotkey)
        {
            try
            {
                string dir = Path.GetDirectoryName(stateFile);
                if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);
                File.WriteAllText(stateFile,
                    "hidden=" + (hidden ?? "0") + "\n" +
                    "windows=" + (windows ?? "") + "\n" +
                    "toolwindow=" + (toolwindow ?? "0") + "\n" +
                    "styles=" + (styles ?? "") + "\n" +
                    "hotkey=" + (hotkey ?? "") + "\n" +
                    "updated=" + DateTime.UtcNow.ToString("o") + "\n");
            }
            catch {}
        }

        /// One master switch: OFF→ON hides everything (half-applied toolwindow
        /// styles are cleared first); ON→OFF restores everything.
        public static string Toggle(List<string> names, string stateFile, string hotkey)
        {
            if ((ReadStateValue(stateFile, "hidden") ?? "0") == "1")
            {
                List<IntPtr> remembered = ParseHandles(ReadStateValue(stateFile, "windows") ?? "");
                int shown = ShowAll(names, remembered);
                WriteState(stateFile, "0", "", "0", "", hotkey);
                return shown > 0 ? "shown" : "shown-nothing";
            }
            if ((ReadStateValue(stateFile, "toolwindow") ?? "0") == "1")
            {
                RestoreToolWindow(ParseStyles(ReadStateValue(stateFile, "styles") ?? ""));
            }
            List<IntPtr> hidden = HideAll(names);
            List<long> ids = new List<long>();
            foreach (IntPtr h in hidden) ids.Add(h.ToInt64());
            WriteState(stateFile, "1", string.Join(",", ids.ToArray()), "0", "", hotkey);
            return "hidden";
        }

        public static bool ToggleToolWindow(List<string> names, string stateFile, string hotkey)
        {
            if ((ReadStateValue(stateFile, "toolwindow") ?? "0") == "1")
            {
                RestoreToolWindow(ParseStyles(ReadStateValue(stateFile, "styles") ?? ""));
                WriteState(stateFile, ReadStateValue(stateFile, "hidden") ?? "0", ReadStateValue(stateFile, "windows") ?? "", "0", "", hotkey);
                return false;
            }
            string styles = ApplyToolWindow(names);
            WriteState(stateFile, ReadStateValue(stateFile, "hidden") ?? "0", ReadStateValue(stateFile, "windows") ?? "", "1", styles, hotkey);
            return true;
        }

        /// Global-hotkey listener. Exits on its own once the process is gone.
        public static int RunListener(string[] names, string stateFile, uint mods, uint vk, string hotkey)
        {
            HotkeyForm form = new HotkeyForm();
            form.ShowInTaskbar = false;
            form.FormBorderStyle = FormBorderStyle.None;
            form.WindowState = FormWindowState.Minimized;
            form.CreateControl();
            IntPtr handle = form.Handle;
            if (!RegisterHotKey(handle, 0xB00B, mods, vk))
            {
                form.Dispose();
                return 3;
            }
            form.HotkeyPress += delegate { Toggle(new List<string>(names), stateFile, hotkey); };
            Timer watch = new Timer();
            watch.Interval = 3000;
            watch.Tick += delegate
            {
                if (ProcessCount(new List<string>(names)) == 0)
                {
                    watch.Stop();
                    form.Close();
                }
            };
            watch.Start();
            Application.Run(form);
            UnregisterHotKey(handle, 0xB00B);
            return 0;
        }
    }

    public class HotkeyForm : Form
    {
        public event Action HotkeyPress;

        protected override void WndProc(ref Message m)
        {
            const int WM_HOTKEY = 0x0312;
            if (m.Msg == WM_HOTKEY)
            {
                if (HotkeyPress != null) HotkeyPress();
                return;
            }
            base.WndProc(ref m);
        }

        protected override void SetVisibleCore(bool value)
        {
            base.SetVisibleCore(false);
        }
    }
}
'@

function Get-Names { param([string]$csv) $list = @(); foreach ($part in $csv.Split(';')) { $t = $part.Trim(); if ($t.Length -gt 0) { $list += $t } }; if ($list.Count -eq 0) { $list = @('DeepSeek Harness') }; return $list }

function Parse-Hotkey {
    param([string]$spec)
    $mods = 0x4000  # MOD_NOREPEAT
    $vk = 0x42      # B
    if (-not [string]::IsNullOrEmpty($spec)) {
        $parts = $spec -split '\+'
        $key = $parts[$parts.Count - 1].Trim()
        foreach ($p in $parts[0..($parts.Count - 2)]) {
            switch -Regex ($p.Trim()) {
                '^(?i)(ctrl|control)$' { $mods = $mods -bor 0x2 }
                '^(?i)alt$'            { $mods = $mods -bor 0x1 }
                '^(?i)shift$'          { $mods = $mods -bor 0x4 }
                '^(?i)(win|meta)$'     { $mods = $mods -bor 0x8 }
            }
        }
        try { $vk = [int][Enum]::Parse([System.Windows.Forms.Keys], $key, $true) } catch { $vk = 0x42 }
    }
    return @{ mods = [uint32]$mods; vk = [uint32]$vk }
}

$names = Get-Names $ProcessName

switch ($Action) {

    'check' {
        $visible = [DshStealth.Core]::VisibleTops($names)
        $windows = @()
        foreach ($h in $visible) {
            $windows += @{ hwnd = $h.ToInt64(); title = [DshStealth.Core]::Title($h); class = '' }
        }
        @{ running = ([DshStealth.Core]::ProcessCount($names) -gt 0)
           visibleWindows = $visible.Count
           hidden = ([DshStealth.Core]::ReadStateValue($StateFile, 'hidden') -eq '1')
           toolwindow = ([DshStealth.Core]::ReadStateValue($StateFile, 'toolwindow') -eq '1')
           windows = $windows } | ConvertTo-Json -Compress -Depth 3
    }

    'hide' {
        if ([DshStealth.Core]::ReadStateValue($StateFile, 'toolwindow') -eq '1') {
            [void][DshStealth.Core]::RestoreToolWindow([DshStealth.Core]::ParseStyles([DshStealth.Core]::ReadStateValue($StateFile, 'styles')))
        }
        $hidden = [DshStealth.Core]::HideAll($names)
        $ids = @(); foreach ($h in $hidden) { $ids += $h.ToInt64() }
        [DshStealth.Core]::WriteState($StateFile, '1', ($ids -join ','), '0', '', $Hotkey)
        @{ action = 'hide'; hiddenCount = $hidden.Count } | ConvertTo-Json -Compress
    }

    'show' {
        $remembered = [DshStealth.Core]::ParseHandles([DshStealth.Core]::ReadStateValue($StateFile, 'windows'))
        $shown = [DshStealth.Core]::ShowAll($names, $remembered)
        $tw = [DshStealth.Core]::ReadStateValue($StateFile, 'toolwindow'); if ($null -eq $tw) { $tw = '0' }
        $st = [DshStealth.Core]::ReadStateValue($StateFile, 'styles');    if ($null -eq $st) { $st = '' }
        [DshStealth.Core]::WriteState($StateFile, '0', '', $tw, $st, $Hotkey)
        @{ action = 'show'; shownCount = $shown } | ConvertTo-Json -Compress
    }

    'toggle' {
        $result = [DshStealth.Core]::Toggle($names, $StateFile, $Hotkey)
        $visible = [DshStealth.Core]::VisibleTops($names)
        @{ action = 'toggle'; result = $result; hidden = ($result -eq 'hidden'); visibleWindows = $visible.Count } | ConvertTo-Json -Compress
    }

    'toolwindow-on' {
        $styles = [DshStealth.Core]::ApplyToolWindow($names)
        $hd = [DshStealth.Core]::ReadStateValue($StateFile, 'hidden');   if ($null -eq $hd) { $hd = '0' }
        $wd = [DshStealth.Core]::ReadStateValue($StateFile, 'windows');  if ($null -eq $wd) { $wd = '' }
        [DshStealth.Core]::WriteState($StateFile, $hd, $wd, '1', $styles, $Hotkey)
        @{ action = 'toolwindow-on'; changed = ($styles.Length -gt 0) } | ConvertTo-Json -Compress
    }

    'toolwindow-off' {
        $count = [DshStealth.Core]::RestoreToolWindow([DshStealth.Core]::ParseStyles([DshStealth.Core]::ReadStateValue($StateFile, 'styles')))
        $hd = [DshStealth.Core]::ReadStateValue($StateFile, 'hidden');   if ($null -eq $hd) { $hd = '0' }
        $wd = [DshStealth.Core]::ReadStateValue($StateFile, 'windows');  if ($null -eq $wd) { $wd = '' }
        [DshStealth.Core]::WriteState($StateFile, $hd, $wd, '0', '', $Hotkey)
        @{ action = 'toolwindow-off'; restored = $count } | ConvertTo-Json -Compress
    }

    'toolwindow-toggle' {
        $on = [DshStealth.Core]::ToggleToolWindow($names, $StateFile, $Hotkey)
        @{ action = 'toolwindow-toggle'; on = $on } | ConvertTo-Json -Compress
    }

    'listen' {
        $hk = Parse-Hotkey $Hotkey
        $namesArray = @($names)
        $exit = [DshStealth.Core]::RunListener($namesArray, $StateFile, $hk.mods, $hk.vk, $Hotkey)
        @{ action = 'listen'; exit = $exit } | ConvertTo-Json -Compress
        exit $exit
    }
}
