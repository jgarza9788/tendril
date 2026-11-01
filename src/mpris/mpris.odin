// MPRIS: lets the desktop's media keys, playerctl, and status-bar widgets see and
// control Tendril. It speaks just enough D-Bus over the session bus socket to own
// the name org.mpris.MediaPlayer2.tendril and answer the player interface.
package mpris

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

PATH        :: "/org/mpris/MediaPlayer2"
IFACE_ROOT  :: "org.mpris.MediaPlayer2"
IFACE_PLAYER :: "org.mpris.MediaPlayer2.Player"
IFACE_PROPS :: "org.freedesktop.DBus.Properties"
BUS_NAME    :: "org.mpris.MediaPlayer2.tendril"

// What the player looks like right now. The app fills one in every frame.
Snapshot :: struct {
	status:      string, // "Playing", "Paused" or "Stopped"
	title:       string,
	artist:      string,
	album:       string,
	track_id:    string, // a D-Bus object path, or "" when nothing is loaded
	loop:        string, // "None", "Track" or "Playlist"
	length_us:   i64,
	position_us: i64,
	volume:      f64,    // 0..1
	can_next:    bool,
	can_prev:    bool,
	can_play:    bool,
	shuffle:     bool,
}

Command_Kind :: enum { Play, Pause, Play_Pause, Stop, Next, Previous, Seek, Set_Position, Set_Volume, Set_Shuffle, Set_Loop, Quit }

Command :: struct {
	kind:  Command_Kind,
	value: i64, // Seek: offset in microseconds; Set_Position: absolute microseconds; Set_Shuffle: 0 or 1; Set_Loop: 0 none, 1 track, 2 playlist
	vol:   f64, // Set_Volume
}

Service :: struct {
	fd:        linux.Fd,
	active:    bool,
	serial:    u32,
	rbuf:      [dynamic]u8,
	name:      string,    // the bus name we ended up with (owned)
	unique:    string,    // our connection id, e.g. ":1.42" (owned)
	last:      Snapshot,  // owned strings; what we last told clients
	have_last: bool,
}

// --- connection -------------------------------------------------------------------

bus_path :: proc() -> string {
	addr := os.get_env("DBUS_SESSION_BUS_ADDRESS", context.temp_allocator)
	for part in strings.split(addr, ",", context.temp_allocator) {
		p := part
		if strings.has_prefix(p, "unix:") { p = p[5:] }
		if strings.has_prefix(p, "path=") { return p[5:] }
	}
	return fmt.tprintf("/run/user/%d/bus", linux.getuid())
}

wait_readable :: proc(s: ^Service, ms: i32) -> bool {
	fds := [1]linux.Poll_Fd{{fd = s.fd, events = {.IN}}}
	n, _ := linux.poll(fds[:], ms)
	return n > 0
}

write_all :: proc(s: ^Service, data: []u8) -> bool {
	d := data
	tries := 0
	for len(d) > 0 {
		n, err := linux.write(s.fd, d)
		if err == .EAGAIN {
			tries += 1
			if tries > 200 { return false }
			time.sleep(time.Millisecond)
			continue
		}
		if err != .NONE { s.active = false; return false }
		d = d[n:]
	}
	return true
}

send_msg :: proc(s: ^Service, o: Out) -> bool {
	o := o
	s.serial += 1
	o.serial = s.serial
	data := encode(o, context.temp_allocator)
	return write_all(s, data)
}

// Reads from the socket into the buffer. Returns false if the peer hung up.
fill :: proc(s: ^Service) -> bool {
	buf: [4096]u8
	for {
		n, err := linux.read(s.fd, buf[:])
		if err == .EAGAIN { return true }
		if err != .NONE || n == 0 { return false }
		append(&s.rbuf, ..buf[:n])
		if n < len(buf) { return true }
	}
}

// Blocks (up to `ms`) for the reply to call `serial`, dropping anything else.
wait_reply :: proc(s: ^Service, serial: u32, ms: i32) -> (body: []u8, ok: bool) {
	deadline := time.tick_add(time.tick_now(), time.Duration(ms) * time.Millisecond)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		for {
			size := message_size(s.rbuf[:])
			if size < 0 { return nil, false }
			if size == 0 { break }
			m, parsed := decode(s.rbuf[:size])
			if parsed && m.type == .Method_Return && m.reply_serial == serial {
				out := make([]u8, len(m.body), context.temp_allocator)
				copy(out, m.body)
				remove_range(&s.rbuf, 0, size)
				return out, true
			}
			if parsed && m.type == .Error && m.reply_serial == serial { return nil, false }
			remove_range(&s.rbuf, 0, size)
		}
		if wait_readable(s, 100) && !fill(s) { return nil, false }
	}
	return nil, false
}

