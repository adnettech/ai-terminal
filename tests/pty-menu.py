#!/usr/bin/env python3
"""pty-menu.py ROWS COLS OUT STEP... -- CMD...
Runs CMD on a ROWSxCOLS pty and plays STEPs once the screen is quiet:
  key:<text>   send text (python escapes: \\x1b[B, \\r)    snap:<file>  write the screen as text
  wait:<secs>  pause
OUT gets everything printed, escape codes stripped, plus "scrolled=N" (lines the screen
scrolled while a full-screen UI was open) and "exit=N". A tiny screen emulator: cursor
home/position, erase line/display, newline; colours ignored."""
import fcntl, os, pty, re, select, struct, sys, termios, time
rows, cols, outp = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
sep = sys.argv.index('--'); steps, cmd = sys.argv[4:sep], sys.argv[sep + 1:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
grid = [[' '] * cols for _ in range(rows)]; r = c = 0; alt = False; scrolled = 0; raw = b''
CSI = re.compile(r'\x1b\[([?0-9;]*)([A-Za-z~])')
def feed(text):
    global r, c, alt, scrolled, grid
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == '\x1b':
            m = CSI.match(text, i)
            if not m: i += 1; continue
            a, f = m.groups(); i = m.end()
            if f == 'H':
                p = [int(x) if x else 1 for x in (a.split(';') + ['', ''])[:2]]; r, c = p[0] - 1, p[1] - 1
            elif f == 'K': grid[r][c:] = [' '] * (cols - c)
            elif f == 'J':
                grid[r][c:] = [' '] * (cols - c)
                for k in range(r + 1, rows): grid[k] = [' '] * cols
            elif f in 'hl' and a == '?1049':
                alt = f == 'h'; grid = [[' '] * cols for _ in range(rows)]; r = c = 0
            continue
        i += 1
        if ch == '\n':
            c = 0
            if r == rows - 1:
                grid.pop(0); grid.append([' '] * cols); scrolled += alt
            else: r += 1
        elif ch == '\r': c = 0
        elif ch >= ' ' and c < cols: grid[r][c] = ch; c += 1
def pump(quiet=0.4, limit=10):
    global raw
    end = time.time() + limit; last = time.time()
    while time.time() < end and time.time() - last < quiet:
        if select.select([fd], [], [], 0.05)[0]:
            try: d = os.read(fd, 65536)
            except OSError: return False
            if not d: return False
            raw += d; feed(d.decode('utf-8', 'replace')); last = time.time()
    return True
pump(0.8)
for s in steps:
    kind, _, arg = s.partition(':')
    if kind == 'key': os.write(fd, arg.encode().decode('unicode_escape').encode('latin-1'))
    elif kind == 'snap': open(arg, 'w').write('\n'.join(''.join(l).rstrip() for l in grid) + '\n')
    elif kind == 'wait': time.sleep(float(arg))
    pump()
end = time.time() + 5; st = None
while time.time() < end:
    if not pump(0.2, 0.5):
        break
try:
    p, st = os.waitpid(pid, os.WNOHANG)
    if p == 0: os.kill(pid, 9); st = None
except ChildProcessError: pass
txt = re.sub(r'\x1b\[[?0-9;]*[A-Za-z~]', '', raw.decode('utf-8', 'replace')).replace('\r', '')
open(outp, 'w').write(txt + f'\nscrolled={scrolled}\nexit={os.waitstatus_to_exitcode(st) if st is not None else "killed"}\n')
