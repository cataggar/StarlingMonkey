"""Minimal, stdlib-only JSON Schema (draft-07 subset) validator.

tests/compat/manifest.json declares `"$schema": "./schema/manifest.schema.json"`
but, until this module existed, nothing in this repository actually checked
the manifest against it -- the schema was purely informational (see
cataggar/StarlingMonkey#6 code review). Pulling in the `jsonschema` PyPI
package (or any other third-party dependency) to fix that would be a
heavyweight addition for a small, fixed vocabulary; this module implements
just the draft-07 keywords tests/compat/schema/manifest.schema.json actually
uses -- "type" (including arrays-of-types), "required", "properties",
"items", "enum", "pattern", and "minimum" -- using only `json` and `re` from
the standard library. It is intentionally not a general-purpose JSON Schema
implementation: if manifest.schema.json starts using a keyword this module
doesn't know, `validate()` raises `UnsupportedKeyword` rather than silently
ignoring it, so schema/harness drift is a loud failure, not an unnoticed gap.
"""
from __future__ import annotations

from typing import Any

_SUPPORTED_KEYWORDS = {
    "$schema", "$id", "title", "description",  # metadata / documentation only
    "type", "required", "properties", "items", "enum", "pattern", "minimum",
}

_TYPE_MAP = {
    "object": dict,
    "array": list,
    "string": str,
    "integer": int,
    "number": (int, float),
    "boolean": bool,
    "null": type(None),
}


class SchemaValidationError(ValueError):
    def __init__(self, path: str, message: str) -> None:
        super().__init__(f"{path or '<root>'}: {message}")
        self.path = path


class UnsupportedKeyword(NotImplementedError):
    pass


def _check_type(instance: Any, type_decl: str | list[str], path: str) -> None:
    types = type_decl if isinstance(type_decl, list) else [type_decl]
    py_types = []
    for t in types:
        if t not in _TYPE_MAP:
            raise UnsupportedKeyword(f"unknown schema type '{t}' at {path}")
        py_types.append(_TYPE_MAP[t])
    flattened = tuple(py_types) if not any(isinstance(t, tuple) for t in py_types) else tuple(
        sum(((t,) if not isinstance(t, tuple) else t for t in py_types), ())
    )
    # bool is a subclass of int in Python; only accept it for an explicit "boolean" type.
    if isinstance(instance, bool) and bool not in py_types and "integer" in types:
        raise SchemaValidationError(path, f"expected {types}, got boolean")
    if not isinstance(instance, flattened):
        raise SchemaValidationError(path, f"expected type {types}, got {type(instance).__name__}")


def _validate(instance: Any, schema: dict[str, Any], path: str) -> None:
    unknown = set(schema) - _SUPPORTED_KEYWORDS
    if unknown:
        raise UnsupportedKeyword(f"unsupported schema keyword(s) {sorted(unknown)} at {path}")

    if "type" in schema:
        _check_type(instance, schema["type"], path)

    if "enum" in schema and instance not in schema["enum"]:
        raise SchemaValidationError(path, f"{instance!r} is not one of {schema['enum']}")

    if "pattern" in schema:
        import re
        if not isinstance(instance, str):
            raise SchemaValidationError(path, "pattern requires a string instance")
        if re.search(schema["pattern"], instance) is None:
            raise SchemaValidationError(path, f"{instance!r} does not match pattern {schema['pattern']!r}")

    if "minimum" in schema:
        if not isinstance(instance, (int, float)) or isinstance(instance, bool):
            raise SchemaValidationError(path, "minimum requires a numeric instance")
        if instance < schema["minimum"]:
            raise SchemaValidationError(path, f"{instance} is less than minimum {schema['minimum']}")

    if "required" in schema:
        if not isinstance(instance, dict):
            raise SchemaValidationError(path, "required requires an object instance")
        missing = [k for k in schema["required"] if k not in instance]
        if missing:
            raise SchemaValidationError(path, f"missing required propert{'y' if len(missing)==1 else 'ies'}: {missing}")

    if "properties" in schema:
        if not isinstance(instance, dict):
            raise SchemaValidationError(path, "properties requires an object instance")
        for key, subschema in schema["properties"].items():
            if key in instance:
                _validate(instance[key], subschema, f"{path}.{key}" if path else key)

    if "items" in schema:
        if not isinstance(instance, list):
            raise SchemaValidationError(path, "items requires an array instance")
        for i, item in enumerate(instance):
            _validate(item, schema["items"], f"{path}[{i}]")


def validate(instance: Any, schema: dict[str, Any]) -> None:
    """Validate `instance` against `schema` (a parsed draft-07-subset JSON
    Schema document as described in this module's docstring).

    Raises SchemaValidationError on the first validation failure found, or
    UnsupportedKeyword if the schema uses a keyword this minimal validator
    does not implement (fail loud, not silently ignore).
    """
    _validate(instance, schema, "")
