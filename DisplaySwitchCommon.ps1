#Requires -Version 5.1
<#
.SYNOPSIS
  Shared helpers: attach/detach specific monitors and accept Windows display prompts.
#>

if (-not ('MonitorSwap' -as [type])) {
    Add-Type -ReferencedAssemblies System.Core -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class MonitorSwap {
  const int ENUM_CURRENT_SETTINGS = -1;
  const int CDS_UPDATEREGISTRY = 0x01;
  const int CDS_SET_PRIMARY = 0x10;
  const int CDS_NORESET = 0x10000000;
  const int DM_POSITION = 0x20;
  const int DM_PELSWIDTH = 0x80000;
  const int DM_PELSHEIGHT = 0x100000;
  const int DM_DISPLAYFREQUENCY = 0x400000;
  const int DM_BITSPERPEL = 0x40000;

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels;
    public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType;
    public int dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
  public struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
  }

  [DllImport("user32.dll", CharSet = CharSet.Ansi)]
  static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);
  [DllImport("user32.dll", CharSet = CharSet.Ansi)]
  static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
  [DllImport("user32.dll", CharSet = CharSet.Ansi)]
  static extern int ChangeDisplaySettingsEx(string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, int dwflags, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Ansi)]
  static extern int ChangeDisplaySettingsEx(string lpszDeviceName, IntPtr lpDevMode, IntPtr hwnd, int dwflags, IntPtr lParam);

  public class MonitorRef {
    public string DeviceName;
    public string FriendlyName;
    public string DeviceId;
    public bool Attached;
    public bool Primary;
    public uint MonitorIndex;
    public bool HasPreferredMode;
    public bool IsCurrentPreferred;
    public int CurrentWidth;
    public int CurrentHeight;
  }

  static bool SupportsMode(string deviceName, int preferW, int preferH) {
    if (preferW <= 0) return true;
    for (int i = 0; ; i++) {
      var dm = new DEVMODE();
      dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
      if (!EnumDisplaySettings(deviceName, i, ref dm)) break;
      if (dm.dmPelsWidth == preferW && dm.dmPelsHeight == preferH) return true;
    }
    return false;
  }

  static void FillModeInfo(MonitorRef mon, int preferW, int preferH) {
    var cur = new DEVMODE();
    cur.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (EnumDisplaySettings(mon.DeviceName, ENUM_CURRENT_SETTINGS, ref cur)) {
      mon.CurrentWidth = cur.dmPelsWidth;
      mon.CurrentHeight = cur.dmPelsHeight;
      mon.IsCurrentPreferred = preferW > 0 && cur.dmPelsWidth == preferW && cur.dmPelsHeight == preferH;
    }
    mon.HasPreferredMode = SupportsMode(mon.DeviceName, preferW, preferH);
  }

  public static List<MonitorRef> ListMonitors() {
    return ListMonitors(0, 0);
  }

  public static List<MonitorRef> ListMonitors(int preferW, int preferH) {
    var list = new List<MonitorRef>();
    var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    for (uint i = 0; i < 16; i++) {
      var dd = new DISPLAY_DEVICE();
      dd.cb = Marshal.SizeOf(dd);
      if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
      bool attached = (dd.StateFlags & 1) != 0;
      bool primary = (dd.StateFlags & 4) != 0;

      for (uint mi = 0; mi < 8; mi++) {
        var mon = new DISPLAY_DEVICE();
        mon.cb = Marshal.SizeOf(mon);
        if (!EnumDisplayDevices(dd.DeviceName, mi, ref mon, 0)) break;
        if (string.IsNullOrEmpty(mon.DeviceID) && string.IsNullOrEmpty(mon.DeviceString)) continue;

        // One row per adapter+monitor-id. Inactive paths often copy the
        // active monitor's name onto mon0, so keep every real DeviceID.
        string key = dd.DeviceName + "|" + (mon.DeviceID ?? "") + "|" + mi;
        if (!seen.Add(key)) continue;

        var row = new MonitorRef {
          DeviceName = dd.DeviceName,
          FriendlyName = mon.DeviceString,
          DeviceId = mon.DeviceID,
          Attached = attached,
          Primary = primary,
          MonitorIndex = mi
        };
        FillModeInfo(row, preferW, preferH);
        list.Add(row);
      }
    }
    return list;
  }

  static bool Matches(MonitorRef mon, string match) {
    string m = match.ToUpperInvariant();
    string hay = ((mon.FriendlyName ?? "") + " " + (mon.DeviceId ?? "") + " " + (mon.DeviceName ?? "")).ToUpperInvariant();
    return hay.IndexOf(m) >= 0;
  }

  static MonitorRef FindBest(string match, int preferW, int preferH) {
    MonitorRef best = null;
    long bestScore = long.MinValue;
    foreach (var mon in ListMonitors(preferW, preferH)) {
      if (!Matches(mon, match)) continue;
      long score = 0;
      if (mon.HasPreferredMode) score += 1000;
      if (mon.IsCurrentPreferred) score += 800;
      // Attached-but-wrong-resolution is usually the other screen after Xbox mode
      // relabels every path with the same EDID.
      if (preferW > 0 && mon.Attached && !mon.IsCurrentPreferred) score -= 600;
      if (!mon.Attached && mon.HasPreferredMode) score += 300;
      if (mon.Attached && mon.HasPreferredMode) score += 100;
      if (mon.Primary && mon.IsCurrentPreferred) score += 100;
      if (mon.MonitorIndex == 0 && mon.HasPreferredMode) score += 520;
      if (mon.MonitorIndex > 0) score -= 400; // secondary EDID on another screen's path
      score -= mon.MonitorIndex;
      if (score > bestScore) { bestScore = score; best = mon; }
    }

    // Xbox mode / driver glitches sometimes relabel every path as the PC
    // monitor. Fall back to "whichever path can do this resolution".
    if (best == null || (preferW > 0 && !best.HasPreferredMode)) {
      best = null;
      bestScore = long.MinValue;
      foreach (var mon in ListMonitors(preferW, preferH)) {
        if (!mon.HasPreferredMode) continue;
        long score = 500;
        if (mon.IsCurrentPreferred) score += 800;
        if (preferW > 0 && mon.Attached && !mon.IsCurrentPreferred) score -= 600;
        if (!mon.Attached) score += 300;
        if (Matches(mon, match)) score += 200;
        score -= mon.MonitorIndex;
        if (score > bestScore) { bestScore = score; best = mon; }
      }
    }
    return best;
  }

  static DEVMODE PickMode(string deviceName, int preferW, int preferH) {
    var best = new DEVMODE();
    best.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));

    var cur = new DEVMODE();
    cur.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (EnumDisplaySettings(deviceName, ENUM_CURRENT_SETTINGS, ref cur)) {
      if (preferW <= 0 || (cur.dmPelsWidth == preferW && cur.dmPelsHeight == preferH))
        return cur;
      best = cur;
    }

    long bestScore = -1;
    bool found = false;
    DEVMODE bestPreferred = best;
    long bestPreferredScore = -1;
    for (int i = 0; ; i++) {
      var dm = new DEVMODE();
      dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
      if (!EnumDisplaySettings(deviceName, i, ref dm)) break;
      if (dm.dmBitsPerPel < 32) continue;
      found = true;
      long score = (long)dm.dmPelsWidth * dm.dmPelsHeight * 1000L + dm.dmDisplayFrequency;
      if (score > bestScore) { bestScore = score; best = dm; }
      if (preferW > 0 && dm.dmPelsWidth == preferW && dm.dmPelsHeight == preferH) {
        long pScore = dm.dmDisplayFrequency;
        if (pScore > bestPreferredScore) { bestPreferredScore = pScore; bestPreferred = dm; }
      }
    }
    if (bestPreferredScore >= 0) return bestPreferred;
    if (!found) {
      best.dmBitsPerPel = 32;
      best.dmPelsWidth = preferW > 0 ? preferW : 1920;
      best.dmPelsHeight = preferH > 0 ? preferH : 1080;
      best.dmDisplayFrequency = 60;
    }
    return best;
  }

  static int Enable(string deviceName, int x, int y, int preferW, int preferH, bool primary) {
    var mode = PickMode(deviceName, preferW, preferH);
    mode.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT | DM_BITSPERPEL | DM_DISPLAYFREQUENCY;
    mode.dmPositionX = x;
    mode.dmPositionY = y;
    int flags = CDS_UPDATEREGISTRY | CDS_NORESET;
    if (primary) flags |= CDS_SET_PRIMARY;
    return ChangeDisplaySettingsEx(deviceName, ref mode, IntPtr.Zero, flags, IntPtr.Zero);
  }

  static int Disable(string deviceName) {
    var dm = new DEVMODE();
    dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    EnumDisplaySettings(deviceName, ENUM_CURRENT_SETTINGS, ref dm);
    dm.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT;
    dm.dmPelsWidth = 0;
    dm.dmPelsHeight = 0;
    dm.dmPositionX = 0;
    dm.dmPositionY = 0;
    return ChangeDisplaySettingsEx(deviceName, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY | CDS_NORESET, IntPtr.Zero);
  }

  static int Apply() {
    return ChangeDisplaySettingsEx(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
  }

  static List<string> AttachedDeviceNames() {
    var names = new List<string>();
    var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    for (uint i = 0; i < 16; i++) {
      var dd = new DISPLAY_DEVICE();
      dd.cb = Marshal.SizeOf(dd);
      if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
      if ((dd.StateFlags & 1) == 0) continue;
      if (seen.Add(dd.DeviceName)) names.Add(dd.DeviceName);
    }
    return names;
  }

  /// <summary>
  /// Turn on only the monitor matching a DeviceId fragment from config
  /// (see List-Displays.ps1). preferW/preferH ignore stale EDID copies after
  /// Xbox mode. extraDisable is an optional path to detach (last TV path).
  /// </summary>
  public static string SwitchToOnly(string match, int preferW, int preferH) {
    return SwitchToOnly(match, preferW, preferH, null);
  }

  public static string SwitchToOnly(string match, int preferW, int preferH, string extraDisable) {
    var keep = FindBest(match, preferW, preferH);
    if (keep == null)
      return "ERROR: monitor not found matching '" + match + "'. Is the display powered on and on the right input?";

    var log = new StringBuilder();
    log.AppendLine("Target: " + keep.FriendlyName + " (" + keep.DeviceName + " / " + keep.DeviceId
      + " mon#" + keep.MonitorIndex + " hasMode=" + keep.HasPreferredMode
      + " cur=" + keep.CurrentWidth + "x" + keep.CurrentHeight + ")");

    if (preferW > 0 && !keep.HasPreferredMode) {
      log.AppendLine("WARNING: target path does not advertise " + preferW + "x" + preferH + ".");
    }

    var disable = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    foreach (var name in AttachedDeviceNames()) {
      if (!string.Equals(name, keep.DeviceName, StringComparison.OrdinalIgnoreCase))
        disable.Add(name);
    }
    if (!string.IsNullOrEmpty(extraDisable)
        && !string.Equals(extraDisable, keep.DeviceName, StringComparison.OrdinalIgnoreCase)) {
      disable.Add(extraDisable);
    }

    int rKeep = Enable(keep.DeviceName, 0, 0, preferW, preferH, true);
    log.AppendLine("Enable target rc=" + rKeep);

    foreach (var name in disable) {
      int r = Disable(name);
      log.AppendLine("Disable " + name + " rc=" + r);
    }

    int rApply = Apply();
    log.AppendLine("Apply rc=" + rApply);

    // Second pass: if primary still is not our preferred resolution, try every
    // other path that can do it (Xbox mode often leaves the wrong path active).
    var after = ListMonitors(preferW, preferH);
    bool resolutionOk = preferW <= 0;
    foreach (var mon in after) {
      if (mon.Attached && mon.Primary && mon.IsCurrentPreferred) resolutionOk = true;
    }
    if (!resolutionOk && preferW > 0) {
      log.AppendLine("Primary is not " + preferW + "x" + preferH + "; trying alternate paths...");
      foreach (var cand in ListMonitors(preferW, preferH)) {
        if (!cand.HasPreferredMode) continue;
        if (string.Equals(cand.DeviceName, keep.DeviceName, StringComparison.OrdinalIgnoreCase)) continue;
        int rAlt = Enable(cand.DeviceName, 0, 0, preferW, preferH, true);
        log.AppendLine("Alt enable " + cand.DeviceName + " (" + cand.DeviceId + ") rc=" + rAlt);
        foreach (var name in AttachedDeviceNames()) {
          if (string.Equals(name, cand.DeviceName, StringComparison.OrdinalIgnoreCase)) continue;
          int r = Disable(name);
          log.AppendLine("Disable " + name + " rc=" + r);
        }
        rApply = Apply();
        log.AppendLine("Alt apply rc=" + rApply);
        keep = cand;
        break;
      }
    }

    bool ok = false;
    foreach (var mon in ListMonitors(preferW, preferH)) {
      log.AppendLine("Now: " + mon.DeviceName + " attached=" + mon.Attached + " primary=" + mon.Primary
        + " " + mon.FriendlyName + " id=" + mon.DeviceId + " cur=" + mon.CurrentWidth + "x" + mon.CurrentHeight);
      if (mon.DeviceName == keep.DeviceName && mon.Attached && mon.Primary) ok = true;
      if (preferW > 0 && mon.Attached && mon.Primary && mon.IsCurrentPreferred) ok = true;
    }
    if (!ok) log.AppendLine("WARNING: target does not look primary/attached yet (accept Keep changes if prompted).");
    return log.ToString();
  }
}
'@
}


