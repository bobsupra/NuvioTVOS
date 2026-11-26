#!/bin/sh
# Minimal macOS FFmpeg for the IVTC VideoToolbox filter work. Run from ffmpeg-src.
export TMPDIR="${TMPDIR:-/tmp}"
./configure --prefix="$(pwd)/../ivtc-build/install" \
  --disable-everything --disable-doc --disable-network --disable-ffplay --disable-autodetect \
  --enable-metal --enable-videotoolbox --enable-coreimage --disable-sdl2 \
  --enable-protocol=file,pipe \
  --enable-demuxer=mpegts,matroska,mov,mpegps,mpegvideo \
  --enable-decoder=mpeg2video,h264,rawvideo \
  --enable-parser=mpegvideo,h264 \
  --enable-encoder=wrapped_avframe,rawvideo \
  --enable-muxer=framemd5,null,rawvideo,nut \
  --enable-filter=fieldmatch,decimate,idet,bwdif,yadif,bwdif_videotoolbox,yadif_videotoolbox,hwupload,hwdownload,format,null,scale,setfield,showinfo,fieldmatch_videotoolbox,decimate_videotoolbox \
  "$@"
