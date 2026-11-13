'use strict';
// bcrypt's API on bcryptjs (vendored next to this file, MIT). Plain
// `exports.x =` assignments, so Node's ESM loader sees the named exports
// (import { hash } from 'bcrypt').
const bcryptjs = require('./bcryptjs/index.js');

exports.genSalt = (rounds = 10) => bcryptjs.genSalt(rounds);
exports.hash = (data, saltOrRounds) => bcryptjs.hash(String(data), saltOrRounds);
exports.compare = (data, encrypted) => bcryptjs.compare(String(data), encrypted);
exports.genSaltSync = (rounds = 10) => bcryptjs.genSaltSync(rounds);
exports.hashSync = (data, saltOrRounds) => bcryptjs.hashSync(String(data), saltOrRounds);
exports.compareSync = (data, encrypted) => bcryptjs.compareSync(String(data), encrypted);
exports.getRounds = (encrypted) => bcryptjs.getRounds(encrypted);