function Write-SwitchLog([string]$Message) {
    $log = Join-Path $PSScriptRoot 'display-switch.log'
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $log -Value $line
    Write-Host $Message
}

function Get-DisplaySwitchConfig {
    $configPath = Join-Path $PSScriptRoot 'display-switch.config.ps1'
    $examplePath = Join-Path $PSScriptRoot 'display-switch.config.example.ps1'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw @"
Missing display-switch.config.ps1.

Copy the example and edit your display ids:
  Copy-Item '$examplePath' '$configPath'
  powershell -NoProfile -ExecutionPolicy Bypass -File '$PSScriptRoot\List-Displays.ps1'
"@
    }

    $cfg = & $configPath
    $required = @(
        'MonitorMatch', 'MonitorWidth', 'MonitorHeight', 'MonitorLabel',
        'TvMatch', 'TvWidth', 'TvHeight', 'TvLabel'
    )
    foreach ($key in $required) {
        if ($null -eq $cfg[$key] -or [string]::IsNullOrWhiteSpace([string]$cfg[$key])) {
            throw "display-switch.config.ps1 is missing '$key'."
        }
    }
    foreach ($pair in @(
        @{ Key = 'MonitorMatch'; Bad = @('MONITOR_ID', 'PUT_MONITOR_ID_HERE') },
        @{ Key = 'TvMatch'; Bad = @('TV_ID', 'PUT_TV_ID_HERE') }
    )) {
        if ($pair.Bad -contains [string]$cfg[$pair.Key]) {
            throw "display-switch.config.ps1 still has placeholder $($pair.Key). Run List-Displays.ps1 and set your id."
        }
    }

    if (-not $cfg.ContainsKey('TvMode') -or [string]::IsNullOrWhiteSpace([string]$cfg.TvMode)) {
        $cfg.TvMode = 'Xbox'
    }
    $mode = [string]$cfg.TvMode
    if ($mode -notin @('Xbox', 'BigPicture')) {
        throw "display-switch.config.ps1 TvMode must be 'Xbox' or 'BigPicture' (got '$mode')."
    }
    $cfg.TvMode = $mode

    # ModeDelaySeconds preferred; XboxDelaySeconds kept as a fallback alias.
    if ($cfg.ContainsKey('ModeDelaySeconds') -and $null -ne $cfg.ModeDelaySeconds) {
        # keep as-is
    }
    elseif ($cfg.ContainsKey('XboxDelaySeconds') -and $null -ne $cfg.XboxDelaySeconds) {
        $cfg.ModeDelaySeconds = $cfg.XboxDelaySeconds
    }
    else {
        $cfg.ModeDelaySeconds = 1
    }
    return $cfg
}

