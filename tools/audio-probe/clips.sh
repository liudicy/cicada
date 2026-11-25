#!/bin/zsh
# Test clips for probe.py, 16 kHz mono 16-bit WAV in $1: the sample meeting's segments come from
# probe.py itself; these are spoken lines with a known text, plus a clip with no speech.
set -e
out=${1:?folder}
mkdir -p "$out"
clip() { # name voice text
  say -v "$2" -o "$out/$1.aiff" "$3"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$out/$1.aiff" "$out/$1.wav"
  rm "$out/$1.aiff"
  print -r -- "$3" > "$out/$1.txt"
}
clip zh-1 Tingting "我们下周二之前要把预算定下来，市场部那边还在等报价。"
clip zh-2 Tingting "这个方案我觉得风险有点大，能不能先在上海试点一个月？"
clip en-1 Samantha "Let's push the launch to the second week of March, the vendor still hasn't signed the contract."
clip en-2 Daniel "Could you send me the revised numbers before Thursday's board meeting?"
clip ja-1 Kyoko "来週の会議までに、新しいデザイン案を三つ用意してください。"
clip ko-1 Yuna "이번 분기 매출은 지난 분기보다 십오 퍼센트 늘었습니다."
clip mix-1 Tingting "这周我们先跟 Google 的 team 对一下 API 的 timeline。"
# No speech: two seconds of Glass and Submarine, the kind of sound a meeting app makes.
afconvert -f WAVE -d LEI16@16000 -c 1 /System/Library/Sounds/Submarine.aiff "$out/none-1.wav"
print -r -- "" > "$out/none-1.txt"
ls "$out"
# The sample meeting (probe.py cuts it the way the ports do); plain PCM, which Python's wave reads.
afconvert -f WAVE -d LEI16@16000 -c 1 "${0:A:h}/../../android/app/src/main/assets/sample.wav" "$out/sample.pcm"
