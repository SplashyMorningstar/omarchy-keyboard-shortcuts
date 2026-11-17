#!/usr/bin/env python3
"""Safe user-config helper for the Omarchy Keyboard Shortcuts plugin."""

from __future__ import annotations

import argparse
import datetime as dt
import itertools
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any


PLUGIN_ID = "io.github.splashymorningstar.keybindings"
MODIFIERS = {
    "SUPER": 64,
    "SHIFT": 1,
    "CTRL": 4,
    "ALT": 8,
}
MODIFIER_ORDER = ("SUPER", "CTRL", "ALT", "SHIFT")
KEY_RE = re.compile(r"^[A-Za-z0-9_:+.-]{1,64}$")
APP_ID_RE = re.compile(r"^[^/\\\x00-\x1f\x7f]{1,255}$")
MAX_NAME_LENGTH = 128
MAX_BINDINGS = 300
CAPTURE_WATCHDOG_SECONDS = 180
SYSTEM_ACTIONS = {
    "screenshot": {
        "name": "Screenshot",
        "command": "omarchy-capture-screenshot",
    },
    "lock": {
        "name": "Lock screen",
        "command": "omarchy-system-lock",
    },
    "workspace-next": {
        "name": "Next workspace",
        "command": "hyprctl dispatch workspace +1",
    },
    "workspace-previous": {
        "name": "Previous workspace",
        "command": "hyprctl dispatch workspace -1",
    },
    "volume-up": {
        "name": "Volume up",
        "command": "omarchy-audio-output-volume raise",
    },
    "volume-down": {
        "name": "Volume down",
        "command": "omarchy-audio-output-volume lower",
    },
    "volume-mute": {
        "name": "Toggle mute",
        "command": "omarchy-audio-output-volume mute-toggle",
    },
}


def config_dir() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))


def state_dir() -> Path:
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "omarchy" / "keybindings-manager"


def bindings_file() -> Path:
    return config_dir() / "hypr" / "bindings.lua"


def generated_file() -> Path:
    return config_dir() / "hypr" / "omarchy-keybindings.lua"


def database_file() -> Path:
    return state_dir() / "bindings.json"


def backup_dir() -> Path:
    return state_dir() / "backups"


def capture_state_file() -> Path:
    return state_dir() / "capture-session.json"


def emit(value: dict[str, Any]) -> None:
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def clean_text(value: str, limit: int = MAX_NAME_LENGTH) -> str:
    cleaned = "".join(ch for ch in str(value) if ch >= " " and ch != "\x7f")
    return cleaned.strip()[:limit]


def lua_string(value: str) -> str:
    """Return a Lua quoted string literal, escaping every control byte."""
    result = ['"']
    for char in str(value):
        code = ord(char)
        if char == "\\":
            result.append("\\\\")
        elif char == '"':
            result.append('\\"')
        elif char == "\n":
            result.append("\\n")
        elif char == "\r":
            result.append("\\r")
        elif char == "\t":
            result.append("\\t")
        elif code < 32 or code == 127:
            result.append(f"\\{code:03d}")
        else:
            result.append(char)
    result.append('"')
    return "".join(result)


def normalize_chord(value: str) -> tuple[str, int, str]:
    """Validate a chord and return its spelling, modifier mask, and key."""
    parts = [part.strip() for part in str(value).split("+")]
    if not parts or any(not part for part in parts):
        raise ValueError("invalid key combination")

    key_parts = [part for part in parts if part.upper() not in MODIFIERS]
    modifiers = [part.upper() for part in parts if part.upper() in MODIFIERS]
    if len(key_parts) != 1 or len(set(modifiers)) != len(modifiers):
        raise ValueError("use one key and each modifier at most once")

    key = key_parts[0]
    if not KEY_RE.fullmatch(key):
        raise ValueError("unsupported key name")
    if key.upper() in MODIFIERS:
        raise ValueError("a modifier cannot be used as the main key")

    ordered = [mod for mod in MODIFIER_ORDER if mod in modifiers] + [key]
    mask = 0
    for modifier in modifiers:
        mask |= MODIFIERS[modifier]
    return " + ".join(ordered), mask, key


def chord_from_bind(bind: dict[str, Any]) -> tuple[str, int, str] | None:
    try:
        key = str(bind.get("key", "")).strip()
        if not key and bind.get("keycode") is not None:
            keycode = int(bind["keycode"])
            if keycode < 0:
                return None
            key = f"code:{keycode}"
        if not KEY_RE.fullmatch(key):
            return None
        mask = int(bind.get("modmask", 0))
        if mask < 0 or mask & ~sum(MODIFIERS.values()):
            return None
        mods = [name for name in MODIFIER_ORDER if mask & MODIFIERS[name]]
        return " + ".join(mods + [key]), mask, key
    except (TypeError, ValueError):
        return None


