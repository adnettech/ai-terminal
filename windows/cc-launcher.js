#!/usr/bin/env node
// cc — Claude Code workspace launcher for Windows. Installed by windows/ccinstall.ps1 as
// %USERPROFILE%\.local\bin\cc-launcher.js; cc.cmd runs it.
//
// A small menu over %USERPROFILE%\Projects so every session starts in the right folder with
// the right CLAUDE.md loaded, and so getting back to earlier work never needs cd or claude's
// flags. The generic half of the Ubuntu fleet launcher (templates/cc-launcher.sh in the
// platform layer), without the engagement/fleet entries:
//
//   <project>    any folder under Projects (major work; create one from the menu)
//   os-changes   THIS machine: settings, troubleshooting, local system work
//   misc         small research & everything else (one subfolder per topic)
//
// Session recall & hygiene:
//   - "↩ Pick up where you left off": recent sessions across every workspace (last
//     CC_RECALL_DAYS days, default 5) as cards: gist, exchanges, duration, context fill.
//   - context >= CC_CTX_FULL (85) shows red as FULL and steers to "⚑ Wrap up & hand off",
//     which resumes the session with a prompt that has Claude write HANDOFF.md; the next
//     visit to that folder offers "⇥ New session from hand-off".
//   - a one-time 3-screen tour on the first run; ? shows help on any screen.
//
// Keys: arrows/j/k + Enter, 1-9 jump, Esc back, ? help, q quit. Without a console (pipes,
// tests) it falls back to a numbered prompt. `cc <folder>` skips the menu; other arguments
// pass through to claude. CC_LAUNCHER_DRYRUN=1 prints the claude command instead of running it.
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const cp = require('child_process');
const readline = require('readline');

const HOME = os.homedir();
const PROJECTS = path.join(HOME, 'Projects');
const STATE = path.join(HOME, '.local', 'state', 'cc-launcher');
const SESSIONS = path.join(HOME, '.claude', 'projects');
const WIN_CACHE = path.join(STATE, 'model-windows.json');   // written by cc-statusline.js
const TOUR_MARK = path.join(STATE, 'tour-done');
const CLAUDE = (() => {
    const p = path.join(HOME, '.local', 'bin', process.platform === 'win32' ? 'claude.exe' : 'claude');
    return fs.existsSync(p) ? p : 'claude';
})();
const CLAUDE_ARGS = ['--dangerously-skip-permissions'];
const RECALL_DAYS = parseInt(process.env.CC_RECALL_DAYS || '5', 10);
const CTX_NUDGE = parseInt(process.env.CC_CTX_NUDGE || '80', 10);
const CTX_FULL = parseInt(process.env.CC_CTX_FULL || '85', 10);

const WRAPUP_PROMPT = "This session's context is nearly full, so let's wrap up. Write a hand-off into HANDOFF.md in this folder (create or overwrite it): what we are working on, what is done, what is in progress, the exact next steps, and the key files, decisions and gotchas a fresh session needs. If CLAUDE.md's \"What this is\" is stale, update it too. Be complete but concise. When finished, tell me to close this session and start a new one from the launcher — it will offer \"New session from hand-off\".";
const HANDOFF_PROMPT = 'Read HANDOFF.md in this folder and continue the work from where the previous session left off. Summarize the plan in one short paragraph and then get going.';

fs.mkdirSync(PROJECTS, { recursive: true });

// ── UI toolkit ─────────────────────────────────────────────────────────────────
const FANCY = Boolean(process.stdin.isTTY && process.stdout.isTTY);
const E = (s) => (FANCY ? s : '');
const C0 = E('\x1b[0m'), DIM = E('\x1b[2m'), BOLD = E('\x1b[1m'), ACC = E('\x1b[36m');
const WARN = E('\x1b[33m'), RED = E('\x1b[31m'), INV = E('\x1b[7m');
const cols = () => process.stdout.columns || 100;
const out = (s) => process.stdout.write(s);
const HOST = os.hostname().split('.')[0] || 'terminal';

let uiOpen = false;
function ui_open() { if (FANCY && !uiOpen) { out('\x1b[?1049h\x1b[?25l'); uiOpen = true; } }
function ui_close() { if (uiOpen) { out('\x1b[?25h\x1b[?1049l'); uiOpen = false; } }
process.on('exit', () => { ui_close(); });

