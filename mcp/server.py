import argparse
import hmac
import json
import re
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from ipaddress import IPv4Address, IPv4Network
from pathlib import Path
from threading import Condition, Thread
from uuid import uuid4

from mcp.server.fastmcp import FastMCP


def main() -> None:
    parser = argparse.ArgumentParser(description="Serve ReFlex page snapshots over MCP stdio.")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("snapshot", type=Path, nargs="?")
    source.add_argument("--listen", type=IPv4Address, help="Computer's private Wi-Fi IPv4 address.")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token", help="32-character hexadecimal pairing token for LAN mode.")
    args = parser.parse_args()

    server = FastMCP("ReFlex")
    condition = Condition()
    pending = None
    latest = None
    receiver = None

    if args.listen is not None:
        private_ranges = ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
        if not any(args.listen in IPv4Network(network) for network in private_ranges):
            parser.error("--listen requires a private LAN IPv4 address.")
        if not args.token or not re.fullmatch(r"[0-9a-f]{32}", args.token):
            parser.error("--token requires 32 lowercase hexadecimal characters.")
        expected_auth = f"Bearer {args.token}".encode("ascii")

        class SnapshotReceiver(BaseHTTPRequestHandler):
            def setup(self) -> None:
                self.request.settimeout(10)
                super().setup()

            def authorized(self) -> bool:
                supplied = self.headers.get("Authorization", "").encode("latin-1")
                if hmac.compare_digest(supplied, expected_auth):
                    return True
                self.send_error(HTTPStatus.UNAUTHORIZED)
                return False

            def do_GET(self) -> None:
                if not self.authorized():
                    return
                if self.path != "/request":
                    self.send_error(HTTPStatus.NOT_FOUND)
                    return
                with condition:
                    request_id = pending
                body = (request_id or "").encode("ascii")
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self) -> None:
                nonlocal latest
                if not self.authorized():
                    return
                request_id = self.path.removeprefix("/snapshot/")
                if not self.path.startswith("/snapshot/") or not re.fullmatch(r"[0-9a-f]{32}", request_id):
                    self.send_error(HTTPStatus.NOT_FOUND)
                    return
                length = self.headers.get("Content-Length", "")
                if not re.fullmatch(r"[0-9]{1,7}", length) or not 0 < int(length) <= 4_000_000:
                    self.send_error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
                    return
                try:
                    snapshot = json.loads(self.rfile.read(int(length)).decode("utf-8"))
                except (UnicodeError, ValueError, RecursionError):
                    self.send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                    return
                if not valid_snapshot(snapshot):
                    self.send_error(HTTPStatus.BAD_REQUEST, "Invalid ReFlex snapshot")
                    return
                with condition:
                    accepted = request_id == pending and latest is None
                    if accepted:
                        latest = snapshot
                        condition.notify_all()
                if not accepted:
                    self.send_error(HTTPStatus.CONFLICT)
                    return
                self.send_response(HTTPStatus.NO_CONTENT)
                self.end_headers()

        receiver = ThreadingHTTPServer((str(args.listen), args.port), SnapshotReceiver)
        Thread(target=receiver.serve_forever, daemon=True).start()

    @server.tool()
    def read_page_snapshot() -> dict:
        """Fetch the phone's current UIKit page and selected control, or read the configured local export."""
        nonlocal pending, latest
        if args.snapshot is not None:
            snapshot = json.loads(args.snapshot.read_text(encoding="utf-8"))
            if not valid_snapshot(snapshot):
                raise ValueError("Expected a ReFlex page snapshot with schemaVersion 1.")
            return snapshot
        with condition:
            if pending is not None:
                raise ValueError("A page refresh is in progress. Retry in a moment.")
            pending = uuid4().hex
            latest = None
            try:
                if not condition.wait_for(lambda: latest is not None, timeout=8):
                    raise ValueError("Phone did not respond. Open the host app and enable the ReFlex LAN session.")
                return latest
            finally:
                pending = None
                latest = None

    @server.tool()
    def inspect_controller_runtime(query: str = "") -> dict:
        """Filter the current page controller's captured method selectors by substring."""
        snapshot = read_page_snapshot()
        runtime = snapshot.get("runtime")
        if runtime is None:
            raise ValueError("Enable the ReFlex LAN session to capture Runtime metadata.")
        term = query.casefold()
        return {
            "controllerClass": snapshot["controllerClass"],
            **{
                kind: [name for name in runtime[kind] if term in name.casefold()]
                for kind in ("instanceMethods", "classMethods")
            },
        }

    try:
        server.run(transport="stdio")
    finally:
        if receiver is not None:
            receiver.shutdown()
            receiver.server_close()


def valid_snapshot(snapshot: object) -> bool:
    return (
        isinstance(snapshot, dict)
        and snapshot.get("schemaVersion") == 1
        and isinstance(snapshot.get("controllerClass"), str)
        and isinstance(snapshot.get("rootView"), dict)
        and (
            "runtime" not in snapshot
            or (
                isinstance(runtime := snapshot["runtime"], dict)
                and all(
                    isinstance(names := runtime.get(kind), list)
                    and all(isinstance(name, str) for name in names)
                    for kind in ("instanceMethods", "classMethods")
                )
            )
        )
    )


if __name__ == "__main__":
    main()