def unbind_variants(mask: int, key: str) -> list[str]:
    """Return modifier orderings Hyprland may require for an existing bind."""
    modifiers = [name for name in MODIFIER_ORDER if mask & MODIFIERS[name]]
    return [
        " + ".join((*ordered, key))
        for ordered in itertools.permutations(modifiers)
    ]


def load_records() -> list[dict[str, Any]]:
    path = database_file()
    if not path.exists():
        return []
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"couldn't read shortcut data: {error}") from error
    if not isinstance(value, list):
        raise ValueError("shortcut data has an invalid format")
    records = []
    for entry in value[:MAX_BINDINGS]:
        if not isinstance(entry, dict):
            continue
        try:
            keys, _, _ = normalize_chord(entry.get("keys", ""))
            kind = str(entry.get("kind", "application"))
            if kind not in {"application", "system"}:
                continue
            action_id = str(entry.get("actionId", ""))
            if kind == "application":
                desktop_id = str(entry.get("desktopId", ""))
                if not APP_ID_RE.fullmatch(desktop_id):
                    continue
                name = clean_text(entry.get("name", "")) or desktop_id
            else:
                action = SYSTEM_ACTIONS.get(action_id)
                if not action:
                    continue
                desktop_id = ""
                name = clean_text(entry.get("name", "")) or action["name"]
            removals = []
            for raw_key in entry.get("removeKeys", []):
                try:
                    normalized, _, _ = normalize_chord(raw_key)
                    if normalized not in removals:
                        removals.append(normalized)
                except (TypeError, ValueError):
                    continue
            original_keys = ""
            if entry.get("originalKeys"):
                original_keys = normalize_chord(entry["originalKeys"])[0]
            records.append(
                {
                    "id": str(entry.get("id", ""))[:64],
                    "kind": kind,
                    "desktopId": desktop_id,
                    "name": name,
                    "keys": keys,
                    "removeKeys": removals,
                    "originalKeys": original_keys,
                    "originalDescription": clean_text(entry.get("originalDescription", "")),
                    **({"actionId": action_id} if kind == "system" else {}),
                }
            )
        except (TypeError, ValueError):
            continue
    return records


