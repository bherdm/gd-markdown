# gdMarkdown

A Markdown doc rendering dock for the Godot 4.7 editor. Read your project's `.md` files as formatted pages alongside the viewport.

Standard Markdown support, plus a few Godot-specific features:

- **Editor icons in text.** `{icon:ScriptCreate}` draws Godot Engine icons inline, plus a built-in browser to find names.
- **Links into Godot's docs.** `[position](godot:Node2D.position)` opens the offline class reference.
- **Links between files.** `.md` links open in the dock, `.gd` links open the script editor, and `.tscn` links open the scene.
- **Code blocks with copy buttons** that keep tab indentation intact for pasting GDScript.
- **Tables, task lists, images size options, quotes, and editor theme following**

## Install

1. Copy `addons/gdmarkdown/` into your project's `addons/` folder.
2. Enable **gdMarkdown** in Project → Project Settings → Plugins.

## Guide for Writing Markdown for gdMarkdown

Press the **?** button in the dock to open the guide. It shows every supported feature with examples. You can also read [GUIDE.md](addons/gdmarkdown/GUIDE.md) in Godot's script editor to see the raw text.

## Requirements

Godot 4.7 or later.

## Credits

Table, blockquote, task-list, code-block, and theme-color techniques are adapted from Markdown Previewer by JSH (MIT). See [THIRD_PARTY_NOTICES.md](addons/gdmarkdown/THIRD_PARTY_NOTICES.md).

Developed with assistance from Claude Opus (Anthropic).

## License

gdMarkdown is released under the [MIT License](LICENSE), copyright (c) 2026 bherdm.

Portions adapted from Markdown Previewer by JSH remain under their original MIT License.

gdMarkdown is not affiliated with or endorsed by the Godot Foundation. gdMarkdown uses the GODOT® name and logos under a permissive license granted by the Godot Foundation.