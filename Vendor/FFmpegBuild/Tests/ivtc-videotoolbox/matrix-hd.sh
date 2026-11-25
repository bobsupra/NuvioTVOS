#!/bin/sh
cd "$(dirname "$0")"
sed -n '/^set_opts()/,/^}/p' matrix.sh > ${TMPDIR:-/tmp}/setopts.$$; . ${TMPDIR:-/tmp}/setopts.$$; rm -f ${TMPDIR:-/tmp}/setopts.$$
for f in tc1080_tff; do for o in D E F G H I J; do set_opts $o
  in=fixtures/$f.mkv; [ -e "$in" ] || in=fixtures/$f.ts
  ./compare.sh "$f-$o" "$in" "$FM" "$DM"; done; done
