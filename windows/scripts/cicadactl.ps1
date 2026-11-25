# Sends one debug command to a running dev build (Cicada.exe --dev) and prints its JSON state.
#   .\cicadactl.ps1 state | start | stop | end | notesproblem failed | sample | feed C:\clip.wav | view subtitles | capture on | show records | hide notes | quit
#   AI 服务: provider ling|openrouter|zenmux|custom | switchtoling (a status line's 改用 Ling) | ai-model hear|text|voice|notes <id> | ai-notes same|own [address] | ai-custom-only on|off | show settings ai models
#   AI 服务检查: ai-check | ai-check-sim <unreachable|invalidKey|noCredit|mgmtKey|noModel|noJSON|deaf|busy|serverError|lowBalance|off> (state › ai.check: every step)
#   结束会议: calls zoom.exe=Zoom|none|real | realcalls | endtimes <silence> <countdown> <grace>|off | endkeep
#   改正听错的词: silentlisten zh-CN | heard <text> | fixstate | fixanswer yes|no | fixlater | fixrevert <line> | fixedit <line>=<text>[|one][|keep0] | fixundo | vocabadd Morpho=莫拉 | vocabstate (… @<id> for another meeting)
#   分享…: share "<id>[,full][,pw]" | unshare <id> | sharesheet "<id>[,full][,pw][,names][,30|365][,go]" | sharesheet leaveout | sharesheet | shareinfo <id>
#     (quote anything with a comma: PowerShell would make it a list)
#   存到文件夹: export [state] | export on | off | folder C:\Notes\Cicada | choose (the 存到哪里 dialog) | all (也存一份) | retry   (state › export too); rename <id> <title>
#   会议记录搜索 (Ctrl+F): search <text> | searchstep 1|-1   (meetings found, lines found in the shown one, the line it is on)
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Command)
$pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", "cicada-dev", [System.IO.Pipes.PipeDirection]::InOut)
$pipe.Connect(3000)
$writer = New-Object System.IO.StreamWriter($pipe); $writer.AutoFlush = $true
$reader = New-Object System.IO.StreamReader($pipe)
$writer.WriteLine(($Command -join " "))
$reader.ReadLine()
$pipe.Dispose()