// every line ends in \x1b[K: a redraw paints over the previous frame, no clear, no flicker
function header(sub) {
    return `\x1b[K\n  ${BOLD}${ACC}CLAUDE CODE TERMINAL${C0}  ${DIM}${HOST}${sub ? ' · ' + sub : ''}${C0}\x1b[K\n`
         + `  ${DIM}${'─'.repeat(cols() > 78 ? 74 : Math.max(10, cols() - 4))}${C0}\x1b[K\n\x1b[K\n`;
}
function textPage(sub, body, footer) {
    out('\x1b[H\x1b[J' + header(sub) + body.split('\n').map((l) => `  ${l}\x1b[K\n`).join('')
        + `\n  ${DIM}${footer}${C0}\x1b[K\n`);
}

// raw keys: one queue, split so a pasted burst or an arrow sequence is one key each
let keysOn = false, keyQueue = [], keyWaiter = null;
function splitKeys(d) {
    const ks = [];
    for (let i = 0; i < d.length;) {
        if (d[i] === '\x1b' && (d[i + 1] === '[' || d[i + 1] === 'O')) {
            let j = i + 2;
            while (j < d.length && !/[A-Za-z~]/.test(d[j])) j++;
            ks.push(d.slice(i, j + 1)); i = j + 1;
        } else { ks.push(d[i]); i++; }
    }
    return ks;
}
function keysStart() {
    if (keysOn) return;
    keysOn = true;
    process.stdin.setRawMode(true);
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (d) => {
        for (const k of splitKeys(d)) {
            if (keyWaiter) { const w = keyWaiter; keyWaiter = null; w(k); } else keyQueue.push(k);
        }
    });
    process.stdin.resume();
}
function keysStop() {
    if (!keysOn) return;
    keysOn = false;
    process.stdin.removeAllListeners('data');
    process.stdin.setRawMode(false);
    process.stdin.pause();
    keyQueue = [];
}
function readKey() {
    return new Promise((r) => { if (keyQueue.length) r(keyQueue.shift()); else keyWaiter = r; });
}

// line input, in both modes (cursor shown while typing in fancy mode)
let plainRl = null;
function plainLines() {
    if (!plainRl) {
        plainRl = readline.createInterface({ input: process.stdin, terminal: false });
        plainRl.buffered = []; plainRl.waiter = null; plainRl.ended = false;
        plainRl.on('line', (l) => { if (plainRl.waiter) { const w = plainRl.waiter; plainRl.waiter = null; w(l); } else plainRl.buffered.push(l); });
        plainRl.on('close', () => { plainRl.ended = true; if (plainRl.waiter) { const w = plainRl.waiter; plainRl.waiter = null; w(null); } });
    }
    return plainRl;
}
async function ask(prompt) {
    if (!FANCY) {
        out(prompt + ' ');
        const rl = plainLines();
        if (rl.buffered.length) return rl.buffered.shift();
        if (rl.ended) return null;
        return new Promise((r) => { rl.waiter = r; });
    }
    const was = keysOn; keysStop();
    if (uiOpen) out('\x1b[?25h');
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    const ans = await new Promise((r) => rl.question(`  ${BOLD}${prompt}${C0} `, r));
    rl.close();
    if (uiOpen) out('\x1b[?25l');
    if (was) keysStart();
    return ans;
}

