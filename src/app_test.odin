package main

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"
import "../libs/hnoss/input"
import "../libs/hnoss/style"
import "jellyfin"
import "player"

// --- helpers ------------------------------------------------------------------

// An app with `n` fake servers (heap strings, so app_destroy can free them).
test_app :: proc(n: int) -> (app: App) {
	player.queue_init(&app.q)
	for i in 0 ..< n {
		append(&app.servers, jellyfin.Server{
			id = fmt.aprintf("s%d", i + 1), name = fmt.aprintf("srv%d", i + 1),
			url = fmt.aprintf("http://127.0.0.1:%d", 18000 + i), user = strings.clone("u"),
			user_id = strings.clone("uid"), token = strings.clone("tok"),
		})
		append(&app.conn, Conn.Online)
	}
	return
}

// A finished job result with one artist entry per name, backed by its own arena.
mk_result :: proc(kind: Job_Kind, server_idx, view_id: int, names: []string, start := 0, total := 0, err := jellyfin.Error.None) -> ^Result {
	r := new(Result)
	_ = virtual.arena_init_growing(&r.arena)
	r.kind, r.server_idx, r.view_id, r.start, r.total, r.err = kind, server_idx, view_id, start, total, err
	context.allocator = virtual.arena_allocator(&r.arena)
	r.entries = make([]Entry, len(names))
	for n, i in names {
		r.entries[i] = {item = {id = fmt.aprintf("id-%d-%d", server_idx, start + i), name = strings.clone(n), type = "MusicArtist"}, server = server_idx}
	}
	return r
}

paged_root :: proc(app: ^App) -> ^View {
	v := push_view(app, .Artists, "Artists")
	v.paged = true
	for _ in app.servers { append(&v.pages, Page{}) }
	return v
}

// --- paging -------------------------------------------------------------------

@(test)
paging_accounting :: proc(t: ^testing.T) {
	app := test_app(1)
	defer app_destroy(&app)
	v := paged_root(&app)
	v.pending = 1
	v.pages[0].loading = true

	names := make([]string, 200, context.temp_allocator)
	for i in 0 ..< 200 { names[i] = fmt.tprintf("Artist %03d", i) }
	post_result(mk_result(.Artists, 0, v.id, names, 0, 500))
	handle_results(&app)

	testing.expect_value(t, len(v.entries), 200)
	testing.expect_value(t, v.pages[0].next, 200)
	testing.expect_value(t, v.pages[0].total, 500)
	testing.expect(t, !v.pages[0].loading)
	testing.expect_value(t, v.pending, 0)

	testing.expect(t, !page_wanted(v, 0, 10), "cursor far from the end: no request")
	testing.expect(t, page_wanted(v, 0, 175), "cursor near the end: request the next page")
	v.pages[0].loading = true
	testing.expect(t, !page_wanted(v, 0, 175), "already loading: no duplicate request")
	v.pages[0].loading = false
	v.pages[0].failed = true
	testing.expect(t, !page_wanted(v, 0, 175), "failed: wait for R instead of looping")
	v.pages[0].failed = false
	v.pages[0].next = 500
	testing.expect(t, !page_wanted(v, 0, 195), "everything loaded: nothing more to fetch")
	loaded, total := page_totals(v)
	testing.expect_value(t, loaded, 200)
	testing.expect_value(t, total, 500)
}

@(test)
second_page_appends_at_the_right_offset :: proc(t: ^testing.T) {
	app := test_app(1)
	defer app_destroy(&app)
	v := paged_root(&app)
	v.pending = 2
	post_result(mk_result(.Artists, 0, v.id, {"A", "B"}, 0, 4))
	post_result(mk_result(.Artists, 0, v.id, {"C", "D"}, 2, 4))
	handle_results(&app)
	testing.expect_value(t, len(v.entries), 4)
	testing.expect_value(t, v.pages[0].next, 4)
	testing.expect_value(t, v.entries[3].name, "D")
}

@(test)
multi_server_merge_is_sorted_and_cursor_stays_put :: proc(t: ^testing.T) {
	app := test_app(2)
	defer app_destroy(&app)
	v := paged_root(&app)
	v.pending = 2

	post_result(mk_result(.Artists, 0, v.id, {"Bravo", "Delta"}, 0, 2))
	handle_results(&app)
	v.list.selected = 0 // on "Bravo"
	post_result(mk_result(.Artists, 1, v.id, {"alpha", "Charlie"}, 0, 2))
	handle_results(&app)

	order := [4]string{v.entries[0].name, v.entries[1].name, v.entries[2].name, v.entries[3].name}
	testing.expect_value(t, order, [4]string{"alpha", "Bravo", "Charlie", "Delta"})
	testing.expect_value(t, v.entries[v.list.selected].name, "Bravo")
}

