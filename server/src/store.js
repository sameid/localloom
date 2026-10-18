import { createWriteStream } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';

// IDs double as directory names, so this pattern is what keeps paths inside the data dir.
// The 8-character minimum admits IDs from LocalLoom versions before the server existed.
const ID_PATTERN = /^[A-Za-z0-9_-]{8,64}$/;

export class HttpError extends Error {
  constructor(status, message, extra = {}) {
    super(message);
    this.status = status;
    this.extra = extra;
  }
}

export function isValidId(id) {
  return typeof id === 'string' && ID_PATTERN.test(id);
}

export function newId() {
  return randomBytes(16).toString('base64url');
}

// Each recording lives in <dataDir>/recordings/<id>/ as video.mp4 + meta.json.
// No database: the folder can be backed up or inspected with ordinary tools.
export class Store {
  #root;
  #uploading = new Set();

  constructor(dataDir) {
    this.#root = path.join(dataDir, 'recordings');
  }

  async init() {
    await fs.mkdir(this.#root, { recursive: true });
  }

  #dir(id) {
    if (!isValidId(id)) throw new HttpError(404, 'not found');
    return path.join(this.#root, id);
  }

  videoPath(id) {
    return path.join(this.#dir(id), 'video.mp4');
  }

  async get(id) {
    if (!isValidId(id)) return null;
    try {
      return JSON.parse(await fs.readFile(path.join(this.#dir(id), 'meta.json'), 'utf8'));
    } catch (err) {
      if (err.code === 'ENOENT') return null;
      throw err;
    }
  }

  async list() {
    const entries = await fs.readdir(this.#root, { withFileTypes: true });
    const metas = await Promise.all(
      entries.filter((e) => e.isDirectory()).map((e) => this.get(e.name)),
    );
    return metas.filter(Boolean).sort((a, b) => b.created_at.localeCompare(a.created_at));
  }

  // Bytes stored so far. This is the resume point for an interrupted upload.
  async received(id) {
    try {
      return (await fs.stat(this.videoPath(id))).size;
    } catch (err) {
      if (err.code === 'ENOENT') return 0;
      throw err;
    }
  }

  async create({ id = newId(), size, duration = 0 }) {
    if (!isValidId(id)) throw new HttpError(400, 'id must be 8-64 characters of A-Z, a-z, 0-9, _ or -');
    if (!Number.isSafeInteger(size) || size <= 0) throw new HttpError(400, 'size must be a positive integer');
    if (typeof duration !== 'number' || !Number.isFinite(duration) || duration < 0) {
      throw new HttpError(400, 'duration must be a non-negative number');
    }

    const existing = await this.get(id);
    if (existing) {
      // Lets a client retry a create whose response it never received.
      if (existing.size === size) return { meta: existing, created: false };
      throw new HttpError(409, 'a recording with this id already exists');
    }

    const meta = { id, created_at: new Date().toISOString(), duration, size, status: 'uploading' };
    await fs.mkdir(this.#dir(id), { recursive: true });
    await this.#writeMeta(meta);
    return { meta, created: true };
  }

  // Appends one chunk. The client must send the offset it believes the upload is at;
  // a mismatch returns the real offset so the client can resume from there.
  async append(id, offset, body) {
    if (this.#uploading.has(id)) throw new HttpError(409, 'another upload to this recording is in progress');
    this.#uploading.add(id);
    try {
      const meta = await this.get(id);
      if (!meta) throw new HttpError(404, 'not found');
      if (meta.status !== 'uploading') throw new HttpError(409, 'recording is already complete');

      const current = await this.received(id);
      if (offset !== current) throw new HttpError(409, 'offset mismatch', { offset: current });

      await pipeline(
        body,
        limitBytes(meta.size - current),
        createWriteStream(this.videoPath(id), { flags: 'a' }),
      );
      return await this.received(id);
    } finally {
      this.#uploading.delete(id);
    }
  }

  async complete(id) {
    if (this.#uploading.has(id)) throw new HttpError(409, 'an upload to this recording is in progress');
    const meta = await this.get(id);
    if (!meta) throw new HttpError(404, 'not found');
    if (meta.status === 'ready') return meta;

    const received = await this.received(id);
    if (received !== meta.size) throw new HttpError(409, 'upload is incomplete', { offset: received });

    meta.status = 'ready';
    await this.#writeMeta(meta);
    return meta;
  }

  async remove(id) {
    if (!(await this.get(id))) throw new HttpError(404, 'not found');
    await fs.rm(this.#dir(id), { recursive: true, force: true });
  }

  async #writeMeta(meta) {
    const file = path.join(this.#dir(meta.id), 'meta.json');
    await fs.writeFile(`${file}.tmp`, JSON.stringify(meta, null, 2));
    await fs.rename(`${file}.tmp`, file);
  }
}

function limitBytes(max) {
  let seen = 0;
  return new Transform({
    transform(chunk, _encoding, callback) {
      seen += chunk.length;
      if (seen > max) callback(new HttpError(413, 'upload is larger than the declared size'));
      else callback(null, chunk);
    },
  });
}
