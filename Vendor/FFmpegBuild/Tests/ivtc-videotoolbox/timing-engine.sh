#!/bin/sh
export LC_ALL=C  # awk reads decimal commas under a German locale and truncates every time
# Head to head against AetherEngine main (3820c494): the chain DeinterlaceFilter builds on the
# GPU engine under inverse telecine, against the same chain with the GPU filters, plus each
# CPU stage alone. One filter thread, best of three, minus a decode-only baseline (so the
# hwupload is counted in both engine chains). Per input frame. Needs GPU access.
cd "$(dirname "$0")"
FF=../ffmpeg-src/ffmpeg
HW="-init_hw_device videotoolbox=vt -filter_hw_device vt"
bench() { # label input loops vf  -> "label rtime utime" (best of three)
  for i in 1 2 3; do
    "$FF" -hide_banner -nostats -benchmark -filter_threads 1 $HW -stream_loop $3 -i "$2" -an -vf "$4" -f null - 2>&1 \
      | sed -nE 's/.*utime=([0-9.]+)s.*rtime=([0-9.]+)s.*/\2 \1/p'
  done | sort -n | head -1 | sed "s/^/$1 /"
}
FM="order=auto:combmatch=full"
BW="bwdif_videotoolbox=mode=send_frame:parity=auto:deint=interlaced"
for spec in "tc480_tff.mkv 4 600" "tc480_noise.mkv 4 600" "tc576_tff.mkv 4 600" "tc1080_tff.mkv 2 300"; do
  set -- $spec; in=fixtures/$1; loops=$2; n=$(( $3 * ($2 + 1) ))
  {
  bench base      $in $loops "null"
  bench cpu_fm    $in $loops "fieldmatch=$FM"
  bench cpu_dm    $in $loops "decimate"
  bench gpu_fm    $in $loops "format=nv12,hwupload,fieldmatch_videotoolbox=$FM"
  bench gpu_dm    $in $loops "format=nv12,hwupload,decimate_videotoolbox"
  bench upload    $in $loops "format=nv12,hwupload"
  bench main_gpu  $in $loops "fieldmatch=$FM,decimate,format=nv12,hwupload,$BW"
  bench proposed  $in $loops "format=nv12,hwupload,fieldmatch_videotoolbox=$FM,decimate_videotoolbox,$BW"
  } | awk -v name=$1 -v n=$n '
    $1=="base" {br=$2; bu=$3; printf "%s (%d input frames)\n", name, n; next}
    { printf "  %-9s wall %6.2f ms/frame   cpu %6.2f ms/frame\n", $1, ($2-br)*1000/n, ($3-bu)*1000/n }'
done
