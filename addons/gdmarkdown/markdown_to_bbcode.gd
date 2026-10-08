@tool
extends RefCounted
## gdMarkdown: converts Markdown into a list of blocks for the viewer to render.
##
## Each block is a Dictionary: [code]{"type": "text", "bbcode": String}[/code]
## for formatted text, or [code]{"type": "code", "code": String, "lang": String}[/code]
## for fenced code blocks (which the viewer draws as panels with a copy button).
## Code blocks also carry "indent", their list nesting depth.
##
## Supported: # headings, paragraphs, - * + bullet lists, 1. numbered lists
## (nested with tabs or 2 spaces), - [ ] task lists, | tables |, ``` fenced
## code, `inline code`, **bold**, *italic*, ~~strikethrough~~, [links](url),
## ![images](path), <kbd>keys</kbd>, > blockquotes, and --- horizontal rules.
## Image sizes: ![alt](path){width=300} (Pandoc style) or GitHub's
## <img src="path" width="300">. Width/height may be pixels or a percentage
## of the panel width. Images never grow wider than the panel.
## Extension: {icon:ScriptCreate} inserts a Godot editor icon inline, and
## {icon:images/my_button.svg} inserts your own image at text height.
## Extension: [text](godot:Node2D.position) opens Godot's built-in help.
## Heading links: [text](#heading-name) or [text](file.md#heading-name), using
## GitHub's heading IDs. Each heading starts a new text block that carries an
## "anchor" key, so the viewer can scroll to it.
## Not supported: HTML other than <kbd>, reference-style links, footnotes.
##
## Table, blockquote, and task-list rendering approaches adapted from
## Markdown Previewer by JSH (MIT License). See THIRD_PARTY_NOTICES.md.

## Icons can't be written as BBCode (they live in the editor theme, not in a
## file), so they're emitted as these markers and swapped in by the viewer.
## They're Unicode private-use characters: never in real text, and unlike
## control characters, not removed by strip_edges().
const ICON_START := "\uE000"
const ICON_END := "\uE001"
const TASK_UNCHECKED := "GuiUnchecked"
const TASK_CHECKED := "GuiChecked"
## Task checkboxes are emitted as a marker starting with this prefix, followed
## by the item's source line number and its state ("1" checked, "0" not), so
## the viewer can make them clickable and edit the right line.
const TASK_PREFIX := "task\uE002"

const BULLETS: Array[String] = ["•", "◦", "▪"]
const HEADING_SCALE: Array[float] = [2.0, 1.6, 1.35, 1.18, 1.08, 1.0]
## Images are emitted as an icon marker whose name starts with this prefix,
## followed by path, width, and height separated by IMAGE_SEP. The viewer
## sizes them, since only it knows how wide the panel is.
const IMAGE_PREFIX := "img\uE002"
const IMAGE_SEP := "\uE002"

## Colors are 6-digit hex strings; sizes are pixels. The viewer replaces these
## defaults with values taken from the current editor theme.
var style := {
	"text": "bfbfbf",
	"muted": "8a8a8a",
	"accent": "569eff",
	"code_bg": "222222",
	"inline_code_bg": "2e2e2e",
	"kbd_bg": "3a3a3a",
	"border": "4a4a4a",
	"table_header_bg": "2a2a2a",
	"quote_bg": "262a30",
	"body_size": 16,
	"cell_pad": 6,
	"quote_pad": 10,
}

