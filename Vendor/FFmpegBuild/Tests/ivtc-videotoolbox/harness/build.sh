#!/bin/sh
# Builds the two kernel harnesses against the local FFmpeg tree (../../ffmpeg-src, built).
set -e
cd "$(dirname "$0")"
S=../../ffmpeg-src
# vf_fieldmatch.c with one line added: copy compare_fields' six sums out before they are used.
sed 's/^    if (accumPm < 500 \&\& accumNm < 500 \&\& (accumPml >= 500 || accumNml >= 500) \&\&$/    g_acc[0] = accumPc; g_acc[1] = accumPm; g_acc[2] = accumPml; g_acc[3] = accumNc; g_acc[4] = accumNm; g_acc[5] = accumNml; \/* harness *\/\
&/' $S/libavfilter/vf_fieldmatch.c > vf_fieldmatch_instrumented.c
grep -c "harness" vf_fieldmatch_instrumented.c
EXTRA=$(sed -n 's/^EXTRALIBS=//p' $S/ffbuild/config.mak)
LIBS="$S/libavfilter/libavfilter.a $S/libswscale/libswscale.a $S/libavcodec/libavcodec.a $S/libavformat/libavformat.a $S/libavutil/libavutil.a"
for h in fm dm; do
  clang -fobjc-arc -O1 -I$S -I$S/libavfilter -Wno-deprecated-declarations harness_$h.m $LIBS $EXTRA \
    $(sed -n 's/^EXTRALIBS-avfilter=//p;s/^EXTRALIBS-avcodec=//p;s/^EXTRALIBS-avutil=//p' $S/ffbuild/config.mak) \
    -framework Metal -framework Foundation -framework CoreVideo -framework CoreMedia -framework VideoToolbox \
    -framework CoreFoundation -framework CoreImage -framework AppKit -framework QuartzCore -o harness_$h
done
ls -la harness_fm harness_dm
