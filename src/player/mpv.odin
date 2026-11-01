package player

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"

// State mirrored from mpv through observed properties.
State :: struct {
	position: f64,
	duration: f64,
	paused:   bool,
	idle:     bool, // nothing loaded
	volume:   f64, // 0..100
	ended:    bool, // set when a track finished by itself; consumer clears it
	failed:   bool, // set when a load failed; consumer clears it
}

Player :: struct {
	proc_:  os.Process,
	sock:   linux.Fd,
	path:   string,
	buf:    [dynamic]u8,
	state:  State,
	alive:  bool,
}

Error :: enum { None, Not_Installed, Spawn_Failed, Connect_Failed }

socket_path :: proc(allocator := context.allocator) -> string {
	if dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator); dir != "" {
		return fmt.aprintf("%s/tendril-mpv-%d.sock", dir, os.get_pid(), allocator = allocator)
	}
	return fmt.aprintf("/tmp/tendril-mpv-%d.sock", os.get_pid(), allocator = allocator)
}

// Removes sockets left behind by tendril runs that crashed or were killed.
remove_stale_sockets :: proc() {
	dir := "/tmp"
	if d := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator); d != "" { dir = d }
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for fi in infos {
		name := fi.name
		if !strings.has_prefix(name, "tendril-mpv-") || !strings.has_suffix(name, ".sock") { continue }
		pid_str := name[len("tendril-mpv-"):len(name) - len(".sock")]
		pid, ok := strconv.parse_int(pid_str)
		if !ok || pid == os.get_pid() { continue }
		if !os.exists(fmt.tprintf("/proc/%d", pid)) { os.remove(fi.fullpath) }
	}
}

// Starts a headless mpv and connects to its IPC socket.
start :: proc(p: ^Player, volume := 70, ao := "") -> Error {
	remove_stale_sockets()
	p.path = socket_path()
	args := []string{
		"mpv", "--idle=yes", "--no-video", "--no-terminal", "--force-window=no",
		"--audio-display=no", "--really-quiet", "--gapless-audio=yes", "--replaygain=track", "--audio-client-name=tendril",
		fmt.tprintf("--input-ipc-server=%s", p.path),
		fmt.tprintf("--volume=%d", volume),
	}
	if ao != "" {
		args = {"mpv", "--idle=yes", "--no-video", "--no-terminal", "--force-window=no", "--really-quiet",
			fmt.tprintf("--ao=%s", ao), fmt.tprintf("--input-ipc-server=%s", p.path), fmt.tprintf("--volume=%d", volume)}
	}
	proc_, err := os.process_start({command = args})
	if err != nil {
		return err == os.General_Error.Not_Exist ? .Not_Installed : .Spawn_Failed
	}
	p.proc_ = proc_

	// mpv creates the socket a moment after it starts.
	deadline := time.tick_add(time.tick_now(), 3 * time.Second)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if connect(p) { break }
		time.sleep(25 * time.Millisecond)
	}
	if !p.alive {
		stop(p)
		return .Connect_Failed
	}
	p.state.volume = f64(volume)
	p.state.idle = true
	for name, id in ([]string{"time-pos", "duration", "pause", "idle-active", "volume"}) {
		send(p, "observe_property", id + 1, name)
	}
	return .None
}

@(private)
connect :: proc(p: ^Player) -> bool {
	fd, err := linux.socket(.UNIX, .STREAM, {.NONBLOCK, .CLOEXEC}, {})
	if err != .NONE { return false }
	addr := linux.Sock_Addr_Un{sun_family = .UNIX}
	if len(p.path) >= len(addr.sun_path) { linux.close(fd); return false }
	copy(addr.sun_path[:], p.path)
	if linux.connect(fd, &addr) != .NONE {
		linux.close(fd)
		return false
	}
	p.sock = fd
	p.alive = true
	return true
}

stop :: proc(p: ^Player) {
	if p.alive {
		send(p, "quit")
		linux.close(p.sock)
		p.alive = false
	}
	if p.proc_.pid != 0 {
		_ = os.process_kill(p.proc_)
		_, _ = os.process_wait(p.proc_)
		p.proc_ = {}
	}
	if p.path != "" {
		os.remove(p.path)
		delete(p.path)
		p.path = ""
	}
	delete(p.buf)
}

// Sends `{"command":[args...]}`. Strings are escaped, ints/floats/bools pass through.
send :: proc(p: ^Player, args: ..any) {
	if !p.alive { return }
	line := encode_command(..args)
	defer delete(line)
	data := transmute([]u8)line
	for len(data) > 0 {
		n, err := linux.write(p.sock, data)
		if err == .EAGAIN { time.sleep(time.Millisecond); continue }
		if err != .NONE { p.alive = false; return }
		data = data[n:]
	}
}

