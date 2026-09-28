#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Regression test for per-request memory growth in the bridge.
#
# The soak harness measured the bridge's memory growing by a constant
# ~5 kB per request, whatever the request type or payload size, and a
# referrer walk of a live daemon found every request's buffers and
# sockets still reachable from one module-level dict: double_tls's
# debug helper _id() recorded each object it labelled and never let go.
# The labels are only used as arguments to _debug(), which is a no-op,
# but Python evaluates arguments regardless, so the table filled on
# every request whether or not anyone was debugging (patch 16).
#
# The second leak was in the binding: python-nss-ng before 1.3.2 kept
# every NSPRError raised from C alive, with its traceback and every
# frame and local on it. The bridge's non-blocking handshakes and
# accepts raise PR_WOULD_BLOCK_ERROR as ordinary control flow, several
# times a request. Fixed in python-nss-ng 1.3.2, which the images pin.
#
# The checks are behavioural: objects are labelled the way the bridge's
# buffers are, and errors raised the way its sockets raise them, and
# none may outlive its last reference.
#
# Run inside the sigul bridge image:
#   python3 test/test_bridge_memory.py

# pyright: reportUnknownMemberType=false, reportAttributeAccessIssue=false
# pyright: reportUnknownVariableType=false, reportUnknownArgumentType=false
#
# double_tls is upstream code this repository only patches, and ships
# no type stubs, so its members are untyped by nature.

import gc
import os
import sys
import tracemalloc
import weakref
from collections.abc import Callable

sys.path.insert(0, os.environ.get("SIGUL_LIB", "/usr/share/sigul"))

import double_tls  # noqa: E402
import nss.error  # noqa: E402
import nss.io  # noqa: E402
import nss.nss  # noqa: E402

FAILURES: list[str] = []

ITERATIONS = 1000


class _Labelled:
    """Stands in for a buffer or socket the bridge labels per request."""


def check(label: str, ok: bool, detail: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if not ok:
        FAILURES.append(label)


def test_labelled_objects_are_released() -> None:
    refs: list[weakref.ref[_Labelled]] = []
    for _ in range(ITERATIONS):
        obj = _Labelled()
        _ = double_tls._id(obj)
        refs.append(weakref.ref(obj))
        del obj
    _ = gc.collect()
    alive = sum(1 for r in refs if r() is not None)
    check(
        "objects labelled for debug output are released",
        alive == 0,
        f"{alive} of {ITERATIONS} still alive",
    )


def test_labels_are_stable() -> None:
    # Debug output is only readable if an object keeps one label.
    obj = _Labelled()
    first = double_tls._id(obj)
    check(
        "an object keeps its label",
        double_tls._id(obj) == first,
        f"label {first!r}",
    )


def _live_errors() -> int:
    _ = gc.collect()
    objects: list[object] = gc.get_objects()
    return sum(1 for o in objects if isinstance(o, nss.error.NSPRError))


def _raised_errors_released(label: str, raise_one: Callable[[], None]) -> None:
    raise_one()  # warm any caches before measuring
    tracemalloc.start()
    try:
        before, bytes_before = _live_errors(), tracemalloc.get_traced_memory()[0]
        for _ in range(ITERATIONS):
            raise_one()
        after, bytes_after = _live_errors(), tracemalloc.get_traced_memory()[0]
    finally:
        tracemalloc.stop()
    per_call = (bytes_after - bytes_before) / ITERATIONS
    check(
        label,
        after == before and per_call < 16,
        f"{after - before} of {ITERATIONS} still alive, {per_call:+.1f} B per error",
    )


def test_would_block_errors_are_released() -> None:
    # What the bridge meets on every request: a non-blocking accept
    # with nothing queued.
    listener = nss.io.Socket(nss.io.PR_AF_INET)
    listener.set_socket_option(nss.io.PR_SockOpt_Reuseaddr, True)
    listener.bind(nss.io.NetworkAddress(nss.io.PR_IpAddrLoopback, 0))
    listener.listen(1)
    listener.set_socket_option(nss.io.PR_SockOpt_Nonblocking, True)

    def accept_nothing() -> None:
        try:
            _ = listener.accept()
        except nss.error.NSPRError as e:
            if e.errno != nss.error.PR_WOULD_BLOCK_ERROR:
                raise

    try:
        _raised_errors_released(
            "errors raised from the binding are released", accept_nothing
        )
    finally:
        listener.close()


def test_errors_with_a_message_are_released() -> None:
    # Raised from C with a formatted message, whose string leaked too.
    def parse_bad_name() -> None:
        try:
            _ = nss.nss.DN("this is not=a,,=valid=name")
        except nss.error.NSPRError:
            pass

    _raised_errors_released("errors with a message are released", parse_bad_name)


def main() -> int:
    print("Bridge per-request memory regression tests")
    print()
    test_labelled_objects_are_released()
    test_labels_are_stable()
    test_would_block_errors_are_released()
    test_errors_with_a_message_are_released()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("nothing the bridge labels per request outlives it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
