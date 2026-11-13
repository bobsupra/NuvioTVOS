'use strict';
// AIOStreams' own Usenet engine is off on Apple TV (Nuvio Usenet plays Usenet
// streams natively), so its yEnc addon is not needed.
function unavailable() {
  throw new Error("yEnc is not available on Apple TV: AIOStreams' Usenet engine is off here (Nuvio Usenet plays Usenet streams).");
}
exports.decodeTo = unavailable;
exports.decodeChunk = unavailable;
exports.crc32 = unavailable;
exports.from_post = unavailable;
exports.decode = unavailable;
exports.encode = unavailable;