@(test)
stale_result_is_discarded :: proc(t: ^testing.T) {
	app := test_app(1)
	defer app_destroy(&app)
	root := paged_root(&app)
	child := push_view(&app, .Tracks, "child")
	child_id := child.id
	pop_view(&app) // the user went back before the answer arrived

	post_result(mk_result(.Album_Tracks, 0, child_id, {"x"}))
	handle_results(&app)
	testing.expect_value(t, len(root.entries), 0)
	testing.expect_value(t, len(app.stack), 1)
}

@(test)
results_go_to_their_own_view :: proc(t: ^testing.T) {
	app := test_app(1)
	defer app_destroy(&app)
	root := paged_root(&app)
	child := push_view(&app, .Albums, "child")
	child.pending = 1
	post_result(mk_result(.Albums, 0, child.id, {"One", "Two"}))
	handle_results(&app)
	testing.expect_value(t, len(child.entries), 2)
	testing.expect_value(t, len(root.entries), 0)
	testing.expect_value(t, child.pending, 0)
}

@(test)
jump_to_letter_restarts_the_listing :: proc(t: ^testing.T) {
	app := test_app(0) // no servers: no network jobs are started
	defer app_destroy(&app)
	reset_root(&app)
	jump_to_letter(&app, 'k')
	v := current_view(&app)
	testing.expect_value(t, v.name_from, "K")
	testing.expect_value(t, v.title, "Artists from K")
	testing.expect_value(t, len(app.stack), 1)
}

// --- sessions and failures --------------------------------------------------------

@(test)
unauthorized_marks_session_expired_and_prompts_login :: proc(t: ^testing.T) {
	app := test_app(1)
	defer app_destroy(&app)
	v := paged_root(&app)
	v.pending = 1
	post_result(mk_result(.Artists, 0, v.id, {}, 0, 0, .Unauthorized))
	handle_results(&app)
	testing.expect_value(t, app.conn[0], Conn.Expired)
	testing.expect(t, app.dlg_open, "login dialog opens for the expired server")
	testing.expect_value(t, hnossText(&app), "http://127.0.0.1:18000")
	testing.expect(t, strings.contains(app.toast, "expired"))
}

@(test)
network_error_marks_server_failed :: proc(t: ^testing.T) {
	app := test_app(1)
	defer app_destroy(&app)
	v := paged_root(&app)
	v.pending = 1
	v.pages[0].loading = true
	post_result(mk_result(.Artists, 0, v.id, {}, 0, 0, .Network))
	handle_results(&app)
	testing.expect_value(t, app.conn[0], Conn.Failed)
	testing.expect(t, v.pages[0].failed, "the page is marked failed so scrolling doesn't retry in a loop")
	testing.expect(t, !app.dlg_open)
}

@(test)
failures_are_classified :: proc(t: ^testing.T) {
	testing.expect_value(t, classify_failure(.Unauthorized), Failure.Auth)
	testing.expect_value(t, classify_failure(.Network), Failure.Unreachable)
	testing.expect_value(t, classify_failure(.Spawn_Failed), Failure.Unreachable)
	testing.expect_value(t, classify_failure(.Http), Failure.Server_Error)
	testing.expect_value(t, classify_failure(.None), Failure.Bad_Track)
}

@(test)
playback_stops_after_three_failures_in_a_row :: proc(t: ^testing.T) {
	app := test_app(1)
	defer app_destroy(&app)
	tracks: [5]player.Track
	for i in 0 ..< 5 { tracks[i] = {server_id = "s1", id = "x", title = "t"} }
	player.queue_set(&app.q, tracks[:])

	fail_and_skip(&app, "Couldn't play \"t\"")
	testing.expect_value(t, app.q.pos, 1)
	fail_and_skip(&app, "Couldn't play \"t\"")
	testing.expect_value(t, app.q.pos, 2)
	fail_and_skip(&app, "Couldn't play \"t\"")
	testing.expect_value(t, app.q.pos, 2) // gave up: did not skip a third time
	testing.expect_value(t, app.fail_streak, 0)
	testing.expect(t, strings.contains(app.toast, "Stopped after 3"))
}

