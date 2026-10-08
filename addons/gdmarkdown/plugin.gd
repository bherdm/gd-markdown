@tool
extends EditorPlugin
## gdMarkdown: adds a "Markdown" dock that renders the project's Markdown
## files as formatted, theme-aware text. The ? button opens GUIDE.md, a
## reference for every supported feature, rendered by the viewer itself.

const MarkdownConverter := preload("markdown_to_bbcode.gd")
const DEFAULT_FILE := "res://README.md"
const SKIP_DIRS: Array[String] = ["res://.godot"]
const METADATA_SECTION := "gdmarkdown"
const GUIDE_FILE := "GUIDE.md"

var dock: EditorDock
var file_picker: OptionButton
var scroll: ScrollContainer
var content: VBoxContainer
var converter := MarkdownConverter.new()
var current_path := ""

# Clickable task checkboxes edit the Markdown file. If the file is open in the
# script editor, the panel shows (and edits) the editor's text, so unsaved
# changes there are never overwritten.
var _rendered_source := ""        # the exact text the current page came from
var _watched_editor: CodeEdit     # the script editor tab showing this file
var _editor_change_timer: Timer
var _unsaved_note: Label
var _task_labels := {}             # task line number -> the label drawing its box
var _pressed_task := ""            # the checkbox link a mouse press started on
## This addon's own folder (found at runtime, so renaming it is safe). It's
## left out of the file list, but its GUIDE.md is offered at the bottom.
var _addon_dir := ""
var _has_images := false
var _rendered_width := 0.0
var _resize_timer: Timer
var _anchors := {}  # heading ID -> the block that starts with that heading

# Back/forward history, like a web browser. Each entry is {path, scroll}.
# Following a link or picking a file adds an entry; Back and Forward move
# through them. A page's scroll position is saved when you leave it.
const MAX_HISTORY := 50
var _history: Array[Dictionary] = []
var _history_index := -1
var back_button: Button
var forward_button: Button

# Toolbar buttons and their editor icon names, so icons can be swapped when
# the editor theme changes (light themes use different icon colors).
var _toolbar_icons := {}
var _theme_refresh_queued := false

# Theme values, refreshed whenever the editor theme changes.
var _colors := {}
var _fonts := {}
var _font_sizes := {}
var _scale := 1.0


func _enter_tree() -> void:
	_addon_dir = (get_script() as Script).resource_path.get_base_dir()
	dock = EditorDock.new()
	dock.title = "Markdown"
	dock.layout_key = "gdMarkdown"
	dock.icon_name = &"TextFile"
	dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_UL
	dock.available_layouts = EditorDock.DOCK_LAYOUT_ALL
	dock.add_child(_build_ui())
	add_dock(dock)

	# Images are sized to the panel, so re-render (briefly debounced) when
	# the panel's width changes.
	_resize_timer = Timer.new()
	_resize_timer.one_shot = true
	_resize_timer.wait_time = 0.15
	_resize_timer.timeout.connect(_reload)
	dock.add_child(_resize_timer)
	scroll.resized.connect(_on_scroll_resized)

	# Typing in the script editor updates the page shortly after you pause.
	_editor_change_timer = Timer.new()
	_editor_change_timer.one_shot = true
	_editor_change_timer.wait_time = 0.3
	_editor_change_timer.timeout.connect(_sync_with_editor)
	dock.add_child(_editor_change_timer)

	_read_editor_theme()
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_on_filesystem_changed)
	EditorInterface.get_editor_settings().settings_changed.connect(_on_editor_settings_changed)
	EditorInterface.get_file_system_dock().files_moved.connect(_on_files_moved)
	EditorInterface.get_file_system_dock().folder_moved.connect(_on_folder_moved)
	resource_saved.connect(_on_resource_saved)

	_refresh_file_list()
	var last: String = EditorInterface.get_editor_settings().get_project_metadata(
		METADATA_SECTION, "last_file", DEFAULT_FILE)
	_open(last if FileAccess.file_exists(last) else _first_file())


func _exit_tree() -> void:
	EditorInterface.get_resource_filesystem().filesystem_changed.disconnect(_on_filesystem_changed)
	EditorInterface.get_editor_settings().settings_changed.disconnect(_on_editor_settings_changed)
	EditorInterface.get_file_system_dock().files_moved.disconnect(_on_files_moved)
	EditorInterface.get_file_system_dock().folder_moved.disconnect(_on_folder_moved)
	resource_saved.disconnect(_on_resource_saved)
	_watch_editor(null)
	remove_dock(dock)
	dock.queue_free()


#region Building the panel