static var _heading := RegEx.create_from_string("^(#{1,6})\\s+(.*?)\\s*#*\\s*$")
static var _list_item := RegEx.create_from_string("^([ \\t]*)([-*+]|\\d+[.)])\\s+(.*)$")
static var _task := RegEx.create_from_string("^\\[([ xX])\\]\\s+(.*)$")
static var _task_line := RegEx.create_from_string("^(\\s*(?:[-*+]|\\d+[.)])\\s+\\[)([ xX])(\\].*)$")
static var _attribute := RegEx.create_from_string("(\\w+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s}]+))")
static var _title := RegEx.create_from_string("^(.*?)\\s+(?:\"[^\"]*\"|'[^']*')$")
static var _link_text := RegEx.create_from_string("!?\\[([^\\]]*)\\]\\([^)]*\\)")
static var _html_tag := RegEx.create_from_string("<[^>]+>")
static var _rule := RegEx.create_from_string("^\\s*([-*_])(\\s*\\1){2,}\\s*$")
static var _table_separator := RegEx.create_from_string("^\\s*\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)*\\|?\\s*$")
static var _inline := RegEx.create_from_string(
	"(?<code>`+)(?<code_text>.+?)\\k<code>"
	+ "|\\{icon:(?<icon>[^}\\s]+)\\}"
	+ "|!\\[(?<img_alt>[^\\]]*)\\]\\((?<img_src>[^)]+)\\)(?:\\{(?<img_attrs>[^}]*)\\})?"
	+ "|<img\\s(?<html_img>[^>]*?)/?>"
	+ "|\\[(?<link_text>[^\\]]+)\\]\\((?<link_url>[^)]+)\\)"
	+ "|<kbd>(?<kbd>.+?)</kbd>"
	+ "|\\*\\*(?<bold>.+?)\\*\\*"
	+ "|~~(?<strike>.+?)~~"
	+ "|\\*(?<italic>[^*\\s](?:[^*]*[^*\\s])?)\\*"
)


## Converts [param markdown] to blocks. Relative image and link paths are
## resolved against [param base_dir] (the folder the .md file lives in).
func convert(markdown: String, base_dir: String = "res://") -> Array[Dictionary]:
	var blocks: Array[Dictionary] = []
	var out := ""
	var paragraph: Array[String] = []
	var list_counters := {}
	var last_was_blank := true
	var anchor := ""  # heading ID for the text block being built
	var used_ids := {}
	var lines := markdown.replace("\r\n", "\n").split("\n")
	var i := 0

	while i < lines.size():
		var line: String = lines[i]
		var stripped := line.strip_edges()

		# Fenced code becomes its own block so it can get a copy button.
		if stripped.begins_with("```") or stripped.begins_with("~~~"):
			out += _flush(paragraph, base_dir)
			_push_text(blocks, out, anchor)
			out = ""
			anchor = ""
			# The fence is the run of ` or ~ that opens the block. Only a run at
			# least as long closes it, so ```` can wrap an example containing ```.
			var fence_char := stripped[0]
			var fence_length := stripped.length() - stripped.lstrip(fence_char).length()
			var lead := line.substr(0, line.length() - line.lstrip(" \t").length())
			var depth := lead.count("\t") + floori(lead.count(" ") / 2.0)
			var lang := stripped.substr(fence_length).strip_edges()
			var code_lines: Array[String] = []
			i += 1
			while i < lines.size() and not _closes_fence(lines[i], fence_char, fence_length):
				code_lines.append(lines[i])
				i += 1
			i += 1  # Skip the closing fence (or run off the end if unclosed).
			blocks.append({"type": "code", "lang": lang, "code": _dedent(code_lines), "indent": depth})
			last_was_blank = true
			continue

		if stripped.is_empty():
			out += _flush(paragraph, base_dir)
			if not last_was_blank:
				out += "\n"
			last_was_blank = true
			i += 1
			continue
		last_was_blank = false

		if stripped.contains("|") and i + 1 < lines.size() and _table_separator.search(lines[i + 1]):
			out += _flush(paragraph, base_dir)
			list_counters.clear()
			var table := _table(lines, i, base_dir)
			out += table.bbcode
			i = table.next
			continue

		var m := _heading.search(line)
		if m:
			# Each heading starts a new block so links can scroll right to it.
			out += _flush(paragraph, base_dir)
			_push_text(blocks, out, anchor)
			out = ""
			anchor = _unique_id(heading_id(m.get_string(2)), used_ids)
			list_counters.clear()
			var level := m.get_string(1).length()
			var size := roundi(style.body_size * HEADING_SCALE[level - 1])
			out += "[font_size=%d][b]%s[/b][/font_size]\n" % [size, _inline_to_bbcode(m.get_string(2), base_dir)]
			i += 1
			continue

		if _rule.search(line):
			out += _flush(paragraph, base_dir)
			list_counters.clear()
			out += "[hr color=#%s height=1 width=100%%]\n" % style.border
			i += 1
			continue

		m = _list_item.search(line)
		if m:
			out += _flush(paragraph, base_dir)
			out += _list_line(m, i, list_counters, base_dir)
			i += 1
			continue

		if stripped.begins_with(">"):
			out += _flush(paragraph, base_dir)
			list_counters.clear()
			var quote := _quote(lines, i, base_dir)
			out += quote.bbcode
			i = quote.next
			continue

		list_counters.clear()
		paragraph.append(stripped)
		i += 1

	out += _flush(paragraph, base_dir)
	_push_text(blocks, out, anchor)
	return blocks


