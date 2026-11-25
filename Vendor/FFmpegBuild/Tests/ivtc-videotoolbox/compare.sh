#!/bin/sh
# compare.sh <label> <fixture> <fieldmatch options> <decimate options or "-" for none>
# Runs the CPU chain (fieldmatch,decimate) and the GPU chain (the _videotoolbox filters)
# on the same input and compares, frame by frame:
#   - the output frames and timestamps (framemd5, after converting both to yuv420p),
#   - fieldmatch's per-frame debug line (comb scores, match, combed flag),
#   - decimate's per-cycle debug lines (totdiff, maxbdiff, which frame is dropped).
# Needs GPU access (run outside the sandbox). Prints one result line.
FF=${FF:-${FFMPEG_SRC:-$(dirname "$0")/../ffmpeg-src}/ffmpeg}
label=$1; in=$2; fmo=$3; dmo=$4
out=${OUT:-$(dirname "$0")/out}/$label
rm -rf "$out"; mkdir -p "$out"
if [ "$dmo" = "-" ]; then cdec=""; gdec=""; else cdec=",decimate=$dmo"; gdec=",decimate_videotoolbox=$dmo"; fi
"$FF" -y -hide_banner -nostats -loglevel repeat+debug -i "$in" -an \
    -vf "fieldmatch=$fmo$cdec,format=yuv420p" -f framemd5 "$out/cpu.md5" 2> "$out/cpu.log"
c=$?
"$FF" -y -hide_banner -nostats -loglevel repeat+debug -init_hw_device videotoolbox=vt -filter_hw_device vt -i "$in" -an \
    -vf "format=nv12,hwupload,fieldmatch_videotoolbox=$fmo$gdec,hwdownload,format=nv12,format=yuv420p" \
    -f framemd5 "$out/gpu.md5" 2> "$out/gpu.log"
g=$?
strip() { sed -E 's/^\[[A-Za-z_0-9]+ @ 0x[0-9a-f]+\] //'; }
grep -E "SC:[0-9] \| COMBS:" "$out/cpu.log" | strip > "$out/cpu.fm"
grep -E "SC:[0-9] \| COMBS:" "$out/gpu.log" | strip > "$out/gpu.fm"
grep -E "totdiff=|frame drop" "$out/cpu.log" | strip > "$out/cpu.dm"
grep -E "totdiff=|frame drop" "$out/gpu.log" | strip > "$out/gpu.dm"
grep -v '^#' "$out/cpu.md5" > "$out/cpu.frames"; grep -v '^#' "$out/gpu.md5" > "$out/gpu.frames"
nf=$(wc -l < "$out/cpu.frames" | tr -d ' ')
nfm=$(wc -l < "$out/cpu.fm" | tr -d ' ')
ncomb=$(grep -c "combed=YES" "$out/cpu.fm")
ndrop=$(grep -c "\[DROP\]" "$out/cpu.dm")
cmp -s "$out/cpu.frames" "$out/gpu.frames" && fr=same || fr=DIFF
cmp -s "$out/cpu.fm" "$out/gpu.fm" && fmr=same || fmr=DIFF
cmp -s "$out/cpu.dm" "$out/gpu.dm" && dmr=same || dmr=DIFF
[ $c -eq 0 ] && [ $g -eq 0 ] || fr="EXIT cpu=$c gpu=$g"
printf "%-26s frames=%-5s %-5s fieldmatch=%-5s(%s lines, %s combed) decimate=%-5s(%s drops)\n" \
    "$label" "$nf" "$fr" "$fmr" "$nfm" "$ncomb" "$dmr" "$ndrop"
