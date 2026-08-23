#!/usr/bin/env python3
"""Send an NPC or monster image to the iPad display app."""

from __future__ import annotations

import argparse
import base64
import io
import json
import socket
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional
from urllib import error as urlerror
from urllib import request as urlrequest

COLOR_NAMES = {
    "black": "#000000",
    "white": "#ffffff",
    "gray": "#808080",
    "grey": "#808080",
    "red": "#ff0000",
    "green": "#00ff00",
    "blue": "#0000ff",
}
BONJOUR_SERVICE_TYPE = "_npc-image._tcp.local."


@dataclass(frozen=True)
class DisplayTarget:
    host: str
    port: int
    name: str

    @property
    def label(self) -> str:
        return f"{self.name} at {self.host}:{self.port}"


def register_heif_opener() -> None:
    try:
        from pillow_heif import register_heif_opener
    except ImportError:
        return

    register_heif_opener()


def load_with_pillow(path: Path) -> Any:
    from PIL import Image, ImageOps

    register_heif_opener()
    with Image.open(path) as image:
        return ImageOps.exif_transpose(image).convert("RGBA")


def load_with_sips(path: Path) -> Any:
    from PIL import Image, ImageOps

    with tempfile.TemporaryDirectory() as tmpdir:
        output_path = Path(tmpdir) / "converted.png"
        try:
            subprocess.run(
                ["sips", "-s", "format", "png", str(path), "--out", str(output_path)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
        except FileNotFoundError as exc:
            raise RuntimeError("macOS 'sips' command is not available") from exc
        except subprocess.CalledProcessError as exc:
            message = exc.stderr.strip() or "sips could not convert the image"
            raise RuntimeError(message) from exc

        with Image.open(output_path) as image:
            return ImageOps.exif_transpose(image).convert("RGBA")


def load_image(path: Path) -> Any:
    from PIL import UnidentifiedImageError

    try:
        return load_with_pillow(path)
    except (UnidentifiedImageError, OSError):
        return load_with_sips(path)


def image_to_png_bytes(image: Any, max_edge: Optional[int]) -> bytes:
    if max_edge and max(image.size) > max_edge:
        from PIL import Image

        resampling = getattr(getattr(Image, "Resampling", Image), "LANCZOS")
        image.thumbnail((max_edge, max_edge), resampling)

    output = io.BytesIO()
    image.save(output, format="PNG", optimize=True)
    return output.getvalue()


def normalize_background_color(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None

    color = value.strip().lower()
    if color in COLOR_NAMES:
        return COLOR_NAMES[color]

    if color.startswith("#"):
        hex_value = color[1:]
    else:
        hex_value = color

    if len(hex_value) == 3 and all(character in "0123456789abcdef" for character in hex_value):
        return "#" + "".join(character * 2 for character in hex_value)

    if len(hex_value) == 6 and all(character in "0123456789abcdef" for character in hex_value):
        return "#" + hex_value

    raise RuntimeError("background color must be a name or hex color like '#202020'")


@dataclass
class HTTPResult:
    status_code: int
    text: str

    @property
    def ok(self) -> bool:
        return 200 <= self.status_code < 300

    def json(self) -> Any:
        return json.loads(self.text)


def post_json(url: str, payload: Optional[dict[str, Any]], timeout: float) -> HTTPResult:
    body = json.dumps(payload).encode("utf-8") if payload is not None else b""
    request = urlrequest.Request(url, data=body, method="POST")
    if payload is not None:
        request.add_header("Content-Type", "application/json")
    request.add_header("Accept", "application/json")

    try:
        with urlrequest.urlopen(request, timeout=timeout) as response:
            text = response.read().decode("utf-8", errors="replace")
            return HTTPResult(response.status, text)
    except urlerror.HTTPError as exc:
        text = exc.read().decode("utf-8", errors="replace")
        return HTTPResult(exc.code, text)
    except socket.timeout as exc:
        raise RuntimeError("request failed: timed out waiting for the iPad app to respond") from exc
    except TimeoutError as exc:
        raise RuntimeError("request failed: timed out waiting for the iPad app to respond") from exc
    except urlerror.URLError as exc:
        raise RuntimeError(f"request failed: {exc.reason}") from exc


def send_image(
    ipad_host: str,
    port: int,
    png_bytes: bytes,
    name: str,
    background_color: Optional[str],
    timeout: float,
) -> HTTPResult:
    url = f"http://{ipad_host}:{port}/image"
    payload = {
        "name": name,
        "image": base64.b64encode(png_bytes).decode("ascii"),
    }
    if background_color:
        payload["background_color"] = background_color
    return post_json(url, payload, timeout)


def clear_image(ipad_host: str, port: int, background_color: Optional[str], timeout: float) -> HTTPResult:
    payload = {"background_color": background_color} if background_color else None
    return post_json(f"http://{ipad_host}:{port}/clear", payload, timeout)


class BonjourListener:
    def __init__(self) -> None:
        self.event = threading.Event()
        self.targets: dict[str, DisplayTarget] = {}

    def remove_service(self, zeroconf: Any, service_type: str, name: str) -> None:
        return

    def update_service(self, zeroconf: Any, service_type: str, name: str) -> None:
        self.add_service(zeroconf, service_type, name)

    def add_service(self, zeroconf: Any, service_type: str, name: str) -> None:
        info = zeroconf.get_service_info(service_type, name)
        if info is None:
            return

        host = first_ipv4_address(info)
        if host is None:
            return

        self.targets[name] = DisplayTarget(host=host, port=info.port, name=display_service_name(name))
        self.event.set()


def display_service_name(name: str) -> str:
    suffix = "." + BONJOUR_SERVICE_TYPE
    if name.endswith(suffix):
        return name[: -len(suffix)]
    return name


def first_ipv4_address(info: Any) -> Optional[str]:
    for address in getattr(info, "addresses", []):
        if len(address) == 4:
            return socket.inet_ntoa(address)

    parsed_addresses = getattr(info, "parsed_addresses", None)
    if parsed_addresses is not None:
        for address in parsed_addresses():
            if "." in address:
                return address

    return None


def discover_ipads(timeout: float) -> list[DisplayTarget]:
    try:
        from zeroconf import ServiceBrowser, Zeroconf
    except ImportError as exc:
        raise RuntimeError(
            "Bonjour discovery requires zeroconf. Install with: python -m pip install -r mac_client/requirements.txt"
        ) from exc

    listener = BonjourListener()
    zeroconf = Zeroconf()
    try:
        ServiceBrowser(zeroconf, BONJOUR_SERVICE_TYPE, listener)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            listener.event.wait(timeout=0.1)
            listener.event.clear()
        return sorted(listener.targets.values(), key=lambda target: target.name.lower())
    finally:
        zeroconf.close()


def choose_discovered_target(targets: list[DisplayTarget], selector: Optional[str]) -> DisplayTarget:
    if not targets:
        raise RuntimeError("no NPC Image Display Bonjour service found")

    if selector is None:
        if len(targets) == 1:
            return targets[0]

        lines = ["multiple NPC Image Display targets found:"]
        lines.extend(f"  {index}: {target.label}" for index, target in enumerate(targets, start=1))
        lines.append("choose one with --target NUMBER_OR_NAME")
        raise RuntimeError("\n".join(lines))

    selector = selector.strip()
    if selector.isdigit():
        index = int(selector)
        if 1 <= index <= len(targets):
            return targets[index - 1]
        raise RuntimeError(f"target index {index} is out of range")

    matches = [
        target for target in targets
        if selector.lower() in target.name.lower()
        or selector.lower() in target.host.lower()
        or selector.lower() in target.label.lower()
    ]

    if len(matches) == 1:
        return matches[0]

    if not matches:
        raise RuntimeError(f"no discovered target matched '{selector}'")

    lines = [f"target selector '{selector}' matched multiple displays:"]
    lines.extend(f"  {index}: {target.label}" for index, target in enumerate(targets, start=1) if target in matches)
    lines.append("use a more specific --target value or the target number")
    raise RuntimeError("\n".join(lines))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Send an image to the NPC Image Display iPad app.")
    parser.add_argument("ipad_host", nargs="?", help="iPad IP address or hostname. Omit when using --discover.")
    parser.add_argument("image", nargs="?", type=Path, help="Image path to send")
    parser.add_argument("--name", default="", help="Optional display name metadata. The iPad does not overlay it.")
    parser.add_argument("--port", type=int, help="iPad app port. Defaults to 8080, or the discovered Bonjour port.")
    parser.add_argument("--max-edge", type=int, default=2048, help="Resize longest edge before sending. Use 0 to disable.")
    parser.add_argument("--timeout", type=float, default=10.0, help="HTTP timeout in seconds.")
    parser.add_argument("--discover-timeout", type=float, default=5.0, help="Bonjour discovery timeout in seconds.")
    parser.add_argument("--discover", action="store_true", help="Find the iPad app with Bonjour instead of typing its IP.")
    parser.add_argument("--list-targets", action="store_true", help="List all discovered iPad displays and exit.")
    parser.add_argument("--target", help="When using discovery, choose a display by number, name substring, or IP substring.")
    parser.add_argument("--clear", action="store_true", help="Clear the iPad display instead of sending an image.")
    parser.add_argument(
        "--background-color",
        "--background",
        help="Display background color. Use black, white, gray, red, green, blue, or hex like '#202020'.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    try:
        background_color = normalize_background_color(args.background_color)
        ipad_host = args.ipad_host
        image_path = args.image
        port = args.port or 8080

        if (args.discover or args.list_targets) and image_path is None and ipad_host is not None and not args.clear:
            image_path = Path(ipad_host)
            ipad_host = None

        if args.discover or args.list_targets:
            targets = discover_ipads(args.discover_timeout)

            if args.list_targets:
                if not targets:
                    print("No NPC Image Display targets found")
                    return 1
                for index, target in enumerate(targets, start=1):
                    print(f"{index}: {target.label}")
                return 0

            target = choose_discovered_target(targets, args.target)
            ipad_host = target.host
            port = args.port or target.port
            print(f"discovered {target.label}", file=sys.stderr)

        if ipad_host is None:
            print("error: ipad_host is required unless --discover is used", file=sys.stderr)
            return 2

        if args.clear:
            response = clear_image(ipad_host, port, background_color, args.timeout)
        else:
            if image_path is None:
                print("error: image path is required unless --clear is used", file=sys.stderr)
                return 2
            if not image_path.exists():
                print(f"error: image not found: {image_path}", file=sys.stderr)
                return 2

            image = load_image(image_path)
            max_edge = args.max_edge if args.max_edge > 0 else None
            png_bytes = image_to_png_bytes(image, max_edge)
            name = args.name
            response = send_image(ipad_host, port, png_bytes, name, background_color, args.timeout)

        try:
            body = response.json()
        except json.JSONDecodeError:
            body = response.text

        if response.ok:
            print(body)
            return 0

        print(f"error: server returned HTTP {response.status_code}: {body}", file=sys.stderr)
        return 1
    except ImportError as exc:
        print(
            f"error: missing Python dependency '{exc.name}'. Install with: python -m pip install -r mac_client/requirements.txt",
            file=sys.stderr,
        )
        return 1
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