// pick(menu, subtitle, plainPrompt, {hint, help}) -> {rc: 0 picked | 1 quit | 2 back, i}
// menu rows: {path, name, desc, meta (newline-joined card lines), warn}
async function pick(menu, sub, plainPrompt, opt = {}) {
    if (!FANCY) {
        out((plainPrompt || 'Where are you working?') + '\n');
        menu.forEach((m, i) => {
            out(`  ${i + 1}) ${m.name.padEnd(22)} ${m.desc}\n`);
            if (m.meta) m.meta.split('\n').forEach((l) => out(`      ${l}\n`));
        });
        const k = await ask('>');
        const n = parseInt(k, 10);
        if (k === null || !/^\d+$/.test(String(k).trim()) || n < 1 || n > menu.length) { out('Invalid choice.\n'); return { rc: 1 }; }
        return { rc: 0, i: n - 1 };
    }
    ui_open(); keysStart();
    let cur = 0;
    for (;;) {
        let f = '\x1b[H' + header(sub);
        menu.forEach((m, i) => {
            const num = String(i + 1).padStart(2);
            let desc = m.desc || '';
            // truncate BEFORE styling: cutting a styled string can lose the reset code
            const dmax = Math.max(10, cols() - 36);
            if (desc.length > dmax) desc = desc.slice(0, dmax - 1) + '…';
            if (i === cur) f += `  ${ACC}▸ ${INV}${num}  ${m.name.padEnd(24)} ${desc} ${C0}\x1b[K\n`;
            else f += `    ${num}  ${BOLD}${m.name.padEnd(24)}${C0} ${m.warn ? RED : DIM}${desc}${C0}\x1b[K\n`;
            if (m.meta) {
                for (let ml of m.meta.split('\n')) {
                    if (ml.length > cols() - 12) ml = ml.slice(0, cols() - 13) + '…';
                    const mc = ml.startsWith('⚠') ? RED : DIM;
                    f += i === cur ? `  ${ACC}▍${C0}     ${mc}${ml}${C0}\x1b[K\n` : `        ${mc}${ml}${C0}\x1b[K\n`;
                }
                f += '\x1b[K\n';
            }
        });
        if (opt.hint) f += `\x1b[K\n  ${DIM}${opt.hint}${C0}\x1b[K\n`;
        f += `\x1b[K\n  ${DIM}↑↓ move · Enter open · 1-9 jump · Esc back${opt.help ? ' · ? help' : ''} · q quit${C0}\x1b[K\n\x1b[J`;
        out(f);
        const k = await readKey();
        if (k === '\x1b[A' || k === '\x1bOA' || k === 'k') cur = cur > 0 ? cur - 1 : menu.length - 1;
        else if (k === '\x1b[B' || k === '\x1bOB' || k === 'j') cur = cur < menu.length - 1 ? cur + 1 : 0;
        else if (k === '\x1b') return { rc: 2 };
        else if (k === '\r' || k === '\n') return { rc: 0, i: cur };
        else if (k === 'q' || k === 'Q' || k === '\x03') { ui_close(); return { rc: 1 }; }
        else if (k === '?' && opt.help) { textPage('help', opt.help, 'Press any key to go back'); await readKey(); out('\x1b[H\x1b[J'); }
        else if (/^[1-9]$/.test(k) && +k <= menu.length) return { rc: 0, i: +k - 1 };
    }
}

// ── first-run tour: 30 seconds, once ─────────────────────────────────────────────
async function showTour() {
    if (!FANCY || fs.existsSync(TOUR_MARK)) return;
    ui_open(); keysStart();
    const pages = [
`WORKSPACES                                            (1 of 3)

Your work lives in folders under Projects, and this menu lists them.

  projects         anything big enough for its own folder
  misc             small research & one-off questions
  os-changes       fixes and settings on THIS machine

Claude reads a folder's CLAUDE.md when it starts there — so starting
in the right folder means Claude already knows the right things.`,
`SESSIONS                                              (2 of 3)

Every conversation with Claude is a session, saved with its folder.
Closing the window loses nothing. To get back to one:

  ↩ Pick up where you left off    your recent sessions, newest first
  ↩ Continue the last session     same conversation, same memory
  ☰ Pick an earlier session       that folder's full history

Starting a new session gives Claude a clean slate in that folder.`,
`CONTEXT — Claude's working memory                     (3 of 3)

Each session has a limited working memory, called context. The bar at
the bottom of Claude shows how full it is; so do the cards here.

When a session shows red ⚠ FULL, don't keep working in it:

  1. ⚑ Wrap up & hand off — Claude writes the state to HANDOFF.md
  2. ⇥ New session from hand-off — a fresh session picks it right up

That's the whole habit. The launcher will point the way.`];
    for (const p of pages) {
        textPage('welcome — a 30-second tour', p, 'Press any key to continue…');
        if ((await readKey()) === '\x03') break;
    }
    out('\x1b[H\x1b[J');
    try { fs.mkdirSync(STATE, { recursive: true }); fs.writeFileSync(TOUR_MARK, ''); } catch { /* shown again next time */ }
}

// ── session recall ───────────────────────────────────────────────────────────────
// Claude Code keys sessions by the folder they ran in, every non-alphanumeric character
// turned into '-' (C:\Users\me\Projects\x -> C--Users-me-Projects-x). Drive-letter case
// can differ between shells, so match the folder name case-insensitively.
let sessIndex = null;
function sessDir(dir) {
    if (!sessIndex) {
        sessIndex = new Map();
        try { for (const n of fs.readdirSync(SESSIONS)) sessIndex.set(n.toLowerCase(), n); } catch { /* none yet */ }
    }
    const n = sessIndex.get(dir.replace(/[^A-Za-z0-9]/g, '-').toLowerCase());
    return n ? path.join(SESSIONS, n) : null;
}
function sessionFiles(dir) {   // [{file, mtime}] newest first
    const d = sessDir(dir);
    if (!d) return [];
    try {
        return fs.readdirSync(d).filter((f) => f.endsWith('.jsonl'))
            .map((f) => { const file = path.join(d, f); return { file, mtime: fs.statSync(file).mtimeMs }; })
            .sort((a, b) => b.mtime - a.mtime);
    } catch { return []; }
}
const lastSession = (dir) => (sessionFiles(dir)[0] || {}).file || '';