static func _closes_fence(line: String, fence_char: String, fence_length: int) -> bool:
	var text := line.strip_edges()
	var run := text.length() - text.lstrip(fence_char).length()
	return run >= fence_length and text.substr(run).strip_edges().is_empty()


## Flips a task-list line between "- [ ]" and "- [x]". Returns the line
## unchanged if it isn't a task item.
static func toggle_task_line(line: String) -> String:
	var m := _task_line.search(line)
	if m == null:
		return line
	var mark := "x" if m.get_string(2) == " " else " "
	return m.get_string(1) + mark + m.get_string(3)


static func is_task_checked(line: String) -> bool:
	var m := _task_line.search(line)
	return m != null and m.get_string(2) != " "


static func _push_text(blocks: Array[Dictionary], bbcode: String, anchor: String) -> void:
	var trimmed := bbcode.strip_edges()
	if not trimmed.is_empty():
		blocks.append({"type": "text", "bbcode": trimmed, "anchor": anchor})


## Turns heading text into an ID the way GitHub does, so the same links work
## in both places: "Phase 1: Scene Setup!" becomes "phase-1-scene-setup".
## Formatting is dropped, letters are lowercased, spaces become hyphens, and
## punctuation other than - and _ is removed.
static func heading_id(heading: String) -> String:
	var text := _link_text.sub(heading, "$1", true)
	text = _html_tag.sub(text, "", true)
	var id := ""
	for character in text.strip_edges().to_lower():
		if character == " ":
			id += "-"
		elif character in ["-", "_"] or character.is_valid_int() or character.to_upper() != character.to_lower():
			id += character
	return id


## A repeated heading gets -1, -2, ... added, also matching GitHub.
static func _unique_id(id: String, used: Dictionary) -> String:
	if not used.has(id):
		used[id] = 0
		return id
	used[id] += 1
	return "%s-%d" % [id, used[id]]


## Joins wrapped source lines into one paragraph, Markdown-style.
func _flush(paragraph: Array[String], base_dir: String) -> String:
	if paragraph.is_empty():
		return ""
	var text := " ".join(paragraph)
	paragraph.clear()
	return _inline_to_bbcode(text, base_dir) + "\n"


func _list_line(m: RegExMatch, line_number: int, counters: Dictionary, base_dir: String) -> String:
	var indent := m.get_string(1)
	var depth := indent.count("\t") + floori(indent.count(" ") / 2.0)
	var marker := m.get_string(2)
	var text := m.get_string(3)

	# Leaving a nested list resets the numbering of the deeper levels.
	for key in counters.keys():
		if key > depth:
			counters.erase(key)

	var bullet: String
	var task := _task.search(text)
	if task:
		var done := task.get_string(1) != " "
		bullet = ICON_START + TASK_PREFIX + "%d%s%d" % [line_number, IMAGE_SEP, 1 if done else 0] + ICON_END
		text = task.get_string(2)
	elif marker[0].is_valid_int():
		# A list starts at the number written; later items count up from it.
		counters[depth] = counters[depth] + 1 if counters.has(depth) else marker.to_int()
		bullet = "%d." % counters[depth]
	else:
		counters.erase(depth)
		bullet = BULLETS[mini(depth, BULLETS.size() - 1)]

	var opens := "[indent]".repeat(depth + 1)
	var closes := "[/indent]".repeat(depth + 1)
	return "%s%s %s%s\n" % [opens, bullet, _inline_to_bbcode(text, base_dir), closes]


