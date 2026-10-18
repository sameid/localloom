#!/usr/bin/env node
import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { Store } from './store.js';
import { createHandler } from './app.js';
import { log } from './log.js';

const env = process.env;
const dataDir = path.resolve(env.LOCALLOOM_DATA_DIR ?? 'data');
const host = env.LOCALLOOM_HOST ?? '0.0.0.0';
const port = Number(env.LOCALLOOM_PORT ?? 8080);
const publicUrl = env.LOCALLOOM_PUBLIC_URL?.trim().replace(/\/+$/, '') || null;

const store = new Store(dataDir);
await store.init();
const token = env.LOCALLOOM_TOKEN?.trim() || (await loadOrCreateToken());

const server = http.createServer(createHandler({ store, token, publicUrl }));
// A 32 MB chunk on a slow home uplink can take minutes, so don't cap the whole request.
// Instead, drop connections that go quiet.
server.requestTimeout = 0;
server.setTimeout(120_000);

server.listen(port, host, () => {
  log('listening', { host, port: server.address().port, data_dir: dataDir, public_url: publicUrl });
  if (!publicUrl) log('LOCALLOOM_PUBLIC_URL is not set; share links will use the address clients connect with');
});

const shutdown = () => {
  log('shutting down');
  server.close(() => process.exit(0));
  server.closeIdleConnections();
  setTimeout(() => process.exit(0), 2000).unref();
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

// The macOS app holds our stdin open; if the app dies, stdin closes and we follow it.
if (env.LOCALLOOM_EXIT_WITH_PARENT === '1') {
  process.stdin.on('end', shutdown);
  process.stdin.resume();
}

async function loadOrCreateToken() {
  const file = path.join(dataDir, 'token');
  try {
    return (await fs.readFile(file, 'utf8')).trim();
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
  }
  const created = randomBytes(32).toString('base64url');
  await fs.writeFile(file, `${created}\n`, { mode: 0o600 });
  log('generated owner token', { file });
  return created;
}