func _build_ui() -> Control:
	var root := VBoxContainer.new()
	# Fires whenever the editor's theme is rebuilt, including when Godot
	# follows the operating system's light/dark switch, which changes no
	# editor settings and so isn't caught by settings_changed.
	root.theme_changed.connect(_queue_theme_refresh)

	var toolbar := HBoxContainer.new()
	root.add_child(toolbar)

	# The picker shrinks to fit narrow docks instead of sizing itself to the
	# longest file path; the full path shows in its tooltip.
	file_picker = OptionButton.new()
	file_picker.fit_to_longest_item = false
	file_picker.clip_text = true
	file_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	file_picker.custom_minimum_size.x = 80 * EditorInterface.get_editor_scale()
	file_picker.tooltip_text = "Choose a Markdown file"
	back_button = Button.new()
	back_button.flat = true
	_set_toolbar_icon(back_button, "Back")
	back_button.disabled = true
	back_button.pressed.connect(_go.bind(-1))
	toolbar.add_child(back_button)

	forward_button = Button.new()
	forward_button.flat = true
	_set_toolbar_icon(forward_button, "Forward")
	forward_button.disabled = true
	forward_button.pressed.connect(_go.bind(1))
	toolbar.add_child(forward_button)

	file_picker.item_selected.connect(func(i): _navigate(file_picker.get_item_metadata(i)))
	toolbar.add_child(file_picker)

	var icons := Button.new()
	icons.flat = true
	_set_toolbar_icon(icons, "ImageTexture")
	icons.tooltip_text = "Browse Godot's editor icons and copy {icon:Name} tags"
	icons.pressed.connect(_show_icon_browser)
	toolbar.add_child(icons)

	var help := Button.new()
	help.flat = true
	_set_toolbar_icon(help, "Help")
	help.tooltip_text = "gdMarkdown guide: how to write Markdown for this panel"
	help.pressed.connect(func(): _navigate(_guide_path()))
	toolbar.add_child(help)

	var reload := Button.new()
	reload.flat = true
	_set_toolbar_icon(reload, "Reload")
	reload.tooltip_text = "Reload the file from disk"
	reload.pressed.connect(_reload)
	toolbar.add_child(reload)

	scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 160)
	scroll.gui_input.connect(_on_panel_input)
	scroll.mouse_entered.connect(_sync_with_editor)
	root.add_child(scroll)

	# Below the page, not above it: appearing there doesn't push the page
	# down, so the box you just clicked stays under the mouse.
	_unsaved_note = Label.new()
	_unsaved_note.text = "Showing unsaved changes from the script editor."
	_unsaved_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_unsaved_note.visible = false
	root.add_child(_unsaved_note)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	scroll.add_child(margin)

	content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(content)

	return root


## Pulls colors, fonts, and sizes from the editor theme so the page matches
## light or dark themes and the user's font settings.
func _read_editor_theme() -> void:
	var base := EditorInterface.get_base_control()
	_scale = EditorInterface.get_editor_scale()

	var bg := _theme_color(base, "base_color", Color(0.16, 0.16, 0.16))
	# Godot 4.7's font_color is partly transparent; blend it onto the
	# background so derived colors stay solid.
	var fg_raw := _theme_color(base, "font_color", Color(0.9, 0.9, 0.9))
	var fg := bg.lerp(Color(fg_raw, 1.0), fg_raw.a)
	var accent := _theme_color(base, "accent_color", Color(0.34, 0.62, 1.0))

	_colors = {
		"bg": bg,
		"text": fg,
		"muted": fg.lerp(bg, 0.4),
		"accent": accent,
		"code_bg": bg.lerp(fg, 0.06),
		"inline_code_bg": bg.lerp(fg, 0.12),
		"kbd_bg": bg.lerp(fg, 0.2),
		"border": bg.lerp(fg, 0.25),
		"table_header_bg": bg.lerp(fg, 0.09),
		"quote_bg": bg.lerp(accent, 0.08),
	}
	_fonts = {
		"normal": _theme_font(base, "doc", "main"),
		"bold": _theme_font(base, "doc_bold", "bold"),
		"italics": _theme_font(base, "doc_italic", "main"),
		"mono": _theme_font(base, "doc_source", "source"),
	}
	_font_sizes = {
		"normal": _theme_font_size(base, "doc_size", 16),
		"mono": _theme_font_size(base, "doc_source_size", 15),
	}

	var style := {}
	for key in ["text", "muted", "accent", "code_bg", "inline_code_bg", "kbd_bg",
			"border", "table_header_bg", "quote_bg"]:
		style[key] = (_colors[key] as Color).to_html(false)
	style.body_size = _font_sizes.normal
	style.cell_pad = roundi(8 * _scale)
	style.quote_pad = roundi(10 * _scale)
	converter.style = style


static func _theme_color(base: Control, color_name: String, fallback: Color) -> Color:
	return base.get_theme_color(color_name, &"Editor") if base.has_theme_color(color_name, &"Editor") else fallback


static func _theme_font(base: Control, preferred: String, fallback: String) -> Font:
	for font_name in [preferred, fallback]:
		if base.has_theme_font(font_name, &"EditorFonts"):
			return base.get_theme_font(font_name, &"EditorFonts")
	return null


static func _theme_font_size(base: Control, size_name: String, fallback: int) -> int:
	return base.get_theme_font_size(size_name, &"EditorFonts") if base.has_theme_font_size(size_name, &"EditorFonts") else fallback

#endregion


#region Rendering