## A blockquote is drawn as a two-cell table: a thin accent-colored bar and a
## tinted card holding the quoted lines.
func _quote(lines: PackedStringArray, start: int, base_dir: String) -> Dictionary:
	var inner: Array[String] = []
	var i := start
	while i < lines.size() and lines[i].strip_edges().begins_with(">"):
		inner.append(_inline_to_bbcode(lines[i].strip_edges().trim_prefix(">").strip_edges(), base_dir))
		i += 1
	var pad: int = style.quote_pad
	var bbcode := "[table=2][cell expand=0 bg=#%s padding=2,0,2,0] [/cell]" % style.accent
	bbcode += "[cell expand=1 bg=#%s padding=%d,%d,%d,%d]%s[/cell][/table]\n" % [
		style.quote_bg, pad, pad, pad, pad, "\n".join(inner)]
	return {"bbcode": bbcode, "next": i}


func _table(lines: PackedStringArray, start: int, base_dir: String) -> Dictionary:
	var header := _split_row(lines[start])
	var columns := header.size()
	var aligns := _alignments(lines[start + 1], columns)
	var bbcode := "[table=%d]" % columns
	for c in columns:
		bbcode += _cell(header[c], aligns[c], true, base_dir)

	var i := start + 2
	while i < lines.size() and lines[i].contains("|") and not lines[i].strip_edges().is_empty():
		var row := _split_row(lines[i])
		for c in columns:
			bbcode += _cell(row[c] if c < row.size() else "", aligns[c], false, base_dir)
		i += 1
	return {"bbcode": bbcode + "[/table]\n", "next": i}


func _cell(text: String, align: String, is_header: bool, base_dir: String) -> String:
	var pad: int = style.cell_pad
	var content := _inline_to_bbcode(text, base_dir)
	if is_header:
		content = "[b]%s[/b]" % content
	if align != "left":
		content = "[p align=%s]%s[/p]" % [align, content]
	var bg := " bg=#%s" % style.table_header_bg if is_header else ""
	return "[cell padding=%d,%d,%d,%d border=#%s%s]%s[/cell]" % [pad, floori(pad / 2.0), pad, floori(pad / 2.0), style.border, bg, content]


## Splits "| a | b |" into ["a", "b"], keeping escaped \| as a literal pipe.
static func _split_row(line: String) -> Array[String]:
	var row := line.strip_edges().replace("\\|", "\uE003")
	row = row.trim_prefix("|").trim_suffix("|")
	var cells: Array[String] = []
	for cell in row.split("|"):
		cells.append(cell.strip_edges().replace("\uE003", "|"))
	return cells


static func _alignments(separator: String, columns: int) -> Array[String]:
	var aligns: Array[String] = []
	var parts := _split_row(separator)
	for c in columns:
		var part := parts[c] if c < parts.size() else ""
		if part.begins_with(":") and part.ends_with(":"):
			aligns.append("center")
		elif part.ends_with(":"):
			aligns.append("right")
		else:
			aligns.append("left")
	return aligns


## Removes indentation shared by every line, so a code block nested in a list
## doesn't show (or copy) the list's indentation.
static func _dedent(lines: Array[String]) -> String:
	var common := -1
	for line in lines:
		if line.strip_edges().is_empty():
			continue
		var width := line.length() - line.lstrip(" \t").length()
		common = width if common == -1 else mini(common, width)
	if common <= 0:
		return "\n".join(lines)
	var out: Array[String] = []
	for line in lines:
		out.append(line.substr(mini(common, line.length())))
	return "\n".join(out)


