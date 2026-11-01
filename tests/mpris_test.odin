package tests

import "core:testing"
import "../src/mpris"

@(test)
dbus_strings_and_alignment :: proc(t: ^testing.T) {
	w: mpris.Writer
	defer delete(w.b)
	mpris.w_u8(&w, 7)
	mpris.w_str(&w, "hi") // u32 length is aligned to 4: 3 bytes of padding first
	testing.expect_value(t, len(w.b), 1 + 3 + 4 + 3)
	testing.expect_value(t, w.b[4], 2)
	testing.expect_value(t, w.b[8], 'h')
	testing.expect_value(t, w.b[10], 0) // the nul

	mpris.w_i64(&w, 1) // 8-byte values align to 8
	testing.expect_value(t, len(w.b) % 8, 0)
}

@(test)
dbus_arrays_exclude_their_padding_from_the_length :: proc(t: ^testing.T) {
	w: mpris.Writer
	defer delete(w.b)
	mpris.w_u8(&w, 1)
	m := mpris.w_array_begin(&w, 8) // dict entries: 8-aligned, so 4 bytes of padding after the count
	mpris.w_str(&w, "x")
	mpris.w_array_end(&w, m)
	// layout: [1][pad x3][len u32][pad x4][u32 len 1]["x" 0]
	testing.expect_value(t, w.b[4], 6) // length = the 4-byte string length + "x" + nul, not the padding
	testing.expect_value(t, m.start % 8, 0)
}

@(test)
dbus_messages_round_trip :: proc(t: ^testing.T) {
	body: mpris.Writer
	defer delete(body.b)
	mpris.w_str(&body, "org.mpris.MediaPlayer2.Player")
	mpris.w_str(&body, "Volume")

	data := mpris.encode({
		type = .Method_Call, serial = 42, destination = "org.mpris.MediaPlayer2.tendril",
		path = "/org/mpris/MediaPlayer2", interface = "org.freedesktop.DBus.Properties",
		member = "Get", signature = "ss", body = body.b[:],
	})
	defer delete(data)
	testing.expect_value(t, mpris.message_size(data), len(data))
	testing.expect_value(t, (len(data) - len(body.b)) % 8, 0) // the body starts on an 8-byte boundary

	m, ok := mpris.decode(data)
	testing.expect(t, ok)
	testing.expect_value(t, m.type, mpris.Msg_Type.Method_Call)
	testing.expect_value(t, m.serial, 42)
	testing.expect_value(t, m.path, "/org/mpris/MediaPlayer2")
	testing.expect_value(t, m.interface, "org.freedesktop.DBus.Properties")
	testing.expect_value(t, m.member, "Get")
	testing.expect_value(t, m.destination, "org.mpris.MediaPlayer2.tendril")
	testing.expect_value(t, m.signature, "ss")
	rd := mpris.Reader{data = m.body}
	testing.expect_value(t, mpris.r_str(&rd), "org.mpris.MediaPlayer2.Player")
	testing.expect_value(t, mpris.r_str(&rd), "Volume")
	testing.expect(t, !rd.bad)
}

@(test)
dbus_replies_carry_the_reply_serial :: proc(t: ^testing.T) {
	data := mpris.encode({type = .Method_Return, serial = 5, reply_serial = 42, destination = ":1.7"})
	defer delete(data)
	m, ok := mpris.decode(data)
	testing.expect(t, ok)
	testing.expect_value(t, m.reply_serial, 42)
	testing.expect_value(t, m.destination, ":1.7")
	testing.expect_value(t, len(m.body), 0)
}

@(test)
dbus_partial_and_garbage_input :: proc(t: ^testing.T) {
	data := mpris.encode({type = .Signal, serial = 1, path = "/a", interface = "a.b", member = "C"})
	defer delete(data)
	testing.expect_value(t, mpris.message_size(data[:10]), 0)            // not enough yet
	testing.expect_value(t, mpris.message_size(data[:len(data) - 1]), 0) // one byte short
	garbage := []u8{'B', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	testing.expect_value(t, mpris.message_size(garbage), -1)
	_, ok := mpris.decode(garbage)
	testing.expect(t, !ok)
	// a stream with two messages back to back splits correctly
	two := make([dynamic]u8)
	defer delete(two)
	append(&two, ..data)
	append(&two, ..data)
	testing.expect_value(t, mpris.message_size(two[:]), len(data))
}

@(test)
mpris_properties_are_encoded_as_variants :: proc(t: ^testing.T) {
	sn := mpris.Snapshot{status = "Playing", title = "Song", artist = "Band", album = "LP", track_id = "/org/tendril/track/a1",
		loop = "None", length_us = 215_000_000, position_us = 3_000_000, volume = 0.5, can_next = true, can_play = true}
	w: mpris.Writer
	defer delete(w.b)
	testing.expect(t, mpris.write_variant(&w, mpris.IFACE_PLAYER, "PlaybackStatus", sn))
	rd := mpris.Reader{data = w.b[:]}
	testing.expect_value(t, mpris.r_sig(&rd), "s")
	testing.expect_value(t, mpris.r_str(&rd), "Playing")

	clear(&w.b)
	testing.expect(t, mpris.write_variant(&w, mpris.IFACE_PLAYER, "Position", sn))
	rd = mpris.Reader{data = w.b[:]}
	testing.expect_value(t, mpris.r_sig(&rd), "x")
	testing.expect_value(t, mpris.r_i64(&rd), 3_000_000)

	clear(&w.b)
	testing.expect(t, mpris.write_variant(&w, mpris.IFACE_PLAYER, "Metadata", sn))
	rd = mpris.Reader{data = w.b[:]}
	testing.expect_value(t, mpris.r_sig(&rd), "a{sv}")
	n := int(mpris.r_u32(&rd))
	testing.expect(t, n > 0)

	clear(&w.b)
	testing.expect(t, !mpris.write_variant(&w, mpris.IFACE_PLAYER, "NoSuchThing", sn))
	testing.expect(t, !mpris.write_variant(&w, "no.such.Interface", "Volume", sn))
}
