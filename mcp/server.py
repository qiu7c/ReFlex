import argparse
import base64
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
    request_prefix = ''
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
                    body = (request_prefix + pending).encode("ascii") if pending else b""
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
                trace = snapshot.get("callTrace") if isinstance(snapshot, dict) else None
                if not valid_snapshot(snapshot) and not (
                    isinstance(trace, dict) and trace.get("status") in (
                        "pending_confirmation", "idle", "waiting", "captured", "expired", "cancelled"
                    )
                ):
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

    def fetch_snapshot(class_dump: str | None = None, trace_payload: str | None = None) -> dict:
        nonlocal pending, latest, request_prefix
        if args.snapshot is not None:
            if class_dump is not None or trace_payload is not None:
                raise ValueError("This tool requires a live ReFlex LAN session.")
            snapshot = json.loads(args.snapshot.read_text(encoding="utf-8"))
            if not valid_snapshot(snapshot):
                raise ValueError("Expected a ReFlex page snapshot with schemaVersion 1.")
            return snapshot
        with condition:
            if pending is not None:
                raise ValueError("A page refresh is in progress. Retry in a moment.")
            pending = uuid4().hex
            request_prefix = ""
            if trace_payload is not None:
                request_prefix = f"trace:{trace_payload}:"
            elif class_dump is not None:
                request_prefix = f"header:{class_dump}:"
            latest = None
            try:
                if not condition.wait_for(lambda: latest is not None, timeout=8):
                    raise ValueError("Phone did not respond. Open the host app and enable the ReFlex LAN session.")
                return latest
            finally:
                pending = None
                latest = None

    @server.tool()
    def read_page_snapshot() -> dict:
        """Fetch the phone's current UIKit page and selected control, or read the configured local export."""
        return fetch_snapshot()

    @server.tool()
    def class_dump_current_controller() -> dict:
        """Generate an Objective-C interface header for the live page controller."""
        snapshot = fetch_snapshot(class_dump="")
        header = snapshot.get("classDumpHeader")
        if not header:
            raise ValueError("The phone could not generate a header for the current controller.")
        return {"class": snapshot["controllerClass"], "header": header}

    @server.tool()
    def class_dump_class(class_name: str) -> dict:
        """Generate an interface for a named Objective-C class or protocol in the current app."""
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]{0,255}", class_name):
            raise ValueError("Enter the exact Objective-C class or protocol name.")
        snapshot = fetch_snapshot(class_dump=class_name)
        header = snapshot.get("classDumpHeader")
        if not header:
            raise ValueError(f"No declaration found for {class_name} in the current app.")
        return {"name": class_name, "header": header}

    @server.tool()
    def inspect_selected_view() -> dict:
        """Read the selected UIKit control and its stored delegate class, when available."""
        snapshot = fetch_snapshot()
        selection = snapshot.get("selectedView")
        if selection is None:
            raise ValueError("Select a control on the current page using the ReFlex toolbar.")
        return {"controllerClass": snapshot["controllerClass"], "selectedView": selection}

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

    @server.tool()
    def prepare_call_trace(probe: str, fields: list[str], seconds: int = 60) -> dict:
        """Propose a one-shot task for an explicit debug probe. Confirm it on the phone."""
        identifier = r"[A-Za-z_][A-Za-z0-9_.]{0,63}"
        if not (
            re.fullmatch(identifier, probe)
            and 1 <= len(fields) <= 16
            and all(re.fullmatch(identifier, field) for field in fields)
            and 5 <= seconds <= 300
        ):
            raise ValueError("Use an explicit probe name, 1–16 field names, and 5–300 seconds.")
        task = {"probe": probe, "fields": fields, "seconds": seconds}
        payload = base64.b64encode(json.dumps(task).encode("ascii")).decode("ascii")
        return fetch_snapshot(trace_payload=payload)["callTrace"]

    @server.tool()
    def read_call_trace() -> dict:
        """Read the current explicit probe task status and first captured metadata."""
        return fetch_snapshot(trace_payload="")["callTrace"]

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
        and isinstance(snapshot.get("classDumpHeader", ""), str)
        and isinstance(snapshot.get("selectedView", {}), dict)
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