## Opens a Markdown file without adding to history (used for reloads and
## renames). [param anchor] is a heading ID to scroll to; [param restore]
## is a scroll position to return to (used by Back and Forward).
func _open(path: String, keep_scroll := false, anchor := "", restore := -1) -> void:
	if path.is_empty():
		_show_message("No Markdown files found, and the guide is missing from %s." % _addon_dir)
		return

	if not FileAccess.file_exists(path):
		_show_message("[color=red]Could not open %s[/color]" % path)
		return

	var scroll_position := scroll.scroll_vertical
	current_path = path
	if _history.is_empty():
		_history.append({"path": path, "scroll": 0})
		_history_index = 0
	else:
		_history[_history_index].path = path  # keep history in step with reloads
	_update_history_buttons()
	var editor := _editor_for(path)
	_watch_editor(editor)
	var from_editor := editor != null and _has_unsaved_changes(path)
	_rendered_source = editor.text if from_editor else FileAccess.get_file_as_string(path)
	_unsaved_note.visible = from_editor
	_unsaved_note.add_theme_color_override("font_color", _colors.muted)
	_render(converter.convert(_rendered_source, path.get_base_dir()))

	EditorInterface.get_editor_settings().set_project_metadata(METADATA_SECTION, "last_file", path)
	for i in file_picker.item_count:
		if file_picker.get_item_metadata(i) == path:
			file_picker.select(i)
	file_picker.tooltip_text = path

	# Blocks size themselves over the next frames; restore scroll after that.
	await get_tree().process_frame
	await get_tree().process_frame
	if not anchor.is_empty() and _jump_to(anchor):
		return
	if restore >= 0:
		scroll.scroll_vertical = restore
	else:
		scroll.scroll_vertical = scroll_position if keep_scroll else 0


## Scrolls so the heading with this ID is at the top. Accepts the exact ID,
## or heading text that turns into it ("Scene Setup" finds "scene-setup").
func _jump_to(anchor: String) -> bool:
	var id := anchor.uri_decode()
	if not _anchors.has(id):
		id = MarkdownConverter.heading_id(id)
	if not _anchors.has(id):
		return false
	var target: Control = _anchors[id]
	scroll.scroll_vertical = roundi(content.position.y + target.position.y)
	return true


#region History

## Opens a file (or a heading on the current page) as a new history entry.
func _navigate(path: String, anchor := "") -> void:
	if path == current_path and anchor.is_empty():
		return  # already here; don't add a duplicate entry
	_save_scroll()
	_history.resize(_history_index + 1)  # going somewhere new drops Forward
	_history.append({"path": path, "scroll": 0})
	if _history.size() > MAX_HISTORY:
		_history.pop_front()
	_history_index = _history.size() - 1
	if path == current_path and not anchor.is_empty():
		_jump_to(anchor)
		_update_history_buttons()
	else:
		_open(path, false, anchor)


## Moves through history: -1 for Back, 1 for Forward. Entries for files that
## no longer exist are dropped along the way.
func _go(step: int) -> void:
	_save_scroll()
	var index := _history_index + step
	while index >= 0 and index < _history.size() and not FileAccess.file_exists(_history[index].path):
		_history.remove_at(index)
		if step < 0:
			index -= 1
			_history_index -= 1
	if index < 0 or index >= _history.size():
		_update_history_buttons()
		return
	_history_index = index
	var entry := _history[index]
	if entry.path == current_path:
		scroll.scroll_vertical = entry.scroll
		_update_history_buttons()
	else:
		_open(entry.path, false, "", entry.scroll)


func _save_scroll() -> void:
	if _history_index >= 0 and _history_index < _history.size():
		_history[_history_index].scroll = scroll.scroll_vertical


func _update_history_buttons() -> void:
	var can_back := _history_index > 0
	var can_forward := _history_index < _history.size() - 1
	back_button.disabled = not can_back
	forward_button.disabled = not can_forward
	back_button.tooltip_text = "Back to %s" % _history[_history_index - 1].path.get_file() if can_back else "Back"
	forward_button.tooltip_text = "Forward to %s" % _history[_history_index + 1].path.get_file() if can_forward else "Forward"


## Keeps history pointing at files after they're renamed or moved.
func _rename_in_history(old_path: String, new_path: String) -> void:
	for entry in _history:
		if entry.path == old_path:
			entry.path = new_path
		elif old_path.ends_with("/") and entry.path.begins_with(old_path):
			entry.path = new_path + entry.path.trim_prefix(old_path)
	_update_history_buttons()


## The mouse's side buttons go back and forward, as in a browser.
func _on_panel_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button == null or not button.pressed:
		return
	if button.button_index == MOUSE_BUTTON_XBUTTON1:
		_go(-1)
	elif button.button_index == MOUSE_BUTTON_XBUTTON2:
		_go(1)

#endregion


func _show_message(bbcode: String) -> void:
	_render([{"type": "text", "bbcode": "[i]%s[/i]" % bbcode}])


