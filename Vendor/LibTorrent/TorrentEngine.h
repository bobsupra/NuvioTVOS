#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One file inside a torrent.
@interface TKFile : NSObject
@property (nonatomic, readonly) NSInteger index;
/// Absolute path where libtorrent writes this file on disk.
@property (nonatomic, readonly, copy) NSString *path;
/// Byte offset of this file within the torrent's piece space.
@property (nonatomic, readonly) long long offset;
@property (nonatomic, readonly) long long length;
@end

/// A snapshot of swarm/download state.
@interface TKStats : NSObject
@property (nonatomic, readonly) double downloadRate;   // bytes/sec (payload)
@property (nonatomic, readonly) NSInteger numPeers;
@property (nonatomic, readonly) NSInteger numSeeds;
@property (nonatomic, readonly) double progress;       // 0…1 over wanted bytes
@property (nonatomic, readonly) long long downloadedBytes;
@end

/// Deep connectivity diagnostics: this torrent's swarm state plus session-wide
/// connect/disconnect counters (since launch). Answers, from a single snapshot,
/// which stage is failing: discovery (listPeers), eligibility (connectCandidates),
/// TCP reachability (outgoingAttempts vs connectFailures), or the protocol layer
/// (disconnectReasons past the connect stage).
@interface TKSwarmDiag : NSObject
// Per-torrent, from torrent_status:
@property (nonatomic, readonly) NSInteger numPeers;          // connected (payload-capable)
@property (nonatomic, readonly) NSInteger numSeeds;
@property (nonatomic, readonly) NSInteger numConnections;    // incl. handshaking; >= numPeers
@property (nonatomic, readonly) NSInteger connectCandidates; // known peers eligible to try now
@property (nonatomic, readonly) NSInteger listPeers;         // peers known to the peer list
@property (nonatomic, readonly) NSInteger listSeeds;
@property (nonatomic, readonly, copy) NSString *torrentState; // downloading/finished/seeding/…
@property (nonatomic, readonly) long long totalWanted;       // bytes selected for download
@property (nonatomic, readonly) long long totalWantedDone;
@property (nonatomic, readonly) long long allTimeDownload;
@property (nonatomic, readonly) double downloadRate;         // payload bytes/sec
@property (nonatomic, readonly) double uploadRate;
// Session-wide, since launch:
@property (nonatomic, readonly) long long outgoingAttempts;  // TCP SYNs sent to peers
@property (nonatomic, readonly) long long incomingAccepts;
@property (nonatomic, readonly) long long connectFailures;   // failed at the TCP connect stage
@property (nonatomic, readonly) NSInteger dhtNodes;          // DHT routing-table size
/// "operation/error" → count, e.g. "connect/Operation timed out" → 1234.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSNumber *> *disconnectReasons;
/// Most recent tracker/DHT peer-list reply, e.g. "udp://tracker.x:1337 → 200 peers".
@property (nonatomic, readonly, copy) NSString *lastPeerSource;
@end

/// A thin Objective-C++ facade over libtorrent, exposing exactly what WatchBox's
/// streaming stack needs: add a magnet, learn its files, drive piece-level
/// prioritization from the playhead, ask which pieces are on disk, and read
/// fast-resume data. The localhost `StreamingServer` reads the media file that
/// libtorrent writes to disk once the covering pieces are present.
///
/// All methods are safe to call from any thread; libtorrent's own objects are
/// proxies that marshal to its session thread. Metadata/piece callbacks are
/// delivered on an internal serial queue.
@interface TorrentEngine : NSObject

- (instancetype)initWithSaveDirectory:(NSString *)saveDirectory
                             maxPeers:(NSInteger)maxPeers
                        extraTrackers:(NSArray<NSString *> *)extraTrackers;

/// Begin downloading a magnet, optionally seeded with prior fast-resume data.
- (void)startMagnet:(NSString *)magnetURI resumeData:(nullable NSData *)resumeData;

/// Re-run tracker and DHT discovery for a metadata-only magnet. This is safe to
/// call periodically while waiting: it is deliberately a nudge, not a restart.
- (void)retryMetadataDiscovery;

/// `NO` means the magnet could not be parsed or libtorrent rejected it. Without
/// this, Swift would poll `hasMetadata` until its timeout and misreport an add
/// failure as a peer-discovery problem.
@property (nonatomic, readonly) BOOL isActive;

/// Fires once the info dict is available (files/pieces known).
@property (nonatomic, copy, nullable) void (^onMetadata)(void);
/// Fires (on the internal queue) each time a piece is verified to disk.
@property (nonatomic, copy, nullable) void (^onPieceFinished)(NSInteger pieceIndex);

@property (nonatomic, readonly) BOOL hasMetadata;
- (NSArray<TKFile *> *)files;
@property (nonatomic, readonly) NSInteger pieceLength;
@property (nonatomic, readonly) NSInteger pieceCount;

/// Download only this file at normal priority; the rest are do-not-download.
/// Used for plain downloads (the whole file is wanted).
- (void)selectFile:(NSInteger)fileIndex;

/// Streaming setup: the streamed file at LOW baseline priority (never
/// dont_download — that routes data into libtorrent's `.parts` partfile, which
/// the stream server can't read and whose later migration can wedge the disk
/// thread), other files excluded. The stream server's window (7/5) outranks
/// the baseline so the playhead keeps the bandwidth.
- (void)prepareStreamingForFile:(NSInteger)fileIndex;
/// Marks the prebuffer→playback transition. Currently a no-op (the baseline is
/// already the steady-state one); see the .mm comment for why a two-phase
/// file-priority scheme is not safe on libtorrent 2.0.11.
- (void)beginStreamingSteadyStateForFile:(NSInteger)fileIndex;

- (BOOL)hasPiece:(NSInteger)pieceIndex;
/// Read a whole piece's verified bytes through libtorrent (cache or disk), delivered
/// asynchronously via `read_piece_alert` — never touches the file directly, so it
/// can't race the async disk flush. `nil` on error/teardown.
- (void)readPiece:(NSInteger)pieceIndex completion:(void (^)(NSData * _Nullable))completion NS_SWIFT_DISABLE_ASYNC;
/// Streaming urgency: an earlier (smaller) relative deadline is fetched sooner.
- (void)setPieceDeadline:(NSInteger)pieceIndex milliseconds:(NSInteger)ms;
- (void)clearPieceDeadline:(NSInteger)pieceIndex;
/// 0 = don't download, 1 = low, 4 = default, 7 = top.
- (void)setPiecePriority:(NSInteger)pieceIndex priority:(NSInteger)priority;

- (TKStats *)stats;
/// Deep swarm/connectivity snapshot (see TKSwarmDiag). Also kicks an async
/// session-stats refresh so the DHT gauge stays current at a polling cadence.
- (TKSwarmDiag *)diagnostics;

/// Fast-resume blob (info dict included). Non-blocking: libtorrent generates it
/// asynchronously, so this delivers the result via the completion handler.
/// Imported into Swift as `func saveResumeData() async -> Data?`.
- (void)saveResumeDataWithCompletionHandler:(void (^)(NSData * _Nullable))completionHandler;

- (void)pause;
- (void)resume;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