encode_command :: proc(args: ..any, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"command":[`)
	for a, i in args {
		if i > 0 { strings.write_byte(&b, ',') }
		switch v in a {
		case string:  write_json_string(&b, v)
		case []string:
			strings.write_byte(&b, '[')
			for e, j in v {
				if j > 0 { strings.write_byte(&b, ',') }
				write_json_string(&b, e)
			}
			strings.write_byte(&b, ']')
		case int:     fmt.sbprintf(&b, "%d", v)
		case f64:     fmt.sbprintf(&b, "%v", v)
		case bool:    strings.write_string(&b, v ? "true" : "false")
		case:         strings.write_string(&b, "null")
		}
	}
	strings.write_string(&b, "]}\n")
	return strings.to_string(b)
}

@(private)
write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for c in s {
		switch c {
		case '"':  strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case '\t': strings.write_string(b, `\t`)
		case:
			if c < 0x20 { fmt.sbprintf(b, "\\u%04x", int(c)) } else { strings.write_rune(b, c) }
		}
	}
	strings.write_byte(b, '"')
}

// Reads whatever mpv has sent and updates `state`. Never blocks.
pump :: proc(p: ^Player) {
	if !p.alive { return }
	tmp: [4096]u8
	for {
		n, err := linux.read(p.sock, tmp[:])
		if err == .EAGAIN { break }
		if err != .NONE || n == 0 { p.alive = false; break }
		append(&p.buf, ..tmp[:n])
		if n < len(tmp) { break }
	}
	for {
		nl := -1
		for c, i in p.buf { if c == '\n' { nl = i; break } }
		if nl < 0 { break }
		handle_line(&p.state, string(p.buf[:nl]))
		remove_range(&p.buf, 0, nl + 1)
	}
	if p.alive && !process_running(p) { p.alive = false }
}

@(private)
process_running :: proc(p: ^Player) -> bool {
	st, err := os.process_wait(p.proc_, 0)
	if err == os.General_Error.Timeout { return true }
	return err == nil && !st.exited
}

// Applies one line of mpv's JSON output to `s`. Split out so it can be tested.
handle_line :: proc(s: ^State, line: string) {
	val, err := json.parse(transmute([]u8)line, allocator = context.temp_allocator)
	if err != nil { return }
	obj, is_obj := val.(json.Object)
	if !is_obj { return }
	ev, _ := obj["event"].(json.String)
	switch ev {
	case "property-change":
		name, _ := obj["name"].(json.String)
		data := obj["data"]
		switch name {
		case "time-pos":    if f, ok := num(data); ok { s.position = f }
		case "duration":    if f, ok := num(data); ok { s.duration = f }
		case "volume":      if f, ok := num(data); ok { s.volume = f }
		case "pause":       if b, ok := data.(json.Boolean); ok { s.paused = b }
		case "idle-active": if b, ok := data.(json.Boolean); ok { s.idle = b }
		}
	case "end-file":
		reason, _ := obj["reason"].(json.String)
		switch reason {
		case "eof":   s.ended = true
		case "error": s.failed = true
		}
		s.position = 0
	}
}

@(private)
num :: proc(v: json.Value) -> (f64, bool) {
	#partial switch x in v {
	case json.Float:   return f64(x), true
	case json.Integer: return f64(x), true
	}
	return 0, false
}

// --- Commands -------------------------------------------------------------

// Opens `url`. `auth` (if any) is sent as the Authorization header of every request
// mpv makes for it, so credentials never have to live in the URL. `start` resumes
// part-way into the track.
load :: proc(p: ^Player, url: string, auth := "", start := 0.0) {
	hdr := auth != "" ? []string{fmt.tprintf("Authorization: %s", auth)} : []string{}
	send(p, "set_property", "http-header-fields", hdr)
	if start > 1 {
		send(p, "loadfile", url, "replace", -1, fmt.tprintf("start=%.2f", start))
	} else {
		send(p, "loadfile", url, "replace")
	}
	p.state.paused = false
	p.state.position = start
}

// Queues `url` to play right after the current file, with no gap.
preload :: proc(p: ^Player, url: string) { send(p, "loadfile", url, "append") }

// Drops anything queued after the current file.
preload_clear :: proc(p: ^Player) { send(p, "playlist-clear") }

set_paused :: proc(p: ^Player, paused: bool) { send(p, "set_property", "pause", paused) }
toggle     :: proc(p: ^Player) { set_paused(p, !p.state.paused) }
seek_by    :: proc(p: ^Player, seconds: f64) { send(p, "seek", seconds, "relative") }
seek_to    :: proc(p: ^Player, seconds: f64) { send(p, "seek", seconds, "absolute") }
set_volume :: proc(p: ^Player, v: f64) { send(p, "set_property", "volume", clamp(v, 0, 100)) }
halt       :: proc(p: ^Player) { send(p, "stop") }
