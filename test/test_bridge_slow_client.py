#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Regression test for the bridge's client throughput floor (patch 18).
#
# The bridge serves one request at a time. Patch 11's idle deadline
# sheds a client that goes silent, but not one that trickles: a client
# moving a few bytes a second held signing for everyone for as long as
# its payload took (#31). Patch 18 gives the client's buffer a floor on
# its throughput, measured only over time spent waiting on the client.
#
# The checks drive a real double_tls.OuterBuffer over a fake socket
# whose sends and receives take controlled time, and cover both ways
# the floor can be wrong:
#
# - sheds when it should not: a fast client, a client that is idle
#   while the caller waits on something else (the server signing), and
#   a slow client still inside its grace period must all be kept;
# - keeps when it should not: a client trickling below the floor, on a
#   receive or a send, must be shed once its grace is spent.
#
# Timings are scaled down so the run takes seconds.
#
# Run inside the sigul bridge image:
#   python3 test/test_bridge_slow_client.py

# pyright: reportUnknownMemberType=false, reportUnknownArgumentType=false
# pyright: reportUnknownVariableType=false, reportAttributeAccessIssue=false
#
# double_tls and utils are upstream code this repository only patches,
# and ship no type stubs, so their members are untyped by nature.

import inspect
import os
import socket
import sys
import threading
import time
from collections.abc import Callable
from typing import Protocol, cast

sys.path.insert(0, os.environ.get("SIGUL_LIB", "/usr/share/sigul"))

import double_tls  # noqa: E402
import nss.io  # noqa: E402
import utils  # noqa: E402

FAILURES: list[str] = []

PATCHED = hasattr(double_tls, "SlowPeerError")


class Buffer(Protocol):
    """The slice of double_tls.OuterBuffer these checks drive."""

    def read(self, buf_size: int) -> bytes: ...
    def write(self, data: bytes) -> None: ...