// Connects to the session bus and claims the MPRIS name. Returns false (quietly)
// if there is no session bus or anything goes wrong; the player works without it.
start :: proc(s: ^Service) -> bool {
	fd, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, {})
	if err != .NONE { return false }
	s.fd = fd
	addr := linux.Sock_Addr_Un{sun_family = .UNIX}
	path := bus_path()
	if len(path) >= len(addr.sun_path) { linux.close(fd); return false }
	copy(addr.sun_path[:], path)
	if linux.connect(fd, &addr) != .NONE { linux.close(fd); return false }

	// SASL EXTERNAL: prove who we are with our uid, written as hex of its decimal digits.
	uid := fmt.tprintf("%d", linux.getuid())
	hex := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)uid { fmt.sbprintf(&hex, "%02x", c) }
	if !write_all(s, transmute([]u8)fmt.tprintf("\x00AUTH EXTERNAL %s\r\n", strings.to_string(hex))) { linux.close(fd); return false }
	line: [dynamic]u8
	line.allocator = context.temp_allocator
	for !strings.has_suffix(string(line[:]), "\n") && len(line) < 512 {
		if !wait_readable(s, 2000) { linux.close(fd); return false }
		b: [1]u8
		n, rerr := linux.read(fd, b[:])
		if rerr != .NONE || n == 0 { linux.close(fd); return false }
		append(&line, b[0])
	}
	if !strings.has_prefix(string(line[:]), "OK") { linux.close(fd); return false }
	if !write_all(s, transmute([]u8)string("BEGIN\r\n")) { linux.close(fd); return false }
	s.active = true

	// Hello: the bus replies with our unique name.
	if !send_msg(s, {type = .Method_Call, destination = "org.freedesktop.DBus", path = "/org/freedesktop/DBus", interface = "org.freedesktop.DBus", member = "Hello"}) { stop(s); return false }
	body, ok := wait_reply(s, s.serial, 2000)
	if !ok { stop(s); return false }
	rd := Reader{data = body}
	s.unique = strings.clone(r_str(&rd))

	// Claim the well-known name; if another Tendril already has it, use a suffixed one.
	for attempt in 0 ..< 2 {
		name := attempt == 0 ? BUS_NAME : fmt.tprintf("%s.instance%d", BUS_NAME, os.get_pid())
		w: Writer
		w.b.allocator = context.temp_allocator
		w_str(&w, name)
		w_u32(&w, 4) // DBUS_NAME_FLAG_DO_NOT_QUEUE
		if !send_msg(s, {type = .Method_Call, destination = "org.freedesktop.DBus", path = "/org/freedesktop/DBus", interface = "org.freedesktop.DBus", member = "RequestName", signature = "su", body = w.b[:]}) { stop(s); return false }
		reply, rok := wait_reply(s, s.serial, 2000)
		if !rok { stop(s); return false }
		r2 := Reader{data = reply}
		if code := r_u32(&r2); code == 1 || code == 4 {
			s.name = strings.clone(name)
			_ = linux.fcntl_setfl(s.fd, .SETFL, {.NONBLOCK})
			return true
		}
	}
	stop(s)
	return false
}

stop :: proc(s: ^Service) {
	if s.fd != 0 { linux.close(s.fd) }
	s.fd = 0
	s.active = false
	delete(s.rbuf)
	s.rbuf = nil
	delete(s.name)
	delete(s.unique)
	s.name, s.unique = "", ""
	free_snapshot(&s.last)
	s.have_last = false
}

free_snapshot :: proc(sn: ^Snapshot) {
	delete(sn.status); delete(sn.title); delete(sn.artist); delete(sn.album); delete(sn.track_id); delete(sn.loop)
	sn^ = {}
}

clone_snapshot :: proc(sn: Snapshot) -> Snapshot {
	c := sn
	c.status, c.title, c.artist, c.album = strings.clone(sn.status), strings.clone(sn.title), strings.clone(sn.artist), strings.clone(sn.album)
	c.track_id, c.loop = strings.clone(sn.track_id), strings.clone(sn.loop)
	return c
}

// --- properties -----------------------------------------------------------------------