func _render(blocks: Array) -> void:
	_has_images = false
	_rendered_width = _available_width()
	for child in content.get_children():
		content.remove_child(child)
		child.queue_free()
	content.add_theme_constant_override("separation", roundi(10 * _scale))
	_anchors.clear()
	_task_labels.clear()

	for block in blocks:
		if block.type == "code":
			# Line a code block up with the list item it belongs to.
			var holder := MarginContainer.new()
			holder.add_theme_constant_override("margin_left", roundi(block.get("indent", 0) * _indent_width()))
			holder.add_child(_make_code_block(block.code, block.lang))
			content.add_child(holder)
		else:
			# Extra room above each heading (except at the very top).
			if not block.get("anchor", "").is_empty() and content.get_child_count() > 0:
				var spacer := Control.new()
				spacer.custom_minimum_size.y = roundi(8 * _scale)
				content.add_child(spacer)
			var text_block := _make_text_block(block.bbcode)
			content.add_child(text_block)
			if not block.get("anchor", "").is_empty():
				_anchors[block.anchor] = text_block


## The width of one [indent] level in a RichTextLabel (four spaces).
func _indent_width() -> float:
	var font: Font = _fonts.normal if _fonts.normal else ThemeDB.fallback_font
	return font.get_string_size("    ", HORIZONTAL_ALIGNMENT_LEFT, -1, _font_sizes.normal).x


func _make_text_block(bbcode: String) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.selection_enabled = true
	label.context_menu_enabled = true
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.focus_mode = Control.FOCUS_CLICK
	label.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	label.add_theme_color_override("default_color", _colors.text)
	label.add_theme_constant_override("line_separation", roundi(4 * _scale))
	for kind in ["normal", "bold", "italics", "mono"]:
		if _fonts[kind]:
			label.add_theme_font_override(kind + "_font", _fonts[kind])
	for kind in ["normal", "bold", "italics", "bold_italics"]:
		label.add_theme_font_size_override(kind + "_font_size", _font_sizes.normal)
	label.add_theme_font_size_override("mono_font_size", _font_sizes.mono)

	label.meta_clicked.connect(_on_link_clicked)
	label.gui_input.connect(_on_panel_input)
	label.gui_input.connect(_on_text_block_input.bind(label))
	label.meta_hover_started.connect(func(meta):
		label.set_meta(&"hovered_link", str(meta))
		label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND)
	label.meta_hover_ended.connect(func(_meta):
		label.remove_meta(&"hovered_link")
		label.mouse_default_cursor_shape = Control.CURSOR_ARROW)

	_append_with_icons(label, bbcode)
	return label


## Appends the BBCode piece by piece, inserting icon textures where the
## converter left icon markers. Open tags carry across append_text() calls,
## so an icon inside a list item, table, or bold text keeps its formatting.
func _append_with_icons(label: RichTextLabel, bbcode: String) -> void:
	var icon_size := roundi(_font_sizes.normal * 1.05)
	var pieces := bbcode.split(MarkdownConverter.ICON_START)
	label.append_text(pieces[0])
	for i in range(1, pieces.size()):
		var parts := pieces[i].split(MarkdownConverter.ICON_END, true, 1)
		var icon_name := parts[0]
		if icon_name.begins_with(MarkdownConverter.TASK_PREFIX):
			_add_task_checkbox(label, icon_name.trim_prefix(MarkdownConverter.TASK_PREFIX), icon_size)
			if parts.size() > 1:
				label.append_text(parts[1])
			continue
		if icon_name.begins_with(MarkdownConverter.IMAGE_PREFIX):
			_add_sized_image(label, icon_name.trim_prefix(MarkdownConverter.IMAGE_PREFIX))
			if parts.size() > 1:
				label.append_text(parts[1])
			continue
		var texture := _icon_texture(icon_name)
		if texture:
			label.add_image(texture, 0, icon_size)
		else:
			label.append_text("[color=orange][lb]?%s[rb][/color]" % icon_name)
		if parts.size() > 1:
			label.append_text(parts[1])


## Adds an image at its natural size, or the author's width/height, never
## wider than the panel. Pixel sizes follow the editor's display scale, the
## same way a browser treats CSS pixels on a high-DPI screen.
func _add_sized_image(label: RichTextLabel, spec: String) -> void:
	var fields := spec.split(MarkdownConverter.IMAGE_SEP)
	var texture := load(fields[0]) as Texture2D
	if texture == null:
		label.append_text("[color=orange][lb]can't load image: %s[rb][/color]" % fields[0])
		return
	_has_images = true
	var natural := Vector2(texture.get_size()) * _scale
	var aspect := natural.y / natural.x if natural.x > 0 else 1.0
	var available := _rendered_width if _rendered_width > 0 else natural.x

	var width := _parse_length(fields[1], available)
	var height := _parse_length(fields[2], available)
	if width <= 0 and height <= 0:
		width = natural.x
	if width <= 0:
		width = height / aspect
	if height <= 0:
		height = width * aspect
	if width > available:  # shrink to fit, keeping the proportions
		height *= available / width
		width = available
	label.add_image(texture, roundi(width), roundi(height), Color.WHITE,
			INLINE_ALIGNMENT_CENTER, Rect2(), null, false, fields[3])