class FakeSocket:
    """recv/send that take `delay` seconds per call, `chunk` bytes at a time."""

    def __init__(self, delay: float, chunk: int, payload: bytes = b"") -> None:
        self.delay: float = delay
        self.chunk: int = chunk
        self.pending: bytes = payload

    def recv(self, size: int, _interval: object) -> bytes:
        time.sleep(self.delay)
        run = self.pending[: min(size, self.chunk)]
        self.pending = self.pending[len(run) :]
        return run

    def send(self, data: bytes, _interval: object) -> None:
        time.sleep(self.delay * max(1, len(data) // self.chunk))


def framed(data: bytes) -> bytes:
    """data as one outer-stream chunk: a length header, then the bytes."""
    header = cast(bytes, utils.u32_pack(len(data)))
    return header + data


def buffer(sock: FakeSocket, min_rate: int, grace: float) -> Buffer:
    return cast(
        Buffer,
        double_tls.OuterBuffer(
            sock, idle_timeout=None, min_rate=min_rate, rate_grace=grace
        ),
    )


def check(label: str, ok: bool, detail: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if not ok:
        FAILURES.append(label)


def shed(operation: Callable[[], object]) -> str | None:
    """Run operation; return the SlowPeerError message, or None if kept."""
    try:
        _ = operation()
    except double_tls.SlowPeerError as e:
        return str(e)
    return None


def test_fast_client_kept() -> None:
    payload = b"x" * 200_000
    sock = FakeSocket(delay=0.001, chunk=65_536, payload=framed(payload))
    buf = buffer(sock, min_rate=4096, grace=0.2)
    message = shed(lambda: buf.read(len(payload)))
    check("a fast client is kept", message is None, message or "read 200 kB")


def test_trickling_reader_shed() -> None:
    # 100 bytes every 0.05 s: 2 kB/s against a 4 kB/s floor.
    payload = b"x" * 50_000
    sock = FakeSocket(delay=0.05, chunk=100, payload=framed(payload))
    buf = buffer(sock, min_rate=4096, grace=0.5)
    started = time.monotonic()
    message = shed(lambda: buf.read(len(payload)))
    elapsed = time.monotonic() - started
    check(
        "a client trickling its upload is shed once its grace is spent",
        message is not None and elapsed < 2.0,
        f"after {elapsed:.2f}s: {message}",
    )


def test_trickling_writer_shed() -> None:
    # A client reading its reply 100 bytes per 0.05 s.
    sock = FakeSocket(delay=0.05, chunk=100)
    buf = buffer(sock, min_rate=4096, grace=0.5)
    started = time.monotonic()

    def send_reply() -> None:
        for _ in range(40):
            buf.write(b"y" * 1000)

    message = shed(send_reply)
    elapsed = time.monotonic() - started
    check(
        "a client trickling through its reply is shed",
        message is not None and elapsed < 3.0,
        f"after {elapsed:.2f}s: {message}",
    )


def test_fast_start_buys_no_slow_finish() -> None:
    # A burst, then a trickle. A running average would let the burst's
    # bytes cover the trickle for as long as it took the average to
    # decay - hours, for a 64 MiB burst. The rolling window must not.
    burst = b"x" * 2_000_000
    tail = b"y" * 50_000
    sock = FakeSocket(delay=0.0, chunk=1_000_000, payload=framed(burst))
    buf = buffer(sock, min_rate=4096, grace=0.5)
    _ = buf.read(len(burst))  # fast
    sock.delay, sock.chunk, sock.pending = 0.05, 100, framed(tail)
    started = time.monotonic()
    message = shed(lambda: buf.read(len(tail)))
    elapsed = time.monotonic() - started
    check(
        "a fast start does not buy a slow finish",
        message is not None and elapsed < 2.0,
        f"shed {elapsed:.2f}s into the trickle after a 2 MB burst: {message}",
    )


def test_burst_expires_with_its_window() -> None:
    # A burst, then transfers each waiting almost a whole window. The
    # first slow wait must not be merged into the burst's bucket: that
    # kept the burst's bytes in the window for a second whole window,
    # shedding a client moving ~100 bytes a window one transfer late.
    burst = b"x" * 2_000_000
    tail = b"y" * 400
    sock = FakeSocket(delay=0.0, chunk=1_000_000, payload=framed(burst))
    buf = buffer(sock, min_rate=4096, grace=1.0)
    _ = buf.read(len(burst))  # fast
    sock.delay, sock.chunk, sock.pending = 0.98, 100, framed(tail)
    started = time.monotonic()
    message = shed(lambda: buf.read(len(tail)))
    elapsed = time.monotonic() - started
    check(
        "a burst leaves the window a window after it",
        message is not None and elapsed < 2.45,
        f"shed {elapsed:.2f}s into 100 B per 0.98s after 2 MB, window 1s: {message}",
    )


def test_fast_writer_kept() -> None:
    # Sends return nothing: their bytes must still be counted.
    sock = FakeSocket(delay=0.001, chunk=65_536)
    buf = buffer(sock, min_rate=4096, grace=0.2)

    def send_reply() -> None:
        for _ in range(400):
            buf.write(b"y" * 4000)

    message = shed(send_reply)
    check(
        "a client reading its reply quickly is kept",
        message is None,
        message or "sent 1.6 MB",
    )


def test_slow_client_inside_grace_kept() -> None:
    # Below the floor, but the whole transfer fits inside the grace.
    payload = b"x" * 1_000
    sock = FakeSocket(delay=0.05, chunk=100, payload=framed(payload))
    buf = buffer(sock, min_rate=4096, grace=5.0)
    message = shed(lambda: buf.read(len(payload)))
    check(
        "a slow client inside its grace is kept",
        message is None,
        message or "read 1 kB",
    )


def test_idle_while_server_works_kept() -> None:
    # The caller spends long stretches elsewhere - as the bridge does,
    # waiting on the server while it signs - between fast transfers.
    # That time is not the client's, and must not count against it.
    chunk = b"x" * 1_000
    sock = FakeSocket(delay=0.001, chunk=65_536, payload=framed(chunk) * 3)
    buf = buffer(sock, min_rate=4096, grace=0.2)

    def phases() -> None:
        for _ in range(3):
            _ = buf.read(len(chunk))
            time.sleep(0.5)  # the server signing; the client correctly idle

    message = shed(phases)
    check(
        "a client idle while the server works is kept",
        message is None,
        message or "1.5s of server time between three fast reads",
    )


def test_no_floor_by_default() -> None:
    payload = b"x" * 5_000
    sock = FakeSocket(delay=0.05, chunk=100, payload=framed(payload))
    buf = cast(Buffer, double_tls.OuterBuffer(sock, idle_timeout=None))
    message = shed(lambda: buf.read(len(payload)))
    check(
        "a buffer given no floor never sheds - the server's side",
        message is None,
        message or "slow read of 5 kB kept",
    )


def test_no_floor_keeps_no_history() -> None:
    # The server's buffer has no floor and lives as long as its
    # connection: it must not record every transfer it makes.
    payload = b"x" * 400_000
    sock = FakeSocket(delay=0.0, chunk=100, payload=framed(payload))
    buf = double_tls.OuterBuffer(sock, idle_timeout=None)
    _ = cast(Buffer, buf).read(len(payload))
    kept = len(getattr(buf, "_OuterBuffer__transfers", ()))
    check(
        "a buffer with no floor keeps no transfer history",
        kept == 0,
        f"{kept} transfers recorded over 4000 receives",
    )


def test_history_bounded_by_window() -> None:
    # A peer chopping its data into one-byte transfers must not grow the
    # history: it is kept in buckets of the window, not per transfer.
    payload = b"x" * 20_000
    sock = FakeSocket(delay=0.0, chunk=1, payload=framed(payload))
    buf = double_tls.OuterBuffer(sock, idle_timeout=None, min_rate=1, rate_grace=60.0)
    _ = cast(Buffer, buf).read(len(payload))
    kept = len(getattr(buf, "_OuterBuffer__transfers", ()))
    check(
        "the rate history is bounded by the window, not the transfer count",
        kept <= 61,
        f"{kept} entries kept over 20000 one-byte receives",
    )


INNER_PHASE = 2.0


def _nspr_pair() -> tuple[socket.socket, object]:
    """A loopback connection: a plain socket, and the NSPR socket it reached."""
    listener = nss.io.Socket(nss.io.PR_AF_INET)
    listener.set_socket_option(nss.io.PR_SockOpt_Reuseaddr, True)
    listener.bind(nss.io.NetworkAddress(nss.io.PR_IpAddrLoopback, 0))
    listener.listen(1)
    peer = socket.create_connection(("127.0.0.1", listener.get_sock_name().port))
    accepted = listener.accept()[0]
    _ = listener.close()
    return peer, accepted


def _inner(data: bytes) -> bytes:
    """data as one inner-stream chunk; b"" is the inner stream's end."""
    header = cast(bytes, utils.u32_pack(double_tls._chunk_inner_mask | len(data)))
    return header + data


def _relay_inner(
    feed: Callable[[socket.socket, socket.socket], None],
) -> tuple[str | None, float]:
    """Run the bridge's inner relay while feed(client, server) plays both peers.

    Returns how the relay ended - None if it finished, else the name and
    message of the IdleTimeoutError that ended it - and how long it ran.
    """
    client_peer, client_sock = _nspr_pair()
    server_peer, server_sock = _nspr_pair()
    client_buf = double_tls.OuterBuffer(client_sock, idle_timeout=None)
    server_buf = double_tls.OuterBuffer(server_sock, idle_timeout=None)
    bounds: dict[str, float] = {"idle_timeout": 30.0}
    if "phase_timeout" in inspect.signature(double_tls.bridge_inner_stream).parameters:
        bounds["phase_timeout"] = INNER_PHASE
    feeder = threading.Thread(target=feed, args=(client_peer, server_peer), daemon=True)
    feeder.start()
    started = time.monotonic()
    message: str | None = None
    try:
        double_tls.bridge_inner_stream(client_buf, server_buf, **bounds)
    except double_tls.IdleTimeoutError as e:
        message = f"{type(e).__name__}: {e}"
    elapsed = time.monotonic() - started
    for peer in (client_peer, server_peer):
        peer.close()
    feeder.join(timeout=10)
    return message, elapsed


def _drain(sock: socket.socket) -> None:
    """Read whatever the relay has forwarded; the relay may close it first."""
    try:
        sock.settimeout(0.05)
        while sock.recv(65536):
            pass
    except OSError:
        pass


def test_inner_trickle_shed() -> None:
    # The inner stream is relayed on the raw sockets, past the outer
    # buffers' floor. A client trickling a byte of it every half second
    # never trips the idle deadline, and must be shed by the phase bound.
    def feed(client: socket.socket, server: socket.socket) -> None:
        deadline = time.monotonic() + INNER_PHASE * 4
        try:
            while time.monotonic() < deadline:
                client.sendall(_inner(b"x"))
                _drain(server)
                time.sleep(0.5)
        except OSError:
            pass

    message, elapsed = _relay_inner(feed)
    check(
        "a client trickling through the inner stream is shed",
        message is not None
        and message.startswith("SlowPeerError")
        and elapsed < INNER_PHASE + 1.5,
        f"after {elapsed:.2f}s, phase bound {INNER_PHASE:.0f}s: {message}",
    )


def test_inner_exchange_kept() -> None:
    # An ordinary inner exchange - a few kilobytes each way, then each
    # side's end of stream - finishes, well inside the bound.
    def feed(client: socket.socket, server: socket.socket) -> None:
        client.sendall(_inner(b"c" * 4096) + _inner(b""))
        server.sendall(_inner(b"s" * 4096) + _inner(b""))
        _drain(client)
        _drain(server)

    message, elapsed = _relay_inner(feed)
    check(
        "an ordinary inner exchange is kept",
        message is None and elapsed < 1.0,
        f"finished in {elapsed:.2f}s" if message is None else f"shed: {message}",
    )


def test_slow_inner_exchange_inside_bound_kept() -> None:
    # A slow server handshake inside the bound is not a trickle.
    def feed(client: socket.socket, server: socket.socket) -> None:
        client.sendall(_inner(b"c" * 512) + _inner(b""))
        time.sleep(INNER_PHASE / 2)
        server.sendall(_inner(b"s" * 512) + _inner(b""))
        _drain(client)
        _drain(server)

    message, elapsed = _relay_inner(feed)
    check(
        "a slow inner exchange inside the bound is kept",
        message is None,
        f"finished in {elapsed:.2f}s" if message is None else f"shed: {message}",
    )


def test_floor_needs_a_window() -> None:
    try:
        _ = double_tls.OuterBuffer(FakeSocket(0.0, 1), idle_timeout=None, min_rate=4096)
        rejected = False
    except ValueError:
        rejected = True
    check(
        "a floor without a window is refused, not silently disabled",
        rejected,
        "ValueError" if rejected else "accepted",
    )


def main() -> int:
    print("Bridge client throughput floor regression tests")
    print(f"double_tls: {'PATCHED' if PATCHED else 'UNPATCHED'}")
    print()
    if not PATCHED:
        print("FAIL  double_tls has no SlowPeerError: patch 18 is not applied")
        return 1
    test_fast_client_kept()
    test_trickling_reader_shed()
    test_trickling_writer_shed()
    test_fast_start_buys_no_slow_finish()
    test_burst_expires_with_its_window()
    test_fast_writer_kept()
    test_slow_client_inside_grace_kept()
    test_idle_while_server_works_kept()
    test_no_floor_by_default()
    test_no_floor_keeps_no_history()
    test_history_bounded_by_window()
    test_floor_needs_a_window()
    test_inner_trickle_shed()
    test_inner_exchange_kept()
    test_slow_inner_exchange_inside_bound_kept()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("a trickling client is shed; a slow or waiting one is not")
    return 0


if __name__ == "__main__":
    sys.exit(main())