ROOT_PROPS   := [?]string{"CanQuit", "CanRaise", "HasTrackList", "Identity", "SupportedUriSchemes", "SupportedMimeTypes"}
PLAYER_PROPS := [?]string{"PlaybackStatus", "LoopStatus", "Rate", "Shuffle", "Metadata", "Volume", "Position",
	"MinimumRate", "MaximumRate", "CanGoNext", "CanGoPrevious", "CanPlay", "CanPause", "CanSeek", "CanControl"}

NO_TRACK :: "/org/mpris/MediaPlayer2/TrackList/NoTrack"

// Writes a property's value as a D-Bus variant. False if there is no such property.
write_variant :: proc(w: ^Writer, iface, name: string, sn: Snapshot) -> bool {
	boolean :: proc(w: ^Writer, v: bool) { w_sig(w, "b"); w_bool(w, v) }
	str :: proc(w: ^Writer, v: string) { w_sig(w, "s"); w_str(w, v) }
	dbl :: proc(w: ^Writer, v: f64) { w_sig(w, "d"); w_f64(w, v) }
	empty_strings :: proc(w: ^Writer) {
		w_sig(w, "as")
		m := w_array_begin(w, 4)
		w_array_end(w, m)
	}
	switch iface {
	case IFACE_ROOT:
		switch name {
		case "CanQuit":             boolean(w, true)
		case "CanRaise":            boolean(w, false)
		case "HasTrackList":        boolean(w, false)
		case "Identity":            str(w, "Tendril")
		case "SupportedUriSchemes": empty_strings(w)
		case "SupportedMimeTypes":  empty_strings(w)
		case: return false
		}
	case IFACE_PLAYER:
		switch name {
		case "PlaybackStatus": str(w, sn.status != "" ? sn.status : "Stopped")
		case "LoopStatus":     str(w, sn.loop != "" ? sn.loop : "None")
		case "Rate", "MinimumRate", "MaximumRate": dbl(w, 1)
		case "Shuffle":        boolean(w, sn.shuffle)
		case "Volume":         dbl(w, sn.volume)
		case "Position":       w_sig(w, "x"); w_i64(w, sn.position_us)
		case "CanGoNext":      boolean(w, sn.can_next)
		case "CanGoPrevious":  boolean(w, sn.can_prev)
		case "CanPlay", "CanPause", "CanSeek": boolean(w, sn.can_play)
		case "CanControl":     boolean(w, true)
		case "Metadata":
			w_sig(w, "a{sv}")
			arr := w_array_begin(w, 8)
			entry :: proc(w: ^Writer, key: string) {
				w_align(w, 8)
				w_str(w, key)
			}
			entry(w, "mpris:trackid")
			w_sig(w, "o"); w_str(w, sn.track_id != "" ? sn.track_id : NO_TRACK)
			if sn.track_id != "" {
				entry(w, "mpris:length"); w_sig(w, "x"); w_i64(w, sn.length_us)
				entry(w, "xesam:title");  w_sig(w, "s"); w_str(w, sn.title)
				entry(w, "xesam:album");  w_sig(w, "s"); w_str(w, sn.album)
				entry(w, "xesam:artist")
				w_sig(w, "as")
				a := w_array_begin(w, 4)
				w_str(w, sn.artist)
				w_array_end(w, a)
			}
			w_array_end(w, arr)
		case: return false
		}
	case: return false
	}
	return true
}

// a{sv} of every property of an interface.
write_all_props :: proc(w: ^Writer, iface: string, sn: Snapshot) {
	names: []string
	switch iface {
	case IFACE_ROOT:   names = ROOT_PROPS[:]
	case IFACE_PLAYER: names = PLAYER_PROPS[:]
	}
	arr := w_array_begin(w, 8)
	for n in names {
		w_align(w, 8)
		w_str(w, n)
		_ = write_variant(w, iface, n, sn)
	}
	w_array_end(w, arr)
}

// --- handling calls -----------------------------------------------------------------

