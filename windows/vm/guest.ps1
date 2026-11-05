# Guest-side helpers, run over SSH. SSH sessions have no desktop, so anything that needs one
# (launching Cicada, playing sound, screenshots, clicks, the foreground window) runs as a one-off
# scheduled task in tester's logged-on session and writes its result to a file we read back.
#   guest.ps1 desk '<powershell>'        # run in the desktop session, wait, print its output
#   guest.ps1 launch <exe> [args]        # start a program on the desktop without waiting
#   guest.ps1 shot <out.png>             # screenshot taken inside Windows (what screen sharing sees)
#   guest.ps1 click <x> <y>              # left click at physical pixel x,y
#   guest.ps1 key <keys>                 # SendKeys to the foreground window, e.g. "hello{ENTER}"
#   guest.ps1 front                      # title and process of the foreground window
#   guest.ps1 windows                    # visible top-level windows with their bounds
#   guest.ps1 play <wav>                 # play a WAV from another process (as a meeting app would)
param([Parameter(Position = 0)][string]$Verb, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
$ErrorActionPreference = 'Stop'
$dir = 'C:\cicada-test\guest'; New-Item -ItemType Directory $dir -Force | Out-Null

$native = @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class W {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int x, int y, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool GetWindowDisplayAffinity(IntPtr h, out uint a);
}
'@

function Desk([string]$script, [int]$timeout = 60, [switch]$NoWait) {
  $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
  $ps1 = "$dir\$id.ps1"; $out = "$dir\$id.out"; $done = "$dir\$id.done"
  # The script redirects its own output, so the task line needs no quotes; conhost --headless keeps
  # a console window from flashing up and taking the foreground.
  @"
`$ErrorActionPreference='Continue'
& {
Add-Type -TypeDefinition @'
$native
'@
[W]::SetProcessDPIAware() | Out-Null
try {
$script
} catch { "error: `$_" }
} *> '$out'
Set-Content '$done' 1
"@ | Set-Content $ps1 -Encoding UTF8
  $cmd = "conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps1"
  schtasks /create /tn "cicada-$id" /tr $cmd /sc once /st 23:59 /it /ru $env:USERNAME /f | Out-Null
  schtasks /run /tn "cicada-$id" | Out-Null
  if ($NoWait) { Start-Sleep 1; schtasks /delete /tn "cicada-$id" /f | Out-Null; return }
  $t = 0; while (-not (Test-Path $done) -and $t -lt $timeout * 4) { Start-Sleep -Milliseconds 250; $t++ }
  schtasks /delete /tn "cicada-$id" /f | Out-Null
  if (Test-Path $out) { Get-Content $out -Encoding UTF8 }
  if (-not (Test-Path $done)) { "error: timed out" }
}

switch ($Verb) {
  'desk' { Desk ($Rest -join ' ') }
  'launch' {
    $exe = $Rest[0]; $args2 = ($Rest | Select-Object -Skip 1) -join ' '
    $argPart = if ($args2) { "-ArgumentList '$args2'" } else { '' }
    $dirPart = if (Split-Path $exe) { "-WorkingDirectory '$(Split-Path $exe)'" } else { '' }
    Desk "Start-Process '$exe' $argPart $dirPart" -NoWait
  }
  'shot' {
    $png = $Rest[0]
    Desk @"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
`$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
`$bmp = New-Object System.Drawing.Bitmap `$b.Width, `$b.Height
`$g = [System.Drawing.Graphics]::FromImage(`$bmp); `$g.CopyFromScreen(`$b.Left, `$b.Top, 0, 0, `$bmp.Size)
`$bmp.Save('$png', [System.Drawing.Imaging.ImageFormat]::Png); "saved `$(`$b.Width)x`$(`$b.Height)"
"@
  }
  'click' {
    Desk "[W]::SetCursorPos($($Rest[0]), $($Rest[1])) | Out-Null; Start-Sleep -Milliseconds 100; [W]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [W]::mouse_event(4,0,0,0,[UIntPtr]::Zero); 'clicked'"
  }
  'key' {
    $k = ($Rest -join ' ').Replace("'", "''")
    Desk "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SendKeys]::SendWait('$k'); 'sent'"
  }
  'front' {
    Desk @'
$h = [W]::GetForegroundWindow(); $s = New-Object System.Text.StringBuilder 256; [W]::GetWindowText($h, $s, 256) | Out-Null
$p = 0; [W]::GetWindowThreadProcessId($h, [ref]$p) | Out-Null
"$((Get-Process -Id $p).ProcessName) | $($s.ToString())"
'@
  }
  'windows' {
    Desk @'
$list = New-Object System.Collections.ArrayList
[W]::EnumWindows({ param($h, $l)
  if ([W]::IsWindowVisible($h)) {
    $s = New-Object System.Text.StringBuilder 256; [W]::GetWindowText($h, $s, 256) | Out-Null
    $p = 0; [W]::GetWindowThreadProcessId($h, [ref]$p) | Out-Null
    $name = (Get-Process -Id $p -ErrorAction SilentlyContinue).ProcessName
    if ($name -match 'Cicada|notepad|powershell') {
      $r = New-Object W+RECT; [W]::GetWindowRect($h, [ref]$r) | Out-Null
      $a = 0; [W]::GetWindowDisplayAffinity($h, [ref]$a) | Out-Null
      $ex = [W]::GetWindowLong($h, -20)
      [void]$list.Add(('{0} | {1} | {2},{3} {4}x{5} | exstyle=0x{6:X} affinity={7}' -f $name, $s, $r.L, $r.T, ($r.R - $r.L), ($r.B - $r.T), $ex, $a))
    }
  }; $true }, [IntPtr]::Zero) | Out-Null
$list
'@
  }
  'play' {
    Desk "(New-Object System.Media.SoundPlayer '$($Rest[0])').PlaySync(); 'played'" -timeout 300
  }
  default { "usage: guest.ps1 desk|launch|shot|click|key|front|windows|play" }
}