@(test)
unreachable_probe_stops_and_offers_retry :: proc(t: ^testing.T) {
	app := test_app(1)
	defer app_destroy(&app)
	app.probe_pending = true
	r := mk_result(.Probe, 0, 0, {}, err = .Network)
	defer free_result(r)
	on_probe(&app, r)
	testing.expect(t, !app.probe_pending)
	testing.expect(t, strings.contains(app.toast, "Press R"))
}

@(test)
expired_probe_prompts_login :: proc(t: ^testing.T) {
	app := test_app(1)
	defer app_destroy(&app)
	r := mk_result(.Probe, 0, 0, {}, err = .Unauthorized)
	defer free_result(r)
	on_probe(&app, r)
	testing.expect_value(t, app.conn[0], Conn.Expired)
	testing.expect(t, app.dlg_open)
}

// --- worker threads ---------------------------------------------------------------

// Many jobs at once, each parsing into its own arena and posting to the shared list.
// (This is where an allocator mix-up once crashed the app.) Nothing listens on port 1,
// so every job fails fast with a network error, which still runs the full path:
// spawn, deep-copied server, curl, arena, post, drain, free.
@(test)
concurrent_jobs_round_trip :: proc(t: ^testing.T) {
	// Worker threads must free with the same allocator the test allocated with.
	worker_allocator = context.allocator
	defer worker_allocator = {}
	s := jellyfin.Server{id = "s1", name = "x", url = "http://127.0.0.1:1", user = "u", user_id = "uid", token = "tok", device_id = "d"}
	N :: 8
	for i in 0 ..< N {
		spawn({kind = .Albums, server_idx = i, server = s, start = i * 10, name_from = "K"})
	}
	got: [dynamic]^Result
	defer delete(got)
	deadline := time.tick_add(time.tick_now(), 20 * time.Second)
	for len(got) < N && time.tick_diff(time.tick_now(), deadline) > 0 {
		drain_results(&got)
		time.sleep(20 * time.Millisecond)
	}
	testing.expect_value(t, len(got), N)
	seen: [N]bool
	for r in got {
		testing.expect_value(t, r.err, jellyfin.Error.Network)
		if r.server_idx >= 0 && r.server_idx < N {
			seen[r.server_idx] = true
			testing.expect_value(t, r.start, r.server_idx * 10) // the job's paging args come back
		}
		free_result(r)
	}
	for ok in seen { testing.expect(t, ok, "every job reported exactly once") }
	// A worker posts its result and then frees its own copies; let that finish
	// before the runner checks for leaks.
	time.sleep(300 * time.Millisecond)
	results_destroy()
}

// Small helper so the tests above don't need the hnoss import.
hnossText :: proc(app: ^App) -> string {
	return string(app.in_url.text[:])
}

// --- keys, themes, lyrics, search, layout ---------------------------------------------

@(test)
default_keys_all_parse_and_dont_collide :: proc(t: ^testing.T) {
	binds, bad := build_binds(map[string][]string{})
	defer delete(binds)
	testing.expect_value(t, len(bad), 0)
	for b, i in binds {
		for o in binds[i + 1:] {
			same := b.code == o.code && b.mods == o.mods && (b.code != .Char || b.ch == o.ch)
			testing.expectf(t, !same, "two actions share a key: %v and %v", b.action, o.action)
		}
	}
}

@(test)
keys_can_be_rebound :: proc(t: ^testing.T) {
	keys := [?]string{"ctrl+n", "J"}
	over := make(map[string][]string)
	defer delete(over)
	over["next"] = keys[:]
	binds, bad := build_binds(over)
	defer delete(binds)
	testing.expect_value(t, len(bad), 0)
	ev_ctrl_n := input.Event(input.Key{code = .Char, char = 'n', mods = {.Ctrl}})
	ev_plain_n := input.Event(input.Key{code = .Char, char = 'n'})
	testing.expect_value(t, action_for(binds[:], ev_ctrl_n), Action.Next)
	testing.expect_value(t, action_for(binds[:], ev_plain_n), Action.None) // overriding replaces the default
	testing.expect_value(t, key_label(binds[:], .Next), "ctrl+n")
	space := input.Event(input.Key{code = .Char, char = ' '})
	testing.expect_value(t, action_for(binds[:], space), Action.Play_Pause)
	right := input.Event(input.Key{code = .Right})
	testing.expect_value(t, action_for(binds[:], right), Action.Seek_Fwd)
}