function Get-TvShellModePath {
    Join-Path $PSScriptRoot '.tv-mode'
}

function Save-TvShellMode([string]$Mode) {
    Set-Content -LiteralPath (Get-TvShellModePath) -Value $Mode -Encoding ascii
}

function Get-SavedTvShellMode {
    $path = Get-TvShellModePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $mode = (Get-Content -LiteralPath $path -Raw).Trim()
    if ($mode -in @('Xbox', 'BigPicture')) { return $mode }
    return $null
}

function Clear-TvShellMode {
    Remove-Item -LiteralPath (Get-TvShellModePath) -Force -ErrorAction SilentlyContinue
}

function Get-SteamPath {
    $fromReg = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamExe
    if ($fromReg -and (Test-Path -LiteralPath $fromReg)) {
        return (Resolve-Path -LiteralPath $fromReg).Path
    }
    foreach ($path in @(
        "${env:ProgramFiles(x86)}\Steam\steam.exe",
        "$env:ProgramFiles\Steam\steam.exe"
    )) {
        if (Test-Path -LiteralPath $path) { return $path }
    }
    throw 'Steam not found. Install Steam or set TvMode to Xbox in display-switch.config.ps1.'
}

function Enter-SteamBigPicture {
    $steam = Get-SteamPath
    Write-SwitchLog "Opening Steam Big Picture via $steam"
    [XboxModeNative]::MinimizeConsole()

    # steam:// works whether Steam is already running or not; -bigpicture alone often no-ops if Steam is open
    Start-Process -FilePath $steam -ArgumentList @('steam://open/bigpicture')

    Start-Sleep -Milliseconds 800
    $steamProcs = @(Get-Process -Name 'steam' -ErrorAction SilentlyContinue)
    if ($steamProcs.Count -eq 0) {
        Write-SwitchLog 'Steam not running yet; launching with -bigpicture'
        Start-Process -FilePath $steam -ArgumentList '-bigpicture'
    }
}

