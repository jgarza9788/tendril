package tests

import "core:fmt"
import "core:testing"
import "../src/player"

mk :: proc(n: int) -> []player.Track {
	ts := make([]player.Track, n)
	for i in 0 ..< n { ts[i] = {id = "x", title = "t"}; ts[i].length = f64(i) }
	return ts
}

@(test)
queue_next_prev :: proc(t: ^testing.T) {
	q: player.Queue
	player.queue_init(&q)
	defer player.queue_destroy(&q)
	ts := mk(3); defer delete(ts)
	player.queue_set(&q, ts)
	cur, _ := player.queue_current(&q)
	testing.expect_value(t, cur.length, 0)
	testing.expect(t, player.queue_next(&q))
	testing.expect(t, player.queue_next(&q))
	testing.expect(t, !player.queue_next(&q), "end of queue stops with repeat off")
	testing.expect(t, player.queue_prev(&q))
	cur, _ = player.queue_current(&q)
	testing.expect_value(t, cur.length, 1)
}

@(test)
queue_repeat :: proc(t: ^testing.T) {
	q: player.Queue
	player.queue_init(&q)
	defer player.queue_destroy(&q)
	ts := mk(2); defer delete(ts)
	player.queue_set(&q, ts)
	q.repeat = .One
	testing.expect(t, player.queue_next(&q, auto = true))
	testing.expect_value(t, q.pos, 0) // repeat-one replays on natural end
	testing.expect(t, player.queue_next(&q, auto = false))
	testing.expect_value(t, q.pos, 1) // but a manual skip moves on
	q.repeat = .All
	testing.expect(t, player.queue_next(&q))
	testing.expect_value(t, q.pos, 0) // wraps
	testing.expect(t, player.queue_prev(&q))
	testing.expect_value(t, q.pos, 1) // wraps backwards
}

@(test)
queue_shuffle_keeps_current_and_covers_all :: proc(t: ^testing.T) {
	q: player.Queue
	player.queue_init(&q)
	defer player.queue_destroy(&q)
	ts := mk(20); defer delete(ts)
	player.queue_set(&q, ts, 7)
	player.queue_toggle_shuffle(&q)
	cur, _ := player.queue_current(&q)
	testing.expect_value(t, cur.length, 7) // current track is unchanged
	seen: [20]bool
	for i in q.order { seen[i] = true }
	for s in seen { testing.expect(t, s, "every track appears exactly once") }
	testing.expect_value(t, len(q.order), 20)
	player.queue_toggle_shuffle(&q)
	cur, _ = player.queue_current(&q)
	testing.expect_value(t, cur.length, 7) // still on it after un-shuffling
	testing.expect_value(t, q.pos, 7)
}

@(test)
mpv_property_events :: proc(t: ^testing.T) {
	s: player.State
	player.handle_line(&s, `{"event":"property-change","id":1,"name":"time-pos","data":12.5}`)
	player.handle_line(&s, `{"event":"property-change","id":2,"name":"duration","data":213}`)
	player.handle_line(&s, `{"event":"property-change","id":3,"name":"pause","data":true}`)
	player.handle_line(&s, `{"event":"property-change","id":3,"name":"time-pos"}`) // no data: ignored
	testing.expect_value(t, s.position, 12.5)
	testing.expect_value(t, s.duration, 213)
	testing.expect(t, s.paused)
	player.handle_line(&s, `{"event":"end-file","reason":"eof"}`)
	testing.expect(t, s.ended)
	testing.expect_value(t, s.position, 0)
	player.handle_line(&s, `{"event":"end-file","reason":"error"}`)
	testing.expect(t, s.failed)
	player.handle_line(&s, `not json`) // must not crash
}

@(test)
mpv_encode_command :: proc(t: ^testing.T) {
	got := player.encode_command("loadfile", `http://h/a"b?x=1`, "replace")
	defer delete(got)
	testing.expect_value(t, got, "{\"command\":[\"loadfile\",\"http://h/a\\\"b?x=1\",\"replace\"]}\n")
	got2 := player.encode_command("set_property", "pause", true)
	defer delete(got2)
	testing.expect_value(t, got2, "{\"command\":[\"set_property\",\"pause\",true]}\n")
	got3 := player.encode_command("observe_property", 1, "time-pos")
	defer delete(got3)
	testing.expect_value(t, got3, "{\"command\":[\"observe_property\",1,\"time-pos\"]}\n")
}

@(test)
mpv_encode_header_list :: proc(t: ^testing.T) {
	got := player.encode_command("set_property", "http-header-fields", []string{`Authorization: MediaBrowser Token="x"`})
	defer delete(got)
	testing.expect_value(t, got, "{\"command\":[\"set_property\",\"http-header-fields\",[\"Authorization: MediaBrowser Token=\\\"x\\\"\"]]}\n")
}

// The queue copies what it is given: changing or freeing the originals afterwards
// must not affect it. (Leak tracking in the test runner also proves queue_destroy
// frees every copy.)
@(test)
queue_owns_its_strings :: proc(t: ^testing.T) {
	q: player.Queue
	player.queue_init(&q)
	defer player.queue_destroy(&q)

	title := make([]u8, 5)
	copy(title, "Hello")
	player.queue_add(&q, {{server_id = "s", id = "i", title = string(title), artist = "a"}})
	title[0] = 'J' // mutate the caller's buffer
	delete(title)  // and free it

	cur, ok := player.queue_current(&q)
	testing.expect(t, ok)
	testing.expect_value(t, cur.title, "Hello")
	player.queue_clear(&q) // frees the copies; the destroy above must not double free
	player.queue_add(&q, {{server_id = "s", id = "j", title = "again"}})
	cur, _ = player.queue_current(&q)
	testing.expect_value(t, cur.title, "again")
}

