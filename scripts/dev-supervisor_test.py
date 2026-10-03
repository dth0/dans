#!/usr/bin/env python3
"""Exercise the actual embedded supervisor with a stalled process lookup."""

import os
import signal
import subprocess
import tempfile
import time
from pathlib import Path


def check():
    root = Path(__file__).resolve().parent.parent
    script = (root / "scripts/dev-stack.sh").read_text()
    start = script.index("\tsh -c '\n\t\tlaunch_marker=$1") + len("\tsh -c '")
    end = script.index("\n\t' dans-operation-supervisor", start)
    supervisor = script[start:end]

    for slow_lookup in (False, True):
        with tempfile.TemporaryDirectory(prefix="dans-supervisor-test-") as directory:
            work = Path(directory)
            marker = work / "operation"
            for suffix in (".wait", ".lease", ".stderr.pipe"):
                os.mkfifo(str(marker) + suffix)
            env = os.environ.copy()
            env.pop("DANS_DEV_TEST_TRACE_SUPERVISOR", None)
            if slow_lookup:
                probe = work / "ps"
                probe.write_text("#!/bin/sh\nexec sleep 30\n")
                probe.chmod(0o755)
                env["PATH"] = str(work) + os.pathsep + env["PATH"]
            with (work / "output").open("wb") as output:
                child = subprocess.Popen(
                    ["/bin/sh", "-c", supervisor, "supervisor-test", str(marker), "1",
                     "/bin/sh", "-c", ":"],
                    env=env, stdout=output, stderr=output, start_new_session=True,
                )
                try:
                    for suffix in (".ready", ".finished"):
                        deadline = time.monotonic() + 2
                        while not Path(str(marker) + suffix).exists():
                            if child.poll() is not None or time.monotonic() >= deadline:
                                raise AssertionError("supervisor cancellation: timeout")
                            time.sleep(0.01)
                        if suffix == ".ready":
                            Path(str(marker) + ".go").touch()
                    assert Path(str(marker) + ".status").read_text().strip() == "0"
                    release = os.open(str(marker) + ".wait", os.O_RDWR | os.O_NONBLOCK)
                    try:
                        os.write(release, b"release\n")
                    finally:
                        os.close(release)
                    assert child.wait(timeout=2) == 0
                finally:
                    if child.poll() is None:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait()

    print("supervisor cancellation: ok")


try:
    check()
except Exception:
    print("supervisor cancellation: failed")
    raise SystemExit(1)