function Exit-SteamBigPicture {
    Write-SwitchLog 'Closing Steam Big Picture...'
    try {
        $steam = Get-SteamPath
        Start-Process -FilePath $steam -ArgumentList @('steam://close/bigpicture') -ErrorAction SilentlyContinue
    }
    catch {
        Write-SwitchLog "Could not reach Steam to close Big Picture ($($_.Exception.Message))."
    }
    Start-Sleep -Milliseconds 600
}

function Enter-TvShell {
    param([Parameter(Mandatory)][ValidateSet('Xbox', 'BigPicture')][string]$Mode)

    switch ($Mode) {
        'Xbox' { Enter-XboxMode }
        'BigPicture' { Enter-SteamBigPicture }
    }
    Save-TvShellMode $Mode
}

function Exit-TvShell {
    param(
        [int]$TvWidth = 0,
        [int]$TvHeight = 0
    )

    $mode = Get-SavedTvShellMode
    if (-not $mode) {
        try { $mode = (Get-DisplaySwitchConfig).TvMode } catch { $mode = 'Xbox' }
    }

    switch ($mode) {
        'Xbox' { Exit-XboxMode -TvWidth $TvWidth -TvHeight $TvHeight }
        'BigPicture' { Exit-SteamBigPicture }
        default { Exit-XboxMode -TvWidth $TvWidth -TvHeight $TvHeight }
    }
    Clear-TvShellMode
}

