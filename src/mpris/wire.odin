// The little bit of the D-Bus wire format that MPRIS needs: little-endian
// marshalling with the format's alignment rules, and a message parser.
package mpris

import "core:strings"

// --- writing ----------------------------------------------------------------------

Writer :: struct { b: [dynamic]u8 }

w_align :: proc(w: ^Writer, n: int) {
	for len(w.b) % n != 0 { append(&w.b, 0) }
}

w_u8 :: proc(w: ^Writer, v: u8) { append(&w.b, v) }

w_u32 :: proc(w: ^Writer, v: u32) {
	w_align(w, 4)
	append(&w.b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

w_u64 :: proc(w: ^Writer, v: u64) {
	w_align(w, 8)
	for i in 0 ..< 8 { append(&w.b, u8(v >> (uint(i) * 8))) }
}

w_i64 :: proc(w: ^Writer, v: i64) { w_u64(w, u64(v)) }
w_f64 :: proc(w: ^Writer, v: f64) { w_u64(w, transmute(u64)v) }
w_bool :: proc(w: ^Writer, v: bool) { w_u32(w, v ? 1 : 0) }

// A string or object path: u32 length, the bytes, a nul.
w_str :: proc(w: ^Writer, s: string) {
	w_u32(w, u32(len(s)))
	append(&w.b, ..transmute([]u8)s)
	append(&w.b, 0)
}

// A signature: u8 length, the bytes, a nul.
w_sig :: proc(w: ^Writer, s: string) {
	append(&w.b, u8(len(s)))
	append(&w.b, ..transmute([]u8)s)
	append(&w.b, 0)
}

// Arrays are a u32 byte count followed by the elements, which start aligned to
// their own alignment (the count does not include that padding).
Array_Mark :: struct { len_at, start: int }

w_array_begin :: proc(w: ^Writer, elem_align: int) -> Array_Mark {
	w_align(w, 4)
	at := len(w.b)
	append(&w.b, 0, 0, 0, 0)
	w_align(w, elem_align)
	return {at, len(w.b)}
}

w_array_end :: proc(w: ^Writer, m: Array_Mark) {
	n := u32(len(w.b) - m.start)
	w.b[m.len_at], w.b[m.len_at + 1], w.b[m.len_at + 2], w.b[m.len_at + 3] = u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24)
}

// --- reading ----------------------------------------------------------------------

Reader :: struct {
	data: []u8,
	off:  int,
	bad:  bool, // ran off the end
}

r_align :: proc(r: ^Reader, n: int) {
	for r.off % n != 0 { r.off += 1 }
}

r_u8 :: proc(r: ^Reader) -> u8 {
	if r.off + 1 > len(r.data) { r.bad = true; return 0 }
	v := r.data[r.off]
	r.off += 1
	return v
}

r_u32 :: proc(r: ^Reader) -> u32 {
	r_align(r, 4)
	if r.off + 4 > len(r.data) { r.bad = true; return 0 }
	d := r.data[r.off:]
	r.off += 4
	return u32(d[0]) | u32(d[1]) << 8 | u32(d[2]) << 16 | u32(d[3]) << 24
}

r_i64 :: proc(r: ^Reader) -> i64 {
	r_align(r, 8)
	if r.off + 8 > len(r.data) { r.bad = true; return 0 }
	v: u64
	for i in 0 ..< 8 { v |= u64(r.data[r.off + i]) << (uint(i) * 8) }
	r.off += 8
	return i64(v)
}

// Returns a view into the message; clone it if it must outlive the buffer.
r_str :: proc(r: ^Reader) -> string {
	n := int(r_u32(r))
	if r.bad || r.off + n + 1 > len(r.data) { r.bad = true; return "" }
	s := string(r.data[r.off:r.off + n])
	r.off += n + 1
	return s
}

r_sig :: proc(r: ^Reader) -> string {
	n := int(r_u8(r))
	if r.bad || r.off + n + 1 > len(r.data) { r.bad = true; return "" }
	s := string(r.data[r.off:r.off + n])
	r.off += n + 1
	return s
}

// --- messages ---------------------------------------------------------------------

Msg_Type :: enum u8 { Invalid, Method_Call, Method_Return, Error, Signal }

// Header field codes.
F_PATH :: 1
F_INTERFACE :: 2
F_MEMBER :: 3
F_ERROR_NAME :: 4
F_REPLY_SERIAL :: 5
F_DESTINATION :: 6
F_SENDER :: 7
F_SIGNATURE :: 8

Message :: struct {
	type:         Msg_Type,
	flags:        u8,
	serial:       u32,
	reply_serial: u32,
	path, interface, member, error_name, destination, sender, signature: string,
	body:         []u8,
}

// What a message to be sent looks like.
Out :: struct {
	type:         Msg_Type,
	flags:        u8,
	serial:       u32,
	reply_serial: u32,
	path, interface, member, error_name, destination, signature: string,
	body:         []u8,
}

// Serialises a message (little-endian, protocol version 1).
encode :: proc(o: Out, allocator := context.allocator) -> []u8 {
	f: Writer
	f.b.allocator = context.temp_allocator
	field :: proc(f: ^Writer, code: u8, sig: string, s: string, u: u32 = 0) {
		w_align(f, 8)
		w_u8(f, code)
		w_sig(f, sig)
		switch sig {
		case "o", "s": w_str(f, s)
		case "g":      w_sig(f, s)
		case "u":      w_u32(f, u)
		}
	}
	if o.path != ""         { field(&f, F_PATH, "o", o.path) }
	if o.interface != ""    { field(&f, F_INTERFACE, "s", o.interface) }
	if o.member != ""       { field(&f, F_MEMBER, "s", o.member) }
	if o.error_name != ""   { field(&f, F_ERROR_NAME, "s", o.error_name) }
	if o.reply_serial != 0  { field(&f, F_REPLY_SERIAL, "u", "", o.reply_serial) }
	if o.destination != ""  { field(&f, F_DESTINATION, "s", o.destination) }
	if o.signature != ""    { field(&f, F_SIGNATURE, "g", o.signature) }

	m: Writer
	m.b.allocator = allocator
	w_u8(&m, 'l')
	w_u8(&m, u8(o.type))
	w_u8(&m, o.flags)
	w_u8(&m, 1)
	w_u32(&m, u32(len(o.body)))
	w_u32(&m, o.serial)
	w_u32(&m, u32(len(f.b)))
	append(&m.b, ..f.b[:])
	w_align(&m, 8)
	append(&m.b, ..o.body)
	return m.b[:]
}

// How many bytes the first message in `data` occupies, or 0 if it is incomplete.
// -1 means the data is not a valid message stream.
message_size :: proc(data: []u8) -> int {
	if len(data) < 16 { return 0 }
	if data[0] != 'l' { return -1 } // big-endian peers are not supported
	rd := Reader{data = data, off = 4}
	body_len := int(r_u32(&rd))
	_ = r_u32(&rd) // serial
	fields_len := int(r_u32(&rd))
	if body_len > 1 << 24 || fields_len > 1 << 16 { return -1 }
	header := 16 + fields_len
	header = (header + 7) / 8 * 8
	total := header + body_len
	return len(data) >= total ? total : 0
}

// Parses one complete message. Strings point into `data`.
decode :: proc(data: []u8) -> (m: Message, ok: bool) {
	size := message_size(data)
	if size <= 0 { return {}, false }
	rd := Reader{data = data[:size], off = 1}
	m.type = Msg_Type(r_u8(&rd))
	m.flags = r_u8(&rd)
	_ = r_u8(&rd) // version
	body_len := int(r_u32(&rd))
	m.serial = r_u32(&rd)
	fields_len := int(r_u32(&rd))
	fields_end := rd.off + fields_len
	for rd.off < fields_end && !rd.bad {
		r_align(&rd, 8)
		code := r_u8(&rd)
		sig := r_sig(&rd)
		switch sig {
		case "o", "s":
			v := r_str(&rd)
			switch code {
			case F_PATH:        m.path = v
			case F_INTERFACE:   m.interface = v
			case F_MEMBER:      m.member = v
			case F_ERROR_NAME:  m.error_name = v
			case F_DESTINATION: m.destination = v
			case F_SENDER:      m.sender = v
			}
		case "g":
			v := r_sig(&rd)
			if code == F_SIGNATURE { m.signature = v }
		case "u":
			v := r_u32(&rd)
			if code == F_REPLY_SERIAL { m.reply_serial = v }
		case:
			return {}, false // a field type we don't know how to skip
		}
	}
	if rd.bad { return {}, false }
	rd.off = (fields_end + 7) / 8 * 8
	if rd.off + body_len > size { return {}, false }
	m.body = data[rd.off:rd.off + body_len]
	return m, true
}

_ :: strings
