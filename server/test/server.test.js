import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Store } from '../src/store.js';
import { createHandler, parseRange } from '../src/app.js';

const TOKEN = 'test-token';
let server;
let dataDir;
let base;

before(async () => {
  dataDir = await fs.mkdtemp(path.join(os.tmpdir(), 'localloom-test-'));
  await fs.writeFile(path.join(dataDir, 'secret.txt'), 'do not serve me');
  const store = new Store(dataDir);
  await store.init();
  server = http.createServer(createHandler({ store, token: TOKEN, publicUrl: 'https://loom.example.com' }));
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  server.close();
  await fs.rm(dataDir, { recursive: true, force: true });
});

const auth = { Authorization: `Bearer ${TOKEN}` };

function api(method, url, { body, headers = {} } = {}) {
  const isJson = body !== undefined && !(body instanceof Uint8Array);
  return fetch(base + url, {
    method,
    headers: { ...auth, ...(isJson && { 'Content-Type': 'application/json' }), ...headers },
    body: isJson ? JSON.stringify(body) : body,
  });
}

async function createRecording(bytes, id) {
  const res = await api('POST', '/api/recordings', { body: { id, size: bytes.length, duration: 3.5 } });
  assert.equal(res.status, 201);
  return res.json();
}

async function upload(id, bytes, offset = 0) {
  return api('PUT', `/api/recordings/${id}/content`, {
    body: bytes,
    headers: { 'Upload-Offset': String(offset), 'Content-Type': 'application/octet-stream' },
  });
}

test('health check and home page do not reveal recordings', async () => {
  assert.equal(await (await fetch(`${base}/healthz`)).text(), 'ok');
  const home = await fetch(`${base}/`);
  assert.equal(home.status, 200);
  assert.equal(home.redirected, false);
});

test('API requires the owner token', async () => {
  assert.equal((await fetch(`${base}/api/recordings`)).status, 401);
  assert.equal((await fetch(`${base}/api/recordings`, { headers: { Authorization: 'Bearer nope' } })).status, 401);
  assert.equal((await api('GET', '/api/recordings')).status, 200);
});

test('encoded slashes and dot segments cannot escape the data directory', async () => {
  for (const url of [
    '/media/..%2Fsecret.txt',
    '/media/..%2F..%2Fsecret.txt',
    '/media/%2e%2e%2F%2e%2e%2Fsecret',
    '/v/..%2F..%2Fsecret.txt',
    '/media/../secret.txt',
  ]) {
    const res = await fetch(base + url);
    assert.equal(res.status, 404, url);
    assert.doesNotMatch(await res.text(), /do not serve me/, url);
  }
  const res = await api('GET', '/api/recordings/..%2F..%2Fsecret.txt');
  assert.equal(res.status, 404);
});