function Accept-DisplayChangePrompt {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    if (-not ('DisplayPromptHelper2' -as [type])) {
        Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class DisplayPromptHelper2 {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern int GetClassName(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr hDlg, int nIDDlgItem);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr FindWindowEx(IntPtr hwndParent, IntPtr hwndChildAfter, string lpszClass, string lpszWindow);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
  public const int SW_RESTORE = 9;
  public const uint BM_CLICK = 0x00F5;
  public const int IDYES = 6;
}
"@
    }

    # CDS usually applies with no dialog; only wait briefly
    $deadline = (Get-Date).AddSeconds(2)
    $accepted = $false
    while ((Get-Date) -lt $deadline) {
        $script:PromptWindows = New-Object System.Collections.Generic.List[IntPtr]
        $callback = [DisplayPromptHelper2+EnumWindowsProc] {
            param([IntPtr]$hWnd, [IntPtr]$lParam)
            if (-not [DisplayPromptHelper2]::IsWindowVisible($hWnd)) { return $true }
            $title = New-Object System.Text.StringBuilder 256
            $cls = New-Object System.Text.StringBuilder 256
            [void][DisplayPromptHelper2]::GetWindowText($hWnd, $title, $title.Capacity)
            [void][DisplayPromptHelper2]::GetClassName($hWnd, $cls, $cls.Capacity)
            $t = $title.ToString()
            $c = $cls.ToString()
            if ($t -match 'Display settings|Display Settings|Keep changes|Keep these display' -or
                ($c -eq '#32770' -and $t -match 'Display')) {
                $script:PromptWindows.Add($hWnd)
            }
            return $true
        }
        [DisplayPromptHelper2]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null

        foreach ($hwnd in $script:PromptWindows) {
            [DisplayPromptHelper2]::ShowWindow($hwnd, [DisplayPromptHelper2]::SW_RESTORE) | Out-Null
            [DisplayPromptHelper2]::SetForegroundWindow($hwnd) | Out-Null
            Start-Sleep -Milliseconds 150

            # Prefer clicking a "Keep changes" button if present
            $btn = [DisplayPromptHelper2]::FindWindowEx($hwnd, [IntPtr]::Zero, 'Button', 'Keep changes')
            if ($btn -eq [IntPtr]::Zero) {
                $btn = [DisplayPromptHelper2]::FindWindowEx($hwnd, [IntPtr]::Zero, 'Button', '&Keep changes')
            }
            if ($btn -ne [IntPtr]::Zero) {
                [DisplayPromptHelper2]::PostMessage($btn, [DisplayPromptHelper2]::BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            }
            else {
                # Default button is usually Keep changes
                [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
            }
            $accepted = $true
            Write-SwitchLog 'Accepted display change prompt.'
        }

        if ($accepted) { return }
        Start-Sleep -Milliseconds 400
    }
}

if (-not ('XboxModeNative' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class XboxModeNative {
  delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT pt, uint dwFlags);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);
  [DllImport("user32.dll")] static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
  [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();

  const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
  const uint KEYEVENTF_KEYUP = 0x0002;
  const byte VK_LWIN = 0x5B;
  const byte VK_F11 = 0x7A;
  const byte VK_MENU = 0x12;
  const byte VK_RETURN = 0x0D;
  const int SW_MINIMIZE = 6;
  const int SW_RESTORE = 9;
  const uint SWP_SHOWWINDOW = 0x0040;
  const int TOLERANCE = 16;

  [StructLayout(LayoutKind.Sequential)]
  struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)]
  struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct MONITORINFO {
    public int cbSize;
    public RECT rcMonitor;
    public RECT rcWork;
    public int dwFlags;
  }

  static EnumProc _enumKeepAlive;
  static IntPtr _xboxHwnd;
  static int _xboxArea;
  static bool _covers;
  static IntPtr _dialogHwnd;
  static bool _dialogEntering;

  static bool IsXboxTitle(string title) {
    if (string.IsNullOrEmpty(title)) return false;
    return string.Equals(title.Trim(), "Xbox", StringComparison.OrdinalIgnoreCase)
        || string.Equals(title.Trim(), "Xbox mode", StringComparison.OrdinalIgnoreCase);
  }

  static RECT PrimaryRect() {
    IntPtr mon = MonitorFromPoint(new POINT(), 1); // MONITOR_DEFAULTTOPRIMARY
    MONITORINFO mi = new MONITORINFO();
    mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
    if (mon == IntPtr.Zero || !GetMonitorInfo(mon, ref mi)) {
      RECT fallback = new RECT();
      fallback.Right = 1920;
      fallback.Bottom = 1080;
      return fallback;
    }
    return mi.rcMonitor;
  }

  static bool Covers(RECT window, RECT monitor) {
    return window.Left <= monitor.Left + TOLERANCE
        && window.Top <= monitor.Top + TOLERANCE
        && window.Right >= monitor.Right - TOLERANCE
        && window.Bottom >= monitor.Bottom - TOLERANCE;
  }

  static bool OnXboxWindow(IntPtr hWnd, IntPtr lParam) {
    if (!IsWindowVisible(hWnd)) return true;
    StringBuilder sb = new StringBuilder(512);
    GetWindowText(hWnd, sb, sb.Capacity);
    if (!IsXboxTitle(sb.ToString())) return true;
    RECT rect;
    if (!GetWindowRect(hWnd, out rect)) return true;
    int area = Math.Max(0, rect.Right - rect.Left) * Math.Max(0, rect.Bottom - rect.Top);
    if (_xboxHwnd == IntPtr.Zero || area > _xboxArea) {
      _xboxHwnd = hWnd;
      _xboxArea = area;
    }
    if (Covers(rect, PrimaryRect())) _covers = true;
    return true;
  }

  static void ScanXboxWindows() {
    _xboxHwnd = IntPtr.Zero;
    _xboxArea = 0;
    _covers = false;
    _enumKeepAlive = OnXboxWindow;
    EnumWindows(_enumKeepAlive, IntPtr.Zero);
  }

  public static bool XboxCoversPrimary() {
    ScanXboxWindows();
    return _covers;
  }

  public static string DescribeXboxWindow() {
    ScanXboxWindows();
    if (_xboxHwnd == IntPtr.Zero) return "no Xbox window";
    RECT rect;
    if (!GetWindowRect(_xboxHwnd, out rect)) return "Xbox window (no rect)";
    RECT primary = PrimaryRect();
    return "Xbox window " + (rect.Right - rect.Left) + "x" + (rect.Bottom - rect.Top)
        + " at " + rect.Left + "," + rect.Top
        + "; primary " + (primary.Right - primary.Left) + "x" + (primary.Bottom - primary.Top)
        + " covers=" + _covers;
  }

  public static bool PlaceXboxOnPrimary() {
    ScanXboxWindows();
    if (_xboxHwnd == IntPtr.Zero) return false;
    RECT primary = PrimaryRect();
    RECT rect;
    if (!GetWindowRect(_xboxHwnd, out rect)) return false;
    int w = Math.Max(1, rect.Right - rect.Left);
    int h = Math.Max(1, rect.Bottom - rect.Top);
    int pw = Math.Max(1, primary.Right - primary.Left);
    int ph = Math.Max(1, primary.Bottom - primary.Top);
    if (w > pw) w = pw;
    if (h > ph) h = ph;
    bool inside = rect.Left >= primary.Left && rect.Top >= primary.Top
        && rect.Right <= primary.Right && rect.Bottom <= primary.Bottom;
    int x = inside ? rect.Left : primary.Left + Math.Max(0, (pw - w) / 2);
    int y = inside ? rect.Top : primary.Top + Math.Max(0, (ph - h) / 2);
    ShowWindow(_xboxHwnd, SW_RESTORE);
    SetWindowPos(_xboxHwnd, IntPtr.Zero, x, y, w, h, SWP_SHOWWINDOW);
    keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
    SetForegroundWindow(_xboxHwnd);
    keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    return true;
  }

  static bool OnDialog(IntPtr hWnd, IntPtr lParam) {
    if (_dialogHwnd != IntPtr.Zero) return false;
    if (!IsWindowVisible(hWnd)) return true;
    StringBuilder sb = new StringBuilder(512);
    GetWindowText(hWnd, sb, sb.Capacity);
    string title = sb.ToString();
    if (string.IsNullOrEmpty(title)) return true;
    bool match = _dialogEntering
        ? title.IndexOf("Switching to Xbox", StringComparison.OrdinalIgnoreCase) >= 0
        : (title.IndexOf("Switching to Windows", StringComparison.OrdinalIgnoreCase) >= 0
            || title.IndexOf("Windows desktop", StringComparison.OrdinalIgnoreCase) >= 0);
    if (!match) return true;
    _dialogHwnd = hWnd;
    return false;
  }

  public static IntPtr FindModeDialog(bool entering) {
    _dialogHwnd = IntPtr.Zero;
    _dialogEntering = entering;
    _enumKeepAlive = OnDialog;
    EnumWindows(_enumKeepAlive, IntPtr.Zero);
    return _dialogHwnd;
  }

  public static void PressEnterOn(IntPtr hWnd) {
    if (hWnd == IntPtr.Zero) return;
    ShowWindow(hWnd, SW_RESTORE);
    SetForegroundWindow(hWnd);
    Thread.Sleep(120);
    keybd_event(VK_RETURN, 0, 0, UIntPtr.Zero);
    Thread.Sleep(40);
    keybd_event(VK_RETURN, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
  }

  public static void MinimizeConsole() {
    IntPtr console = GetConsoleWindow();
    if (console != IntPtr.Zero) ShowWindow(console, SW_MINIMIZE);
  }

  public static void SendWinF11() {
    keybd_event(VK_LWIN, 0, KEYEVENTF_EXTENDEDKEY, UIntPtr.Zero);
    keybd_event(VK_F11, 0, 0, UIntPtr.Zero);
    Thread.Sleep(60);
    keybd_event(VK_F11, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    keybd_event(VK_LWIN, 0, KEYEVENTF_KEYUP | KEYEVENTF_EXTENDEDKEY, UIntPtr.Zero);
  }
}
'@
}

function Get-XboxModeFlagPath {
    Join-Path $PSScriptRoot '.xbox-mode'
}

function Set-XboxModeFlag {
    Set-Content -LiteralPath (Get-XboxModeFlagPath) -Value (Get-Date -Format 'o') -Encoding ascii
}

function Clear-XboxModeFlag {
    Remove-Item -LiteralPath (Get-XboxModeFlagPath) -Force -ErrorAction SilentlyContinue
}

function Confirm-XboxSwitch {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Enter', 'Exit')]
        [string]$Action
    )

    $entering = $Action -eq 'Enter'
    $hwnd = [XboxModeNative]::FindModeDialog($entering)
    if ($hwnd -ne [IntPtr]::Zero) {
        $names = if ($entering) { @('Enter Xbox mode', 'Continue') } else { @('Continue', 'Exit Xbox mode') }
        try {
            Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
            $win = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
            foreach ($name in $names) {
                $cond = New-Object System.Windows.Automation.AndCondition(
                    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $name)),
                    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)))
                $btn = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
                if ($btn) {
                    $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                    Write-SwitchLog "Confirmed Xbox switch: $name"
                    return $true
                }
            }
        }
        catch {
            Write-SwitchLog "Could not click the Xbox switch dialog ($($_.Exception.Message))."
        }

        [XboxModeNative]::PressEnterOn($hwnd)
        Write-SwitchLog 'Confirmed Xbox switch with Enter.'
        return $true
    }

    # Unique labels only. A generic Continue button can belong to some other dialog.
    # Searching the whole UI tree is slow, so the hotkey wait loop must not do it every pass.
    $unique = if ($entering) { 'Enter Xbox mode' } else { 'Exit Xbox mode' }
    $now = Get-Date
    if ($script:LastXboxPromptSearch -and ($now - $script:LastXboxPromptSearch).TotalSeconds -lt 3) {
        return $false
    }
    $script:LastXboxPromptSearch = $now
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $cond = New-Object System.Windows.Automation.AndCondition(
            (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $unique)),
            (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)))
        $btn = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        if ($btn) {
            $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            Write-SwitchLog "Clicked '$unique'."
            return $true
        }
    }
    catch { }
    return $false
}

