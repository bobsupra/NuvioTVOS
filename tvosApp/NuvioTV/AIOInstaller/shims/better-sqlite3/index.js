'use strict';
// AIOStreams on Apple TV: native addons can't be loaded there, so this stands
// in for better-sqlite3 using Node's built-in SQLite (node:sqlite, Node 24).
// It covers what AIOStreams' SQLite driver uses: new Database(file),
// pragma(), exec(), prepare() → { reader, run, get, all, iterate }, close().
const { DatabaseSync } = require('node:sqlite');

// Extended result codes → better-sqlite3's error code names.
const CODES = {
  5: 'SQLITE_BUSY', 6: 'SQLITE_LOCKED', 19: 'SQLITE_CONSTRAINT',
  275: 'SQLITE_CONSTRAINT_CHECK', 787: 'SQLITE_CONSTRAINT_FOREIGNKEY',
  1299: 'SQLITE_CONSTRAINT_NOTNULL', 1555: 'SQLITE_CONSTRAINT_PRIMARYKEY',
  2067: 'SQLITE_CONSTRAINT_UNIQUE', 2579: 'SQLITE_CONSTRAINT_ROWID',
};

class SqliteError extends Error {
  constructor(error) {
    super(error.message);
    this.name = 'SqliteError';
    this.code = CODES[error.errcode] || (typeof error.errcode === 'number' ? 'SQLITE_ERROR' : error.code);
    this.cause = error;
  }
}

function wrap(fn) {
  try {
    return fn();
  } catch (error) {
    throw error && error.code === 'ERR_SQLITE_ERROR' ? new SqliteError(error) : error;
  }
}

function args(params) {
  return params.length === 1 && params[0] && typeof params[0] === 'object' && !Array.isArray(params[0]) && !ArrayBuffer.isView(params[0])
    ? params
    : params.map((value) => (value === undefined ? null : value));
}

function plain(row) {
  return row ? Object.assign({}, row) : row;
}

class Statement {
  constructor(statement, source) {
    this._statement = statement;
    this.source = source;
    this.reader = wrap(() => statement.columns().length > 0);
  }

  run(...params) {
    return wrap(() => {
      const info = this._statement.run(...args(params));
      return { changes: Number(info.changes), lastInsertRowid: info.lastInsertRowid };
    });
  }

  get(...params) {
    return wrap(() => plain(this._statement.get(...args(params))));
  }

  all(...params) {
    return wrap(() => this._statement.all(...args(params)).map(plain));
  }

  *iterate(...params) {
    for (const row of this.all(...params)) yield row;
  }
}

class Database {
  constructor(filename, options = {}) {
    this.name = filename;
    this._db = wrap(() => new DatabaseSync(filename === undefined ? ':memory:' : filename, {
      readOnly: !!options.readonly,
    }));
    this.open = true;
  }

  prepare(source) {
    return new Statement(wrap(() => this._db.prepare(source)), source);
  }

  exec(source) {
    wrap(() => this._db.exec(source));
    return this;
  }

  pragma(source, options = {}) {
    const rows = wrap(() => this._db.prepare(`PRAGMA ${source}`).all()).map(plain);
    if (options.simple) {
      const first = rows[0];
      return first ? first[Object.keys(first)[0]] : undefined;
    }
    return rows;
  }

  transaction(fn) {
    const db = this;
    return function (...params) {
      db.exec('BEGIN');
      try {
        const result = fn.apply(this, params);
        db.exec('COMMIT');
        return result;
      } catch (error) {
        try { db.exec('ROLLBACK'); } catch (ignored) { /* already rolled back */ }
        throw error;
      }
    };
  }

  close() {
    if (this.open) {
      wrap(() => this._db.close());
      this.open = false;
    }
    return this;
  }
}

Database.SqliteError = SqliteError;
module.exports = Database;
module.exports.default = Database;
module.exports.SqliteError = SqliteError;