## Handles inline Markdown. Plain text between matches is escaped so stray
## square brackets (like array[0]) never get read as BBCode tags.
func _inline_to_bbcode(text: String, base_dir: String) -> String:
	var out := ""
	var pos := 0
	for m in _inline.search_all(text):
		out += _escape(text.substr(pos, m.get_start() - pos))
		pos = m.get_end()
		if m.get_start("code") != -1:
			out += "[bgcolor=#%s][code]%s[/code][/bgcolor]" % [style.inline_code_bg, _escape(m.get_string("code_text").strip_edges())]
		elif m.get_start("icon") != -1:
			var icon := m.get_string("icon")
			if icon.contains("/") or icon.contains("."):  # a file, not a theme icon
				icon = _resolve(icon, base_dir)
			out += ICON_START + icon + ICON_END
		elif m.get_start("img_src") != -1:
			var attrs := _attributes(m.get_string("img_attrs"))
			out += _image(m.get_string("img_alt"), _target(m.get_string("img_src")), attrs, base_dir)
		elif m.get_start("html_img") != -1:
			var attrs := _attributes(m.get_string("html_img"))
			out += _image(attrs.get("alt", ""), _target(attrs.get("src", "")), attrs, base_dir)
		elif m.get_start("link_url") != -1:
			# Spaces are encoded so they survive inside the [url=...] tag;
			# the viewer decodes them again when the link is clicked.
			var url := _resolve(_target(m.get_string("link_url")), base_dir).replace(" ", "%20")
			out += "[color=#%s][url=%s]%s[/url][/color]" % [style.accent, url, _inline_to_bbcode(m.get_string("link_text"), base_dir)]
		elif m.get_start("kbd") != -1:
			out += "[bgcolor=#%s][code]\u00A0%s\u00A0[/code][/bgcolor]" % [style.kbd_bg, _escape(m.get_string("kbd"))]
		elif m.get_start("bold") != -1:
			out += "[b]%s[/b]" % _inline_to_bbcode(m.get_string("bold"), base_dir)
		elif m.get_start("strike") != -1:
			out += "[s]%s[/s]" % _inline_to_bbcode(m.get_string("strike"), base_dir)
		elif m.get_start("italic") != -1:
			out += "[i]%s[/i]" % _inline_to_bbcode(m.get_string("italic"), base_dir)
	out += _escape(text.substr(pos))
	return out


func _image(alt: String, src: String, attrs: Dictionary, base_dir: String) -> String:
	if src.is_empty():
		return ""
	if src.contains("://") and not src.begins_with("res://"):
		# Web images can't be shown in the editor, so offer a link instead.
		return "[color=#%s][url=%s]%s[/url][/color]" % [style.accent, src, _escape("[image: %s]" % (alt if alt else src))]
	var path := _resolve(src, base_dir)
	if not ResourceLoader.exists(path):
		return "[color=orange]%s[/color]" % _escape("[missing image: %s]" % path)
	var parts: Array[String] = [path, attrs.get("width", ""), attrs.get("height", ""), alt]
	return ICON_START + IMAGE_PREFIX + IMAGE_SEP.join(parts) + ICON_END


## Reads key=value pairs from {width=300 height="50%"} or an HTML tag's
## attributes. Values may be quoted with "" or '' or left bare.
static func _attributes(text: String) -> Dictionary:
	var attrs := {}
	for m in _attribute.search_all(text):
		var value := m.get_string(2)
		if m.get_start(3) != -1:
			value = m.get_string(3)
		elif m.get_start(4) != -1:
			value = m.get_string(4)
		attrs[m.get_string(1).to_lower()] = value.strip_edges()
	return attrs


## Cleans up a link or image target. Accepts every common way of writing a
## path with spaces: My%20Lesson.md (GitHub, VS Code), <My Lesson.md>
## (CommonMark), or plain My Lesson.md. An optional "title" is dropped.
static func _target(raw: String) -> String:
	var target := raw.strip_edges()
	var titled := _title.search(target)
	if titled:
		target = titled.get_string(1).strip_edges()
	if target.begins_with("<") and target.ends_with(">"):
		target = target.substr(1, target.length() - 2)
	if not target.contains("://") or target.begins_with("res://"):
		target = target.uri_decode()  # web addresses stay encoded for the browser
	return target


static func _resolve(target: String, base_dir: String) -> String:
	if target.contains("://") or target.begins_with("#") or target.begins_with("godot:"):
		return target
	return base_dir.path_join(target).simplify_path()


static func _escape(text: String) -> String:
	return text.replace("[", "\u0001").replace("]", "[rb]").replace("\u0001", "[lb]")