function Enter-XboxMode {
    Write-SwitchLog 'Entering Xbox Mode (Win+F11)...'
    # Keep this console off the TV. Xbox mode shows whatever is in front,
    # and launching the Xbox app before the hotkey restores it on the old monitor.
    [XboxModeNative]::MinimizeConsole()
    Start-Sleep -Milliseconds 400

    if ([XboxModeNative]::XboxCoversPrimary()) {
        Set-XboxModeFlag
        Write-SwitchLog 'Xbox mode is already on this screen.'
        return
    }

    [XboxModeNative]::SendWinF11()
    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline) {
        try { Confirm-XboxSwitch -Action Enter | Out-Null } catch { }
        if ([XboxModeNative]::XboxCoversPrimary()) { break }
        Start-Sleep -Milliseconds 400
    }

    if (-not [XboxModeNative]::XboxCoversPrimary()) {
        Write-SwitchLog 'Xbox home is not covering this display; opening it here...'
        try {
            Start-Process 'shell:AppsFolder\Microsoft.GamingApp_8wekyb3d8bbwe!Microsoft.Xbox.App' -ErrorAction SilentlyContinue
        }
        catch { }
        try { [XboxModeNative]::PlaceXboxOnPrimary() | Out-Null } catch { }
        $deadline = (Get-Date).AddSeconds(8)
        while ((Get-Date) -lt $deadline) {
            try { Confirm-XboxSwitch -Action Enter | Out-Null } catch { }
            if ([XboxModeNative]::XboxCoversPrimary()) { break }
            Start-Sleep -Milliseconds 400
        }
    }

    Set-XboxModeFlag
    if ([XboxModeNative]::XboxCoversPrimary()) {
        Write-SwitchLog 'Xbox mode is on the Xbox screen.'
    }
    else {
        Write-SwitchLog ("WARNING: Xbox screen is not on this display. " + [XboxModeNative]::DescribeXboxWindow())
    }
}

