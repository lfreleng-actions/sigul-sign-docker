#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Regression test for the server's liveness heartbeat (patch 19).
#
# The server's probes checked for an established connection to the
# bridge: state a frozen server keeps. Frozen, it stayed Ready for
# about four minutes and was replaced after about five and a half,
# against a bound of three (#33). Patch 19 has the supervising parent
# wait for its request child a second at a time and rewrite a heartbeat
# between slices, unless that child has been stopped.
#
# The checks drive the real supervisor functions over a real forked
# child, and cover both ways the heartbeat can be wrong:
#
# - stale when it should be fresh: a child that is merely waiting, as a
#   request child waits for the next request, and a parent sleeping
#   between reconnection attempts while the bridge is down;
# - fresh when it should be stale: a child that has been stopped.
#
# Also checks that orphans are still reaped (patch 08), that the
# child's exit status still comes back, and that its exit ends the wait
# at once rather than on the next slice - the next request waits on it.
# And that the chart's liveness probe, reading the heartbeat, replaces a
# server whose child lost the bridge as fast as the probe it replaced.
#
# Run inside the sigul server image:
#   python3 test/test_server_heartbeat.py

# pyright: reportUnknownMemberType=false, reportUnknownArgumentType=false
# pyright: reportUnknownVariableType=false, reportAttributeAccessIssue=false
#
# server is upstream code this repository only patches, and ships no
# type stubs, so its members are untyped by nature.

import errno
import os
import re
import signal
import socket
import sys
import tempfile
import threading
import time
from typing import cast
from unittest import mock

sys.path.insert(0, os.environ.get("SIGUL_LIB", "/usr/share/sigul"))

import server  # noqa: E402

FAILURES: list[str] = []

PATCHED = hasattr(server, "_beat")

# As shipped, before the checks below shorten it to keep the run brief.
DISCONNECTED_SECONDS = cast(int, getattr(server, "_DISCONNECTED_SECONDS", 0))


