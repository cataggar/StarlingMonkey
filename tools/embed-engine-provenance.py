#!/usr/bin/env python3

import hashlib
import pathlib
import re
import sys


SECTION_NAME = b"starling:engine-provenance"
MAGIC = b"\0asm\x01\0\0\0"


def read_uleb(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    shift = 0
    for _ in range(5):
        if offset >= len(data):
            raise ValueError("truncated WebAssembly section length")
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, offset
        shift += 7
    raise ValueError("invalid WebAssembly section length")


def write_uleb(value: int) -> bytes:
    output = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        output.append(byte | (0x80 if value else 0))
        if not value:
            return bytes(output)


def without_existing_provenance(module: bytes) -> bytes:
    if not module.startswith(MAGIC):
        raise ValueError("input is not a WebAssembly 1.0 module")

    output = bytearray(MAGIC)
    offset = len(MAGIC)
    while offset < len(module):
        section_start = offset
        section_id = module[offset]
        offset += 1
        size, payload_start = read_uleb(module, offset)
        section_end = payload_start + size
        if section_end > len(module):
            raise ValueError("truncated WebAssembly section")

        is_provenance = False
        if section_id == 0:
            name_size, name_start = read_uleb(module, payload_start)
            name_end = name_start + name_size
            if name_end > section_end:
                raise ValueError("truncated WebAssembly custom section name")
            is_provenance = module[name_start:name_end] == SECTION_NAME

        if not is_provenance:
            output.extend(module[section_start:section_end])
        offset = section_end
    return bytes(output)


def main() -> None:
    if len(sys.argv) != 7:
        raise SystemExit(
            "usage: embed-engine-provenance.py "
            "<input.wasm> <output.wasm> <host-api> <feature-tuple> "
            "<component-world> <surface-world>"
        )

    source, destination, host_api, features, component_world, surface_world = (
        sys.argv[1:]
    )
    for label, value in (
        ("host API identity", host_api),
        ("component world", component_world),
        ("surface world", surface_world),
    ):
        if (
            not value
            or len(value.encode()) > 256
            or any(ord(char) < 0x20 or char in "\r\n=" for char in value)
        ):
            raise SystemExit(f"invalid {label}")
    if not re.fullmatch(r"[01]{5}", features):
        raise SystemExit("feature tuple must contain exactly five 0/1 values")

    base = without_existing_provenance(pathlib.Path(source).read_bytes())
    digest = hashlib.sha256(base).hexdigest()
    metadata = (
        "schema=1\n"
        f"sha256={digest}\n"
        f"host-api={host_api}\n"
        f"features={features}\n"
        f"component-world={component_world}\n"
        f"surface-world={surface_world}\n"
    ).encode()
    custom_payload = write_uleb(len(SECTION_NAME)) + SECTION_NAME + metadata
    section = b"\0" + write_uleb(len(custom_payload)) + custom_payload
    pathlib.Path(destination).write_bytes(base + section)


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        raise SystemExit(str(error)) from error
