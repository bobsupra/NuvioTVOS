//
// Use this file to import your target's public headers that you would like to expose to Swift.
//
#import "TorrentEngine.h"
#import "AIOCrashNotes.h"
// zlib's CRC32, for the yEnc checksum of Usenet articles (UsenetCRC32).
#include <zlib.h>
// node-yencode's yEnc decoder (NEON), for UsenetYEnc: YEnc/README.md.
#import "YEnc/NuvioYEnc.h"