def check(label: str, ok: bool, detail: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if not ok:
        FAILURES.append(label)


def _age(path: str) -> float:
    try:
        return time.time() - os.stat(path).st_mtime
    except OSError:
        return float("inf")


def _fork_child(seconds: float, status: int = 0) -> int:
    pid = os.fork()
    if pid == 0:
        time.sleep(seconds)
        os._exit(status)
    return pid


def _watch(path: str, until: threading.Event, ages: list[float]) -> None:
    while not until.is_set():
        ages.append(_age(path))
        time.sleep(0.25)


def _supervise(child: int, path: str) -> tuple[int, list[float]]:
    """Run the real wait on child, sampling the heartbeat's age meanwhile."""
    ages: list[float] = []
    done = threading.Event()
    watcher = threading.Thread(target=_watch, args=(path, done, ages))
    watcher.start()
    try:
        status = server._wait_for_child_reaping_orphans(child)
    finally:
        done.set()
        watcher.join()
    return status, ages


def test_fresh_while_child_waits(directory: str) -> None:
    path = os.path.join(directory, "waiting")
    server._heartbeat_path = path
    child = _fork_child(4.0)
    status, ages = _supervise(child, path)
    worst = max(ages[2:]) if len(ages) > 2 else float("inf")
    check(
        "fresh while the request child is waiting",
        worst < 3 * server._HEARTBEAT_SLICE_SECONDS,
        f"oldest {worst:.2f}s over a 4.0s wait",
    )
    check(
        "the child's exit status still comes back",
        os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0,
        f"status {status}",
    )


def test_stale_while_child_stopped(directory: str) -> None:
    path = os.path.join(directory, "stopped")
    server._heartbeat_path = path
    server._beat()  # a fresh heartbeat, so staleness is measured, not absence
    child = _fork_child(60.0)
    time.sleep(0.2)
    os.kill(child, signal.SIGSTOP)

    def release() -> None:
        time.sleep(5.0)
        os.kill(child, signal.SIGKILL)
        os.kill(child, signal.SIGCONT)

    threading.Thread(target=release, daemon=True).start()
    _, ages = _supervise(child, path)
    # The staleness reached while it was stopped: once killed it is no
    # longer stopped, and a beat before it is reaped is right, so the
    # last sample may be fresh.
    grew = max(ages) if ages else 0.0
    check(
        "withheld while the request child is stopped",
        3.0 < grew < float("inf"),
        f"age {grew:.2f}s after 5.0s with the child stopped",
    )


def test_stale_while_child_holds_no_connection(directory: str) -> None:
    """The teardown wedge: a sleeping child, and nothing connected.

    patches/06 fixes the known cause, a teardown that waited on its
    peer forever with the parent waiting on it. The heartbeat must be
    the backstop the chart's connection check was: withheld once a
    child has held no connection to the bridge for longer than the bound.
    """
    path = os.path.join(directory, "disconnected")
    server._heartbeat_path = path
    server._bridge_port = 1  # nothing is connected to port 1
    server._DISCONNECTED_SECONDS = 2
    server._disconnected_since = None
    try:
        child = _fork_child(6.0)
        _, ages = _supervise(child, path)
    finally:
        server._bridge_port = None
    grew = ages[-1] if ages else 0.0
    check(
        "withheld once a child has held no bridge connection past the bound",
        2.0 < grew < float("inf"),
        f"age {grew:.2f}s at the end of a 6.0s wait with nothing connected, bound 2s",
    )


def test_fresh_while_child_holds_connection(directory: str) -> None:
    path = os.path.join(directory, "connected")
    server._heartbeat_path = path
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = cast(int, listener.getsockname()[1])
    client = socket.create_connection(("127.0.0.1", port))
    peer = listener.accept()[0]
    server._bridge_port = port
    server._DISCONNECTED_SECONDS = 2
    server._disconnected_since = None
    try:
        child = _fork_child(6.0)
        _, ages = _supervise(child, path)
    finally:
        server._bridge_port = None
        for s_ in (client, peer, listener):
            s_.close()
    worst = max(ages[2:]) if len(ages) > 2 else float("inf")
    check(
        "fresh while the child holds its bridge connection",
        worst < 3 * server._HEARTBEAT_SLICE_SECONDS,
        f"oldest {worst:.2f}s over a 6.0s wait, connected throughout",
    )


def test_fresh_while_waiting_for_bridge(directory: str) -> None:
    path = os.path.join(directory, "reconnecting")
    server._heartbeat_path = path
    ages: list[float] = []
    done = threading.Event()
    watcher = threading.Thread(target=_watch, args=(path, done, ages))
    watcher.start()
    try:
        server._sleep_beating(4.0)
    finally:
        done.set()
        watcher.join()
    worst = max(ages[2:]) if len(ages) > 2 else float("inf")
    check(
        "fresh while sleeping between reconnections to the bridge",
        worst < 3 * server._HEARTBEAT_SLICE_SECONDS,
        f"oldest {worst:.2f}s over a 4.0s reconnection sleep",
    )


def test_orphans_still_reaped(directory: str) -> None:
    server._heartbeat_path = os.path.join(directory, "reaping")
    orphan = _fork_child(0.1, status=7)
    child = _fork_child(1.5)
    _ = server._wait_for_child_reaping_orphans(child)
    try:
        _ = os.waitpid(orphan, os.WNOHANG)
        reaped = False
    except ChildProcessError:
        reaped = True
    check(
        "a second child exiting meanwhile is still reaped",
        reaped,
        "no zombie left" if reaped else f"pid {orphan} left unreaped",
    )


#: The chart's old connection probe: six failures twenty seconds apart
#: restarted a server whose child held no bridge connection. The
#: heartbeat is that probe's backstop and must be no slower.
OLD_PROBE_BOUND_SECONDS = 120

CHART_TEMPLATE = os.environ.get(
    "SIGUL_SERVER_TEMPLATE", "/chart/server-statefulset.yaml"
)


def _liveness_budget() -> tuple[int, int, int] | str:
    """(age bound, period, failure threshold) of the chart's server liveness probe."""
    try:
        with open(CHART_TEMPLATE) as f:
            text = f.read()
    except OSError as e:
        return f"cannot read the chart template ({e}); mount K8S/charts/sigul/templates at /chart"
    probe = text.split("livenessProbe:", 1)[-1].split("readinessProbe:", 1)[0]
    found = [
        re.search(r"test \$a -le (\d+)", probe),
        re.search(r"periodSeconds: (\d+)", probe),
        re.search(r"failureThreshold: (\d+)", probe),
    ]
    if not all(found):
        return "the server liveness probe no longer has the expected shape"
    age, period, failures = (int(m.group(1)) for m in found if m)
    return age, period, failures


def test_disconnected_wedge_replaced_in_time() -> None:
    # A child without a bridge connection stops the heartbeat once it
    # has been disconnected _DISCONNECTED_SECONDS, within one slice;
    # the beat then has to age past the probe's bound, and the probe
    # to fail failureThreshold times, the first up to a period late.
    budget = _liveness_budget()
    if isinstance(budget, str):
        check(
            "a disconnected child is replaced within the old probe's bound",
            False,
            budget,
        )
        return
    age, period, failures = budget
    worst = (
        DISCONNECTED_SECONDS + server._HEARTBEAT_SLICE_SECONDS + age + failures * period
    )
    parts = f"{DISCONNECTED_SECONDS} + {server._HEARTBEAT_SLICE_SECONDS} + {age} + {failures}x{period}"
    check(
        "a disconnected child is replaced within the old probe's bound",
        worst <= OLD_PROBE_BOUND_SECONDS,
        f"{parts} = {worst}s at worst, bound {OLD_PROBE_BOUND_SECONDS}s",
    )


def _reap_delay(exit_after: float) -> float:
    """Seconds between a child's exit and the wait returning its status."""
    child = _fork_child(exit_after)
    start = time.monotonic()
    _ = server._wait_for_child_reaping_orphans(child)
    return time.monotonic() - start - exit_after


def test_child_reaped_promptly(directory: str) -> None:
    # The next request child is forked only once the wait returns, so a
    # wait that notices the exit on the next one-second tick adds up to
    # a second to every request: +0.6s median, measured end to end.
    server._heartbeat_path = os.path.join(directory, "prompt")
    worst = max(_reap_delay(0.2) for _ in range(3))
    check(
        "a request child's exit ends the wait at once",
        worst < 0.25 * server._HEARTBEAT_SLICE_SECONDS,
        f"worst {worst:.3f}s after exit, over 3 children",
    )


def test_wait_without_pidfd(directory: str) -> None:
    # Where no pidfd can be had the wait falls back to plain slices:
    # coarser, but it must still return the right status and beat.
    server._heartbeat_path = os.path.join(directory, "no-pidfd")
    unavailable = OSError(errno.ENOSYS, os.strerror(errno.ENOSYS))
    with mock.patch.object(os, "pidfd_open", side_effect=unavailable):
        child = _fork_child(1.5, status=3)
        status, ages = _supervise(child, server._heartbeat_path)
    worst = max(ages[2:]) if len(ages) > 2 else float("inf")
    check(
        "without a pidfd the wait still returns the status and beats",
        os.WIFEXITED(status)
        and os.WEXITSTATUS(status) == 3
        and worst < 3 * server._HEARTBEAT_SLICE_SECONDS,
        f"status {status}, oldest heartbeat {worst:.2f}s",
    )


def test_no_heartbeat_path_is_inert() -> None:
    server._heartbeat_path = None
    try:
        server._beat()
        ok = True
    except Exception as e:  # noqa: BLE001
        ok = False
        print(f"      {e!r}")
    check("no heartbeat path configured is a no-op", ok, "nothing written")


def main() -> int:
    print("Server liveness heartbeat regression tests")
    print(f"server: {'PATCHED' if PATCHED else 'UNPATCHED'}")
    print()
    if not PATCHED:
        print("FAIL  server has no heartbeat: patch 19 is not applied")
        return 1
    with tempfile.TemporaryDirectory() as directory:
        test_fresh_while_child_waits(directory)
        test_stale_while_child_stopped(directory)
        test_stale_while_child_holds_no_connection(directory)
        test_fresh_while_child_holds_connection(directory)
        test_fresh_while_waiting_for_bridge(directory)
        test_orphans_still_reaped(directory)
        test_child_reaped_promptly(directory)
        test_wait_without_pidfd(directory)
        test_disconnected_wedge_replaced_in_time()
        test_no_heartbeat_path_is_inert()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("the heartbeat tells a waiting server from a wedged one")
    return 0


if __name__ == "__main__":
    sys.exit(main())
