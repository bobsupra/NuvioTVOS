#!/bin/sh
# Every fixture through every option set, CPU against GPU. Needs GPU access.
cd "$(dirname "$0")"
set_opts() {
  case $1 in
    A) FM="order=auto:combmatch=full"; DM="" ;;
    B) FM="combmatch=sc"; DM="" ;;
    C) FM="combmatch=none"; DM="-" ;;
    D) FM="mode=pc:combmatch=full"; DM="-" ;;
    E) FM="mode=pc_u:combmatch=full"; DM="-" ;;
    F) FM="mchroma=0:combmatch=full"; DM="chroma=0" ;;
    G) FM="order=bff:field=top:combmatch=full"; DM="blockx=16:blocky=16" ;;
    H) FM="y0=100:y1=200:combmatch=full:cthresh=4:combpel=40:blockx=8:blocky=32"; DM="cycle=4" ;;
    I) FM="cthresh=-1:combmatch=full"; DM="mixed=1" ;;
    J) FM="combmatch=full:scthresh=2"; DM="dupthresh=3:scthresh=5" ;;
  esac
}
SD="tc480_tff tc480_bff true60i_480 tc480_noise tc480_mandel tc576_tff"
HD="tc1080_tff"
for f in $SD; do for o in A B C D E F G H I J; do set_opts $o
  in=fixtures/$f.mkv; [ -e "$in" ] || in=fixtures/$f.ts
  ./compare.sh "$f-$o" "$in" "$FM" "$DM"; done; done
for f in $HD; do for o in ${HD_SETS:-A B C}; do set_opts $o
  in=fixtures/$f.mkv; [ -e "$in" ] || in=fixtures/$f.ts
  ./compare.sh "$f-$o" "$in" "$FM" "$DM"; done; done