## "300" or "300px" -> scaled pixels; "50%" -> half the available width.
func _parse_length(value: String, available: float) -> float:
	value = value.strip_edges()
	if value.ends_with("%"):
		return available * value.trim_suffix("%").to_float() / 100.0
	return value.trim_suffix("px").to_float() * _scale


func _available_width() -> float:
	return content.size.x if content.size.x > 0 else scroll.size.x - 24 * _scale


func _on_scroll_resized() -> void:
	if _has_images and absf(_available_width() - _rendered_width) > 1:
		_resize_timer.start()


func _icon_texture(icon_name: String) -> Texture2D:
	if icon_name.begins_with("res://"):
		if not ResourceLoader.exists(icon_name):
			return null
		return load(icon_name) as Texture2D
	var theme := EditorInterface.get_editor_theme()
	if theme.has_icon(icon_name, &"EditorIcons"):
		return theme.get_icon(icon_name, &"EditorIcons")
	return null


## A code block: tinted panel, language label, copy button, and the code in
## the editor's monospace font. Copying uses the original text, tabs intact,
## so pasted GDScript keeps valid indentation.
func _make_code_block(code: String, lang: String) -> Control:
	var panel := PanelContainer.new()
	var box := StyleBoxFlat.new()
	box.bg_color = _colors.code_bg
	box.border_color = _colors.border
	box.set_border_width_all(1)
	box.set_corner_radius_all(roundi(6 * _scale))
	box.set_content_margin_all(roundi(10 * _scale))
	panel.add_theme_stylebox_override("panel", box)

	var column := VBoxContainer.new()
	panel.add_child(column)

	var header := HBoxContainer.new()
	column.add_child(header)

	var lang_label := Label.new()
	lang_label.text = lang
	lang_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lang_label.add_theme_color_override("font_color", _colors.muted)
	if _fonts.mono:
		lang_label.add_theme_font_override("font", _fonts.mono)
	lang_label.add_theme_font_size_override("font_size", _font_sizes.mono - 2)
	header.add_child(lang_label)

	var copy := Button.new()
	copy.flat = true
	copy.focus_mode = Control.FOCUS_NONE
	copy.icon = _icon_texture("ActionCopy")
	copy.tooltip_text = "Copy code"
	copy.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	copy.pressed.connect(_on_copy_pressed.bind(copy, code))
	header.add_child(copy)

	# Long lines scroll sideways inside the block instead of wrapping, since
	# wrapped code hides its real indentation.
	var code_scroll := ScrollContainer.new()
	code_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(code_scroll)

	var body := RichTextLabel.new()
	body.bbcode_enabled = false
	body.fit_content = true
	body.scroll_active = false
	body.autowrap_mode = TextServer.AUTOWRAP_OFF
	body.selection_enabled = true
	body.context_menu_enabled = true
	body.focus_mode = Control.FOCUS_CLICK
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	body.add_theme_color_override("default_color", _colors.text)
	if _fonts.mono:
		body.add_theme_font_override("normal_font", _fonts.mono)
	body.add_theme_font_size_override("normal_font_size", _font_sizes.mono)
	body.text = code.replace("\t", "    ")
	body.gui_input.connect(_on_panel_input)
	code_scroll.add_child(body)

	return panel


func _on_copy_pressed(button: Button, code: String) -> void:
	DisplayServer.clipboard_set(code)
	button.icon = _icon_texture("StatusSuccess")
	button.tooltip_text = "Copied!"
	await get_tree().create_timer(1.2).timeout
	if is_instance_valid(button):
		button.icon = _icon_texture("ActionCopy")
		button.tooltip_text = "Copy code"

#endregion


#region Events

func _on_link_clicked(meta: Variant) -> void:
	var target := str(meta)
	if target.begins_with("task:"):
		_toggle_task(target.trim_prefix("task:").to_int())
	elif target.begins_with("#"):  # a heading on this page
		_navigate(current_path, target.substr(1))
	elif target.begins_with("godot:"):
		_open_godot_help(target.trim_prefix("godot:").uri_decode())
	elif target.begins_with("res://"):
		var anchor := ""
		if target.contains("#"):
			anchor = target.get_slice("#", 1)
			target = target.get_slice("#", 0)
		target = target.uri_decode()
		match target.get_extension():
			"md":
				_navigate(target, anchor)
			"tscn", "scn":
				EditorInterface.open_scene_from_path(target)
			"gd":
				EditorInterface.edit_script(load(target))
			_:
				EditorInterface.select_file(target)
	else:
		OS.shell_open(target)


## Re-reads the current file. If it was renamed or deleted out from under
## us, falls back to the default file instead of showing an error.
func _reload() -> void:
	if FileAccess.file_exists(current_path):
		_open(current_path, true)
	else:
		_open(_first_file())


func _on_resource_saved(_resource: Resource) -> void:
	_sync_with_editor()


func _on_filesystem_changed() -> void:
	_refresh_file_list()
	_sync_with_editor()


