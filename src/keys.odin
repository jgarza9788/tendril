package main

import "core:fmt"
import "core:strings"
import "../libs/hnoss/input"

// Everything a key can do. The lower-cased name ("play_pause") is what config.json uses.
Action :: enum {
	None,
	Quit, Play_Pause, Next, Prev, Shuffle, Repeat,
	Vol_Up, Vol_Down, Seek_Fwd, Seek_Back,
	Tab_1, Tab_2, Tab_3, Tab_4, Tab_5, Tab_Next, Tab_Prev, Search,
	Add_Server, Remove_Server,
	Queue_Add, Play_Next, Queue_Remove, Queue_Up, Queue_Down, Queue_Clear, Save_Playlist,
	Favorite, Favorite_Current,
	Lyrics, Retry, Jump, Help, Back, Theme_Next, View_Cycle,
}

Bind :: struct {
	code:   input.Key_Code,
	ch:     rune,
	mods:   input.Key_Modifiers,
	action: Action,
}

// Default keys per action. Order matters for the help screen: the first is shown.
DEFAULT_KEYS := [Action][]string{
	.None = {},
	.Quit = {"q", "ctrl+c"}, .Play_Pause = {"space"}, .Next = {"n"}, .Prev = {"p"},
	.Shuffle = {"s"}, .Repeat = {"r"},
	.Vol_Up = {"+", "="}, .Vol_Down = {"-"}, .Seek_Fwd = {".", "right"}, .Seek_Back = {",", "left"},
	.Tab_1 = {"1"}, .Tab_2 = {"2"}, .Tab_3 = {"3"}, .Tab_4 = {"4"}, .Tab_5 = {"5"},
	.Tab_Next = {"]"}, .Tab_Prev = {"["}, .Search = {"/"},
	.Add_Server = {"N"}, .Remove_Server = {"X"},
	.Queue_Add = {"a"}, .Play_Next = {"A"}, .Queue_Remove = {"d"}, .Queue_Up = {"K"}, .Queue_Down = {"J"},
	.Queue_Clear = {"C"}, .Save_Playlist = {"W"},
	.Favorite = {"f"}, .Favorite_Current = {"F"},
	.Lyrics = {"l"}, .Retry = {"R"}, .Jump = {"g"}, .Help = {"?"},
	.Back = {"esc", "backspace"}, .Theme_Next = {"T"}, .View_Cycle = {"v"},
}

// The name used in config.json. Written out because it is part of the file format.
action_name :: proc(a: Action) -> string {
	switch a {
	case .None: return "none"
	case .Quit: return "quit"
	case .Play_Pause: return "play_pause"
	case .Next: return "next"
	case .Prev: return "prev"
	case .Shuffle: return "shuffle"
	case .Repeat: return "repeat"
	case .Vol_Up: return "vol_up"
	case .Vol_Down: return "vol_down"
	case .Seek_Fwd: return "seek_fwd"
	case .Seek_Back: return "seek_back"
	case .Tab_1: return "tab_1"
	case .Tab_2: return "tab_2"
	case .Tab_3: return "tab_3"
	case .Tab_4: return "tab_4"
	case .Tab_5: return "tab_5"
	case .Tab_Next: return "tab_next"
	case .Tab_Prev: return "tab_prev"
	case .Search: return "search"
	case .Add_Server: return "add_server"
	case .Remove_Server: return "remove_server"
	case .Queue_Add: return "queue_add"
	case .Play_Next: return "play_next"
	case .Queue_Remove: return "queue_remove"
	case .Queue_Up: return "queue_up"
	case .Queue_Down: return "queue_down"
	case .Queue_Clear: return "queue_clear"
	case .Save_Playlist: return "save_playlist"
	case .Favorite: return "favorite"
	case .Favorite_Current: return "favorite_current"
	case .Lyrics: return "lyrics"
	case .Retry: return "retry"
	case .Jump: return "jump"
	case .Help: return "help"
	case .Back: return "back"
	case .Theme_Next: return "theme_next"
	case .View_Cycle: return "view_cycle"
	}
	return ""
}