mk_named :: proc(n: int) -> [dynamic]player.Track {
	ts: [dynamic]player.Track
	for i in 0 ..< n { append(&ts, player.Track{server_id = "s", id = "x", title = fmt.tprintf("t%d", i), length = f64(i)}) }
	return ts
}

title_at :: proc(q: ^player.Queue, p: int) -> string { return q.tracks[q.order[p]].title }

@(test)
queue_remove_keeps_the_current_track :: proc(t: ^testing.T) {
	q: player.Queue
	player.queue_init(&q)
	defer player.queue_destroy(&q)
	ts := mk_named(5); defer delete(ts)
	player.queue_set(&q, ts[:], 2) // playing t2

	testing.expect(t, !player.queue_remove(&q, 0)) // remove something before it
	testing.expect_value(t, q.pos, 1)
	testing.expect_value(t, title_at(&q, q.pos), "t2")
	testing.expect(t, !player.queue_remove(&q, 3)) // and something after it
	testing.expect_value(t, title_at(&q, q.pos), "t2")
	testing.expect(t, player.queue_remove(&q, q.pos), "removing the playing track says so")
	testing.expect_value(t, title_at(&q, q.pos), "t3") // pos now points at the one that followed
	testing.expect_value(t, len(q.tracks), 2)
}

@(test)
queue_remove_last_and_empty :: proc(t: ^testing.T) {
	q: player.Queue
	player.queue_init(&q)
	defer player.queue_destroy(&q)
	ts := mk_named(2); defer delete(ts)
	player.queue_set(&q, ts[:], 1)
	testing.expect(t, player.queue_remove(&q, 1))
	testing.expect_value(t, q.pos, 0) // fell back to the new last track
	testing.expect(t, player.queue_remove(&q, 0))
	testing.expect_value(t, q.pos, -1)
	testing.expect_value(t, len(q.order), 0)
}

@(test)
queue_move_follows_the_current_track :: proc(t: ^testing.T) {
	q: player.Queue
	player.queue_init(&q)
	defer player.queue_destroy(&q)
	ts := mk_named(4); defer delete(ts)
	player.queue_set(&q, ts[:], 1) // playing t1
	testing.expect_value(t, player.queue_move(&q, 1, 1), 2) // move the playing track down
	testing.expect_value(t, title_at(&q, q.pos), "t1")
	testing.expect_value(t, player.queue_move(&q, 0, 1), 1) // move t0 past it: current slides up
	testing.expect_value(t, title_at(&q, q.pos), "t1")
	testing.expect_value(t, player.queue_move(&q, 0, -1), 0) // can't move above the top
	testing.expect_value(t, player.queue_move(&q, 3, 1), 3) // or below the bottom
}

@(test)
queue_insert_next_goes_after_current_in_order :: proc(t: ^testing.T) {
	q: player.Queue
	player.queue_init(&q)
	defer player.queue_destroy(&q)
	ts := mk_named(3); defer delete(ts)
	player.queue_set(&q, ts[:], 0)
	extra: [2]player.Track = {{server_id = "s", id = "a", title = "A"}, {server_id = "s", id = "b", title = "B"}}
	player.queue_insert_next(&q, extra[:])
	order := [5]string{title_at(&q, 0), title_at(&q, 1), title_at(&q, 2), title_at(&q, 3), title_at(&q, 4)}
	testing.expect_value(t, order, [5]string{"t0", "A", "B", "t1", "t2"})
	testing.expect_value(t, q.pos, 0)
}

@(test)
queue_peek_next_only_when_known :: proc(t: ^testing.T) {
	q: player.Queue
	player.queue_init(&q)
	defer player.queue_destroy(&q)
	ts := mk_named(3); defer delete(ts)
	player.queue_set(&q, ts[:], 0)
	pos, ok := player.queue_peek_next(&q)
	testing.expect(t, ok)
	testing.expect_value(t, pos, 1)
	q.repeat = .One
	_, ok = player.queue_peek_next(&q)
	testing.expect(t, !ok, "repeat one replays the same track: nothing to preload")
	q.repeat = .Off
	q.pos = 2
	_, ok = player.queue_peek_next(&q)
	testing.expect(t, !ok, "end of the queue")
}

@(test)
queue_restore_validates_the_order :: proc(t: ^testing.T) {
	q: player.Queue
	player.queue_init(&q)
	defer player.queue_destroy(&q)
	ts := mk_named(3); defer delete(ts)
	player.queue_restore(&q, ts[:], {2, 0, 1}, 1, true, .All)
	testing.expect_value(t, title_at(&q, 0), "t2")
	testing.expect_value(t, q.pos, 1)
	testing.expect(t, q.shuffle)
	testing.expect_value(t, q.repeat, player.Repeat.All)
	player.queue_restore(&q, ts[:], {0, 0, 1}, 99, false, .Off) // not a permutation, pos out of range
	testing.expect_value(t, title_at(&q, 0), "t0")
	testing.expect_value(t, q.pos, 2)
}