## Follows the open file when it's renamed or moved in the FileSystem dock.
func _on_files_moved(old_file: String, new_file: String) -> void:
	_rename_in_history(old_file, new_file)
	if old_file == current_path:
		_refresh_file_list()
		_open(new_file, true)


## Follows the open file when a folder above it is renamed or moved.
func _on_folder_moved(old_folder: String, new_folder: String) -> void:
	var old_prefix := old_folder.trim_suffix("/") + "/"
	_rename_in_history(old_prefix, new_folder.trim_suffix("/") + "/")
	if current_path.begins_with(old_prefix):
		_refresh_file_list()
		_open(new_folder.trim_suffix("/") + "/" + current_path.trim_prefix(old_prefix), true)


func _on_editor_settings_changed() -> void:
	var changed := EditorInterface.get_editor_settings().get_changed_settings()
	for setting in changed:
		if setting.begins_with("interface/theme") or setting.begins_with("interface/editor/main_font") \
				or setting.begins_with("interface/editor/code_font") or setting.contains("font_size"):
			_queue_theme_refresh()
			return


## Theme changes can arrive several at once (and also when the dock is just
## moved), so gather them into one check at the end of the frame.
func _queue_theme_refresh() -> void:
	if not _theme_refresh_queued:
		_theme_refresh_queued = true
		_refresh_theme.call_deferred()


## Re-reads the editor theme and re-renders only if something visible changed.
func _refresh_theme() -> void:
	_theme_refresh_queued = false
	var before := [_colors.duplicate(), _fonts.duplicate(), _font_sizes.duplicate(), _scale]
	_read_editor_theme()
	if before == [_colors, _fonts, _font_sizes, _scale]:
		return
	for button in _toolbar_icons:
		button.icon = _icon_texture(_toolbar_icons[button])
	_refresh_file_list()  # the guide entry has an icon too
	_reload()


func _set_toolbar_icon(button: Button, icon_name: String) -> void:
	_toolbar_icons[button] = icon_name
	button.icon = _icon_texture(icon_name)

#endregion


#region Task checkboxes

## A checkbox wrapped in a link, so clicking it reports its source line.
## Unlike text links, it's never underlined.
func _add_task_checkbox(label: RichTextLabel, spec: String, icon_size: int) -> void:
	var fields := spec.split(MarkdownConverter.IMAGE_SEP)
	var checked := fields[1] == "1"
	var icon := MarkdownConverter.TASK_CHECKED if checked else MarkdownConverter.TASK_UNCHECKED
	label.push_meta("task:" + fields[0], RichTextLabel.META_UNDERLINE_NEVER)
	label.add_image(_icon_texture(icon), 0, icon_size, Color.WHITE, INLINE_ALIGNMENT_CENTER,
			Rect2(), "task:" + fields[0], false, _checkbox_tooltip(checked))
	label.pop()
	_task_labels[fields[0].to_int()] = label


## Checkbox clicks are handled here, before the label itself sees them.
## Otherwise quick repeated clicks count as double-clicks, which the label
## uses to select text, and most of the clicks would be lost.
func _on_text_block_input(event: InputEvent, label: RichTextLabel) -> void:
	var button := event as InputEventMouseButton
	if button == null or button.button_index != MOUSE_BUTTON_LEFT:
		return
	var link: String = label.get_meta(&"hovered_link", "")
	if button.pressed:
		_pressed_task = link if link.begins_with("task:") else ""
		if not _pressed_task.is_empty():
			label.accept_event()
	elif not _pressed_task.is_empty():
		label.accept_event()
		# Like a button: the click counts if released over the same box.
		if link == _pressed_task:
			_toggle_task(link.trim_prefix("task:").to_int())
		_pressed_task = ""


## Redraws one checkbox without rebuilding the page, so clicks in quick
## succession all land on the same, already-drawn box.
func _set_checkbox(line: int, checked: bool) -> void:
	var label: RichTextLabel = _task_labels.get(line)
	if not is_instance_valid(label):
		_open(current_path, true)
		return
	var icon := MarkdownConverter.TASK_CHECKED if checked else MarkdownConverter.TASK_UNCHECKED
	label.update_image("task:%d" % line, RichTextLabel.UPDATE_TEXTURE | RichTextLabel.UPDATE_TOOLTIP,
			_icon_texture(icon), 0, 0, Color.WHITE, INLINE_ALIGNMENT_CENTER, Rect2(), false,
			_checkbox_tooltip(checked))


static func _checkbox_tooltip(checked: bool) -> String:
	return "Click to uncheck" if checked else "Click to check"