const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
function ageOf(file) {
    let t;
    try { t = fs.statSync(file).mtime; } catch { return '?'; }
    const hm = `${String(t.getHours()).padStart(2, '0')}:${String(t.getMinutes()).padStart(2, '0')}`;
    const day = (d) => d.toDateString();
    const y = new Date(); y.setDate(y.getDate() - 1);
    if (day(t) === day(new Date())) return `today ${hm}`;
    if (day(t) === day(y)) return `yesterday ${hm}`;
    return `${MON[t.getMonth()]} ${String(t.getDate()).padStart(2, '0')}`;
}

// Context window for a model id, learned rather than guessed: transcripts record the model
// and its usage but not the window. cc-statusline.js caches what Claude Code reports for
// the running model. Unknown -> no percentage at all: a guessed denominator would read 5x
// high on a 1M model and flag every folder FULL.
function windowFor(model) {
    if (process.env.CC_CONTEXT_WINDOW) return parseInt(process.env.CC_CONTEXT_WINDOW, 10);
    try { return JSON.parse(fs.readFileSync(WIN_CACHE, 'utf8'))[model || ''] || null; } catch { return null; }
}

// {ctx, msgs, mins, gist} for one transcript; ctx/mins null when unknown
function sessMeta(file) {
    let gist = '', msgs = 0, first = null, last = null, usage = null, model = '';
    try {
        const buf = fs.readFileSync(file, 'utf8');
        const lines = buf.split('\n');
        for (let i = 0; i < Math.min(120, lines.length); i++) {
            let d; try { d = JSON.parse(lines[i]); } catch { continue; }
            if (d.type === 'summary' && d.summary && !gist) gist = d.summary;
            if ((d.type === 'user' || d.type === 'assistant') && !first) first = d.timestamp;
            if (d.type === 'user' && !gist) {
                let c = (d.message || {}).content;
                if (Array.isArray(c)) c = c.filter((x) => x && x.type === 'text').map((x) => x.text || '').join(' ');
                if (typeof c === 'string') { const s = c.split(/\s+/).join(' ').trim(); if (s && !s.startsWith('<')) gist = s; }
            }
        }
        const tail = buf.length > 262144 ? buf.slice(buf.indexOf('\n', buf.length - 262144) + 1) : buf;
        for (const line of tail.split('\n')) {
            let d; try { d = JSON.parse(line); } catch { continue; }
            if ((d.type === 'user' || d.type === 'assistant') && d.timestamp) last = d.timestamp;
            if (d.type === 'assistant') {
                const m = d.message || {};
                if (m.usage && m.usage.input_tokens != null) { usage = m.usage; model = m.model || model; }
            }
        }
        for (const line of lines) if (line.includes('"type":"user"') || line.includes('"type":"assistant"')) msgs++;
    } catch { /* unreadable: report what we have */ }
    let ctx = null;
    if (usage) {
        const used = (usage.input_tokens || 0) + (usage.cache_read_input_tokens || 0) + (usage.cache_creation_input_tokens || 0);
        const win = windowFor(model);
        if (win) ctx = Math.max(0, Math.min(100, Math.floor(used * 100 / win)));
    }
    let mins = null;
    const a = Date.parse(first), b = Date.parse(last);
    if (!isNaN(a) && !isNaN(b)) mins = Math.max(1, Math.floor((b - a) / 60000));
    return { ctx, msgs, mins, gist: (gist || '(no summary)').replace(/[|\t]/g, ' ').slice(0, 64) };
}

