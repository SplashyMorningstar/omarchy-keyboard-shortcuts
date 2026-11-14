# Keyboard Shortcuts for Omarchy

Create application shortcuts and built-in system-action shortcuts from an
Omarchy menu. Advanced users can open a separate Hyprland Lua file in Neovim
and write their own `o.bind(...)` or `o.rebind(...)` commands.

## Features

- Create shortcuts for installed desktop applications.
- Choose from fixed system actions: screenshot, lock screen, workspace
  navigation, and output volume controls.
- Edit or remove shortcuts created by this plugin.
- Replace a described Omarchy shortcut and restore it by removing the override.
- Detect occupied shortcuts, show what they currently do, and ask before
  replacing them. Removing the replacement restores the original binding.
- Keep custom Lua commands in a separate user-owned file.
- English interface and keyboard-only navigation.

## Keyboard controls

- **Up/Down:** move through menu choices, application results, system actions,
  and existing shortcuts. Left/Right also move through focused button choices.
- **Enter:** choose the focused option or confirm the current step.
- **Escape:** return to the previous step; close the plugin from the first step.
- **Tab/Shift+Tab:** move between controls, including remove and close buttons.
- Shortcut capture automatically pauses Hyprland keyboard shortcuts so an
  existing binding cannot launch an app while you record it. Bindings are
  restored as soon as capture ends, when the panel closes, or automatically
  after three minutes if the capture is interrupted.
- To enter a chord such as `SUPER + SHIFT + M` manually, click the text field or
  press Tab, then press Enter to check it for conflicts. If safe capture cannot
  start, the **Retry safe capture** button is available.
- In the occupied-shortcut prompt, choose **Rewrite shortcut** or **Cancel**
  with the arrow keys, Tab, or Enter. Escape cancels the rewrite.
- In search fields, type to filter. Down enters the results; Up from the first
  result returns to the search field.
- In the remove confirmation, arrow keys or Tab switch between Cancel and
  Remove; Enter activates the selected choice.

## Requirements

- Omarchy Quattro with its Quickshell shell and Hyprland Lua configuration.
- Python 3 and `hyprctl` (included with Omarchy).
- `gtk-launch` for application shortcuts.
- Neovim and `omarchy-launch-tui` for the optional custom-command editor.

## Installation

Community installation starts with the public GitHub repository:

```sh
omarchy plugin add https://github.com/SplashyMorningstar/omarchy-keyboard-shortcuts.git
```

Replace the URL if you choose a different repository name.
Review the source before enabling it: Omarchy plugins run unsandboxed inside
the long-lived shell process. Then enable the plugin:

```sh
omarchy plugin enable io.github.splashymorningstar.keybindings
```

### Add the menu entries

Merge the entries in
[`examples/omarchy-menu.jsonc`](examples/omarchy-menu.jsonc) into
`~/.config/omarchy/extensions/omarchy-menu.jsonc`. Add them to the existing
JSONC object; do not replace the file if it contains other custom menu entries.

### Set up Hyprland

The manager writes generated shortcuts to
`~/.config/hypr/omarchy-keybindings.lua` and adds a marked `require(...)` block
to `~/.config/hypr/bindings.lua`. It makes a backup before changing either
file. The custom Lua file is never overwritten; copy the starter only if the
destination does not already exist:

```sh
PLUGIN_DIR="$HOME/.config/omarchy/plugins/io.github.splashymorningstar.keybindings"
mkdir -p "$HOME/.config/hypr"
cp -n "$PLUGIN_DIR/examples/omarchy-keybindings-custom.lua" \
  "$HOME/.config/hypr/omarchy-keybindings-custom.lua"
python3 "$PLUGIN_DIR/manager.py" install
hyprctl reload
hyprctl configerrors
```

The manager stores shortcut data in
`~/.local/state/omarchy/keybindings-manager/bindings.json`. It does not edit
Omarchy's packaged defaults or use `sudo`.

## Custom commands

Choose **Custom command (advanced)** to open
`~/.config/hypr/omarchy-keybindings-custom.lua` in Neovim. Add user-authored
Lua bindings there. For example:

```lua
o.bind("SUPER + ALT + O", "Open Obsidian", { launch = "obsidian" })
o.rebind("SUPER + ALT + T", "Open terminal", { launch = "alacritty" })
```

These commands run with your user permissions. Review them before saving.
Hyprland reloads its Lua configuration when the file changes; verify with
`hyprctl configerrors`.

## Removal

Run the manager's uninstaller while the plugin is still installed:

```sh
PLUGIN_DIR="$HOME/.config/omarchy/plugins/io.github.splashymorningstar.keybindings"
python3 "$PLUGIN_DIR/manager.py" uninstall
```

It removes only this plugin's exact marked loader block, backs up
`bindings.lua`, and reloads Hyprland. It preserves the generated module,
shortcut database, and custom Lua file so they remain available if you
reinstall. Then remove the three `setup.keybindings` entries from the Omarchy
menu extension and remove the plugin:

```sh
omarchy plugin remove io.github.splashymorningstar.keybindings
```

If you manually added an unmarked `require("hypr.omarchy-keybindings")`, remove
that line yourself; the uninstaller deliberately leaves unmarked user content
untouched.

## Development checks

```sh
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" Keybindings.qml
python3 -m unittest discover -s tests -v
python3 -m py_compile manager.py tests/test_manager.py
```

## Marketplace listing

Suggested category: **System**. Suggested tags: `system`, `hyprland`,
`quickshell`. The manifest uses `io.github.splashymorningstar.keybindings`
and the repository includes an MIT license. Before submitting, confirm the
GitHub account and that this permanent plugin ID remains globally available,
publish this repository publicly, and follow the
[Omarchy Plugins publishing guide](https://plugins.omarchy.org/publish.html).
The marketplace validates listings, not plugin security.