// Parses "n", "N", "space", "esc", "left", "ctrl+c", "alt+x"... into a binding.
parse_key :: proc(spec: string) -> (b: Bind, ok: bool) {
	rest := spec
	for {
		switch {
		case strings.has_prefix(rest, "ctrl+"):  b.mods += {.Ctrl}; rest = rest[5:]; continue
		case strings.has_prefix(rest, "alt+"):   b.mods += {.Alt}; rest = rest[4:]; continue
		}
		break
	}
	switch strings.to_lower(rest, context.temp_allocator) {
	case "space":     b.code, b.ch = .Char, ' '
	case "enter":     b.code = .Enter
	case "esc":       b.code = .Esc
	case "tab":       b.code = .Tab
	case "backspace": b.code = .Backspace
	case "up":        b.code = .Up
	case "down":      b.code = .Down
	case "left":      b.code = .Left
	case "right":     b.code = .Right
	case "f1": b.code = .F1
	case "f2": b.code = .F2
	case "f3": b.code = .F3
	case "f4": b.code = .F4
	case "f5": b.code = .F5
	case "f6": b.code = .F6
	case "f7": b.code = .F7
	case "f8": b.code = .F8
	case "f9": b.code = .F9
	case "f10": b.code = .F10
	case "f11": b.code = .F11
	case "f12": b.code = .F12
	case:
		if len(rest) == 0 { return {}, false }
		n := 0
		r: rune
		for c in rest { r = c; n += 1 }
		if n != 1 { return {}, false }
		b.code, b.ch = .Char, r
	}
	return b, true
}

// Builds the binding table from the defaults plus the user's overrides. Overriding
// an action replaces all of its default keys. Returns the specs that did not parse.
build_binds :: proc(overrides: map[string][]string, allocator := context.allocator) -> (binds: [dynamic]Bind, bad: [dynamic]string) {
	binds.allocator = allocator
	bad.allocator = context.temp_allocator
	for a in Action {
		if a == .None { continue }
		specs := DEFAULT_KEYS[a]
		if user, found := overrides[action_name(a)]; found { specs = user }
		for sp in specs {
			b, ok := parse_key(sp)
			if !ok { append(&bad, sp); continue }
			b.action = a
			append(&binds, b)
		}
	}
	return
}

action_for :: proc(binds: []Bind, ev: input.Event) -> Action {
	k, ok := ev.(input.Key)
	if !ok { return .None }
	for b in binds {
		if b.code != k.code || b.mods != k.mods { continue }
		if b.code == .Char && b.ch != k.char { continue }
		return b.action
	}
	return .None
}

// The key shown for an action in help text.
key_label :: proc(binds: []Bind, a: Action) -> string {
	for b in binds {
		if b.action != a { continue }
		name: string
		#partial switch b.code {
		case .Char:      name = b.ch == ' ' ? "space" : string_from_rune(b.ch)
		case .Enter:     name = "enter"
		case .Esc:       name = "esc"
		case .Tab:       name = "tab"
		case .Backspace: name = "backspace"
		case .Up:        name = "↑"
		case .Down:      name = "↓"
		case .Left:      name = "←"
		case .Right:     name = "→"
		case .F1 ..= .F12: name = fmt.tprintf("f%d", int(b.code) - int(input.Key_Code.F1) + 1)
		case:            name = "?"
		}
		if .Ctrl in b.mods { return strings.concatenate({"ctrl+", name}, context.temp_allocator) }
		if .Alt in b.mods { return strings.concatenate({"alt+", name}, context.temp_allocator) }
		return name
	}
	return ""
}

@(private="file")
string_from_rune :: proc(r: rune) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_rune(&b, r)
	return strings.to_string(b)
}
