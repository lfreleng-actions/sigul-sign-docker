#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Regression test for the server's request alarm (patch 20).
#
# Every request child arms signal.alarm(CHILD_TIMEOUT_SECS) as a
# backstop. It was armed at fork, before the child had a request, so a
# request arriving late in an idle child's hour got only what was left
# of it: on a quiet server one lasting d seconds was cut off with
# probability of about d/3600. And the kill was silent - the SystemExit
# the alarm raises was swallowed and the child reported success (#48).
#
# The checks run the real request_handling_child() and read_request()
# in a forked child, over a fake bridge connection that controls how
# long the child waits for a request and how long the request runs.
#
# Run inside the sigul server image:
#   python3 test/test_server_request_alarm.py

# pyright: reportUnknownMemberType=false, reportUnknownArgumentType=false
# pyright: reportUnknownVariableType=false, reportAttributeAccessIssue=false
#
# server is upstream code this repository only patches, and ships no
# type stubs, so its members are untyped by nature.

import logging
import os
import signal
import sys
import tempfile
import time
from types import SimpleNamespace

sys.path.insert(0, os.environ.get("SIGUL_LIB", "/usr/share/sigul"))

import server  # noqa: E402
import utils  # noqa: E402

FAILURES: list[str] = []

PATCHED = hasattr(server, "_run_request_child")

TIMEOUT = 2


def check(label: str, ok: bool, detail: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if not ok:
        FAILURES.append(label)


class FakeBridge:
    """The request child's bridge connection, with scripted timing.

    The child's first read waits `idle` seconds for a request, as a child
    waits for the bridge to hand it a client; with request=False no
    request ever comes. The next read is the request itself: it takes
    `work` seconds, notes that it got that far, then ends the request.
    """

    def __init__(self, idle: float, work: float, request: bool, done: str) -> None:
        self.idle: float = idle
        self.work: float = work
        self.request: bool = request
        self.done: str = done
        self.reads: int = 0

    def outer_read(self, _size: int) -> bytes:
        self.reads += 1
        if self.reads == 1:
            time.sleep(self.idle if self.request else 3600)
            return utils.u32_pack(utils.protocol_version)
        time.sleep(self.work)
        with open(self.done, "w") as f:
            _ = f.write("done")
        raise EOFError()

    def outer_close(self) -> None:
        pass


def _child_body(config: SimpleNamespace) -> int:
    if PATCHED:
        return server._run_request_child(config)
    # What server.main ran in each child before patch 20.
    _ = signal.signal(signal.SIGALRM, server.sigalarm_handler)
    _ = signal.alarm(server.CHILD_TIMEOUT_SECS)
    return server.request_handling_child(config)


def _no_op(_config: object) -> None:
    return None


def _run(
    idle: float, work: float, request: bool = True
) -> tuple[int, float, bool, str]:
    """Fork a request child; return its exit status, run time, whether
    its request got to the end, and what it logged."""
    directory = tempfile.mkdtemp()
    done = os.path.join(directory, "done")
    log = os.path.join(directory, "log")
    started = time.monotonic()
    pid = os.fork()
    if pid == 0:
        status = 2
        try:
            logging.basicConfig(filename=log, level=logging.INFO, force=True)
            server.CHILD_TIMEOUT_SECS = TIMEOUT
            server.utils.nss_init = _no_op
            server.server_common.db_open = _no_op

            def bridge(*_args: object) -> FakeBridge:
                return FakeBridge(idle, work, request, done)

            server.double_tls.DoubleTLSClient = bridge
            config = SimpleNamespace(
                daemon_uid=None,
                daemon_gid=None,
                bridge_hostname="bridge",
                bridge_port=0,
                server_cert_nickname="server",
            )
            status = _child_body(config)
            logging.shutdown()
        finally:
            os._exit(status)
    _, wait_status = os.waitpid(pid, 0)
    elapsed = time.monotonic() - started
    with open(log) as f:
        logged = f.read()
    return os.waitstatus_to_exitcode(wait_status), elapsed, os.path.exists(done), logged


def test_late_request_gets_its_budget() -> None:
    # Arrives when the child has used most of its budget waiting, and
    # needs most of a budget itself: timed from arrival, it finishes.
    status, elapsed, done, _ = _run(idle=TIMEOUT * 0.75, work=TIMEOUT * 0.75)
    outcome = "finished" if done else "cut off"
    check(
        "a request arriving late in a child's life gets its whole budget",
        done and status == 0,
        f"{outcome} after {elapsed:.1f}s in all, budget {TIMEOUT}s from arrival, exit {status}",
    )


def test_overrun_is_reported() -> None:
    # Runs past its budget: killed, and said so - to the parent, by exit
    # status, and in the log.
    status, elapsed, done, logged = _run(idle=0.1, work=TIMEOUT * 3)
    check(
        "a request overrunning its budget is killed on time",
        not done and elapsed < TIMEOUT * 2,
        f"after {elapsed:.1f}s, budget {TIMEOUT}s",
    )
    check(
        "... and reported as a timeout",
        status == server._CHILD_TIMEOUT and "timed out" in logged,
        f"exit {status} (timeout is {server._CHILD_TIMEOUT}), log: {logged.strip()[-80:]!r}",
    )


def test_idle_child_recycled_quietly() -> None:
    # No request comes: the alarm ends the wait so a fresh child can
    # take over, which is routine, not a timeout to report.
    status, elapsed, _, logged = _run(idle=0, work=0, request=False)
    check(
        "an idle child is replaced on its idle bound, quietly",
        status == 0 and elapsed < TIMEOUT * 2 and "timed out" not in logged,
        f"exit {status} after {elapsed:.1f}s, bound {TIMEOUT}s",
    )


def main() -> int:
    print("Server request alarm regression tests")
    print(f"server: {'PATCHED' if PATCHED else 'UNPATCHED'}")
    print()
    test_late_request_gets_its_budget()
    test_overrun_is_reported()
    test_idle_child_recycled_quietly()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("a request is timed from its arrival, and a timeout is reported")
    return 0


if __name__ == "__main__":
    sys.exit(main())