INTROSPECT_XML :: `<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="org.freedesktop.DBus.Introspectable"><method name="Introspect"><arg direction="out" type="s"/></method></interface>
  <interface name="org.freedesktop.DBus.Properties">
    <method name="Get"><arg direction="in" type="s"/><arg direction="in" type="s"/><arg direction="out" type="v"/></method>
    <method name="GetAll"><arg direction="in" type="s"/><arg direction="out" type="a{sv}"/></method>
    <method name="Set"><arg direction="in" type="s"/><arg direction="in" type="s"/><arg direction="in" type="v"/></method>
    <signal name="PropertiesChanged"><arg type="s"/><arg type="a{sv}"/><arg type="as"/></signal>
  </interface>
  <interface name="org.mpris.MediaPlayer2">
    <method name="Raise"/><method name="Quit"/>
    <property name="CanQuit" type="b" access="read"/><property name="CanRaise" type="b" access="read"/>
    <property name="HasTrackList" type="b" access="read"/><property name="Identity" type="s" access="read"/>
    <property name="SupportedUriSchemes" type="as" access="read"/><property name="SupportedMimeTypes" type="as" access="read"/>
  </interface>
  <interface name="org.mpris.MediaPlayer2.Player">
    <method name="Next"/><method name="Previous"/><method name="Pause"/><method name="PlayPause"/><method name="Stop"/><method name="Play"/>
    <method name="Seek"><arg direction="in" type="x"/></method>
    <method name="SetPosition"><arg direction="in" type="o"/><arg direction="in" type="x"/></method>
    <method name="OpenUri"><arg direction="in" type="s"/></method>
    <property name="PlaybackStatus" type="s" access="read"/><property name="LoopStatus" type="s" access="readwrite"/>
    <property name="Rate" type="d" access="read"/><property name="Shuffle" type="b" access="readwrite"/>
    <property name="Metadata" type="a{sv}" access="read"/><property name="Volume" type="d" access="readwrite"/>
    <property name="Position" type="x" access="read"/><property name="MinimumRate" type="d" access="read"/>
    <property name="MaximumRate" type="d" access="read"/><property name="CanGoNext" type="b" access="read"/>
    <property name="CanGoPrevious" type="b" access="read"/><property name="CanPlay" type="b" access="read"/>
    <property name="CanPause" type="b" access="read"/><property name="CanSeek" type="b" access="read"/>
    <property name="CanControl" type="b" access="read"/>
  </interface>
</node>`

reply_ok :: proc(s: ^Service, m: Message, sig := "", body: []u8 = nil) {
	if m.flags & 1 != 0 { return } // the caller doesn't want a reply
	_ = send_msg(s, {type = .Method_Return, reply_serial = m.serial, destination = m.sender, signature = sig, body = body})
}

reply_error :: proc(s: ^Service, m: Message, name, text: string) {
	if m.flags & 1 != 0 { return }
	w: Writer
	w.b.allocator = context.temp_allocator
	w_str(&w, text)
	_ = send_msg(s, {type = .Error, reply_serial = m.serial, destination = m.sender, error_name = name, signature = "s", body = w.b[:]})
}

handle_call :: proc(s: ^Service, m: Message, sn: Snapshot, cmds: ^[dynamic]Command) {
	if m.interface == "org.freedesktop.DBus.Peer" {
		if m.member == "Ping" { reply_ok(s, m) } else if m.member == "GetMachineId" {
			w: Writer; w.b.allocator = context.temp_allocator
			w_str(&w, "00000000000000000000000000000000")
			reply_ok(s, m, "s", w.b[:])
		}
		return
	}
	if m.path != PATH {
		reply_error(s, m, "org.freedesktop.DBus.Error.UnknownObject", "no such object")
		return
	}
	rd := Reader{data = m.body}
	w: Writer
	w.b.allocator = context.temp_allocator

	switch m.interface {
	case "org.freedesktop.DBus.Introspectable":
		w_str(&w, INTROSPECT_XML)
		reply_ok(s, m, "s", w.b[:])
	case IFACE_PROPS:
		switch m.member {
		case "Get":
			iface, name := r_str(&rd), r_str(&rd)
			if write_variant(&w, iface, name, sn) { reply_ok(s, m, "v", w.b[:]) } else {
				reply_error(s, m, "org.freedesktop.DBus.Error.UnknownProperty", name)
			}
		case "GetAll":
			write_all_props(&w, r_str(&rd), sn)
			reply_ok(s, m, "a{sv}", w.b[:])
		case "Set":
			iface, name := r_str(&rd), r_str(&rd)
			vsig := r_sig(&rd)
			if iface == IFACE_PLAYER && name == "Volume" && vsig == "d" {
				r_align(&rd, 8)
				if rd.off + 8 <= len(rd.data) {
					bits: u64
					for i in 0 ..< 8 { bits |= u64(rd.data[rd.off + i]) << (uint(i) * 8) }
					append(cmds, Command{kind = .Set_Volume, vol = clamp(transmute(f64)bits, 0, 1)})
				}
				reply_ok(s, m)
			} else if iface == IFACE_PLAYER && name == "Shuffle" && vsig == "b" {
				append(cmds, Command{kind = .Set_Shuffle, value = i64(r_u32(&rd))})
				reply_ok(s, m)
			} else if iface == IFACE_PLAYER && name == "LoopStatus" && vsig == "s" {
				loop := r_str(&rd)
				v: i64 = loop == "Track" ? 1 : (loop == "Playlist" ? 2 : 0)
				append(cmds, Command{kind = .Set_Loop, value = v})
				reply_ok(s, m)
			} else {
				reply_error(s, m, "org.freedesktop.DBus.Error.PropertyReadOnly", name)
			}
		case:
			reply_error(s, m, "org.freedesktop.DBus.Error.UnknownMethod", m.member)
		}
	case IFACE_ROOT:
		switch m.member {
		case "Raise": reply_ok(s, m)
		case "Quit":
			append(cmds, Command{kind = .Quit})
			reply_ok(s, m)
		case: reply_error(s, m, "org.freedesktop.DBus.Error.UnknownMethod", m.member)
		}
	case IFACE_PLAYER:
		kind: Command_Kind
		value: i64
		switch m.member {
		case "Play":      kind = .Play
		case "Pause":     kind = .Pause
		case "PlayPause": kind = .Play_Pause
		case "Stop":      kind = .Stop
		case "Next":      kind = .Next
		case "Previous":  kind = .Previous
		case "Seek":
			kind, value = .Seek, r_i64(&rd)
		case "SetPosition":
			_ = r_str(&rd) // track id
			kind, value = .Set_Position, r_i64(&rd)
		case "OpenUri":
			reply_ok(s, m)
			return
		case:
			reply_error(s, m, "org.freedesktop.DBus.Error.UnknownMethod", m.member)
			return
		}
		if !rd.bad { append(cmds, Command{kind = kind, value = value}) }
		reply_ok(s, m)
	case:
		reply_error(s, m, "org.freedesktop.DBus.Error.UnknownInterface", m.interface)
	}
}

