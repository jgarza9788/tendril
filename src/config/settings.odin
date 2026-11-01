package config

import "core:encoding/json"
import "core:os"
import "core:path/filepath"

// User preferences, in ~/.config/tendril/config.json (kept apart from servers.json,
// which holds secrets). Every field is optional: missing ones keep their defaults.
Settings :: struct {
	volume:   int,                  // starting volume, 0-100 (a restored session overrides it)
	scrobble: bool,                 // report playback to the server
	mpris:    bool,                 // let media keys and playerctl control Tendril
	theme:    string,               // palette name: abyss, sunset, forest, mono
	accent:   string,               // "#rrggbb" to pin the accent colour; empty = follow the cover
	keys:     map[string][]string,  // action name -> keys, e.g. "next": ["n", "ctrl+n"]
}

default_settings :: proc() -> Settings {
	return {volume = 70, scrobble = true, mpris = true, theme = "abyss"}
}

settings_path :: proc() -> (path: string, ok: bool) {
	dir, err := os.user_config_dir(context.allocator)
	if err != nil { return "", false }
	defer delete(dir)
	joined, jerr := filepath.join({dir, "tendril", "config.json"})
	return joined, jerr == nil
}

// Loads settings, allocating strings with `allocator` (give it an arena and free
// that when done). `ok` is false if the file exists but could not be parsed; the
// defaults are returned in that case.
load_settings_from :: proc(path: string, allocator := context.allocator) -> (s: Settings, ok: bool) {
	s = default_settings()
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return s, true } // no file is fine
	if json.unmarshal(data, &s, allocator = allocator) != nil {
		return default_settings(), false
	}
	s.volume = clamp(s.volume, 0, 100)
	return s, true
}

load_settings :: proc(allocator := context.allocator) -> (Settings, bool) {
	path, ok := settings_path()
	if !ok { return default_settings(), true }
	defer delete(path)
	return load_settings_from(path, allocator)
}