function Test-PrimaryResolution {
    param([int]$Width, [int]$Height)
    foreach ($mon in [MonitorSwap]::ListMonitors($Width, $Height)) {
        if ($mon.Attached -and $mon.Primary -and $mon.CurrentWidth -eq $Width -and $mon.CurrentHeight -eq $Height) {
            return $true
        }
    }
    return $false
}

function Exit-XboxMode {
    param(
        [int]$TvWidth = 0,
        [int]$TvHeight = 0
    )

    $flagged = Test-Path -LiteralPath (Get-XboxModeFlagPath)
    $before = [XboxModeNative]::XboxCoversPrimary()
    $onTvRes = $false
    if ($TvWidth -gt 0 -and $TvHeight -gt 0) {
        $onTvRes = Test-PrimaryResolution -Width $TvWidth -Height $TvHeight
    }
    # After Xbox mode, window detection can fail. If the desktop is still at
    # TV resolution or we left a flag, force an exit attempt.
    $shouldExit = $before -or $flagged -or $onTvRes
    if (-not $shouldExit) {
        Write-SwitchLog 'Xbox mode is already off.'
        return
    }

    Write-SwitchLog 'Exiting Xbox Mode (Win+F11)...'
    [XboxModeNative]::MinimizeConsole()
    [XboxModeNative]::SendWinF11()

    $deadline = (Get-Date).AddSeconds(10)
    $confirmed = $false
    while ((Get-Date) -lt $deadline) {
        try {
            if (Confirm-XboxSwitch -Action Exit) { $confirmed = $true }
        } catch { }
        if (-not [XboxModeNative]::XboxCoversPrimary() -and ($confirmed -or -not $before)) { break }
        if (-not [XboxModeNative]::XboxCoversPrimary() -and ((Get-Date) -gt $deadline.AddSeconds(-6))) { break }
        Start-Sleep -Milliseconds 400
    }

    # A stale flag must not leave Xbox mode on. If the toggle entered it, leave again.
    if (-not $before) {
        $checkUntil = (Get-Date).AddSeconds(5)
        $entered = $false
        while ((Get-Date) -lt $checkUntil) {
            $enterDialog = [XboxModeNative]::FindModeDialog($true)
            if ($enterDialog -ne [IntPtr]::Zero -or [XboxModeNative]::XboxCoversPrimary()) {
                $entered = $true
                break
            }
            Start-Sleep -Milliseconds 400
        }
        if ($entered) {
            Write-SwitchLog 'That toggle entered Xbox mode; turning it back off.'
            [XboxModeNative]::SendWinF11()
            $deadline = (Get-Date).AddSeconds(8)
            while ((Get-Date) -lt $deadline) {
                try { Confirm-XboxSwitch -Action Exit | Out-Null } catch { }
                if (-not [XboxModeNative]::XboxCoversPrimary()) { break }
                Start-Sleep -Milliseconds 400
            }
        }
    }

    Clear-XboxModeFlag
    if ([XboxModeNative]::XboxCoversPrimary()) {
        Write-SwitchLog 'WARNING: Xbox mode still looks on.'
    }
    else {
        Write-SwitchLog 'Xbox mode off.'
    }
}

