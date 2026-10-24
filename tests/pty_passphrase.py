#!/usr/bin/env python3
"""Run a command in a pseudo-terminal and type a passphrase at each prompt,
the way a person would. Used by run-tests.sh to test the interactive path.

    pty_passphrase.py PASSPHRASE -- COMMAND [ARGS...]

Exits with the command's exit status. Fails if the command sits silently for
30 seconds (for example, waiting on a question nobody answers).
"""
import os
import pty
import re
import select
import sys
import time

passphrase = sys.argv[1].encode()
cmd = sys.argv[sys.argv.index("--") + 1:]

pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)

buf = b""
answered = 0
last = time.time()
prompt = re.compile(rb"(enter passphrase[^\n]*|verify passphrase)[^\n]*: ?$", re.I)
while True:
    ready, _, _ = select.select([fd], [], [], 1.0)
    if ready:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        buf += data
        sys.stdout.write(data.decode(errors="replace"))
        sys.stdout.flush()
        last = time.time()
        # Answer only a prompt sitting at the end of the output, once each.
        tail = buf.rsplit(b"\n", 1)[-1]
        if prompt.search(tail):
            time.sleep(0.2)
            os.write(fd, passphrase + b"\n")
            answered += 1
            buf += b"\n"
    elif time.time() - last > 30:
        print("\n[pty] no output for 30s - command is waiting on something", flush=True)
        os.kill(pid, 9)
        os.waitpid(pid, 0)
        sys.exit(124)

_, status = os.waitpid(pid, 0)
print(f"\n[pty] answered {answered} passphrase prompt(s)", flush=True)
sys.exit(os.waitstatus_to_exitcode(status))