// --- per-frame ------------------------------------------------------------------------

// Answers anything clients asked since last frame, queues the commands they sent
// into `cmds`, and tells clients when what is playing changed.
pump :: proc(s: ^Service, sn: Snapshot, cmds: ^[dynamic]Command) {
	if !s.active { return }
	if !fill(s) { s.active = false; return }
	for {
		size := message_size(s.rbuf[:])
		if size < 0 { s.active = false; return }
		if size == 0 { break }
		if m, ok := decode(s.rbuf[:size]); ok && m.type == .Method_Call {
			handle_call(s, m, sn, cmds)
		}
		remove_range(&s.rbuf, 0, size)
	}
	if s.active { announce_changes(s, sn) }
}

// Emits PropertiesChanged for whatever differs from what clients last heard.
announce_changes :: proc(s: ^Service, sn: Snapshot) {
	if !s.have_last {
		s.last = clone_snapshot(sn)
		s.have_last = true
		return
	}
	l := s.last
	changed := make([dynamic]string, context.temp_allocator)
	if l.status != sn.status { append(&changed, "PlaybackStatus") }
	if l.loop != sn.loop { append(&changed, "LoopStatus") }
	if l.shuffle != sn.shuffle { append(&changed, "Shuffle") }
	if l.track_id != sn.track_id || l.title != sn.title || l.artist != sn.artist || l.album != sn.album || l.length_us != sn.length_us {
		append(&changed, "Metadata")
	}
	if abs(l.volume - sn.volume) > 0.004 { append(&changed, "Volume") }
	if l.can_next != sn.can_next { append(&changed, "CanGoNext") }
	if l.can_prev != sn.can_prev { append(&changed, "CanGoPrevious") }
	if l.can_play != sn.can_play { append(&changed, "CanPlay") }
	if len(changed) == 0 { return }

	w: Writer
	w.b.allocator = context.temp_allocator
	w_str(&w, IFACE_PLAYER)
	arr := w_array_begin(&w, 8)
	for n in changed {
		w_align(&w, 8)
		w_str(&w, n)
		_ = write_variant(&w, IFACE_PLAYER, n, sn)
	}
	w_array_end(&w, arr)
	inv := w_array_begin(&w, 4)
	w_array_end(&w, inv)
	_ = send_msg(s, {type = .Signal, path = PATH, interface = IFACE_PROPS, member = "PropertiesChanged", signature = "sa{sv}as", body = w.b[:]})

	free_snapshot(&s.last)
	s.last = clone_snapshot(sn)
}