test('chunked upload, resume after offset mismatch, then playback with ranges', async () => {
  const bytes = new Uint8Array(1000).map((_, i) => i % 251);
  const created = await createRecording(bytes);
  assert.equal(created.status, 'uploading');
  assert.equal(created.offset, 0);
  assert.equal(created.id.length, 22);
  assert.equal(created.share_url, `https://loom.example.com/v/${created.id}`);

  // Not watchable until complete.
  assert.match(await (await fetch(`${base}/v/${created.id}`)).text(), /still uploading/);
  assert.equal((await fetch(`${base}/media/${created.id}.mp4`)).status, 404);

  assert.deepEqual(await (await upload(created.id, bytes.slice(0, 400))).json(), { offset: 400 });

  // A client that lost track of progress learns the real offset from the 409.
  const mismatch = await upload(created.id, bytes.slice(0, 400), 0);
  assert.equal(mismatch.status, 409);
  assert.equal((await mismatch.json()).offset, 400);

  const early = await api('POST', `/api/recordings/${created.id}/complete`);
  assert.equal(early.status, 409);

  assert.deepEqual(await (await upload(created.id, bytes.slice(400), 400)).json(), { offset: 1000 });
  const done = await (await api('POST', `/api/recordings/${created.id}/complete`)).json();
  assert.equal(done.status, 'ready');

  const page = await fetch(`${base}/v/${created.id}`);
  assert.match(await page.text(), new RegExp(`/media/${created.id}\\.mp4`));
  assert.match(page.headers.get('content-security-policy'), /default-src 'none'/);

  const full = await fetch(`${base}/media/${created.id}.mp4`);
  assert.equal(full.status, 200);
  assert.deepEqual(new Uint8Array(await full.arrayBuffer()), bytes);

  const partial = await fetch(`${base}/media/${created.id}.mp4`, { headers: { Range: 'bytes=100-199' } });
  assert.equal(partial.status, 206);
  assert.equal(partial.headers.get('content-range'), 'bytes 100-199/1000');
  assert.deepEqual(new Uint8Array(await partial.arrayBuffer()), bytes.slice(100, 200));

  const tail = await fetch(`${base}/media/${created.id}.mp4`, { headers: { Range: 'bytes=-10' } });
  assert.deepEqual(new Uint8Array(await tail.arrayBuffer()), bytes.slice(990));

  const bad = await fetch(`${base}/media/${created.id}.mp4`, { headers: { Range: 'bytes=5000-' } });
  assert.equal(bad.status, 416);
});

test('uploads larger than the declared size are rejected', async () => {
  const created = await createRecording(new Uint8Array(10));
  const res = await upload(created.id, new Uint8Array(20));
  assert.equal(res.status, 413);
  const meta = await (await api('GET', `/api/recordings/${created.id}`)).json();
  assert.ok(meta.offset <= 10);
});

test('create is idempotent for retries and keeps client-chosen legacy IDs', async () => {
  const bytes = new Uint8Array(5);
  const first = await createRecording(bytes, 'a1b2c3d4');
  assert.equal(first.id, 'a1b2c3d4');
  const retry = await api('POST', '/api/recordings', { body: { id: 'a1b2c3d4', size: 5 } });
  assert.equal(retry.status, 200);
  const clash = await api('POST', '/api/recordings', { body: { id: 'a1b2c3d4', size: 6 } });
  assert.equal(clash.status, 409);
  const invalid = await api('POST', '/api/recordings', { body: { id: '../etc', size: 6 } });
  assert.equal(invalid.status, 400);
});

test('delete removes the recording and its share link', async () => {
  const bytes = new Uint8Array(3);
  const { id } = await createRecording(bytes);
  await upload(id, bytes);
  await api('POST', `/api/recordings/${id}/complete`);
  assert.equal((await api('DELETE', `/api/recordings/${id}`)).status, 204);
  assert.equal((await fetch(`${base}/v/${id}`)).status, 404);
  assert.equal((await api('GET', `/api/recordings/${id}`)).status, 404);
});

test('list returns newest first with share URLs', async () => {
  const { recordings } = await (await api('GET', '/api/recordings')).json();
  assert.ok(recordings.length >= 2);
  assert.ok(recordings.every((r) => r.share_url.startsWith('https://loom.example.com/v/')));
  const dates = recordings.map((r) => r.created_at);
  assert.deepEqual(dates, [...dates].sort().reverse());
});

test('parseRange', () => {
  assert.deepEqual(parseRange('bytes=0-', 10), { start: 0, end: 9 });
  assert.deepEqual(parseRange('bytes=5-100', 10), { start: 5, end: 9 });
  assert.deepEqual(parseRange('bytes=-3', 10), { start: 7, end: 9 });
  assert.equal(parseRange('bytes=0-1,4-5', 10), null);
  assert.equal(parseRange('bytes=10-', 10), 'unsatisfiable');
  assert.equal(parseRange('bytes=-0', 10), 'unsatisfiable');
  assert.equal(parseRange('bytes=6-2', 10), 'unsatisfiable');
});
