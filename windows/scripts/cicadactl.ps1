# Sends one debug command to a running dev build (Cicada.exe --dev) and prints its JSON state.
#   .\cicadactl.ps1 state | start | stop | end | notesproblem failed | sample | feed C:\clip.wav | view subtitles | capture on | show records | quit
#   结束会议: calls zoom.exe=Zoom|none|real | realcalls | endtimes <silence> <countdown> <grace>|off | endkeep
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Command)
$pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", "cicada-dev", [System.IO.Pipes.PipeDirection]::InOut)
$pipe.Connect(3000)
$writer = New-Object System.IO.StreamWriter($pipe); $writer.AutoFlush = $true
$reader = New-Object System.IO.StreamReader($pipe)
$writer.WriteLine(($Command -join " "))
$reader.ReadLine()
$pipe.Dispose()