## Checks or unchecks the task on [param line] of the current file.
func _toggle_task(line: int) -> void:
	var path := current_path
	var editor := _editor_for(path)
	var unsaved := _has_unsaved_changes(path)
	if unsaved and editor == null:
		_toast("%s has unsaved changes in the script editor. Save it, then try again." % path.get_file())
		return

	# Edit the text the page was made from. If that text has changed since
	# (in the editor or on disk), refresh instead of guessing which line.
	var in_editor := editor != null and unsaved
	var source := editor.text if in_editor else FileAccess.get_file_as_string(path)
	if source != _rendered_source:
		_reload()
		_toast("%s changed since it was shown. The page is refreshed; try again." % path.get_file())
		return

	var lines := source.split("\n")
	var new_line := MarkdownConverter.toggle_task_line(lines[line]) if line < lines.size() else ""
	if line >= lines.size() or new_line == lines[line]:
		_reload()
		return

	if editor:
		# The file is open in the script editor: change the text there and
		# let the user save it as usual (it's undoable there with Cmd/Ctrl+Z).
		# Writing the file directly would make Godot report the open file as
		# "modified outside Godot".
		editor.begin_complex_operation()
		editor.set_line(line, new_line)
		editor.end_complex_operation()
	else:
		lines[line] = new_line
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			_toast("Couldn't save %s: %s" % [path.get_file(), error_string(FileAccess.get_open_error())], EditorToaster.SEVERITY_ERROR)
			return
		file.store_string("\n".join(lines))
		file.close()

	# The page already shows everything else correctly; just flip this box
	# and remember the new text, so the refresh that follows the edit finds
	# nothing to redo.
	lines[line] = new_line
	_rendered_source = editor.text if editor else "\n".join(lines)
	_unsaved_note.visible = editor != null and _has_unsaved_changes(path)
	_set_checkbox(line, MarkdownConverter.is_task_checked(new_line))


## The script editor's text box for [param path], or null if it isn't open.
func _editor_for(path: String) -> CodeEdit:
	var script_editor := EditorInterface.get_script_editor()
	var editors := script_editor.get_open_script_editors()
	if editors.is_empty():
		return null
	var tabs := editors[0].get_parent() as TabContainer
	if tabs == null:
		return null
	# The script editor's file list shows each file's path as a tooltip and
	# stores its tab number as metadata. This isn't a public API, so if a
	# future Godot changes it, the lookup simply finds nothing.
	for list in script_editor.find_children("*", "ItemList", true, false):
		var items := list as ItemList
		for i in items.item_count:
			var tab: Variant = items.get_item_metadata(i)
			if items.get_item_tooltip(i) == path and tab is int and tab < tabs.get_tab_count():
				var editor := tabs.get_tab_control(tab) as ScriptEditorBase
				if editor:
					return editor.get_base_editor() as CodeEdit
	return null


func _has_unsaved_changes(path: String) -> bool:
	return path in EditorInterface.get_script_editor().get_unsaved_files()


## Follows typing in the script editor tab that shows the current file.
func _watch_editor(editor: CodeEdit) -> void:
	if editor == _watched_editor:
		return
	if is_instance_valid(_watched_editor) and _watched_editor.text_changed.is_connected(_editor_change_timer.start):
		_watched_editor.text_changed.disconnect(_editor_change_timer.start)
	_watched_editor = editor
	if editor:
		editor.text_changed.connect(_editor_change_timer.start)


## Catches changes the panel couldn't hear about, such as the file being
## opened in the script editor after the page was shown.
func _sync_with_editor() -> void:
	if current_path.is_empty() or not FileAccess.file_exists(current_path):
		_reload()
		return
	var editor := _editor_for(current_path)
	var from_editor := editor != null and _has_unsaved_changes(current_path)
	var source := editor.text if from_editor else FileAccess.get_file_as_string(current_path)
	if source != _rendered_source or editor != _watched_editor or from_editor != _unsaved_note.visible:
		_reload()


func _toast(message: String, severity := EditorToaster.SEVERITY_WARNING) -> void:
	EditorInterface.get_editor_toaster().push_toast("gdMarkdown: " + message, severity)

#endregion


#region Godot help links

## Functions documented under @GDScript; other global functions live in
## @GlobalScope.
const GDSCRIPT_FUNCTIONS: Array[String] = ["Color8", "assert", "char", "convert",
	"dict_to_inst", "get_stack", "inst_to_dict", "is_instance_of", "len", "load",
	"ord", "preload", "print_debug", "print_stack", "range", "type_exists"]


## Opens the editor's offline class reference, which always matches the
## installed Godot version. Accepts Node2D, Node2D.position,
## Input.is_action_just_pressed, Vector2.length(), print(), KEY_SHIFT, @export.
func _open_godot_help(reference: String) -> void:
	EditorInterface.set_main_screen_editor("Script")
	EditorInterface.get_script_editor().goto_help(_help_topic(reference))