@(test)
bad_key_specs_are_reported :: proc(t: ^testing.T) {
	keys := [?]string{"ctrl+", "toolong"}
	over := make(map[string][]string)
	defer delete(over)
	over["next"] = keys[:]
	binds, bad := build_binds(over)
	defer delete(binds)
	testing.expect_value(t, len(bad), 2)
}

@(test)
hex_colours :: proc(t: ^testing.T) {
	c, ok := parse_hex_color("#ff8800")
	testing.expect(t, ok)
	testing.expect_value(t, c, style.Rgb{255, 136, 0})
	_, ok = parse_hex_color("ff880")
	testing.expect(t, !ok)
	_, ok = parse_hex_color("#gg0000")
	testing.expect(t, !ok)
	testing.expect_value(t, palette_index("forest"), 2)
	testing.expect_value(t, palette_index("no-such-theme"), 0)
}

@(test)
lyric_lines_follow_the_playback_position :: proc(t: ^testing.T) {
	lines := []jellyfin.Lyric_Line{{0, "a"}, {20_000_000, "b"}, {50_000_000, "c"}}
	testing.expect_value(t, current_lyric_index(lines, 0), 0)
	testing.expect_value(t, current_lyric_index(lines, 1.9), 0)
	testing.expect_value(t, current_lyric_index(lines, 2.0), 1)
	testing.expect_value(t, current_lyric_index(lines, 99), 2)
	testing.expect(t, lyrics_synced(lines))
	unsynced := []jellyfin.Lyric_Line{{0, "a"}, {0, "b"}}
	testing.expect(t, !lyrics_synced(unsynced))
}

@(test)
search_results_are_grouped_by_type :: proc(t: ^testing.T) {
	app := test_app(1)
	defer app_destroy(&app)
	v := push_view(&app, .Tracks, "Search: x")
	v.grouped = true
	v.pending = 2
	tracks := mk_result(.Search, 0, v.id, {"Song"})
	tracks.entries[0].type = "Audio"
	artists := mk_result(.Artists, 0, v.id, {"Band"})
	post_result(tracks)
	post_result(artists)
	handle_results(&app)
	testing.expect_value(t, len(v.entries), 2)
	testing.expect_value(t, v.entries[0].type, "MusicArtist") // artists first, whatever arrived first
	testing.expect_value(t, v.entries[1].type, "Audio")
}

@(test)
layout_modes_by_width :: proc(t: ^testing.T) {
	testing.expect_value(t, layout_mode(200), Layout_Mode.Wide)
	testing.expect_value(t, layout_mode(110), Layout_Mode.Wide)
	testing.expect_value(t, layout_mode(109), Layout_Mode.Medium)
	testing.expect_value(t, layout_mode(76), Layout_Mode.Medium)
	testing.expect_value(t, layout_mode(75), Layout_Mode.Narrow)
}

@(test)
removing_the_playing_track_moves_on :: proc(t: ^testing.T) {
	app := test_app(1)
	defer app_destroy(&app)
	tracks: [3]player.Track
	for i in 0 ..< 3 { tracks[i] = {server_id = "s1", id = "x", title = fmt.tprintf("t%d", i)} }
	player.queue_set(&app.q, tracks[:], 1)
	app.queue_list.selected = 1
	queue_remove_selected(&app) // mpv isn't running in tests; the queue bookkeeping is what matters
	testing.expect_value(t, len(app.q.tracks), 2)
	cur, _ := player.queue_current(&app.q)
	testing.expect_value(t, cur.title, "t2")
}

@(test)
favourites_toggle_updates_the_entry_and_the_queue_track :: proc(t: ^testing.T) {
	app := test_app(1)
	defer app_destroy(&app)
	v := paged_root(&app)
	v.pending = 1
	post_result(mk_result(.Artists, 0, v.id, {"Band"}, 0, 1))
	handle_results(&app)
	worker_allocator = context.allocator
	defer worker_allocator = {}
	toggle_favorite_entry(&app, v, 0)
	testing.expect(t, v.entries[0].user_data.is_favorite)
	toggle_favorite_entry(&app, v, 0)
	testing.expect(t, !v.entries[0].user_data.is_favorite)

	tracks: [1]player.Track = {{server_id = "s1", id = "x", title = "t"}}
	player.queue_set(&app.q, tracks[:])
	toggle_favorite_current(&app)
	testing.expect(t, app.q.tracks[0].favorite)
	time.sleep(300 * time.Millisecond) // let the (failing, fire-and-forget) jobs finish
	rs: [dynamic]^Result
	defer delete(rs)
	drain_results(&rs)
	for r in rs { free_result(r) }
	results_destroy()
}
