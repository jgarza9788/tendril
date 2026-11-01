package tests

import "core:fmt"
import "core:os"
import "core:testing"
import "../src/player"
import "../src/session"

@(test)
session_round_trip :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/tendril-test-%d-sess", os.get_pid())
	path := fmt.tprintf("%s/session.json", dir)
	defer { os.remove(path); os.remove(dir) }

	q: player.Queue
	player.queue_init(&q)
	defer player.queue_destroy(&q)
	ts := mk_named(4); defer delete(ts)
	ts[1].title = `has "quotes" and \ slashes`
	ts[1].favorite = true
	player.queue_set(&q, ts[:], 2)
	player.queue_toggle_shuffle(&q)
	q.repeat = .All

	snap := session.snapshot(&q, 83.5, 42)
	testing.expect(t, session.save_to(snap, path))

	loaded, ok := session.load_from(path)
	testing.expect(t, ok)
	defer session.destroy(loaded)
	testing.expect_value(t, len(loaded.tracks), 4)
	testing.expect_value(t, loaded.position, 83.5)
	testing.expect_value(t, loaded.volume, 42)
	testing.expect_value(t, loaded.tracks[1].title, `has "quotes" and \ slashes`)
	testing.expect(t, loaded.tracks[1].favorite)

	q2: player.Queue
	player.queue_init(&q2)
	defer player.queue_destroy(&q2)
	session.restore(&q2, loaded)
	testing.expect_value(t, len(q2.tracks), 4)
	testing.expect(t, q2.shuffle)
	testing.expect_value(t, q2.repeat, player.Repeat.All)
	cur1, _ := player.queue_current(&q)
	cur2, _ := player.queue_current(&q2)
	testing.expect_value(t, cur2.title, cur1.title) // resumes on the same track
}

@(test)
session_missing_or_corrupt_is_not_an_error :: proc(t: ^testing.T) {
	_, ok := session.load_from("/tmp/tendril-no-such-session.json")
	testing.expect(t, !ok)
	path := fmt.tprintf("/tmp/tendril-test-%d-bad.json", os.get_pid())
	defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, "{ nope") == nil)
	_, ok = session.load_from(path)
	testing.expect(t, !ok)
}
