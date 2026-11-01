// Remembers the queue across restarts: which tracks, their order, where you were.
package session

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "../player"

Session :: struct {
	tracks:   []player.Track,
	order:    []int,
	pos:      int,
	shuffle:  bool,
	repeat:   int,
	position: f64, // seconds into the current track
	volume:   f64,
}

default_path :: proc() -> (path: string, ok: bool) {
	base: string
	if d := os.get_env("XDG_STATE_HOME", context.temp_allocator); d != "" {
		base = d
	} else if h := os.get_env("HOME", context.temp_allocator); h != "" {
		j, err := filepath.join({h, ".local", "state"}, context.temp_allocator)
		if err != nil { return "", false }
		base = j
	} else {
		return "", false
	}
	joined, err := filepath.join({base, "tendril", "session.json"})
	return joined, err == nil
}

// Captures the queue. The result borrows the queue's strings: save it before the
// queue changes.
snapshot :: proc(q: ^player.Queue, position, volume: f64) -> Session {
	return {
		tracks = q.tracks[:], order = q.order[:], pos = q.pos, shuffle = q.shuffle,
		repeat = int(q.repeat), position = position, volume = volume,
	}
}

save_to :: proc(s: Session, path: string) -> bool {
	_ = os.make_directory_all(filepath.dir(path), {.Read_User, .Write_User, .Execute_User})
	data, err := json.marshal(s, {pretty = true}, context.temp_allocator)
	if err != nil { return false }
	return os.write_entire_file(path, data, {.Read_User, .Write_User}) == nil
}

save :: proc(s: Session) -> bool {
	path, ok := default_path()
	if !ok { return false }
	defer delete(path)
	return save_to(s, path)
}

// Loads a session. Allocates with context.allocator (free with `destroy`).
load_from :: proc(path: string) -> (s: Session, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return {}, false }
	defer delete(data)
	if json.unmarshal(data, &s) != nil {
		destroy(s)
		return {}, false
	}
	return s, true
}

load :: proc() -> (Session, bool) {
	path, ok := default_path()
	if !ok { return {}, false }
	defer delete(path)
	return load_from(path)
}

destroy :: proc(s: Session) {
	for t in s.tracks { player.track_free(t) }
	delete(s.tracks)
	delete(s.order)
}

// Puts a loaded session into `q` (the queue copies the tracks).
restore :: proc(q: ^player.Queue, s: Session) {
	rep := player.Repeat(clamp(s.repeat, 0, len(player.Repeat) - 1))
	player.queue_restore(q, s.tracks, s.order, s.pos, s.shuffle, rep)
}
