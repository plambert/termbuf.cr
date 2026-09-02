"""A terminal just real enough to answer CPR, so `measure_columns.cr` can be
tested without taking anyone's screen, and so its failure paths can be tested at
all -- a real terminal will not drop replies on request.

It charges one column per code point, which is both what Terminal.app does and
simple enough that the expected answer for every sample is just its length --
so a misattributed reply shows up immediately across the whole corpus.

    crystal build scripts/measure_columns.cr -o /tmp/measure_columns
    python3 scripts/fake_terminal.py /tmp/measure_columns /tmp/out            # the 67
    python3 scripts/fake_terminal.py /tmp/measure_columns /tmp/out corpus.tsv # all of it
    python3 scripts/fake_terminal.py /tmp/measure_columns /tmp/out corpus.tsv 137
    python3 scripts/fake_terminal.py /tmp/measure_columns /tmp/out corpus.tsv 1

The last two drop every 137th reply and every reply. With one in 137 lost the
instrument must lose those samples and misattribute none; with all of them lost
it must abort inside a second and write nothing.
"""
import os, pty, re, struct, fcntl, termios, sys, codecs

binary, out = sys.argv[1], sys.argv[2]
corpus = sys.argv[3] if len(sys.argv) > 3 else None
drop_every = int(sys.argv[4]) if len(sys.argv) > 4 else 0

argv = [binary, out] + ([corpus] if corpus else [])
pid, fd = pty.fork()
if pid == 0:
    os.execv(binary, argv)

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 64, 200, 0, 0))

# Incremental, so a multi-byte character split across two reads is one
# character and not two replacements.
decoder = codecs.getincrementaldecoder("utf-8")("replace")
col = 1
buf = ""
answers = dropped = 0
transcript = []
CSI = re.compile(r"\x1b\[([0-9;?]*)([\$ ]?)([A-Za-z])")

while True:
    try:
        data = os.read(fd, 65536)
    except OSError:
        break
    if not data:
        break
    chunk = decoder.decode(data)
    transcript.append(chunk)
    buf += chunk

    while buf:
        esc = buf.find("\x1b")
        if esc == -1:
            col += len(buf); buf = ""; break
        if esc > 0:
            col += len(buf[:esc]); buf = buf[esc:]
        m = CSI.match(buf)
        if not m:
            if len(buf) > 64:      # not a sequence we know; drop the ESC
                col += 1; buf = buf[1:]; continue
            break                   # partial, wait for more
        params, inter, final = m.group(1), m.group(2), m.group(3)
        buf = buf[m.end():]

        if final == "n" and params == "6":
            answers += 1
            if drop_every and answers % drop_every == 0:
                dropped += 1
            else:
                os.write(fd, f"\x1b[1;{col}R".encode())
        elif final == "p" and params == "?2027":
            os.write(fd, b"\x1b[?2027;2$y")
        elif final == "H":
            parts = params.split(";")
            col = int(parts[1]) if len(parts) > 1 and parts[1] else 1
        # everything else -- erase, autowrap, alt screen -- moves nothing

os.waitpid(pid, 0)
print(f"answered {answers} queries, dropped {dropped}")
text = "".join(transcript)
import re as _re
plain = _re.sub(r"\x1b\[[0-9;?]*[\$ ]?[A-Za-z]", "", text)
plain = "".join(c for c in plain if c.isprintable() or c == "\n")
print("--- child said:", plain.strip()[:600])
