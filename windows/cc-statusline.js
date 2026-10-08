#!/usr/bin/env node
// Claude Code statusline for Windows: <project> · <model> · context N%  (wrap-up nudge ≥80%)
//
// The Windows twin of tools/cc-statusline.sh, installed by windows/ccinstall.ps1 as
// %USERPROFILE%\.local\bin\cc-statusline.js. Node rather than PowerShell: Claude Code redraws
// the statusline constantly, Windows PowerShell 5.1 takes a third of a second to start, and
// its stdout is not UTF-8 by default (the · and ⚠ would come out as mojibake).
//
// Same logic as the bash version: trust the window and used_percentage Claude Code reports for
// the running model (never hardcode a window), fall back to the latest turn's usage in the
// transcript. Tunables (env): CC_CONTEXT_WINDOW (override), CC_CTX_NUDGE (default 80).
// The model-window cache the bash version writes is for a platform launcher that has no
// Windows counterpart, so it is left out here.
'use strict';
const fs = require('fs');
const path = require('path');

function lastUsage(tp) {
    if (!tp) return null;
    let last = null;
    try {
        const size = fs.statSync(tp).size;
        const tail = Math.min(size, 262144);          // long transcript: only the tail matters
        const buf = Buffer.alloc(tail);
        const fd = fs.openSync(tp, 'r');
        try { fs.readSync(fd, buf, 0, tail, size - tail); } finally { fs.closeSync(fd); }
        const lines = buf.toString('utf8').split('\n');
        if (tail < size) lines.shift();               // discard the partial first line
        for (const line of lines) {
            let e;
            try { e = JSON.parse(line); } catch { continue; }
            const u = e && e.message && e.message.usage;
            if (u && typeof u === 'object' && u.input_tokens != null) last = u;
        }
    } catch { /* no transcript yet */ }
    return last;
}

function render(d) {
    const model = (d.model || {}).display_name || '';
    const cwd = path.basename((d.workspace || {}).current_dir || '');
    const cw = d.context_window || {};
    const seg = [cwd, model].filter(Boolean);

    const envWin = process.env.CC_CONTEXT_WINDOW;
    const win = envWin ? parseInt(envWin, 10) : (cw.context_window_size || 200000);

    let pct = envWin ? null : cw.used_percentage;     // trust Claude Code's own figure
    if (pct == null) {
        let total = cw.total_input_tokens;
        if (!total) {
            // null before the first API call and again after /compact
            const u = lastUsage(d.transcript_path);
            if (u) total = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0)
                         + (u.cache_creation_input_tokens || 0);
        }
        if (total) pct = Math.floor(total * 100 / win);
    }

    if (pct != null) {
        pct = Math.max(0, Math.min(100, Math.trunc(pct)));
        if (pct >= parseInt(process.env.CC_CTX_NUDGE || '80', 10)) {
            seg.push(`⚠ context ${pct}% — wrap up: have Claude document state, then start fresh`);
        } else {
            seg.push(`context ${pct}%`);
        }
    }
    return seg.join(' · ');
}

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => { raw += c; });
process.stdin.on('end', () => {
    // A statusline that cannot read its input says nothing — a throw here would spray a
    // stack trace through every session.
    try { process.stdout.write(render(JSON.parse(raw)) + '\n'); } catch { /* silent */ }
});
