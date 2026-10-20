#!/usr/bin/env node
// typecheck-snippets.mjs -- type-check every ```ts block in the plugin's markdown against the installed @onkernel/sdk.
//   cd lab && npm install && node ../scripts/typecheck-snippets.mjs [--all] [files...]
// Each block becomes its own module (imports hoisted; `const kernel = new Kernel()` and common imports added when missing).
// "Cannot find name" errors are ignored (snippets are fragments that use helpers like askUser); everything else is reported,
// so wrong method names, wrong params and wrong shapes fail. Blocks whose first line contains "novalidate" are skipped.
// --all also reports "Cannot find name" errors.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '..');
// a fresh directory under the cwd (so node_modules resolves from the cwd); only this directory is ever removed
const work = mkdtempSync(resolve(process.cwd(), '.snippet-check-'));
process.on('exit', () => rmSync(work, { recursive: true, force: true })); // every exit path, including a read error below
const args = process.argv.slice(2);
const all = args.includes('--all');
const fileArgs = args.filter((a) => !a.startsWith('--'));

function walk(dir, out = []) {
  for (const n of readdirSync(dir)) {
    const p = join(dir, n);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (n.endsWith('.md')) out.push(p);
  }
  return out;
}
const files = fileArgs.length ? fileArgs.map((f) => resolve(f)) : walk(join(repo, 'plugins/kernel/skills'));

const map = new Map(); // generated file -> { md, line }
let n = 0;
for (const f of files) {
  const lines = readFileSync(f, 'utf8').split('\n');
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^```(ts|tsx|typescript)\s*$/);
    if (!m) continue;
    const start = i + 1;
    const body = [];
    for (i = i + 1; i < lines.length && !lines[i].startsWith('```'); i++) body.push(lines[i]);
    if (body.length && /novalidate/.test(body[0])) continue;
    if (m[1] === 'tsx') continue; // React/JSX fragments are not checked here
    const tagged = body.map((text, k) => ({ text, md: start + k }));
    const imports = tagged.filter((l) => /^import\s/.test(l.text));
    const rest = tagged.filter((l) => !/^import\s/.test(l.text));
    const joined = body.join('\n');
    const pre = [];
    if (!imports.some((l) => /from ['"]@onkernel\/sdk['"]/.test(l.text))) pre.push({ text: "import Kernel from '@onkernel/sdk';", md: 0 });
    if (!imports.some((l) => /playwright-core/.test(l.text)) && /\bchromium\b/.test(joined)) pre.push({ text: "import { chromium } from 'playwright-core';", md: 0 });
    if (!/\b(const|let|var)\s+kernel\b/.test(joined)) pre.push({ text: 'const kernel = new Kernel();', md: 0 });
    const name = `s${String(++n).padStart(3, '0')}.ts`;
    const all_ = [...imports, ...pre, ...rest, { text: 'export {};', md: 0 }];
    writeFileSync(join(work, name), all_.map((l) => l.text).join('\n') + '\n');
    map.set(name, { md: relative(repo, f), lines: all_.map((l) => l.md) });
  }
}
writeFileSync(join(work, 'tsconfig.json'), JSON.stringify({
  compilerOptions: { target: 'es2022', module: 'esnext', moduleResolution: 'bundler', strict: true, noEmit: true, skipLibCheck: true, types: ['node'], lib: ['es2023'], noImplicitAny: false, noUnusedLocals: false },
  include: ['*.ts'],
}));
let out = '';
let failed = false;
try {
  execFileSync('npx', ['--no-install', 'tsc', '-p', join(work, 'tsconfig.json'), '--pretty', 'false'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
} catch (e) {
  failed = true;
  out = String(e.stdout || '') + String(e.stderr || '');
}
if (failed && !/error TS\d+/.test(out)) {
  // tsc did not run to a diagnostic (missing typescript, bad config, killed): that is a failure, not a pass
  console.log(`typecheck-snippets: tsc failed without a TypeScript diagnostic:\n${out.slice(0, 600)}`);
  rmSync(work, { recursive: true, force: true });
  process.exit(1);
}
const IGNORE = all ? [] : ['TS2304', 'TS2552', 'TS2584', 'TS2503', 'TS18004', 'TS2307', 'TS1108'];
let bad = 0;
for (const l of out.split('\n')) {
  const m = l.match(/^(?:.*[\\/])?(s\d+\.ts)\((\d+),(\d+)\): error (TS\d+): (.*)$/);
  if (!m) { if (/error TS/.test(l)) { console.log(l); bad++; } continue; }
  const [, f, line, , code, msg] = m;
  // an unresolved module is ignored for optional packages, never for the SDK this check exists to verify
  if (IGNORE.includes(code) && !(code === 'TS2307' && /@onkernel\/sdk/.test(msg))) continue;
  const info = map.get(f);
  const mdLine = info ? info.lines[Number(line) - 1] : '?';
  console.log(`${info ? info.md : f}:${mdLine}: ${code} ${msg}`);
  bad++;
}
console.log(`typecheck-snippets: ${n} snippets from ${files.length} files, ${bad} type error(s)${all ? '' : ' (undefined-name errors ignored)'}`);
rmSync(work, { recursive: true, force: true });
process.exit(bad ? 1 : 0);
