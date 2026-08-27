import pty, os, re, sys, subprocess
out = []
def rd(fd):
    d = os.read(fd, 65536); out.append(d); return d
pty.spawn(['/bin/bash', sys.argv[1], sys.argv[2]], rd)
raw = b''.join(out).decode('utf-8', 'replace')

# Minimal terminal: rows, cursor, ESC[nA (up), ESC[nJ (clear to end), ESC[K, \r
scr, cur, col = [], 0, 0
def put(ch):
    global cur, col
    while len(scr) <= cur: scr.append('')
    line = scr[cur]
    if col > len(line): line = line + ' ' * (col - len(line))
    scr[cur] = line[:col] + ch + line[col+1:]
    col += 1
i = 0
while i < len(raw):
    c = raw[i]
    if c == '\x1b':
        m = re.match(r'\x1b\[(\d*)([A-Za-z])', raw[i:])
        if m:
            n = int(m.group(1) or 1); k = m.group(2)
            if k == 'A': cur = max(0, cur - n); col = 0
            elif k == 'B': cur += n
            elif k == 'J':
                while len(scr) <= cur: scr.append('')
                scr[cur] = scr[cur][:col]; del scr[cur+1:]
            elif k == 'K':
                while len(scr) <= cur: scr.append('')
                scr[cur] = scr[cur][:col]
            i += m.end(); continue
        m = re.match(r'\x1b\[\?25[lh]', raw[i:])
        if m: i += m.end(); continue
        m = re.match(r'\x1b\[[0-9;]*m', raw[i:])
        if m: i += m.end(); continue
    if c == '\n': cur += 1; col = 0
    elif c == '\r': col = 0
    else: put(c)
    i += 1
screen = '\n'.join(scr).rstrip('\n')
# argv[3] names the LIVE table (its title is the only thing that tells one box
# from another); argv[4] is how many boxes the screen should end up holding in
# total, because a scenario may deliberately print a static panel above the live
# one -- and a live table that miscounts its own height eats that panel, which is
# a bottom-border short rather than a top-border extra.
title = sys.argv[3] if len(sys.argv) > 3 else 'Datasets to load'
want_bots = int(sys.argv[4]) if len(sys.argv) > 4 else 1
tops = screen.count('╭─ ' + title)
bots = screen.count('╰')
print("=== FINAL SCREEN ===")
print(screen)
print("=== tables on screen: %d top borders, %d bottom borders (wanted 1 and %d) ==="
      % (tops, bots, want_bots))

# The screen is not the whole story. When bash reaps a background job that was
# killed, it prints the job's own source at the terminal -- and a later redraw
# can paint over the evidence while the damage to the cursor arithmetic is
# already done. So count it in the RAW stream, where nothing can overwrite it.
noise = len(re.findall(r'Terminated:? *\d*|Killed:? *\d*', raw))
print("=== shell job announcements: %d ===" % noise)
sys.exit(0 if (tops == 1 and bots == want_bots and noise == 0) else 1)