def write_atomic(path: Path, content: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def backup_file(path: Path) -> None:
    if not path.exists():
        return
    destination_dir = backup_dir()
    destination_dir.mkdir(parents=True, exist_ok=True)
    timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    destination = destination_dir / f"{path.name}.{timestamp}.bak"
    shutil.copy2(path, destination)


def render_lua(records: list[dict[str, Any]]) -> bytes:
    lines = [
        f"-- Generated by {PLUGIN_ID}. Changes made here may be overwritten.",
        "",
    ]
    for record in records:
        removals = list(record.get("removeKeys", []))
        original = record.get("originalKeys", "")
        if original and original not in removals:
            removals.append(original)
        for key in removals:
            lines.append(f"hl.unbind({lua_string(key)})")
        if record.get("kind", "application") == "system":
            action = SYSTEM_ACTIONS.get(str(record.get("actionId", "")))
            if not action:
                continue
            lines.append(
                "o.bind("
                + ", ".join(
                    (
                        lua_string(record["keys"]),
                        lua_string(record["name"]),
                        lua_string(action["command"]),
                    )
                )
                + ")"
            )
        else:
            launch = "gtk-launch " + shlex.quote(str(record["desktopId"]) + ".desktop")
            lines.append(
                "o.bind("
                + ", ".join(
                    (
                        lua_string(record["keys"]),
                        lua_string(record["name"]),
                        "{ launch = " + lua_string(launch) + " }",
                    )
                )
                + ")"
            )
        lines.append("")
    lines.append('require("hypr.omarchy-keybindings-custom")')
    return ("\n".join(lines).rstrip() + "\n").encode("utf-8")


def current_binds() -> list[dict[str, Any]]:
    result = subprocess.run(
        ["hyprctl", "-j", "binds"],
        text=True,
        capture_output=True,
        timeout=8,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(clean_text(result.stderr or result.stdout) or "Hyprland is unavailable")
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("Hyprland returned invalid keybinding data") from error
    if not isinstance(data, list):
        raise RuntimeError("Hyprland returned invalid keybinding data")
    return [entry for entry in data if isinstance(entry, dict)]


def system_bindings() -> list[dict[str, Any]]:
    records = load_records()
    managed_keys = set()
    for record in records:
        managed_keys.add(record["keys"].casefold())
        managed_keys.update(key.casefold() for key in record["removeKeys"])
        if record["originalKeys"]:
            managed_keys.add(record["originalKeys"].casefold())

    result = []
    seen = set()
    for bind in current_binds():
        if bind.get("mouse") or bind.get("submap") or not bind.get("description"):
            continue
        chord = chord_from_bind(bind)
        if chord is None:
            continue
        keys, mask, key = chord
        if keys.casefold() in managed_keys:
            continue
        signature = (mask, key.casefold())
        if signature in seen:
            continue
        seen.add(signature)
        result.append(
            {
                "keys": keys,
                "description": clean_text(bind.get("description", "")),
                "source": "system",
            }
        )
    result.sort(key=lambda entry: (entry["description"].casefold(), entry["keys"].casefold()))
    return result[:MAX_BINDINGS]


def find_conflict_details(chord: str, ignored_keys: set[str]) -> dict[str, Any] | None:
    _, wanted_mask, wanted_key = normalize_chord(chord)
    descriptions = []
    found_keys = ""
    for bind in current_binds():
        if bind.get("mouse") or bind.get("submap"):
            continue
        current = chord_from_bind(bind)
        if current is None:
            continue
        keys, mask, key = current
        if keys.casefold() in ignored_keys:
            continue
        if mask == wanted_mask and key.casefold() == wanted_key.casefold():
            found_keys = found_keys or keys
            description = clean_text(bind.get("description", ""))
            if description and description not in descriptions:
                descriptions.append(description)
    if not found_keys:
        return None
    return {
        "keys": found_keys,
        "description": " / ".join(descriptions) or found_keys,
        "source": "hyprland",
        "recordId": "",
        "replaceable": True,
    }


def find_conflict(chord: str, ignored_keys: set[str]) -> str:
    conflict = find_conflict_details(chord, ignored_keys)
    return conflict["description"] if conflict else ""


def find_record_conflict_details(
    chord: str,
    records: list[dict[str, Any]],
    ignored_id: str = "",
) -> dict[str, Any] | None:
    candidate = normalize_chord(chord)[0].casefold()
    for record in records:
        if ignored_id and record["id"] == ignored_id:
            continue
        if record["keys"].casefold() == candidate:
            return {
                "keys": record["keys"],
                "description": record["name"],
                "source": "managed",
                "recordId": record["id"],
                "replaceable": True,
            }
        reserved = set(record["removeKeys"])
        if record["originalKeys"]:
            reserved.add(record["originalKeys"])
        if candidate in {key.casefold() for key in reserved}:
            return {
                "keys": normalize_chord(chord)[0],
                "description": record["originalDescription"] or record["name"],
                "source": "reserved",
                "recordId": record["id"],
                "replaceable": True,
            }
    return None


def find_record_conflict(chord: str, records: list[dict[str, Any]], ignored_id: str = "") -> str:
    conflict = find_record_conflict_details(chord, records, ignored_id)
    return conflict["description"] if conflict else ""


def unique_chords(chords: list[str]) -> list[str]:
    result = []
    seen = set()
    for chord in chords:
        normalized = normalize_chord(chord)[0]
        if normalized.casefold() not in seen:
            result.append(normalized)
            seen.add(normalized.casefold())
    return result


def conflict_for_save(
    chord: str,
    records: list[dict[str, Any]],
    ignored_keys: set[str],
    ignored_id: str = "",
) -> dict[str, Any] | None:
    return find_record_conflict_details(chord, records, ignored_id) or find_conflict_details(chord, ignored_keys)


def apply_conflict_replacement(
    target: dict[str, Any],
    records: list[dict[str, Any]],
    conflict: dict[str, Any],
) -> set[str]:
    """Replace the explicitly confirmed binding while retaining its restore keys."""
    chord = normalize_chord(conflict["keys"])[0]
    ignored_keys = {chord.casefold()}

    if conflict["source"] == "managed":
        replaced = next((record for record in records if record["id"] == conflict["recordId"]), None)
        if replaced is None:
            return set()
        target["removeKeys"] = unique_chords(
            list(target.get("removeKeys", []))
            + list(replaced.get("removeKeys", []))
            + [replaced["keys"]]
        )
        if not target.get("originalKeys") and replaced.get("originalKeys"):
            target["originalKeys"] = replaced["originalKeys"]
            target["originalDescription"] = replaced.get("originalDescription", "")
        records.remove(replaced)
    elif conflict["source"] == "reserved":
        owner = next((record for record in records if record["id"] == conflict["recordId"]), None)
        if owner is None:
            return set()
        owner["removeKeys"] = [
            key for key in owner.get("removeKeys", [])
            if key.casefold() != chord.casefold()
        ]
        if owner.get("originalKeys", "").casefold() == chord.casefold():
            owner["originalKeys"] = ""
            owner["originalDescription"] = ""
        target["removeKeys"] = unique_chords(list(target.get("removeKeys", [])) + [chord])
        if not target.get("originalKeys"):
            target["originalKeys"] = chord
            target["originalDescription"] = conflict["description"]
    else:
        target["removeKeys"] = unique_chords(list(target.get("removeKeys", [])) + [chord])
        if not target.get("originalKeys"):
            target["originalKeys"] = chord
            target["originalDescription"] = conflict["description"]
    return ignored_keys


def confirm_conflict(
    conflict: dict[str, Any] | None,
    expected: dict[str, str] | None,
) -> dict[str, Any] | None:
    if not conflict:
        return None
    if expected is None:
        raise ShortcutConflict(conflict)
    same_conflict = all(
        str(conflict.get(key, "")) == str(expected.get(key, ""))
        for key in ("keys", "description", "source", "recordId")
    )
    if not same_conflict:
        raise ShortcutConflict(conflict)
    if not conflict.get("replaceable"):
        raise ShortcutConflict(conflict)
    return conflict


def config_errors() -> list[str]:
    result = subprocess.run(
        ["hyprctl", "-j", "configerrors"],
        text=True,
        capture_output=True,
        timeout=8,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(clean_text(result.stderr or result.stdout) or "couldn't check Hyprland configuration")
    try:
        errors = json.loads(result.stdout)
    except json.JSONDecodeError:
        return [clean_text(result.stdout, 1000)] if result.stdout.strip() else []
    if not isinstance(errors, list):
        return []
    return [clean_text(value, 1000) for value in errors if clean_text(value, 1000)]


def reload_hyprland(before_errors: list[str] | None = None) -> tuple[bool, str]:
    try:
        result = subprocess.run(
            ["hyprctl", "reload"],
            text=True,
            capture_output=True,
            timeout=15,
            check=False,
        )
        if result.returncode != 0:
            return False, clean_text(result.stderr or result.stdout) or "Hyprland couldn't reload"
        after_errors = config_errors()
    except (OSError, subprocess.TimeoutExpired, RuntimeError) as error:
        return False, str(error)

    previous = before_errors or []
    new_errors = [error for error in after_errors if error not in previous]
    if new_errors:
        return False, new_errors[0]
    return True, ""


def run_hyprland_lua(code: str) -> None:
    try:
        result = subprocess.run(
            ["hyprctl", "eval", code],
            text=True,
            capture_output=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f"couldn't pause keyboard shortcuts: {error}") from error
    if result.returncode != 0:
        raise RuntimeError(
            clean_text(result.stderr or result.stdout, 1000)
            or "Hyprland couldn't pause keyboard shortcuts"
        )


def read_capture_state() -> dict[str, Any] | None:
    try:
        value = json.loads(capture_state_file().read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def clear_capture_state(token: str) -> None:
    path = capture_state_file()
    state = read_capture_state()
    if state and state.get("token") == token:
        try:
            path.unlink()
        except FileNotFoundError:
            pass


def capture_start() -> None:
    state_path = capture_state_file()
    if state_path.exists():
        existing = read_capture_state()
        if existing and time.time() - float(existing.get("startedAt", 0)) > CAPTURE_WATCHDOG_SECONDS:
            success, message = reload_hyprland(existing.get("beforeErrors", []))
            if not success:
                raise RuntimeError(f"couldn't recover the previous capture session: {message}")
            clear_capture_state(str(existing.get("token", "")))
        else:
            raise RuntimeError("keyboard shortcut capture is already active")

    before_errors = config_errors()
    chords = set()
    unbind_chords = set()
    for bind in current_binds():
        if bind.get("mouse") or bind.get("submap"):
            continue
        chord = chord_from_bind(bind)
        if chord:
            chords.add(chord[0])
            _, mask, key = chord
            unbind_chords.update(unbind_variants(mask, key))

    token = uuid.uuid4().hex
    state = {
        "token": token,
        "startedAt": time.time(),
        "beforeErrors": before_errors,
        "chords": sorted(chords),
    }
    state_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    write_atomic(
        state_path,
        (json.dumps(state, ensure_ascii=False) + "\n").encode("utf-8"),
    )

    try:
        subprocess.Popen(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "capture-watchdog",
                "--token",
                token,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            start_new_session=True,
        )
    except (OSError, subprocess.SubprocessError) as error:
        clear_capture_state(token)
        raise RuntimeError(f"couldn't start keyboard-capture recovery timer: {error}") from error

    try:
        lua_chords = ", ".join(lua_string(chord) for chord in sorted(unbind_chords))
        if lua_chords:
            run_hyprland_lua(
                "for _, chord in ipairs({" + lua_chords + "}) do hl.unbind(chord) end"
            )
        remaining = set()
        for bind in current_binds():
            if bind.get("mouse") or bind.get("submap"):
                continue
            chord = chord_from_bind(bind)
            if chord:
                remaining.add(chord[0].casefold())
        still_active = sorted(chord for chord in chords if chord.casefold() in remaining)
        if still_active:
            raise RuntimeError(
                "some keyboard shortcuts could not be paused: " + ", ".join(still_active[:5])
            )
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        restored, restore_error = reload_hyprland(before_errors)
        if restored:
            clear_capture_state(token)
        detail = f"couldn't pause keyboard shortcuts: {error}"
        if not restored:
            detail += f"; recovery reload failed: {restore_error}"
        raise RuntimeError(detail) from error


def capture_stop() -> None:
    state = read_capture_state()
    if not state:
        emit({"ok": True, "message": "keyboard shortcuts are already active"})
        return

    before_errors = state.get("beforeErrors")
    if not isinstance(before_errors, list):
        before_errors = []
    success, message = reload_hyprland(before_errors)
    if not success:
        raise RuntimeError(f"couldn't restore keyboard shortcuts: {message}")
    clear_capture_state(str(state.get("token", "")))
    emit({"ok": True})


def capture_watchdog(token: str) -> None:
    deadline = time.monotonic() + CAPTURE_WATCHDOG_SECONDS
    while time.monotonic() < deadline:
        state = read_capture_state()
        if not state or state.get("token") != token:
            return
        time.sleep(min(2, max(0, deadline - time.monotonic())))

    state = read_capture_state()
    if not state or state.get("token") != token:
        return
    before_errors = state.get("beforeErrors")
    if not isinstance(before_errors, list):
        before_errors = []
    success, _ = reload_hyprland(before_errors)
    if success:
        clear_capture_state(token)


def snapshot(path: Path) -> bytes | None:
    try:
        return path.read_bytes()
    except FileNotFoundError:
        return None


def restore_snapshot(path: Path, content: bytes | None) -> None:
    if content is None:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
    else:
        mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
        write_atomic(path, content, mode)


LOADER_START = f"-- BEGIN {PLUGIN_ID} managed loader"
LOADER_END = f"-- END {PLUGIN_ID} managed loader"
LOADER_CONTENT = (
    f"{LOADER_START}\n"
    'require("hypr.omarchy-keybindings")\n'
    f"{LOADER_END}"
)

MENU_START = f"// BEGIN {PLUGIN_ID} menu entries"
MENU_END = f"// END {PLUGIN_ID} menu entries"
MENU_ENTRIES = """\
  "setup.keybindings": {
    "icon": "",
    "label": "Keyboard Shortcuts",
    "description": "Create and edit application and system shortcuts",
    "action": ""
  },
  "setup.keybindings.create": {
    "icon": "",
    "label": "Create a shortcut",
    "action": "omarchy-shell shell summon io.github.splashymorningstar.keybindings '{\\"mode\\":\\"create\\"}'"
  },
  "setup.keybindings.edit": {
    "icon": "󰏫",
    "label": "Edit a shortcut",
    "action": "omarchy-shell shell summon io.github.splashymorningstar.keybindings '{\\"mode\\":\\"edit\\"}'"
  }\
"""


def ensure_loader() -> bool:
    """Create the generated module and add one marked require to bindings.lua."""
    user_bindings = bindings_file()
    if not user_bindings.is_file():
        raise RuntimeError(f"Hyprland bindings file not found: {user_bindings}")
    generated = generated_file()
    if not generated.exists():
        write_atomic(generated, render_lua([]))

    current = user_bindings.read_text(encoding="utf-8")
    if LOADER_START in current and LOADER_END in current:
        if current.count(LOADER_START) != 1 or current.count(LOADER_END) != 1:
            raise RuntimeError("the managed loader markers appear more than once")
        return False
    if 'require("hypr.omarchy-keybindings")' in current:
        return False
    if LOADER_START in current or LOADER_END in current:
        raise RuntimeError("the managed loader marker is incomplete")

    backup_file(user_bindings)
    updated = current.rstrip() + ("\n\n" if current.strip() else "") + LOADER_CONTENT + "\n"
    write_atomic(user_bindings, updated.encode("utf-8"), user_bindings.stat().st_mode & 0o777)
    return True


def persist(records: list[dict[str, Any]], reload: bool = True) -> None:
    db_path = database_file()
    lua_path = generated_file()
    old_db = snapshot(db_path)
    old_lua = snapshot(lua_path)

    if old_db is not None:
        backup_file(db_path)
    if old_lua is not None:
        backup_file(lua_path)

    try:
        serialized = (json.dumps(records, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        write_atomic(db_path, serialized)
        write_atomic(lua_path, render_lua(records))
    except Exception:
        restore_snapshot(db_path, old_db)
        restore_snapshot(lua_path, old_lua)
        raise

    if not reload:
        return
    try:
        before = config_errors()
    except (OSError, subprocess.TimeoutExpired, RuntimeError) as error:
        restore_snapshot(db_path, old_db)
        restore_snapshot(lua_path, old_lua)
        raise RuntimeError(f"shortcut wasn't applied: {error}") from error

    success, message = reload_hyprland(before)
    if success:
        return
    restore_snapshot(db_path, old_db)
    restore_snapshot(lua_path, old_lua)
    reload_hyprland()
    raise RuntimeError(f"shortcut wasn't applied: {message}")


def menu_file() -> Path:
    return (
        Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
        / "omarchy"
        / "extensions"
        / "omarchy-menu.jsonc"
    )


def ensure_menu_entries() -> bool:
    """Inject the plugin's menu entries into omarchy-menu.jsonc if absent.

    Returns True if entries were added, False if already present.
    Does nothing if the file already contains our block or the entry IDs.
    """
    path = menu_file()
    path.parent.mkdir(parents=True, exist_ok=True)

    if path.exists():
        current = path.read_text(encoding="utf-8")
    else:
        # Create a minimal JSONC file with the standard header comment.
        current = "{\n}\n"

    if MENU_START in current:
        return False
    # Also skip if any of our keys are already present (manual install).
    if '"setup.keybindings"' in current or '"setup.keybindings.create"' in current:
        return False

    # Find the last closing brace and insert before it.
    last_brace = current.rfind("}")
    if last_brace == -1:
        raise RuntimeError(f"cannot parse {path}: no closing brace found")

    before = current[:last_brace].rstrip()
    # Add a comma after the previous entry if the content before the brace is non-empty JSON
    # (i.e. not just whitespace/comments).
    stripped = before
    # Remove // line comments for the check
    for line in before.splitlines():
        stripped = stripped  # keep original for insertion
    needs_comma = bool(re.search(r'[}\]"0-9]', before.split("//")[0] if "//" in before else before))

    block = (
        ((",\n  " if needs_comma else "\n  ") + f"// {MENU_START}\n  ")
        + MENU_ENTRIES.replace("\n", "\n  ")
        + f"\n  // {MENU_END}"
    )
    updated = before + block + "\n}\n"

    backup_file(path)
    write_atomic(path, updated.encode("utf-8"))
    return True


def remove_menu_entries() -> bool:
    """Remove the managed menu block from omarchy-menu.jsonc if present.

    Returns True if removed, False if the block was not found.
    """
    path = menu_file()
    if not path.exists():
        return False

    current = path.read_text(encoding="utf-8")
    start_marker = f"// {MENU_START}"
    end_marker = f"// {MENU_END}"

    if start_marker not in current:
        return False

    # Remove from the leading comma/newline before the start marker to end marker.
    pattern = re.compile(
        r",?\s*//\s*" + re.escape(MENU_START) + r".*?//\s*" + re.escape(MENU_END),
        re.DOTALL,
    )
    updated = pattern.sub("", current)
    if updated == current:
        return False

    backup_file(path)
    write_atomic(path, updated.encode("utf-8"))
    return True


def ensure_custom_lua(plugin_dir: Path) -> None:
    """Copy the starter custom Lua file if the user does not have one yet."""
    dest = (
        Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
        / "hypr"
        / "omarchy-keybindings-custom.lua"
    )
    if dest.exists():
        return
    source = plugin_dir / "examples" / "omarchy-keybindings-custom.lua"
    if not source.is_file():
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, dest)


def install() -> None:
    plugin_dir = Path(__file__).parent
    generated = generated_file()
    user_bindings = bindings_file()
    old_generated = snapshot(generated)
    old_bindings = snapshot(user_bindings)
    try:
        loader_changed = ensure_loader()
        ensure_custom_lua(plugin_dir)
        ensure_menu_entries()
        records = load_records()
        if generated.exists():
            write_atomic(generated, render_lua(records))
        if not loader_changed:
            emit({"ok": True, "message": "already installed"})
            return
        try:
            before = config_errors()
        except (OSError, subprocess.TimeoutExpired, RuntimeError) as error:
            raise RuntimeError(f"couldn't validate Hyprland configuration: {error}") from error
        success, message = reload_hyprland(before)
        if not success:
            raise RuntimeError(f"couldn't load the shortcut manager: {message}")
    except Exception:
        restore_snapshot(user_bindings, old_bindings)
        restore_snapshot(generated, old_generated)
        reload_hyprland()
        raise
    emit({"ok": True, "message": "installed"})


def uninstall() -> None:
    """Remove only the exact loader block owned by this plugin."""
    user_bindings = bindings_file()
    if not user_bindings.is_file():
        raise RuntimeError(f"Hyprland bindings file not found: {user_bindings}")

    current = user_bindings.read_text(encoding="utf-8")
    if LOADER_START not in current and LOADER_END not in current:
        emit({"ok": True, "message": "no managed loader found; nothing changed"})
        return
    if current.count(LOADER_START) != 1 or current.count(LOADER_END) != 1:
        raise RuntimeError("the managed loader markers are incomplete or duplicated")

    start = current.index(LOADER_START)
    end_marker = current.index(LOADER_END) + len(LOADER_END)
    if end_marker < start or current[start:end_marker] != LOADER_CONTENT.rstrip("\n"):
        raise RuntimeError("the managed loader block was edited; leaving it unchanged")

    remove_start = start
    if current[max(0, start - 2):start] == "\n\n":
        remove_start -= 1
    remove_end = end_marker + (1 if current[end_marker:end_marker + 1] == "\n" else 0)
    updated = current[:remove_start] + current[remove_end:]
    old_bindings = current.encode("utf-8")

    backup_file(user_bindings)
    write_atomic(user_bindings, updated.encode("utf-8"), user_bindings.stat().st_mode & 0o777)
    try:
        before = config_errors()
    except (OSError, subprocess.TimeoutExpired, RuntimeError) as error:
        restore_snapshot(user_bindings, old_bindings)
        raise RuntimeError(f"couldn't validate Hyprland configuration: {error}") from error

    success, message = reload_hyprland(before)
    if not success:
        restore_snapshot(user_bindings, old_bindings)
        reload_hyprland()
        raise RuntimeError(f"couldn't remove the shortcut manager: {message}")
    remove_menu_entries()
    emit(
        {
            "ok": True,
            "message": "managed loader removed; shortcut data and user custom config were preserved",
        }
    )


def save_app(
    desktop_id: str,
    name: str,
    keys: str,
    entry_id: str = "",
    original_keys: str = "",
    original_description: str = "",
    expected_conflict: dict[str, str] | None = None,
) -> dict[str, Any]:
    desktop_id = str(desktop_id).removesuffix(".desktop")
    if not APP_ID_RE.fullmatch(desktop_id):
        raise ValueError("unsupported application entry")
    name = clean_text(name)
    if not name:
        raise ValueError("the application name is empty")
    keys, _, _ = normalize_chord(keys)
    records = load_records()

    target_index = next((index for index, row in enumerate(records) if row["id"] == entry_id), None) if entry_id else None
    if entry_id and target_index is None:
        raise ValueError("shortcut not found")
    ignored = set()
    if target_index is not None:
        target = records[target_index]
        ignored.add(target["keys"].casefold())
        old_keys = target["keys"]
        remove_keys = list(target["removeKeys"])
        if old_keys.casefold() not in {key.casefold() for key in remove_keys}:
            remove_keys.append(old_keys)
        target.update(
            {
                "kind": "application",
                "desktopId": desktop_id,
                "name": name,
                "keys": keys,
                "removeKeys": remove_keys,
            }
        )
        target.pop("actionId", None)
    else:
        if len(records) >= MAX_BINDINGS:
            raise ValueError("shortcut limit reached")
        if original_keys:
            original_keys = normalize_chord(original_keys)[0]
            ignored.add(original_keys.casefold())
        target = {
            "id": uuid.uuid4().hex,
            "kind": "application",
            "desktopId": desktop_id,
            "name": name,
            "keys": keys,
            "removeKeys": [original_keys] if original_keys else [],
            "originalKeys": original_keys,
            "originalDescription": clean_text(original_description),
        }
        records.append(target)

    conflict = confirm_conflict(
        conflict_for_save(keys, records, ignored, target["id"]),
        expected_conflict,
    )
    if conflict:
        ignored.update(apply_conflict_replacement(target, records, conflict))
        remaining = conflict_for_save(keys, records, ignored, target["id"])
        if remaining:
            raise ShortcutConflict(remaining)
    persist(records)
    return target


def save_system_action(
    action_id: str,
    keys: str,
    entry_id: str = "",
    original_keys: str = "",
    original_description: str = "",
    expected_conflict: dict[str, str] | None = None,
) -> dict[str, Any]:
    action_id = str(action_id)
    action = SYSTEM_ACTIONS.get(action_id)
    if not action:
        raise ValueError("unsupported system action")
    keys, _, _ = normalize_chord(keys)
    records = load_records()

    target_index = next((index for index, row in enumerate(records) if row["id"] == entry_id), None) if entry_id else None
    if entry_id and target_index is None:
        raise ValueError("shortcut not found")
    ignored = set()
    if target_index is not None:
        target = records[target_index]
        ignored.add(target["keys"].casefold())
        old_keys = target["keys"]
        remove_keys = list(target["removeKeys"])
        if old_keys.casefold() not in {key.casefold() for key in remove_keys}:
            remove_keys.append(old_keys)
        target.update(
            {
                "kind": "system",
                "desktopId": "",
                "actionId": action_id,
                "name": action["name"],
                "keys": keys,
                "removeKeys": remove_keys,
            }
        )
    else:
        if len(records) >= MAX_BINDINGS:
            raise ValueError("shortcut limit reached")
        if original_keys:
            original_keys = normalize_chord(original_keys)[0]
            ignored.add(original_keys.casefold())
        target = {
            "id": uuid.uuid4().hex,
            "kind": "system",
            "desktopId": "",
            "actionId": action_id,
            "name": action["name"],
            "keys": keys,
            "removeKeys": [original_keys] if original_keys else [],
            "originalKeys": original_keys,
            "originalDescription": clean_text(original_description),
        }
        records.append(target)

    conflict = confirm_conflict(
        conflict_for_save(keys, records, ignored, target["id"]),
        expected_conflict,
    )
    if conflict:
        ignored.update(apply_conflict_replacement(target, records, conflict))
        remaining = conflict_for_save(keys, records, ignored, target["id"])
        if remaining:
            raise ShortcutConflict(remaining)
    persist(records)
    return target


class ShortcutConflict(ValueError):
    def __init__(self, conflict: dict[str, Any]):
        self.conflict = conflict
        super().__init__(conflict.get("description") or conflict.get("keys") or "shortcut conflict")


def remove_record(entry_id: str) -> None:
    records = load_records()
    updated = [record for record in records if record["id"] != entry_id]
    if len(updated) == len(records):
        raise ValueError("shortcut not found")
    persist(updated)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    commands.add_parser("install")
    commands.add_parser("uninstall")
    commands.add_parser("setup-auto")
    commands.add_parser("list-custom")
    commands.add_parser("list-system")
    commands.add_parser("capture-start")
    commands.add_parser("capture-stop")
    watchdog = commands.add_parser("capture-watchdog")
    watchdog.add_argument("--token", required=True)

    save = commands.add_parser("save-app")
    save.add_argument("--desktop-id", required=True)
    save.add_argument("--name", required=True)
    save.add_argument("--keys", required=True)
    save.add_argument("--id", default="")
    save.add_argument("--original-keys", default="")
    save.add_argument("--original-description", default="")
    add_conflict_confirmation_arguments(save)

    save_action = commands.add_parser("save-action")
    save_action.add_argument("--action-id", required=True)
    save_action.add_argument("--keys", required=True)
    save_action.add_argument("--id", default="")
    save_action.add_argument("--original-keys", default="")
    save_action.add_argument("--original-description", default="")
    add_conflict_confirmation_arguments(save_action)

    remove = commands.add_parser("remove")
    remove.add_argument("--id", required=True)
    return root


def add_conflict_confirmation_arguments(command: argparse.ArgumentParser) -> None:
    command.add_argument("--replace-conflict", action="store_true")
    command.add_argument("--replace-conflict-keys", default="")
    command.add_argument("--replace-conflict-description", default="")
    command.add_argument("--replace-conflict-source", default="")
    command.add_argument("--replace-conflict-record-id", default="")


def expected_conflict_from_args(args: argparse.Namespace) -> dict[str, str] | None:
    if not args.replace_conflict:
        return None
    if not args.replace_conflict_keys or args.replace_conflict_source not in {
        "hyprland",
        "managed",
        "reserved",
    }:
        raise ValueError("missing confirmed shortcut-conflict details")
    return {
        "keys": args.replace_conflict_keys,
        "description": args.replace_conflict_description,
        "source": args.replace_conflict_source,
        "recordId": args.replace_conflict_record_id,
    }


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "install":
            install()
        elif args.command == "uninstall":
            uninstall()
        elif args.command == "list-custom":
            emit({"ok": True, "entries": load_records()})
        elif args.command == "list-system":
            emit({"ok": True, "entries": system_bindings()})
        elif args.command == "capture-start":
            capture_start()
            emit({"ok": True})
        elif args.command == "capture-stop":
            capture_stop()
        elif args.command == "capture-watchdog":
            capture_watchdog(args.token)
        elif args.command == "save-app":
            entry = save_app(
                args.desktop_id,
                args.name,
                args.keys,
                args.id,
                args.original_keys,
                args.original_description,
                expected_conflict_from_args(args),
            )
            emit({"ok": True, "entry": entry})
        elif args.command == "save-action":
            entry = save_system_action(
                args.action_id,
                args.keys,
                args.id,
                args.original_keys,
                args.original_description,
                expected_conflict_from_args(args),
            )
            emit({"ok": True, "entry": entry})
        elif args.command == "setup-auto":
            # Silent auto-setup called from QML on first load. Never raises
            # on non-critical failures so the plugin opens normally even on
            # unusual system configurations.
            plugin_dir = Path(__file__).parent
            try:
                ensure_custom_lua(plugin_dir)
                ensure_menu_entries()
                ensure_loader()
                records = load_records()
                generated = generated_file()
                if not generated.exists():
                    write_atomic(generated, render_lua(records))
                # Best-effort Hyprland reload; ignore errors silently.
                try:
                    before = config_errors()
                    reload_hyprland(before)
                except Exception:
                    pass
            except Exception as exc:
                emit({"ok": False, "kind": "error", "message": clean_text(str(exc), 500)})
                return 0  # Exit 0 so QML doesn't treat it as fatal
            emit({"ok": True, "message": "auto-setup complete"})
        elif args.command == "remove":
            remove_record(args.id)
            emit({"ok": True})
        return 0
    except ShortcutConflict as error:
        emit(
            {
                "ok": False,
                "kind": "conflict",
                "message": str(error),
                "conflict": error.conflict,
            }
        )
        return 2
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        emit({"ok": False, "kind": "error", "message": clean_text(str(error), 1000)})
        return 1


if __name__ == "__main__":
    sys.exit(main())
