import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


PLUGIN_DIR = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("keybindings_manager", PLUGIN_DIR / "manager.py")
manager = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(manager)


class ShortcutManagerTests(unittest.TestCase):
    def test_normalize_captured_chord(self):
        self.assertEqual(
            manager.normalize_chord("SUPER + SHIFT + D"),
            ("SUPER + SHIFT + D", 65, "D"),
        )

    def test_normalize_chord_rejects_missing_key_and_duplicate_modifier(self):
        with self.assertRaises(ValueError):
            manager.normalize_chord("SUPER + SHIFT")
        with self.assertRaises(ValueError):
            manager.normalize_chord("SUPER + SUPER + D")

    def test_chord_from_bind_preserves_case_sensitive_xkb_key(self):
        self.assertEqual(
            manager.chord_from_bind({"key": "comma", "modmask": 64}),
            ("SUPER + comma", 64, "comma"),
        )

    def test_lua_string_escapes_quotes_backslashes_and_newlines(self):
        self.assertEqual(manager.lua_string('Yap "fast"\\\n'), '"Yap \\"fast\\"\\\\\\n"')

    def test_render_lua_uses_desktop_entry_and_removes_overridden_chord(self):
        rendered = manager.render_lua(
            [
                {
                    "id": "1",
                    "desktopId": "yapfast",
                    "name": 'Yap "Fast"',
                    "keys": "SUPER + SHIFT + D",
                    "removeKeys": ["SUPER + K"],
                    "originalKeys": "SUPER + K",
                }
            ]
        ).decode()
        self.assertEqual(rendered.count('hl.unbind("SUPER + K")'), 1)
        self.assertIn('require("hypr.omarchy-keybindings-custom")', rendered)
        self.assertIn(
            'o.bind("SUPER + SHIFT + D", "Yap \\"Fast\\"", '
            '{ launch = "gtk-launch yapfast.desktop" })',
            rendered,
        )

    def test_render_lua_quotes_desktop_ids_containing_spaces(self):
        rendered = manager.render_lua(
            [
                {
                    "id": "1",
                    "desktopId": "Example App",
                    "name": "Example",
                    "keys": "SUPER + E",
                    "removeKeys": [],
                    "originalKeys": "",
                }
            ]
        ).decode()
        self.assertIn("gtk-launch 'Example App.desktop'", rendered)

    def test_render_lua_uses_the_fixed_system_action_command(self):
        rendered = manager.render_lua(
            [
                {
                    "id": "entry-1",
                    "kind": "system",
                    "desktopId": "",
                    "actionId": "screenshot",
                    "name": "Take a screenshot",
                    "keys": "SUPER + SHIFT + P",
                    "removeKeys": [],
                    "originalKeys": "",
                }
            ]
        ).decode()
        self.assertIn(
            'o.bind("SUPER + SHIFT + P", "Take a screenshot", "omarchy-capture-screenshot")',
            rendered,
        )

    def test_load_records_keeps_legacy_app_records_and_system_actions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bindings.json"
            path.write_text(
                json.dumps(
                    [
                        {"id": "app", "desktopId": "example", "name": "Example", "keys": "SUPER + E"},
                        {
                            "id": "action",
                            "kind": "system",
                            "actionId": "lock",
                            "name": "Lock the screen",
                            "keys": "SUPER + SHIFT + L",
                        },
                    ]
                ),
                encoding="utf-8",
            )
            with patch.object(manager, "database_file", return_value=path):
                records = manager.load_records()

        self.assertEqual([record["kind"] for record in records], ["application", "system"])
        self.assertEqual(records[1]["actionId"], "lock")

    def test_uninstall_removes_only_the_managed_loader_and_keeps_user_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "bindings.lua"
            user_content = "-- my other bindings\n"
            path.write_text(user_content + "\n" + manager.LOADER_CONTENT + "\n", encoding="utf-8")
            with (
                patch.object(manager, "bindings_file", return_value=path),
                patch.object(manager, "backup_dir", return_value=root / "backups"),
                patch.object(manager, "config_errors", return_value=[]),
                patch.object(manager, "reload_hyprland", return_value=(True, "")) as reload_hyprland,
                patch.object(manager, "emit"),
            ):
                manager.uninstall()

            self.assertEqual(path.read_text(encoding="utf-8"), user_content)
            self.assertEqual(len(list((root / "backups").glob("*.bak"))), 1)
            reload_hyprland.assert_called_once_with([])

    def test_uninstall_leaves_an_unmarked_manual_require_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bindings.lua"
            manual = 'require("hypr.omarchy-keybindings")\n'
            path.write_text(manual, encoding="utf-8")
            with (
                patch.object(manager, "bindings_file", return_value=path),
                patch.object(manager, "emit"),
                patch.object(manager, "reload_hyprland") as reload_hyprland,
            ):
                manager.uninstall()

            self.assertEqual(path.read_text(encoding="utf-8"), manual)
            reload_hyprland.assert_not_called()

    def test_uninstall_refuses_to_remove_an_edited_loader_block(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bindings.lua"
            edited = manager.LOADER_CONTENT.replace(
                'require("hypr.omarchy-keybindings")',
                'require("hypr.some-other-module")',
            )
            path.write_text(edited + "\n", encoding="utf-8")
            with patch.object(manager, "bindings_file", return_value=path):
                with self.assertRaisesRegex(RuntimeError, "block was edited"):
                    manager.uninstall()

            self.assertEqual(path.read_text(encoding="utf-8"), edited + "\n")

    def test_conflict_detection_compares_case_insensitively(self):
        binds = [{"key": "d", "modmask": 65, "description": "Existing app"}]
        with patch.object(manager, "current_binds", return_value=binds):
            self.assertEqual(manager.find_conflict("SUPER + SHIFT + D", set()), "Existing app")
            self.assertEqual(
                manager.find_conflict_details("SUPER + SHIFT + D", set()),
                {
                    "keys": "SUPER + SHIFT + d",
                    "description": "Existing app",
                    "source": "hyprland",
                    "recordId": "",
                    "replaceable": True,
                },
            )

    def test_conflict_detection_can_ignore_a_binding_being_replaced(self):
        binds = [{"key": "F", "modmask": 65, "description": "File manager"}]
        with patch.object(manager, "current_binds", return_value=binds):
            self.assertEqual(
                manager.find_conflict("SUPER + SHIFT + F", {"SUPER + SHIFT + F".casefold()}),
                "",
            )

    def test_save_replacing_existing_binding_preserves_what_to_restore(self):
        binds = [{"key": "F", "modmask": 65, "description": "File manager"}]
        with (
            patch.object(manager, "load_records", return_value=[]),
            patch.object(manager, "current_binds", return_value=binds),
            patch.object(manager, "persist") as persist,
        ):
            entry = manager.save_app(
                "example.desktop",
                "Example",
                "SUPER + SHIFT + F",
                original_keys="SUPER + SHIFT + F",
                original_description="File manager",
            )

        self.assertEqual(entry["removeKeys"], ["SUPER + SHIFT + F"])
        self.assertEqual(entry["originalKeys"], "SUPER + SHIFT + F")
        self.assertEqual(entry["originalDescription"], "File manager")
        persist.assert_called_once()

    def test_save_rejects_a_conflict_without_persisting(self):
        binds = [{"key": "D", "modmask": 65, "description": "Existing shortcut"}]
        with (
            patch.object(manager, "load_records", return_value=[]),
            patch.object(manager, "current_binds", return_value=binds),
            patch.object(manager, "persist") as persist,
        ):
            with self.assertRaises(manager.ShortcutConflict):
                manager.save_app("example", "Example", "SUPER + SHIFT + D")

        persist.assert_not_called()

    def test_confirmed_system_conflict_is_replaced_and_restorable(self):
        binds = [{"key": "D", "modmask": 65, "description": "Open dashboard"}]
        conflict = {
            "keys": "SUPER + SHIFT + D",
            "description": "Open dashboard",
            "source": "hyprland",
            "recordId": "",
            "replaceable": True,
        }
        with (
            patch.object(manager, "load_records", return_value=[]),
            patch.object(manager, "current_binds", return_value=binds),
            patch.object(manager, "persist") as persist,
        ):
            entry = manager.save_app(
                "yapfast",
                "Yapfast",
                "SUPER + SHIFT + D",
                expected_conflict=conflict,
            )

        self.assertEqual(entry["originalKeys"], "SUPER + SHIFT + D")
        self.assertEqual(entry["originalDescription"], "Open dashboard")
        self.assertEqual(entry["removeKeys"], ["SUPER + SHIFT + D"])
        persist.assert_called_once()

    def test_conflict_confirmation_reprompts_if_the_occupied_binding_changed(self):
        binds = [{"key": "D", "modmask": 65, "description": "Open another app"}]
        stale_conflict = {
            "keys": "SUPER + SHIFT + D",
            "description": "Open dashboard",
            "source": "hyprland",
            "recordId": "",
        }
        with (
            patch.object(manager, "load_records", return_value=[]),
            patch.object(manager, "current_binds", return_value=binds),
            patch.object(manager, "persist") as persist,
        ):
            with self.assertRaises(manager.ShortcutConflict) as raised:
                manager.save_app(
                    "yapfast",
                    "Yapfast",
                    "SUPER + SHIFT + D",
                    expected_conflict=stale_conflict,
                )

        self.assertEqual(raised.exception.conflict["description"], "Open another app")
        persist.assert_not_called()

    def test_confirmed_managed_conflict_replaces_the_record_and_keeps_restore_keys(self):
        existing = {
            "id": "old-entry",
            "kind": "application",
            "desktopId": "old-app",
            "name": "Old app",
            "keys": "SUPER + SHIFT + D",
            "removeKeys": ["SUPER + K", "SUPER + SHIFT + D"],
            "originalKeys": "SUPER + K",
            "originalDescription": "Open terminal",
        }
        conflict = {
            "keys": "SUPER + SHIFT + D",
            "description": "Old app",
            "source": "managed",
            "recordId": "old-entry",
            "replaceable": True,
        }
        with (
            patch.object(manager, "load_records", return_value=[existing.copy()]),
            patch.object(manager, "current_binds", return_value=[
                {"key": "D", "modmask": 65, "description": "Old app"},
            ]),
            patch.object(manager, "persist") as persist,
        ):
            entry = manager.save_app(
                "yapfast",
                "Yapfast",
                "SUPER + SHIFT + D",
                expected_conflict=conflict,
            )
            saved_records = persist.call_args.args[0]

        self.assertEqual(entry["originalKeys"], "SUPER + K")
        self.assertEqual(entry["originalDescription"], "Open terminal")
        self.assertEqual(entry["removeKeys"], ["SUPER + K", "SUPER + SHIFT + D"])
        self.assertEqual([record["name"] for record in saved_records], ["Yapfast"])
        persist.assert_called_once()

    def test_confirmed_reserved_conflict_moves_the_reservation_to_the_new_shortcut(self):
        existing = {
            "id": "old-entry",
            "kind": "application",
            "desktopId": "old-app",
            "name": "Old app",
            "keys": "SUPER + SHIFT + F",
            "removeKeys": ["SUPER + K", "SUPER + SHIFT + F"],
            "originalKeys": "SUPER + K",
            "originalDescription": "Open terminal",
        }
        conflict = {
            "keys": "SUPER + K",
            "description": "Open terminal",
            "source": "reserved",
            "recordId": "old-entry",
            "replaceable": True,
        }
        with (
            patch.object(manager, "load_records", return_value=[existing.copy()]),
            patch.object(manager, "current_binds", return_value=[]),
            patch.object(manager, "persist") as persist,
        ):
            entry = manager.save_app(
                "yapfast",
                "Yapfast",
                "SUPER + K",
                expected_conflict=conflict,
            )
            saved_records = persist.call_args.args[0]

        old_entry = next(record for record in saved_records if record["id"] == "old-entry")
        self.assertEqual(old_entry["removeKeys"], ["SUPER + SHIFT + F"])
        self.assertEqual(old_entry["originalKeys"], "")
        self.assertEqual(entry["originalKeys"], "SUPER + K")
        self.assertEqual(entry["originalDescription"], "Open terminal")
        persist.assert_called_once()

    def test_save_system_action_can_replace_a_binding_reversibly(self):
        binds = [{"key": "P", "modmask": 65, "description": "Power"}]
        with (
            patch.object(manager, "load_records", return_value=[]),
            patch.object(manager, "current_binds", return_value=binds),
            patch.object(manager, "persist") as persist,
        ):
            entry = manager.save_system_action(
                "screenshot",
                "SUPER + SHIFT + P",
                original_keys="SUPER + SHIFT + P",
                original_description="Power",
            )

        self.assertEqual(entry["kind"], "system")
        self.assertEqual(entry["actionId"], "screenshot")
        self.assertEqual(entry["removeKeys"], ["SUPER + SHIFT + P"])
        self.assertEqual(entry["originalDescription"], "Power")
        persist.assert_called_once()

    def test_save_system_action_rejects_an_existing_conflict(self):
        binds = [{"key": "P", "modmask": 65, "description": "Existing shortcut"}]
        with (
            patch.object(manager, "load_records", return_value=[]),
            patch.object(manager, "current_binds", return_value=binds),
            patch.object(manager, "persist") as persist,
        ):
            with self.assertRaisesRegex(manager.ShortcutConflict, "Existing shortcut"):
                manager.save_system_action("screenshot", "SUPER + SHIFT + P")

        persist.assert_not_called()

    def test_editing_custom_binding_keeps_original_restore_chord(self):
        existing = {
            "id": "entry-1",
            "desktopId": "example",
            "name": "Example",
            "keys": "SUPER + SHIFT + F",
            "removeKeys": ["SUPER + SHIFT + B"],
            "originalKeys": "SUPER + SHIFT + B",
            "originalDescription": "Browser",
        }
        binds = [{"key": "F", "modmask": 65, "description": "Example"}]
        with (
            patch.object(manager, "load_records", return_value=[existing.copy()]),
            patch.object(manager, "current_binds", return_value=binds),
            patch.object(manager, "persist") as persist,
        ):
            entry = manager.save_app(
                "example",
                "Example",
                "SUPER + SHIFT + G",
                entry_id="entry-1",
            )

        self.assertEqual(entry["keys"], "SUPER + SHIFT + G")
        self.assertEqual(entry["originalKeys"], "SUPER + SHIFT + B")
        self.assertEqual(entry["originalDescription"], "Browser")
        self.assertEqual(entry["removeKeys"], ["SUPER + SHIFT + B", "SUPER + SHIFT + F"])
        persist.assert_called_once()

    def test_save_rejects_chord_reserved_by_another_shortcut_for_restore(self):
        existing = {
            "id": "entry-1",
            "desktopId": "example",
            "name": "Example",
            "keys": "SUPER + SHIFT + G",
            "removeKeys": ["SUPER + K"],
            "originalKeys": "SUPER + K",
            "originalDescription": "Keybindings",
        }
        with (
            patch.object(manager, "load_records", return_value=[existing]),
            patch.object(manager, "current_binds", return_value=[]),
            patch.object(manager, "persist") as persist,
        ):
            with self.assertRaisesRegex(manager.ShortcutConflict, "Keybindings"):
                manager.save_app("other-app", "Other app", "SUPER + K")

        persist.assert_not_called()

    def test_editing_missing_record_does_not_create_a_new_shortcut(self):
        with (
            patch.object(manager, "load_records", return_value=[]),
            patch.object(manager, "persist") as persist,
        ):
            with self.assertRaisesRegex(ValueError, "shortcut not found"):
                manager.save_app("example", "Example", "SUPER + D", entry_id="missing")

        persist.assert_not_called()


if __name__ == "__main__":
    unittest.main()