const fmtDur = (m) => (m == null ? '' : m >= 60 ? `${Math.floor(m / 60)}h ${String(m % 60).padStart(2, '0')}m` : `${m}m`);
function card(sm) {   // -> {meta, warn}
    let l3 = `${sm.msgs} exchanges`;
    const dur = fmtDur(sm.mins);
    if (dur) l3 += ` · ${dur}`;
    let warn = false;
    if (sm.ctx != null) {
        if (sm.ctx >= CTX_FULL) { warn = true; l3 += `\n⚠ context ${sm.ctx}% — FULL: wrap up & hand off, don't build here`; }
        else l3 += ` · context ${sm.ctx}% used`;
    }
    return { meta: `"${sm.gist}"\n${l3}`, warn };
}
function sessLine(file) {
    const sm = sessMeta(file);
    return `"${sm.gist}" · ${ageOf(file)}${sm.ctx != null ? ` · context ${sm.ctx}%` : ''}`;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function ctxNudge(pct) {
    out(`\n  ${WARN}⚠ That session's context is ${pct}% used.${C0} Good hygiene: have Claude write\n`
      + '    the state down — what\'s done, what\'s next, where things live — into the\n'
      + '    project docs, then start a fresh session. ("Wrap up & hand off" in the\n'
      + '    launcher does exactly this.)\n\n');
    await sleep(2000);
}

// ── stamps ───────────────────────────────────────────────────────────────────────
const today = () => new Date().toISOString().slice(0, 10);
function ensureOsChanges() {
    const d = path.join(PROJECTS, 'os-changes');
    fs.mkdirSync(d, { recursive: true });
    const readme = path.join(d, 'README.md'), cmd = path.join(d, 'CLAUDE.md');
    if (!fs.existsSync(readme)) fs.writeFileSync(readme,
`# OS Changes — ${HOST}

Local-system change log for this machine. LOCAL ONLY — keep it out of git.
Newest first. Every entry needs enough detail to undo it.

| Date | Category | Summary | Details |
|------|----------|---------|---------|
| ${today()} | Project | Initial setup of os-changes tracking | Created this file. |
`);
    if (!fs.existsSync(cmd)) fs.writeFileSync(cmd,
`# CLAUDE.md — os-changes (this machine)

You are working on THIS machine's local system: settings, installed software,
troubleshooting, preferences. Project work lives in its own folder under Projects.

- **Log every OS-level change** as a new top row in README.md's table
  (Date | Category | Summary | Details). Details must include how to undo it.
- This folder is LOCAL ONLY: no git, no GitHub.
- Never write secrets into files; verify changes; report results in plain language.
`);
}
function stampProject(dir, misc) {
    fs.writeFileSync(path.join(dir, 'CLAUDE.md'),
`# CLAUDE.md — ${path.basename(dir)} (${misc ? 'misc project' : 'project'})

Started ${today()}.${misc ? ' LOCAL ONLY unless deliberately promoted to a repo.' : ''}

- First session: ask what this project is for and record it here under
  "## What this is" — every later session reads it.
- Never commit secrets; report results in plain language.
- Session hygiene: when a session's context is getting full (watch the status
  bar), have Claude record durable state here — what's done, what's next,
  where things live — then start a fresh session. The launcher's "Wrap up &
  hand off" writes HANDOFF.md for exactly this.
${misc ? '- If this grows into real, lasting work, give it its own folder under Projects.' : '- Small one-off research belongs in misc/, not here.'}

## What this is
_(to be filled in during the first working session)_
`);
}

async function newProjectScreen(kind) {   // -> {target, msg} or null when cancelled
    if (uiOpen) {
        out('\x1b[H\x1b[J' + header('new project'));
        out(kind === 'major'
            ? `  Major work gets its own folder under Projects.\n  ${DIM}Small research belongs in misc — back out and pick misc for that.${C0}\n\n`
            : '  A small research folder under misc/.\n\n');
    }
    const name = String((await ask('Project name (Enter to cancel):')) || '')
        .toLowerCase().replace(/ /g, '-').replace(/[^a-z0-9-]/g, '');
    if (!name) return null;
    if (kind === 'major' && (name === 'os-changes' || name === 'misc')) return null;
    const target = kind === 'major' ? path.join(PROJECTS, name) : path.join(PROJECTS, 'misc', name);
    if (fs.existsSync(target)) return { target, msg: `${name} already exists — opening it.` };
    fs.mkdirSync(target, { recursive: true });
    stampProject(target, kind !== 'major');
    return { target, msg: `Created ${path.relative(PROJECTS, target)} (under Projects)` };
}

// ── menus ────────────────────────────────────────────────────────────────────────
const subdirs = (d) => {
    try {
        return fs.readdirSync(d, { withFileTypes: true }).filter((e) => e.isDirectory() && !e.name.startsWith('.'))
            .map((e) => path.join(d, e.name)).sort((a, b) => a.localeCompare(b));
    } catch { return []; }
};
const ALL_DIRS = subdirs(PROJECTS);
const PROJ_DIRS = ALL_DIRS.filter((d) => !['os-changes', 'misc'].includes(path.basename(d)));

// recent sessions across every workspace (+ misc subprojects), newest first, capped at 8
function buildRecall() {
    const cutoff = Date.now() - RECALL_DAYS * 86400000;
    const rows = [];
    for (const d of [...ALL_DIRS, ...subdirs(path.join(PROJECTS, 'misc'))]) {
        for (const s of sessionFiles(d)) if (s.mtime >= cutoff) rows.push({ dir: d, file: s.file, mtime: s.mtime });
    }
    return rows.sort((a, b) => b.mtime - a.mtime).slice(0, 8);
}
const RECALL = buildRecall();

function mainMenu() {
    const m = [];
    if (RECALL.length) {
        m.push({ path: '@recall', name: '↩ Pick up where you left off',
                 desc: `${RECALL.length} recent session${RECALL.length > 1 ? 's' : ''} · newest: ${path.basename(RECALL[0].dir)} · ${ageOf(RECALL[0].file)}` });
    }
    for (const d of PROJ_DIRS) m.push({ path: d, name: path.basename(d), desc: 'project' });
    m.push({ path: path.join(PROJECTS, 'os-changes'), name: 'os-changes', desc: 'this machine: settings & troubleshooting' });
    m.push({ path: path.join(PROJECTS, 'misc'), name: 'misc', desc: 'small research & everything else' });
    m.push({ path: '@newproject', name: '+ New project…', desc: 'major project at Projects\\<name> (small research goes in misc)' });
    // red-flag folders whose newest session is FULL: the wrap-up habit starts here
    for (const row of m) {
        if (row.path.startsWith('@')) continue;
        const f = lastSession(row.path);
        if (!f) continue;
        const sm = sessMeta(f);
        if (sm.ctx != null && sm.ctx >= CTX_FULL) { row.desc += ' · ⚠ full session — wrap up'; row.warn = true; }
    }
    return m;
}

const MAIN_HELP = `This menu is where every Claude session starts.

Pick a folder to work in — Claude reads that folder's CLAUDE.md and
knows the right project. "Pick up where you left off" lists your
recent conversations so you can continue one.

  + New project…   makes a folder for major work
  misc             small research and one-off questions
  os-changes       settings and fixes on this machine itself

A red "⚠ full session" flag means that folder's last conversation ran
its working memory out — open the folder and pick "Wrap up & hand off".`;
const RECALL_HELP = `Each card is one saved conversation (a "session").

  "…" line        what the conversation was about
  exchanges        how many back-and-forths it holds
  context          how full that conversation's working memory is

A red ⚠ FULL session can't take in much more. Reopen it only to save
its state: "Wrap up & hand off" has Claude write HANDOFF.md, and a
fresh session then picks up from that file with a clean memory.`;
const SESSION_HELP = `  ↩ Continue the last session   reopen the same conversation, same memory
  ⊕ Start a new session         clean slate here (CLAUDE.md still loads)
  ⇥ New session from hand-off   clean slate that first reads HANDOFF.md
  ☰ Pick an earlier session     this folder's full history
  ⚑ Wrap up & hand off          Claude saves state to HANDOFF.md so a
                                fresh session can take over

Rule of thumb: continue while context is healthy; once it runs red,
wrap up and start fresh from the hand-off.`;

// ── launch ───────────────────────────────────────────────────────────────────────
async function launch(target, mode, extra, o = {}) {
    ui_close(); keysStop();
    if (plainRl) plainRl.close();
    if (o.msg) out(o.msg + '\n');
    if (path.basename(target) === 'os-changes') ensureOsChanges();
    const name = path.basename(target);
    let args = [...CLAUDE_ARGS];
    switch (mode) {
        case 'resume-id': out(`→ ${name} — continuing your session\n`); args.push('--resume', o.id, ...extra); break;
        case 'wrapup-id': out(`→ ${name} — wrapping up the session (Claude writes HANDOFF.md)\n`); args.push('--resume', o.id, ...extra, WRAPUP_PROMPT); break;
        case 'wrapup': out(`→ ${name} — wrapping up the last session (Claude writes HANDOFF.md)\n`); args.push('--continue', ...extra, WRAPUP_PROMPT); break;
        case 'handoff': out(`→ ${name} — new session, picking up from HANDOFF.md\n`); args.push(...extra, HANDOFF_PROMPT); break;
        case 'continue': out(`→ ${name}\n`); args.push('--continue', ...extra); break;
        case 'resume': out(`→ ${name}\n`); args.push('--resume', ...extra); break;
        default: out(`→ ${name}\n`); args.push(...extra);
    }
    if ((mode === 'resume-id' || mode === 'continue') && o.pct != null && o.pct >= CTX_NUDGE) await ctxNudge(o.pct);
    return run(target, args);
}
function run(cwd, args) {
    if (process.env.CC_LAUNCHER_DRYRUN) { out(`DRYRUN cwd=${cwd} :: ${CLAUDE} ${args.map((a) => JSON.stringify(a)).join(' ')}\n`); process.exit(0); }
    // Ctrl+C belongs to Claude Code now; without a listener it would kill this parent and
    // hand the console back to the shell while claude is still running.
    process.on('SIGINT', () => {});
    const r = cp.spawnSync(CLAUDE, args, { cwd, stdio: 'inherit' });
    if (r.error) { console.error(`cc: could not start claude (${r.error.message})`); process.exit(1); }
    process.exit(r.status == null ? 1 : r.status);
}

// The first launch after sign-in finishes the plugin installs (claude-mem, superpowers),
// as the Ubuntu kit's post-login hook does: ccinstall leaves a local copy of itself for this.
function finishPlugins() {
    if (process.platform !== 'win32' || process.env.CC_LAUNCHER_DRYRUN) return;
    const cache = path.join(HOME, '.claude', 'plugins', 'cache');
    const finisher = path.join(process.env.LOCALAPPDATA || '', 'ai-terminal', 'ccinstall.ps1');
    if (!fs.existsSync(path.join(HOME, '.claude', '.credentials.json')) || !fs.existsSync(finisher)) return;
    if (fs.existsSync(path.join(cache, 'thedotmack')) && fs.existsSync(path.join(cache, 'superpowers-marketplace'))) return;
    out('ai-terminal: claude is ready - finishing plugin setup\n');
    cp.spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', finisher, '-Finish'], { stdio: 'inherit' });
}

// ── navigation ───────────────────────────────────────────────────────────────────
async function main(argv) {
    // an informational flag is a question for claude, not a request to pick a workspace
    if (['--version', '-v', '--help', '-h'].includes(argv[0])) return run(process.cwd(), argv);
    finishPlugins();
    let target = '';
    if (argv.length && fs.existsSync(path.join(PROJECTS, argv[0])) && fs.statSync(path.join(PROJECTS, argv[0])).isDirectory()) {
        target = path.join(PROJECTS, argv.shift());
    } else if (argv.length && !argv[0].startsWith('-')) {
        console.error(`No such workspace: ${path.join(PROJECTS, argv[0])}`); process.exit(1);
    }
    if (!target) await showTour();

    const quit = () => { ui_close(); process.exit(0); };
    for (;;) {
        if (!target) {
            const menu = mainMenu();
            const p = await pick(menu, 'where are you working?', 'Where are you working?', { help: MAIN_HELP });
            if (p.rc !== 0) quit();               // Esc on the top screen = quit, like q
            target = menu[p.i].path;
        }

        if (target === '@recall') {
            const menu = RECALL.map((r) => {
                const sm = sessMeta(r.file), c = card(sm);
                return { path: '@pick', r, pct: sm.ctx, name: path.basename(r.dir), desc: ageOf(r.file), meta: c.meta, warn: c.warn };
            });
            menu.push({ path: '@back', name: '← Back', desc: '' });
            const p = await pick(menu, `recent sessions (last ${RECALL_DAYS} days) — pick one to continue`, `Recent sessions (last ${RECALL_DAYS} days):`,
                { hint: "context = how full that conversation's working memory is; a FULL one is only good for a wrap-up", help: RECALL_HELP });
            if (p.rc === 1) quit();
            if (p.rc === 2 || menu[p.i].path === '@back') { target = ''; continue; }
            const row = menu[p.i];
            const id = path.basename(row.r.file, '.jsonl');
            let mode = 'resume-id';
            if (row.pct != null && row.pct >= CTX_NUDGE) {   // a filling session: steer to the wrap-up first
                const w = [
                    { path: 'wrapup-id', name: '⚑ Wrap up & hand off', desc: 'recommended: Claude saves the state to HANDOFF.md, then you start fresh' },
                    { path: 'resume-id', name: '↩ Just continue it', desc: 'reopen it as-is' },
                    { path: 'back', name: '← Back', desc: '' }];
                const q = await pick(w, `that session is ${row.pct}% full — wrap it up?`, `Session is ${row.pct}% full — 1 = wrap up & hand off · 2 = just continue · 3 = back:`);
                if (q.rc === 1) quit();
                if (q.rc === 2 || w[q.i].path === 'back') continue;   // back to the recall list
                mode = w[q.i].path;
            }
            return launch(row.r.dir, mode, argv, { id, pct: row.pct });
        }

        if (target === '@newproject') {
            const np = await newProjectScreen('major');
            if (np) return launch(np.target, 'new', argv, { msg: np.msg });
            target = ''; continue;
        }

        if (target === path.join(PROJECTS, 'misc')) {
            fs.mkdirSync(target, { recursive: true });
            const menu = subdirs(target).map((s) => { const lf = lastSession(s); return { path: s, name: path.basename(s), desc: lf ? sessLine(lf) : '' }; });
            menu.push({ path: '@newmisc', name: '+ New project…', desc: 'a small research folder under misc/' });
            menu.push({ path: '@back', name: '← Back', desc: '' });
            const p = await pick(menu, 'misc — which project?', 'misc — which project?');
            if (p.rc === 1) quit();
            if (p.rc === 2 || menu[p.i].path === '@back') { target = ''; continue; }
            if (menu[p.i].path === '@newmisc') {
                const np = await newProjectScreen('misc');
                if (np) return launch(np.target, 'new', argv, { msg: np.msg });
                continue;                          // back to the misc list
            }
            target = menu[p.i].path;               // falls through to the folder screen
        }

        // a folder: continue / new / hand-off / pick earlier / wrap up
        if (argv.length) return launch(target, 'new', argv);
        const lsf = lastSession(target);
        const hasHandoff = fs.existsSync(path.join(target, 'HANDOFF.md'));
        if (!lsf) return launch(target, hasHandoff ? 'handoff' : 'new', argv);
        const sm = sessMeta(lsf), c = card(sm), pct = sm.ctx;
        const menu = [];
        if (pct != null && pct >= CTX_FULL) menu.push({ path: 'wrapup', name: '⚑ Wrap up & hand off', desc: `recommended — the last session is ${pct}% full` });
        menu.push({ path: 'continue', name: '↩ Continue the last session', desc: ageOf(lsf), meta: c.meta, warn: c.warn });
        if (hasHandoff) menu.push({ path: 'handoff', name: '⇥ New session from hand-off', desc: 'fresh start that first reads HANDOFF.md' });
        menu.push({ path: 'new', name: '⊕ Start a new session', desc: `fresh context in ${path.basename(target)}` });
        if (pct != null && pct >= CTX_NUDGE && pct < CTX_FULL) menu.push({ path: 'wrapup', name: '⚑ Wrap up & hand off', desc: `context ${pct}% — save state before it fills` });
        menu.push({ path: 'resume', name: '☰ Pick an earlier session', desc: "browse this folder's history (claude --resume)" });
        menu.push({ path: 'back', name: '← Back', desc: '' });
        let mode;
        if (FANCY) {
            const p = await pick(menu, `${path.basename(target)} — start or continue?`, '', { help: SESSION_HELP });
            if (p.rc === 1) quit();
            if (p.rc === 2 || menu[p.i].path === 'back') { target = ''; continue; }
            mode = menu[p.i].path;
        } else {
            out(`  Last session here: "${sm.gist}" · ${ageOf(lsf)}${pct != null ? ` · context ${pct}%` : ''}\n`);
            let opts = 'Enter = continue it · n = new session · p = pick an earlier one';
            if (pct != null && pct >= CTX_NUDGE) opts += ' · w = wrap up & hand off';
            if (hasHandoff) opts += ' · h = new from hand-off';
            const how = String((await ask(`  ${opts} · b = back:`)) || '').trim().toLowerCase();
            if (how === 'b') { target = ''; continue; }
            mode = { n: 'new', p: 'resume', w: 'wrapup', h: hasHandoff ? 'handoff' : 'continue' }[how] || 'continue';
        }
        return launch(target, mode, argv, { pct });
    }
}

main(process.argv.slice(2)).catch((e) => { ui_close(); console.error(`cc: ${e && e.stack || e}`); process.exit(1); });