function Get-DisplayTargetPath {
    Join-Path $PSScriptRoot '.display-target'
}

function Save-DisplayTarget {
    param(
        [Parameter(Mandatory)][string]$Match,
        [Parameter(Mandatory)][string]$DeviceName
    )
    $path = Get-DisplayTargetPath
    $lines = @()
    if (Test-Path -LiteralPath $path) {
        $lines = @(Get-Content -LiteralPath $path | Where-Object { $_ -and ($_ -notmatch ("^" + [regex]::Escape($Match) + "=")) })
    }
    $lines += ($Match + '=' + $DeviceName)
    Set-Content -LiteralPath $path -Value $lines -Encoding ascii
}

function Get-SavedDisplayTarget {
    param([Parameter(Mandatory)][string]$Match)
    $path = Get-DisplayTargetPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match ("^" + [regex]::Escape($Match) + "=(.+)$")) {
            return $Matches[1].Trim()
        }
    }
    return $null
}

function Invoke-MonitorSwitch {
    param(
        [Parameter(Mandatory)][string]$Match,
        [int]$PreferWidth = 0,
        [int]$PreferHeight = 0,
        [string]$Label = $Match,
        [string]$AlsoDisableMatch = $null
    )

    Write-SwitchLog "Switching to $Label (match=$Match)..."
    Write-SwitchLog 'Connected monitors:'
    [MonitorSwap]::ListMonitors($PreferWidth, $PreferHeight) | ForEach-Object {
        Write-SwitchLog ("  {0} attached={1} primary={2} mon#{3} id={4} cur={5}x{6} hasMode={7}" -f `
            $_.FriendlyName, $_.Attached, $_.Primary, $_.MonitorIndex, $_.DeviceId, $_.CurrentWidth, $_.CurrentHeight, $_.HasPreferredMode)
    }

    $extraDisable = $null
    if ($AlsoDisableMatch) {
        $extraDisable = Get-SavedDisplayTarget -Match $AlsoDisableMatch
        if ($extraDisable) {
            Write-SwitchLog "Also detaching saved $AlsoDisableMatch path: $extraDisable"
        }
    }

    $result = [MonitorSwap]::SwitchToOnly($Match, $PreferWidth, $PreferHeight, $extraDisable)
    $result -split "`n" | ForEach-Object { if ($_.Trim()) { Write-SwitchLog $_.TrimEnd() } }

    if ($result -match '^ERROR:') {
        throw $result.Trim()
    }

    if ($result -match 'Target:\s+.+\((\\\\\.\\DISPLAY\d+)') {
        Save-DisplayTarget -Match $Match -DeviceName $Matches[1]
        Write-SwitchLog "Saved $Match path as $($Matches[1])"
    }

    Accept-DisplayChangePrompt
}
