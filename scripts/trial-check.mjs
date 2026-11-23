#!/usr/bin/env node
/**
 * Uses the trial package the way a customer does, and checks it. Needs Docker and Node 24, and two images, the backend
 * one built with a throwaway vendor key:
 *   LIMS_VERSION=x LIMS_UI_VERSION=y LICENCE_KEY=/path/licence.key LICENCE_TOOL=../LIMS/scripts/licence.mjs node scripts/trial-check.mjs
 * Works in a copy of docker-compose/ under its own project name and removes everything. TRIAL_WORK_DIR: where, if Docker
 * cannot mount the default temp folder.
 */
import { execFileSync } from 'node:child_process';
import { createPrivateKey, randomUUID, sign } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const { LIMS_VERSION, LIMS_UI_VERSION, LICENCE_KEY, LICENCE_TOOL } = process.env;
if (!LIMS_VERSION || !LIMS_UI_VERSION || !LICENCE_KEY || !LICENCE_TOOL) throw new Error('Set LIMS_VERSION, LIMS_UI_VERSION, LICENCE_KEY and LICENCE_TOOL');
const base = process.env.TRIAL_WORK_DIR ?? mkdtempSync(join(tmpdir(), 'trial-'));
const work = join(base, 'trial-check');
const port = process.env.TRIAL_PORT ?? '18080';
const URL_ = `http://localhost:${port}`;
const PASSWORD = 'Trial-Check-12!';
const env = { ...process.env, COMPOSE_PROJECT_NAME: 'lims-trial-check' };
for (const k of ['LIMS_VERSION', 'LIMS_UI_VERSION', 'LICENCE_KEY']) delete env[k];
const run = (cmd, args, opts = {}) => execFileSync(cmd, args, { cwd: work, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 1e8, ...opts });
const dc = (...args) => run('docker', ['compose', ...args]);
const say = (s) => console.log(`\n=== ${s}`);
const ok = (cond, what, detail = '') => {
  if (!cond) throw new Error(`FAIL: ${what} ${detail}`);
  console.log(`ok: ${what}`);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// A restart closes the connections this process kept open; the first request afterwards finds out. Anything else is a failure.
const fetch = (url, opts) => globalThis.fetch(url, opts).catch((e) => (e.cause?.code === 'UND_ERR_SOCKET' ? sleep(500).then(() => globalThis.fetch(url, opts)) : Promise.reject(e)));
const issue = (l) => {
  const body = `LIMS1.${Buffer.from(JSON.stringify({ id: randomUUID(), kind: 'trial', customer: 'Trial check', installation: null, issuedAt: new Date().toISOString(), days: 7, notAfter: new Date(Date.now() + 864e5).toISOString(), graceDays: 0, ...l })).toString('base64url')}`;
  return `${body}.${sign(null, Buffer.from(body), createPrivateKey(readFileSync(LICENCE_KEY))).toString('base64url')}`;
};

let session;
async function call(method, path, body, headers = {}) {
  const res = await fetch(`${URL_}/api/v1${path}`, { method, headers: { 'Content-Type': 'application/json', ...(session ? { cookie: session.cookie, 'X-CSRF-Token': session.csrf } : {}), ...headers }, body: body && JSON.stringify(body) });
  const text = await res.text();
  return { status: res.status, body: text.startsWith('{') || text.startsWith('[') ? JSON.parse(text) : text, res };
}
async function signIn() {
  session = null;
  const r = await call('POST', '/auth/login', { email: 'owner@trial.example', password: PASSWORD });
  if (r.status !== 200) throw new Error(`sign-in ${r.status} ${JSON.stringify(r.body)}`);
  session = { cookie: r.res.headers.getSetCookie()[0].split(';')[0], csrf: r.body.user.csrfToken };
  await call('POST', '/auth/confirm-password', { password: PASSWORD });
  return r;
}
const customer = (name) => call('POST', '/customers', { name, stateName: 'Maharashtra', stateCode: '27' });
const customers = async () => (await call('GET', '/customers?pageSize=100')).body.data.map((c) => c.name).sort();
async function pdf() {
  let d = (await call('POST', '/documents', { kind: 'mis:outstanding-ageing', params: { format: 'pdf' } })).body;
  for (let i = 0; i < 90 && !['DONE', 'FAILED'].includes(d.status); i++) {
    await sleep(1000);
    d = (await call('GET', `/documents/${d.id}`)).body;
  }
  if (d.status !== 'DONE') throw new Error(`document ${JSON.stringify(d)}`);
  return d;
}

mkdirSync(work, { recursive: true });
try {
  cpSync(join(root, 'docker-compose'), work, { recursive: true });
  const first = execFileSync(process.execPath, [LICENCE_TOOL, 'issue', '--key', LICENCE_KEY, '--customer', 'Trial check', '--kind', 'trial', '--days', '7'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  writeFileSync(
    join(work, '.env'),
    readFileSync(join(work, '.env.example'), 'utf8')
      .replace('LIMS_VERSION=', `LIMS_VERSION=${LIMS_VERSION}`)
      .replace('LIMS_UI_VERSION=', `LIMS_UI_VERSION=${LIMS_UI_VERSION}`)
      .replace('LICENCE=', `LICENCE=${first}`)
      .replace(/LIMS_URL=.*/, `LIMS_URL=${URL_}`)
      .replace(/LIMS_PORT=.*/, `LIMS_PORT=${port}`),
  );

  say('One command starts it');
  dc('up', '-d', '--wait');
  ok((await fetch(`${URL_}/health/ready`)).status === 200, 'the app answers at its one address');
  ok((await fetch(`${URL_}/`)).status === 200 && (await (await fetch(`${URL_}/config.js`)).text()).includes(URL_), 'the screens load and call that same address');
  ok((await fetch(`${URL_}/help/`)).status === 200, 'the help site loads');
  ok((await fetch(`${URL_}/api/v1/licence`)).status === 401, 'nothing is open without signing in');

  say('First administrator');
  const setup = (setupToken) => call('POST', '/public/setup', { setupToken, adminEmail: 'owner@trial.example', adminName: 'Owner', adminPassword: PASSWORD });
  ok((await setup('wrong')).status === 403, 'a wrong setup token is refused');
  const token = dc('exec', '-T', 'api', 'cat', '/run/lims/setup-token').trim();
  ok([200, 201].includes((await setup(token)).status), 'the token from the server creates the first administrator');
  ok((await setup(token)).status === 409, 'and only once');
  ok(!dc('logs', '--no-color').includes(token), 'the token is in no log');
  const login = await signIn();
  ok(/HttpOnly/i.test(login.res.headers.getSetCookie()[0]), 'the session cookie is HttpOnly');

  say('Work, files and the licence');
  ok((await call('GET', '/admin/licence')).body.daysLeft === 7, 'the trial from .env is active with 7 days');
  ok((await customer('First')).status === 201, 'work is saved');
  const doc = await pdf();
  ok(doc.url.startsWith(`${URL_}/lims-files/`), 'the PDF’s link is at the one address');
  const file = await fetch(doc.url);
  ok(file.status === 200 && Buffer.from(await file.arrayBuffer()).subarray(0, 5).toString() === '%PDF-', 'the worker made a PDF and the signed link opens it');
  ok((await fetch(doc.url.replace(/Signature=..../, 'Signature=0000'))).status === 403, 'a changed signature is refused');
  ok((await fetch(doc.url.split('?')[0])).status === 403, 'an unsigned file is refused');
  ok((await fetch(`${URL_}/lims-files?list-type=2`)).status === 403, 'files cannot be listed');
  ok((await fetch(doc.url, { method: 'PUT', body: 'x' })).status === 403, 'files cannot be written through the proxy');

  say('Nothing else is reachable');
  const published = JSON.parse(`[${dc('ps', '--format', 'json').trim().split('\n').join(',')}]`).filter((s) => (s.Publishers ?? []).some((p) => p.PublishedPort));
  ok(published.length === 1 && published[0].Service === 'proxy' && published[0].Publishers.every((p) => !p.PublishedPort || p.URL === '127.0.0.1'), 'only the proxy is published, on this machine only');
  ok(dc('exec', '-T', 'api', 'id', '-u').trim() !== '0', 'the app does not run as root');
  let altered = false;
  try {
    dc('exec', '-T', 'postgres', 'sh', '-c', `PGPASSWORD="$(cat /run/lims/app-password)" psql -h 127.0.0.1 -U lims_app -d lims -c 'ALTER TABLE "AuditLog" DISABLE TRIGGER USER'`);
    altered = true;
  } catch {
    // refused, as it should be
  }
  ok(!altered, 'the app’s database role cannot switch off the audit log’s protection');

  say('Restart keeps everything');
  dc('down');
  dc('up', '-d', '--wait');
  await signIn();
  ok((await customers()).join() === 'First', 'the data is still there');

  say('Back up and restore');
  const backup = run('./backup.sh', []).trim().split('\n').pop();
  ok(existsSync(join(work, backup, 'files.tar.gz')), `backed up to ${backup}`);
  await customer('After the backup');
  run('./restore.sh', [backup, '--yes']);
  await signIn();
  ok((await customers()).join() === 'First', 'the restore went back to the backup');
  const again = await fetch((await call('GET', `/documents/${doc.id}`)).body.url);
  ok(again.status === 200 && again.headers.get('content-type') === 'application/pdf' && Buffer.from(await again.arrayBuffer()).subarray(0, 5).toString() === '%PDF-', 'the stored PDF came back, still a PDF');
  ok((await customer('After the restore')).status === 201, 'and work goes on');

  say('The trial ends');
  const short = issue({ notAfter: new Date(Date.now() + 5_000).toISOString() });
  ok((await call('POST', '/admin/licence', { licence: short })).status === 200, 'a licence with seconds left is accepted');
  let refused;
  for (let i = 0; i < 30; i++) {
    await sleep(5000);
    refused = await customer(`Too late ${i}`);
    if (refused.status === 403) break;
  }
  ok(refused.status === 403 && refused.body.error.code === 'READ_ONLY', 'saving is refused by the server');
  ok((await customers()).includes('First'), 'everything is still readable');
  ok((await pdf()).status === 'DONE', 'PDFs and exports still work');
  dc('restart', 'api');
  dc('up', '-d', '--wait');
  await signIn();
  ok((await customer('After a restart')).status === 403, 'restarting, with the first licence still in .env, gives no time back');
  ok((await call('POST', '/admin/licence', { licence: issue({ kind: 'full', days: null }) })).status === 200 && (await customer('Renewed')).status === 201, 'a new licence restores it at once');

  console.log('\nAll checks passed.');
} catch (e) {
  console.error(e.stderr ? `${e.message}\n${e.stderr}` : e);
  try {
    console.error(dc('ps', '-a'));
    console.error(dc('logs', '--no-color', '--tail', '25'));
  } catch {
    // nothing to show
  }
  process.exitCode = 1;
} finally {
  try {
    dc('down', '-v', '--remove-orphans');
    for (const v of run('docker', ['volume', 'ls', '-q', '--filter', 'name=lims-trial-check_']).split('\n').filter(Boolean)) run('docker', ['volume', 'rm', v]);
  } catch (e) {
    console.error(`clean-up: ${e.message}`);
  }
  rmSync(work, { recursive: true, force: true });
}
