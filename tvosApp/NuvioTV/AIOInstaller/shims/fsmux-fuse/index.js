'use strict';
// No FUSE on tvOS: AIOStreams' probe reports it unavailable and skips the mount.
// Stands for @viren070/fsmux-fuse and, from the version after v2.37.0,
// @aiostreams/fsmux-fuse; the names AIOStreams might import are all here.
const reason = 'FUSE is not available on Apple TV';
class FuseUnavailableError extends Error {
  constructor(message = reason) {
    super(message);
    this.name = 'FuseUnavailableError';
  }
}
exports.FuseUnavailableError = FuseUnavailableError;
exports.probeFuse = async () => ({ ok: false, reason });
exports.mountSharedFilesystem = async () => {
  throw new FuseUnavailableError();
};
exports.detachMount = async () => undefined;
exports.nativeTarget = () => ({ reason });
exports.loadNativeBinding = () => ({ reason });
exports.mountInfoAt = async () => null;
exports.isStaleMount = async () => false;
exports.clearMountpoint = async () => undefined;
exports.silentLogger = { debug() {}, info() {}, warn() {}, error() {} };