func _help_topic(reference: String) -> String:
	var ref := reference.strip_edges()
	var is_call := ref.ends_with("()")
	ref = ref.trim_suffix("()")

	if ref.begins_with("@"):
		return "class_annotation:@GDScript:" + ref

	var dot := ref.find(".")
	if dot == -1:
		if is_call:
			var scope := "@GDScript" if ref in GDSCRIPT_FUNCTIONS else "@GlobalScope"
			return "class_method:%s:%s" % [scope, ref]
		if _is_constant_name(ref):
			return "class_constant:@GlobalScope:" + ref
		return "class_name:" + ref

	var cls := ref.substr(0, dot)
	var member := ref.substr(dot + 1)
	if not ClassDB.class_exists(cls):
		# Built-in types like Vector2 and String aren't in ClassDB, so go by
		# how the member is written: length() is a method, UP a constant.
		if is_call:
			return "class_method:%s:%s" % [cls, member]
		if _is_constant_name(member):
			return "class_constant:%s:%s" % [cls, member]
		return "class_property:%s:%s" % [cls, member]

	# Inherited members are documented on the class that declares them
	# (Sprite2D.position lives on Node2D), so find that class first.
	for kind in ["method", "signal", "enum", "constant", "property"]:
		var owner_class := _declaring_class(cls, member, kind)
		if not owner_class.is_empty():
			return "class_%s:%s:%s" % [kind, owner_class, member]
	if is_call:  # Virtual methods like _ready() aren't listed in ClassDB.
		return "class_method:%s:%s" % [cls, member]
	return "class_name:" + cls


func _declaring_class(cls: String, member: String, kind: String) -> String:
	var current := cls
	while not current.is_empty():
		var found := false
		match kind:
			"method":
				found = ClassDB.class_has_method(current, member, true)
			"signal":
				found = ClassDB.class_has_signal(current, member)
				found = found and not ClassDB.class_has_signal(ClassDB.get_parent_class(current), member)
			"enum":
				found = ClassDB.class_has_enum(current, member, true)
			"constant":
				found = ClassDB.class_has_integer_constant(current, member)
				found = found and not ClassDB.class_has_integer_constant(ClassDB.get_parent_class(current), member)
			"property":
				for property in ClassDB.class_get_property_list(current, true):
					if property.name == member:
						found = true
						break
		if found:
			return current
		current = ClassDB.get_parent_class(current)
	return ""


static func _is_constant_name(text: String) -> bool:
	return text == text.to_upper() and text != text.to_lower()

#endregion


#region File list

func _refresh_file_list() -> void:
	file_picker.clear()
	for path in _find_markdown("res://"):
		file_picker.add_item(path.trim_prefix("res://"))
		file_picker.set_item_metadata(file_picker.item_count - 1, path)
	if FileAccess.file_exists(_guide_path()):
		if file_picker.item_count > 0:
			file_picker.add_separator()
		file_picker.add_icon_item(_icon_texture("Help"), "gdMarkdown Guide")
		file_picker.set_item_metadata(file_picker.item_count - 1, _guide_path())
	for i in file_picker.item_count:
		if file_picker.get_item_metadata(i) == current_path:
			file_picker.select(i)


func _guide_path() -> String:
	return _addon_dir.path_join(GUIDE_FILE)


## README.md if there is one, else the first file found, else the guide.
func _first_file() -> String:
	if FileAccess.file_exists(DEFAULT_FILE):
		return DEFAULT_FILE
	for i in file_picker.item_count:
		if file_picker.get_item_metadata(i) != null:
			return file_picker.get_item_metadata(i)
	return ""


func _find_markdown(dir_path: String) -> Array[String]:
	var found: Array[String] = []
	if dir_path in SKIP_DIRS or dir_path == _addon_dir:
		return found
	for file_name in DirAccess.get_files_at(dir_path):
		if file_name.get_extension().to_lower() == "md":
			found.append(dir_path.path_join(file_name))
	for sub in DirAccess.get_directories_at(dir_path):
		found.append_array(_find_markdown(dir_path.path_join(sub)))
	return found

#endregion


#region Icon browser

## A searchable list of every editor icon. Double-click (or Enter) copies the
## {icon:Name} tag to the clipboard, ready to paste into a Markdown file.
func _show_icon_browser() -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Editor Icons — double-click to copy {icon:Name}"
	dialog.ok_button_text = "Close"

	var box := VBoxContainer.new()
	var search := LineEdit.new()
	search.placeholder_text = "Filter (e.g. Script, Play, Node2D)"
	search.clear_button_enabled = true
	box.add_child(search)

	var list := ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.max_columns = 0
	list.same_column_width = true
	list.fixed_column_width = roundi(190 * _scale)
	box.add_child(list)

	var status := Label.new()
	box.add_child(status)
	dialog.add_child(box)

	var theme := EditorInterface.get_editor_theme()
	var names := Array(theme.get_icon_list(&"EditorIcons"))
	names.sort()

	var fill := func(filter: String) -> void:
		list.clear()
		for icon_name in names:
			if filter.is_empty() or icon_name.containsn(filter):
				list.add_item(icon_name, theme.get_icon(icon_name, &"EditorIcons"))
		status.text = "%d icons" % list.item_count
	fill.call("")
	search.text_changed.connect(fill)

	list.item_activated.connect(func(index: int) -> void:
		var tag := "{icon:%s}" % list.get_item_text(index)
		DisplayServer.clipboard_set(tag)
		status.text = "Copied %s" % tag)

	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free())
	EditorInterface.popup_dialog_centered(dialog, Vector2i(Vector2(720, 520) * _scale))
	search.grab_focus()

#endregion
