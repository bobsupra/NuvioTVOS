#!/bin/sh
# Test clips for fieldmatch_videotoolbox / decimate_videotoolbox (generated with a GPL Homebrew ffmpeg; nothing GPL ships).
set -e
H=${H:-/opt/homebrew/bin/ffmpeg}
cd "$(dirname "$0")/fixtures"
enc() { out=$1; shift; "$H" -hide_banner -loglevel error -y "$@" -c:v mpeg2video -flags +ilme+ildct -b:v 8M -pix_fmt yuv420p -an "$out"; }
enc tc480_tff.mkv    -f lavfi -i "testsrc2=size=720x480:rate=24000/1001:duration=20" -vf "telecine=first_field=top:pattern=23,setfield=tff" &
enc tc480_bff.mkv    -f lavfi -i "testsrc2=size=720x480:rate=24000/1001:duration=20" -vf "telecine=first_field=bottom:pattern=23,setfield=bff" &
enc true60i_480.mkv  -f lavfi -i "testsrc2=size=720x480:rate=60000/1001:duration=20" -vf "tinterlace=mode=interleave_top,setfield=tff" &
enc tc480_noise.mkv  -f lavfi -i "testsrc2=size=720x480:rate=24000/1001:duration=20" -vf "noise=alls=30:allf=t+u,telecine=first_field=top:pattern=23,setfield=tff" &
enc tc480_mandel.mkv -f lavfi -i "mandelbrot=size=720x480:rate=24000/1001" -t 20 -vf "telecine=first_field=top:pattern=23,setfield=tff" &
enc tc576_tff.mkv    -f lavfi -i "testsrc2=size=720x576:rate=24000/1001:duration=20" -vf "telecine=first_field=top:pattern=23,setfield=tff" &
enc tc1080_tff.mkv   -f lavfi -i "testsrc2=size=1920x1080:rate=24000/1001:duration=10" -vf "telecine=first_field=top:pattern=23,setfield=tff" &
wait
ls -la
