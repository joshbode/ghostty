#!/usr/bin/env python3

"""Write a multipart payload to the clipboard with the Kitty clipboard
protocol (OSC 5522).

This is the way to reach the clipboard confirmation dialog's multipart
preview, which shows one page per representation. OSC 52 can't get
there: it carries text and nothing else.

Run it in a Ghostty started with the write prompt turned on, since
`clipboard-write` defaults to `allow`:

    ghostty --clipboard-write=ask

then, in that terminal:

    ./test/clipboard-multipart.py

The dialog should offer text/plain, text/html, image/png and
application/octet-stream, previewed as text, text, an image, and a note
that it can't be previewed. Each page is logged at debug level:

    clipboard confirmation preview mime=image/png bytes=73 shown as image
    clipboard confirmation preview parts=4 text=true

The escape sequences go to stdout, so this has to run with stdout
attached to the terminal rather than redirected.
"""

import base64
import struct
import sys
import zlib


def b64(value: bytes | str) -> str:
    """Encode a payload or a metadata value the way OSC 5522 wants it."""
    return base64.b64encode(
        value.encode() if isinstance(value, str) else value
    ).decode()


def png(width: int = 2, height: int = 2, rgb: bytes = b"\xff\x00\x00") -> bytes:
    """A tiny solid color PNG, built here so this needs no fixture files."""

    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        return (
            struct.pack(">I", len(data))
            + body
            + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
        )

    raw = b"".join(b"\x00" + rgb * width for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


# One representation of each kind the preview handles differently: text it
# can show, an image it can decode, and bytes it can do neither with.
PARTS: list[tuple[str, bytes]] = [
    ("text/plain", b"Ghostty multipart clipboard"),
    ("text/html", b"<b>Ghostty</b> multipart clipboard"),
    ("image/png", png()),
    ("application/octet-stream", bytes(range(256)) * 8),
]


def main() -> None:
    # A transaction is opened by `type=write`, carries one `type=wdata`
    # packet per representation, and is committed by a `type=wdata` with
    # no MIME type.
    packets = ["\x1b]5522;type=write\x1b\\"]
    for mime, data in PARTS:
        packets.append(
            f"\x1b]5522;type=wdata:mime={b64(mime)};{b64(data)}\x1b\\"
        )
    packets.append("\x1b]5522;type=wdata\x1b\\")

    sys.stdout.write("".join(packets))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
