package main

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import hnoss "../libs/hnoss"
import "../libs/hnoss/style"
import "config"
import "jellyfin"
import "player"
import "session"
import "viz"
import "mpris"
import "core:mem/virtual"

Conn :: enum { Connecting, Online, Failed, Expired }

// What the middle pane shows. On a wide terminal the queue and servers have their
// own panes, so only Browse is used; on narrow ones `v` cycles through these.
Center_Mode :: enum { Browse, Queue, Servers, Now_Playing }

Layout_Mode :: enum { Wide, Medium, Narrow }

layout_mode :: proc(width: int) -> Layout_Mode {
	switch {
	case width >= 110: return .Wide
	case width >= 76:  return .Medium
	}
	return .Narrow
}

// The first four match TAB_TITLES by index.
View_Kind :: enum { Artists, Albums, Playlists, Search, Favourites, Tracks }

// How far from the end of the loaded list the cursor gets before the next page loads.
PAGE_MARGIN :: 30

// Playback stops after this many tracks fail in a row.
MAX_FAIL_STREAK :: 3

// Paging state for one server within a listing.
Page :: struct {
	next:    int,  // index of the first item not loaded yet
	total:   int,  // how many items the server has (0 until the first page arrives)
	loading: bool,
	failed:  bool, // the last request failed; R retries
}

// One screen of the browser. Drilling into an artist/album pushes a new one.
View :: struct {
	id:        int,
	kind:      View_Kind,
	title:     string,
	entries:   [dynamic]Entry,
	results:   [dynamic]^Result, // arenas that back `entries`
	pending:   int,              // jobs still in flight
	errors:    int,
	list:      hnoss.List_State,
	paged:     bool,             // top-level listing that loads more as you scroll
	grouped:   bool,             // search results: artists, albums, playlists, tracks in that order
	pages:     [dynamic]Page,    // one per server (index = server index)
	name_from: string,           // jump-to-letter: listing starts at this name
}

App :: struct {
	cfg:      config.Config,
	servers:  [dynamic]jellyfin.Server,
	conn:     [dynamic]Conn,
	tab:      int,
	stack:    [dynamic]^View,
	next_id:  int,

	servers_list: hnoss.List_State,
	queue_list:   hnoss.List_State,
	search:       hnoss.Input_State,

	q:          player.Queue,
	pl:         player.Player,
	have_mpv:   bool,
	started:    bool, // something has been played this session

	toast:       string,
	toast_until: f64,
	now:         f64,

	// playback failures
	fail_streak:   int,
	probe_pending: bool,

	jump_pending: bool, // `g` pressed: the next key is the letter to jump to

	// add-server dialog
	dlg_open: bool,
	dlg_busy: bool,
	in_url:   hnoss.Input_State,
	in_user:  hnoss.Input_State,
	in_pass:  hnoss.Input_State,
	dlg_focus_pending: bool,
	help_open: bool,
	last_q_pos: int,

	// audio spectrum (real when mpv's stream can be captured, simulated otherwise)
	spec:       viz.Spectrum,
	viz_n:      int, // bars the last frame had room for

	// media keys / playerctl
	mpris_svc: mpris.Service,
	mpris_on:  bool,
	quit:      bool, // set by a remote Quit

	center:       Center_Mode,
	last_view_id: int,
	fade_start:   f64, // when the current view appeared, for the fade-in

	// settings, keys, theme
	palette_idx:    int,
	pinned_accent:  Maybe(style.Rgb),
	settings:       config.Settings,
	settings_arena: virtual.Arena,
	binds:          [dynamic]Bind,

	// scrobbling: what we last told the server is playing
	scrobble_key:    string,
	scrobble_server: string,
	scrobble_item:   string,
	scrobble_at:     f64,
	scrobble_paused: bool,
	last_pos:        f64,

	// resume
	resume_at:    f64, // seconds to start the next load at (restored session)
	saved_sig:    int,
	saved_at:     f64,

	// gapless: queue position already appended to mpv's playlist, or -1
	preloaded_pos: int,
	gapless_hits:  int, // tracks mpv rolled into by itself (debug counter)
	reloads:       int, // tracks started with an explicit load (debug counter)

	// lyrics, keyed like art
	lyrics:         map[string]^Result,
	lyrics_pending: map[string]bool,
	lyrics_open:    bool,
	lyric_scroll:   f64, // eased line index
	lyric_key:      string,

	// save-queue-as-playlist dialog
	save_open:          bool,
	in_name:            hnoss.Input_State,
	save_focus_pending: bool,

	// cover art, keyed "<server id>:<item id>"; a nil entry means the fetch failed
	art:        map[string]^Result,
	art_pending: map[string]bool,
	art_key:    string, // key of the art being shown
	art_fade:   f64,    // 0..1 cross-fade from the placeholder to the cover
	glow_f:     [4][3]f64,
}

TAB_TITLES := [?]string{"Artists", "Albums", "Playlists", "Search", "Favourites"}

app_init :: proc(app: ^App) {
	app.preloaded_pos = -1
	_ = virtual.arena_init_growing(&app.settings_arena)
	settings_ok: bool
	app.settings, settings_ok = config.load_settings(virtual.arena_allocator(&app.settings_arena))
	bad_keys: [dynamic]string
	app.binds, bad_keys = build_binds(app.settings.keys)
	app.cfg = config.load()
	for s in app.cfg.servers {
		append(&app.servers, s)
		append(&app.conn, Conn.Connecting)
	}
	delete(app.cfg.servers) // the strings now belong to app.servers
	app.cfg.servers = nil
	player.queue_init(&app.q)
	for c, i in GLOW { app.glow_f[i] = {f64(c.r), f64(c.g), f64(c.b)} }
	volume := app.settings.volume
	if sess, ok := session.load(); ok {
		session.restore(&app.q, sess)
		if len(app.q.tracks) > 0 {
			app.started = true
			app.resume_at = sess.position
			if sess.volume > 0 { volume = int(sess.volume) }
			toast(app, fmt.tprintf("Restored %d queued tracks. Space to resume.", len(app.q.tracks)), 6)
		}
		session.destroy(sess)
	}
	if err := player.start(&app.pl, volume); err == .None {
		app.have_mpv = true
	} else {
		toast(app, fmt.tprintf("mpv unavailable (%v): browsing only", err), 8)
	}
	if !settings_ok { toast(app, "config.json could not be read; using defaults", 6) }
	if len(bad_keys) > 0 { toast(app, fmt.tprintf("Unknown key in config.json: %s", bad_keys[0]), 6) }
	apply_theme(app, app.settings.theme)
	if app.settings.mpris { app.mpris_on = mpris.start(&app.mpris_svc) }
	reset_root(app)
}

// Frees everything the app owns, so a leak report at exit shows only real leaks.
app_destroy :: proc(app: ^App) {
	viz.stop(&app.spec)
	mpris.stop(&app.mpris_svc)
	save_session(app)
	if app.scrobble_key != "" {
		// Blocking on purpose: this is the last thing we do, and it makes the play count land.
		if idx := server_index(app, app.scrobble_server); idx >= 0 {
			_ = jellyfin.report(app.servers[idx], .Stop, app.scrobble_item, i64(app.last_pos * 1e7), false)
		}
		clear_scrobble(app)
	}
	if app.have_mpv { player.stop(&app.pl) }
	player.queue_destroy(&app.q)
	for len(app.stack) > 0 { destroy_view(pop(&app.stack)) }
	delete(app.stack)

	rs: [dynamic]^Result
	defer delete(rs)
	drain_results(&rs)
	for r in rs { free_result(r) }
	results_destroy()

	for s in app.servers { free_server_strings(s) }
	delete(app.servers)
	delete(app.conn)
	for k, r in app.art {
		if r != nil { free_result(r) }
		delete(k)
	}
	delete(app.art)
	for k in app.art_pending { delete(k) }
	delete(app.art_pending)
	delete(app.art_key)
	delete(app.toast)
	for k, r in app.lyrics {
		if r != nil { free_result(r) }
		delete(k)
	}
	delete(app.lyrics)
	for k in app.lyrics_pending { delete(k) }
	delete(app.lyrics_pending)
	delete(app.lyric_key)
	delete(app.binds)
	hnoss.input_destroy(&app.in_name)
	virtual.arena_destroy(&app.settings_arena)
	hnoss.input_destroy(&app.search)
	hnoss.input_destroy(&app.in_url)
	hnoss.input_destroy(&app.in_user)
	hnoss.input_destroy(&app.in_pass)
	delete(app.cfg.device_id)
}

// Frees what a server in app.servers owns. device_id is shared with the config.
free_server_strings :: proc(s: jellyfin.Server) {
	delete(s.id); delete(s.name); delete(s.url); delete(s.user)
	delete(s.user_id); delete(s.token)
}

// Shows `msg` for a few seconds. The text is copied.
toast :: proc(app: ^App, msg: string, secs := 3.0) {
	delete(app.toast)
	app.toast = strings.clone(msg)
	app.toast_until = app.now + secs
}

server_index :: proc(app: ^App, id: string) -> int {
	for s, i in app.servers { if s.id == id { return i } }
	return -1
}

// --- views ------------------------------------------------------------------

current_view :: proc(app: ^App) -> ^View {
	return len(app.stack) > 0 ? app.stack[len(app.stack) - 1] : nil
}

push_view :: proc(app: ^App, kind: View_Kind, title: string) -> ^View {
	v := new(View)
	app.next_id += 1
	v.id = app.next_id
	v.kind = kind
	v.title = strings.clone(title)
	append(&app.stack, v)
	return v
}

destroy_view :: proc(v: ^View) {
	for r in v.results { free_result(r) }
	delete(v.results)
	delete(v.entries)
	delete(v.pages)
	delete(v.title)
	delete(v.name_from)
	free(v)
}

pop_view :: proc(app: ^App) {
	if len(app.stack) <= 1 { return }
	destroy_view(pop(&app.stack))
}

root_job_kind :: proc(kind: View_Kind) -> (Job_Kind, bool) {
	#partial switch kind {
	case .Artists:   return .Artists, true
	case .Albums:    return .Albums, true
	case .Playlists: return .Playlists, true
	case .Favourites: return .Favourites, true
	}
	return {}, false
}

// Starts over at the tab's top-level listing, fetched page by page from every
// server. With `name_from` the listing starts at that letter instead of the top.
reset_root :: proc(app: ^App, name_from := "") {
	for len(app.stack) > 0 { destroy_view(pop(&app.stack)) }
	kind := View_Kind(app.tab)
	title := TAB_TITLES[app.tab]
	if name_from != "" { title = fmt.tprintf("%s from %s", title, name_from) }
	v := push_view(app, kind, title)
	if _, ok := root_job_kind(kind); !ok { return }
	v.paged = true
	v.name_from = strings.clone(name_from)
	for _ in app.servers { append(&v.pages, Page{}) }
	for i in 0 ..< len(app.servers) { request_page(app, v, i) }
}

// Fetches the next page of a paged listing from one server.
request_page :: proc(app: ^App, v: ^View, server_idx: int) {
	job_kind, ok := root_job_kind(v.kind)
	if !ok || server_idx >= len(v.pages) { return }
	p := &v.pages[server_idx]
	p.loading = true
	p.failed = false
	v.pending += 1
	spawn({kind = job_kind, server_idx = server_idx, server = app.servers[server_idx],
		view_id = v.id, start = p.next, name_from = v.name_from})
}

// Should the listing fetch another page from this server, given the cursor?
page_wanted :: proc(v: ^View, server_idx, selected: int) -> bool {
	if !v.paged || server_idx >= len(v.pages) { return false }
	p := v.pages[server_idx]
	if p.loading || p.failed || p.next >= p.total { return false }
	return selected >= len(v.entries) - PAGE_MARGIN
}

// Called every frame: loads more as the cursor nears the end of what's loaded.
load_more_if_needed :: proc(app: ^App, v: ^View) {
	for i in 0 ..< len(v.pages) {
		if page_wanted(v, i, v.list.selected) { request_page(app, v, i) }
	}
}

page_totals :: proc(v: ^View) -> (loaded, total: int) {
	for p in v.pages { total += p.total }
	return len(v.entries), total
}

set_tab :: proc(app: ^App, tab: int) {
	if tab == app.tab { return }
	app.tab = tab
	reset_root(app)
}

// `R`: reload the listing and give failed servers another chance.
retry :: proc(app: ^App) {
	// Expired too: if the session is still bad, the 401 prompts for a login again.
	for &c in app.conn { if c == .Failed || c == .Expired { c = .Connecting } }
	reset_root(app)
	toast(app, "Reloading…", 2)
}

// `g` then a letter: restart the listing at that letter.
jump_to_letter :: proc(app: ^App, ch: rune) {
	if len(app.stack) != 1 { return }
	if _, ok := root_job_kind(current_view(app).kind); !ok { return }
	reset_root(app, strings.to_upper(fmt.tprintf("%c", ch), context.temp_allocator))
}

// Search across artists, albums, playlists and tracks on every server. The results
// land in one list, grouped in that order.
submit_search :: proc(app: ^App) {
	term := strings.trim_space(hnoss.input_text(&app.search))
	if term == "" { return }
	v := push_view(app, .Tracks, fmt.tprintf("Search: %s", term))
	v.grouped = true
	for s, i in app.servers {
		for k in ([]Job_Kind{.Artists, .Albums, .Playlists, .Search}) {
			v.pending += 1
			spawn({kind = k, server_idx = i, server = s, arg = k == .Search ? term : "", search = k == .Search ? "" : term, view_id = v.id})
		}
	}
}

group_rank :: proc(e: Entry) -> int {
	switch e.type {
	case "MusicArtist": return 0
	case "MusicAlbum":  return 1
	case "Playlist":    return 2
	}
	return 3
}

// Enter on an entry: drill down, or play when it's a track.
activate :: proc(app: ^App, v: ^View, idx: int) {
	if idx < 0 || idx >= len(v.entries) { return }
	e := v.entries[idx]
	s := app.servers[e.server]
	switch e.type {
	case "MusicArtist":
		nv := push_view(app, .Albums, e.name)
		nv.pending = 1
		spawn({kind = .Albums, server_idx = e.server, server = s, arg = e.id, view_id = nv.id})
	case "MusicAlbum":
		nv := push_view(app, .Tracks, e.name)
		nv.pending = 1
		spawn({kind = .Album_Tracks, server_idx = e.server, server = s, arg = e.id, view_id = nv.id})
	case "Playlist":
		nv := push_view(app, .Tracks, e.name)
		nv.pending = 1
		spawn({kind = .Playlist_Tracks, server_idx = e.server, server = s, arg = e.id, view_id = nv.id})
	case "Audio":
		tracks := make([dynamic]player.Track, context.temp_allocator)
		for te in v.entries {
			if te.type == "Audio" { append(&tracks, borrow_track(app, te)) }
		}
		start := 0
		for te in v.entries[:idx] { if te.type == "Audio" { start += 1 } }
		player.queue_set(&app.q, tracks[:], start)
		play_current(app)
	}
}

// 'a': add the selected item to the end of the queue.
enqueue_selected :: proc(app: ^App, v: ^View, idx: int) {
	if idx < 0 || idx >= len(v.entries) { return }
	e := v.entries[idx]
	s := app.servers[e.server]
	switch e.type {
	case "Audio":
		player.queue_add(&app.q, {borrow_track(app, e)})
		toast(app, fmt.tprintf("Queued: %s", e.name))
	case "MusicAlbum":
		spawn({kind = .Album_Tracks, server_idx = e.server, server = s, arg = e.id, then = .Enqueue})
	case "Playlist":
		spawn({kind = .Playlist_Tracks, server_idx = e.server, server = s, arg = e.id, then = .Enqueue})
	}
}

// A Track that points at the entry's strings. The queue copies it on add.
borrow_track :: proc(app: ^App, e: Entry) -> player.Track {
	artist := e.album_artist
	if len(e.artists) > 0 { artist = e.artists[0] }
	return {
		server_id = app.servers[e.server].id,
		id = e.id, title = e.name, artist = artist, album = e.album, album_id = e.album_id,
		length = jellyfin.seconds(e.item), favorite = e.user_data.is_favorite,
	}
}

// --- playback ---------------------------------------------------------------

find_server :: proc(app: ^App, id: string) -> (jellyfin.Server, bool) {
	i := server_index(app, id)
	if i < 0 { return {}, false }
	return app.servers[i], true
}

play_current :: proc(app: ^App) {
	t, ok := player.queue_current(&app.q)
	if !ok { return }
	if !app.have_mpv {
		toast(app, "mpv isn't running, can't play", 4)
		return
	}
	s, found := find_server(app, t.server_id)
	if !found {
		toast(app, "That track's server was removed", 4)
		return
	}
	url := jellyfin.stream_url(s, t.id)
	defer delete(url)
	start := app.resume_at
	app.resume_at = 0
	app.preloaded_pos = -1 // loading replaces mpv's whole playlist
	app.reloads += 1
	player.load(&app.pl, url, jellyfin.auth_header(s), start)
	app.started = true
}

skip_next :: proc(app: ^App) {
	if player.queue_next(&app.q) { play_current(app) } else if app.have_mpv { player.halt(&app.pl) }
}

skip_prev :: proc(app: ^App) {
	if app.pl.state.position > 3 {
		player.seek_to(&app.pl, 0)
	} else if player.queue_prev(&app.q) {
		play_current(app)
	}
}

// --- playback failures ----------------------------------------------------------

Failure :: enum {
	Auth,         // 401: the session expired or the token was revoked
	Unreachable,  // couldn't connect at all
	Server_Error, // the server answered with an error status
	Bad_Track,    // the server is fine; this file just won't play
}

classify_failure :: proc(err: jellyfin.Error) -> Failure {
	switch err {
	case .Unauthorized:                 return .Auth
	case .Network, .Spawn_Failed:       return .Unreachable
	case .Http, .Bad_Json:              return .Server_Error
	case .None:                         return .Bad_Track
	}
	return .Bad_Track
}

// mpv couldn't play the current track. Ask the server why before deciding what to do.
on_play_failed :: proc(app: ^App) {
	if app.probe_pending { return }
	t, ok := player.queue_current(&app.q)
	if !ok { return }
	idx := server_index(app, t.server_id)
	if idx < 0 {
		toast(app, "That track's server was removed", 4)
		return
	}
	app.probe_pending = true
	spawn({kind = .Probe, server_idx = idx, server = app.servers[idx], arg = t.id})
}

on_probe :: proc(app: ^App, r: ^Result) {
	app.probe_pending = false
	title := ""
	if t, ok := player.queue_current(&app.q); ok { title = t.title }
	name := r.server_idx >= 0 && r.server_idx < len(app.servers) ? app.servers[r.server_idx].name : "the server"
	switch classify_failure(r.err) {
	case .Auth:
		stop_playback(app)
		mark_expired(app, r.server_idx)
	case .Unreachable:
		stop_playback(app)
		toast(app, fmt.tprintf("Can't reach %s. Press R to retry.", name), 6)
	case .Server_Error:
		fail_and_skip(app, fmt.tprintf("Server error %d on \"%s\"", r.status, title))
	case .Bad_Track:
		fail_and_skip(app, fmt.tprintf("Couldn't play \"%s\"", title))
	}
}

// Counts a failed track and moves on, giving up after MAX_FAIL_STREAK in a row.
fail_and_skip :: proc(app: ^App, msg: string) {
	app.fail_streak += 1
	if app.fail_streak >= MAX_FAIL_STREAK {
		app.fail_streak = 0
		stop_playback(app)
		toast(app, fmt.tprintf("%s. Stopped after %d failed tracks in a row.", msg, MAX_FAIL_STREAK), 7)
		return
	}
	toast(app, fmt.tprintf("%s, skipping", msg), 4)
	if player.queue_next(&app.q, auto = true) { play_current(app) }
}

stop_playback :: proc(app: ^App) {
	if app.have_mpv { player.halt(&app.pl) }
}

// The server rejected our token: flag it and open the login dialog for it.
mark_expired :: proc(app: ^App, server_idx: int) {
	if server_idx < 0 || server_idx >= len(app.servers) { return }
	already := app.conn[server_idx] == .Expired
	app.conn[server_idx] = .Expired
	if already { return }
	s := app.servers[server_idx]
	toast(app, fmt.tprintf("Session expired for %s. Log in again.", s.name), 6)
	if !app.dlg_open { open_login_dialog(app, s.url, s.user) }
}

// --- per-frame update ---------------------------------------------------------

update :: proc(app: ^App, dt: f64) {
	app.now += dt
	if app.have_mpv {
		player.pump(&app.pl)
		if !app.pl.alive {
			app.have_mpv = false
			toast(app, "mpv exited", 5)
		}
		st := &app.pl.state
		if st.position > 0.5 { app.fail_streak = 0 }
		if st.ended {
			st.ended = false
			if player.queue_next(&app.q, auto = true) {
				if app.q.pos == app.preloaded_pos {
					app.preloaded_pos = -1 // mpv is already playing it; no reload, no gap
					app.gapless_hits += 1
				} else {
					play_current(app)
				}
			}
		}
		if st.failed {
			st.failed = false
			on_play_failed(app)
		}
	}
	if app.q.pos != app.last_q_pos {
		app.last_q_pos = app.q.pos
		app.queue_list.selected = max(app.q.pos, 0)
	}
	update_scrobble(app)
	update_preload(app)
	update_session_save(app)
	handle_results(app)
	update_art(app, dt)
	update_lyrics(app, dt)
	update_glow(app, dt)

	update_viz(app, dt)
	update_mpris(app)
}

handle_results :: proc(app: ^App) {
	rs: [dynamic]^Result
	rs.allocator = context.temp_allocator
	drain_results(&rs)
	for r in rs {
		if r.kind == .Art {
			on_art(app, r)
			continue
		}
		if r.kind == .Lyrics {
			on_lyrics(app, r)
			continue
		}
		if r.kind == .Report {
			free_result(r)
			continue
		}
		if r.kind == .Favorite {
			if r.err != .None { toast(app, "Couldn't update the favourite", 4) }
			free_result(r)
			continue
		}
		if r.kind == .Save_Playlist {
			if r.err == .None {
				toast(app, fmt.tprintf("Saved playlist with %d tracks", r.total), 4)
				if View_Kind(app.tab) == .Playlists { reset_root(app) }
			} else {
				toast(app, fmt.tprintf("Couldn't save the playlist: %v", r.err), 5)
			}
			free_result(r)
			continue
		}
		if r.kind == .Probe {
			on_probe(app, r)
			free_result(r)
			continue
		}
		if r.kind == .Login {
			on_login(app, r)
			free_result(r)
			continue
		}
		if r.server_idx >= 0 && r.server_idx < len(app.conn) {
			switch r.err {
			case .None:         app.conn[r.server_idx] = .Online
			case .Unauthorized: mark_expired(app, r.server_idx)
			case .Network, .Spawn_Failed, .Http, .Bad_Json: app.conn[r.server_idx] = .Failed
			}
		}
		if r.then != .Show {
			if r.err == .None {
				tracks := make([dynamic]player.Track, context.temp_allocator)
				for e in r.entries { append(&tracks, borrow_track(app, e)) }
				was_empty := len(app.q.tracks) == 0
				if r.then == .Next {
					player.queue_insert_next(&app.q, tracks[:])
					preload_clear(app)
				} else {
					player.queue_add(&app.q, tracks[:])
				}
				toast(app, fmt.tprintf(r.then == .Next ? "Playing %d tracks next" : "Queued %d tracks", len(tracks)))
				if was_empty && r.then == .Play { play_current(app) }
			}
			free_result(r)
			continue
		}
		v: ^View
		for sv in app.stack { if sv.id == r.view_id { v = sv; break } }
		if v == nil { free_result(r); continue } // the user navigated away
		apply_page(app, v, r)
	}
}

// Merges one server's page of results into a view.
apply_page :: proc(app: ^App, v: ^View, r: ^Result) {
	v.pending -= 1
	if r.err != .None { v.errors += 1 }
	if r.server_idx >= 0 && r.server_idx < len(v.pages) {
		p := &v.pages[r.server_idx]
		p.loading = false
		if r.err == .None {
			p.total = r.total
			p.next = r.start + len(r.entries)
		} else {
			p.failed = true
		}
	}

	// Remember the selected item so a re-sort doesn't move the cursor off it.
	sel_server, sel_id, had_sel := -1, "", false
	if v.list.selected >= 0 && v.list.selected < len(v.entries) {
		sel_server, sel_id, had_sel = v.entries[v.list.selected].server, v.entries[v.list.selected].id, true
	}
	append(&v.results, r)
	append(&v.entries, ..r.entries)
	if v.grouped {
		slice.stable_sort_by(v.entries[:], proc(a, b: Entry) -> bool { return group_rank(a) < group_rank(b) })
		if had_sel {
			for e, i in v.entries {
				if e.server == sel_server && e.id == sel_id { v.list.selected = i; break }
			}
		}
	}
	if len(app.servers) > 1 && v.kind != .Tracks {
		slice.stable_sort_by(v.entries[:], proc(a, b: Entry) -> bool {
			return strings.compare(strings.to_lower(a.name, context.temp_allocator), strings.to_lower(b.name, context.temp_allocator)) < 0
		})
		if had_sel {
			for e, i in v.entries {
				if e.server == sel_server && e.id == sel_id { v.list.selected = i; break }
			}
		}
	}
}

on_login :: proc(app: ^App, r: ^Result) {
	app.dlg_busy = false
	if r.err != .None {
		toast(app, fmt.tprintf("Login failed: %v", r.err), 5)
		return
	}
	src := r.server
	s := jellyfin.Server{
		id = strings.clone(src.id), name = strings.clone(src.name), url = strings.clone(src.url),
		user = strings.clone(src.user), user_id = strings.clone(src.user_id), token = strings.clone(src.token),
		device_id = app.cfg.device_id,
	}
	replaced := false
	for &ex, i in app.servers {
		if ex.url == s.url && ex.user == s.user {
			delete(s.id)
			s.id = strings.clone(ex.id)
			free_server_strings(ex)
			ex = s
			app.conn[i] = .Online
			replaced = true
			break
		}
	}
	if !replaced {
		append(&app.servers, s)
		append(&app.conn, Conn.Online)
	}
	persist(app)
	app.dlg_open = false
	toast(app, fmt.tprintf("Connected to %s", s.name))
	reset_root(app)
}

persist :: proc(app: ^App) {
	app.cfg.servers = app.servers[:]
	ok := config.save(app.cfg)
	app.cfg.servers = nil
	if !ok { toast(app, "Couldn't save config", 5) }
}

remove_server :: proc(app: ^App, idx: int) {
	if idx < 0 || idx >= len(app.servers) { return }
	toast(app, fmt.tprintf("Removed %s", app.servers[idx].name))
	free_server_strings(app.servers[idx])
	ordered_remove(&app.servers, idx)
	ordered_remove(&app.conn, idx)
	persist(app)
	reset_root(app)
}

open_login_dialog :: proc(app: ^App, url := "", user := "") {
	hnoss.input_set(&app.in_url, url)
	hnoss.input_set(&app.in_user, user)
	hnoss.input_set(&app.in_pass, "")
	app.dlg_open = true
	app.dlg_busy = false
	app.dlg_focus_pending = true
}

submit_login :: proc(app: ^App) {
	url := strings.trim_space(hnoss.input_text(&app.in_url))
	user := strings.trim_space(hnoss.input_text(&app.in_user))
	pass := hnoss.input_text(&app.in_pass)
	if url == "" || user == "" { toast(app, "Enter a URL and username", 3); return }
	if !strings.contains(url, "://") { url = fmt.tprintf("http://%s", url) }
	url = strings.trim_right(url, "/")
	host := url[strings.index(url, "://") + 3:]
	max_id := 0
	for s in app.servers {
		if n, ok := strconv.parse_int(strings.trim_prefix(s.id, "s")); ok {
			max_id = max(max_id, n)
		}
	}
	srv := jellyfin.Server{
		id = fmt.tprintf("s%d", max_id + 1), name = host, url = url, user = user, device_id = app.cfg.device_id,
	}
	app.dlg_busy = true
	spawn({kind = .Login, server_idx = -1, server = srv, password = pass})
}

// --- cover art ----------------------------------------------------------------

// Where the current track's cover lives, as (cache key, item id).
current_art_ref :: proc(app: ^App) -> (key, item: string, ok: bool) {
	t, has := player.queue_current(&app.q)
	if !has || !app.started { return }
	item = t.album_id != "" ? t.album_id : t.id
	return fmt.tprintf("%s:%s", t.server_id, item), item, true
}

current_art :: proc(app: ^App) -> (art: ^Art, ok: bool) {
	key, _, has := current_art_ref(app)
	if !has { return }
	r := app.art[key] or_return
	if r == nil { return }
	return &r.art, true
}

update_art :: proc(app: ^App, dt: f64) {
	key, item, ok := current_art_ref(app)
	if !ok { return }
	if key != app.art_key {
		delete(app.art_key)
		app.art_key = strings.clone(key)
		app.art_fade = 0
	}
	app.art_fade = min(app.art_fade + dt * 1.6, 1)
	if key in app.art || key in app.art_pending { return }
	t, _ := player.queue_current(&app.q)
	s, found := find_server(app, t.server_id)
	if !found { return }
	app.art_pending[strings.clone(key)] = true
	spawn({kind = .Art, server_idx = -1, server = s, arg = item, key = key})
}

on_art :: proc(app: ^App, r: ^Result) {
	key := strings.clone(r.key) // r's arena may be freed below
	if pk, _ := delete_key(&app.art_pending, key); pk != "" { delete(pk) }
	if r.err == .None && r.art.w > 0 {
		app.art[key] = r
	} else {
		app.art[key] = nil
		free_result(r)
	}
}

// Eases the global gradient toward the cover's colours (or the defaults).
update_glow :: proc(app: ^App, dt: f64) {
	target := DEFAULT_GLOW
	tint, have_tint := app.pinned_accent.?
	if !have_tint {
		if art, ok := current_art(app); ok {
			tint, have_tint = style.Rgb{art.dominant.x, art.dominant.y, art.dominant.z}, true
		}
	}
	if have_tint {
		d := tint
		target = {style.lerp_rgb(d, TEAL, 0.35), d, style.lerp_rgb(d, VIOLET, 0.45), style.lerp_rgb(d, MAGENTA, 0.55)}
	}
	k := clamp(dt * 2.5, 0, 1)
	for i in 0 ..< 4 {
		t := [3]f64{f64(target[i].r), f64(target[i].g), f64(target[i].b)}
		app.glow_f[i] += (t - app.glow_f[i]) * k
		g := app.glow_f[i]
		GLOW[i] = {u8(g.x + 0.5), u8(g.y + 0.5), u8(g.z + 0.5)}
	}
}

// Bilinear sample of a cover at u,v in 0..1, over its centred square crop
// (so a non-square cover is cropped, never stretched).
sample_art :: proc(a: ^Art, u, v: f64) -> style.Rgb {
	side := min(a.w, a.h)
	ox, oy := f64(a.w - side) / 2, f64(a.h - side) / 2
	fx := ox + clamp(u, 0, 1) * f64(max(side - 1, 0))
	fy := oy + clamp(v, 0, 1) * f64(max(side - 1, 0))
	x0, y0 := int(fx), int(fy)
	x1, y1 := min(x0 + 1, a.w - 1), min(y0 + 1, a.h - 1)
	tx, ty := fx - f64(x0), fy - f64(y0)
	px :: proc(a: ^Art, x, y: int) -> [3]f64 {
		i := (y * a.w + x) * 3
		return {f64(a.rgb[i]), f64(a.rgb[i + 1]), f64(a.rgb[i + 2])}
	}
	top := px(a, x0, y0) * (1 - tx) + px(a, x1, y0) * tx
	bot := px(a, x0, y1) * (1 - tx) + px(a, x1, y1) * tx
	c := top * (1 - ty) + bot * ty
	return {u8(c.x + 0.5), u8(c.y + 0.5), u8(c.z + 0.5)}
}

// --- queue editing ----------------------------------------------------------------

// `A`: put the selected item right after the current track.
play_next_selected :: proc(app: ^App, v: ^View, idx: int) {
	if idx < 0 || idx >= len(v.entries) { return }
	e := v.entries[idx]
	s := app.servers[e.server]
	switch e.type {
	case "Audio":
		player.queue_insert_next(&app.q, {borrow_track(app, e)})
		preload_clear(app)
		toast(app, fmt.tprintf("Playing next: %s", e.name))
	case "MusicAlbum":
		spawn({kind = .Album_Tracks, server_idx = e.server, server = s, arg = e.id, then = .Next})
	case "Playlist":
		spawn({kind = .Playlist_Tracks, server_idx = e.server, server = s, arg = e.id, then = .Next})
	}
}

// Throws away anything gapless mode already handed to mpv, after the queue changed.
preload_clear :: proc(app: ^App) {
	if app.preloaded_pos >= 0 && app.have_mpv { player.preload_clear(&app.pl) }
	app.preloaded_pos = -1
}

queue_remove_selected :: proc(app: ^App) {
	p := app.queue_list.selected
	if p < 0 || p >= len(app.q.order) { return }
	was_current := player.queue_remove(&app.q, p)
	preload_clear(app)
	if !was_current { return }
	if len(app.q.order) == 0 {
		stop_playback(app)
		app.started = false
	} else {
		play_current(app)
	}
}

queue_move_selected :: proc(app: ^App, delta: int) {
	app.queue_list.selected = player.queue_move(&app.q, app.queue_list.selected, delta)
	preload_clear(app)
}

queue_clear_all :: proc(app: ^App) {
	if len(app.q.tracks) == 0 { return }
	player.queue_clear(&app.q)
	preload_clear(app)
	stop_playback(app)
	app.started = false
	toast(app, "Queue cleared")
}

open_save_dialog :: proc(app: ^App) {
	if len(app.q.order) == 0 { toast(app, "The queue is empty", 3); return }
	hnoss.input_set(&app.in_name, "Tendril queue")
	app.save_open = true
	app.save_focus_pending = true
}

// Saves the queue as a playlist on the server of its first track (a playlist can't
// span servers, so tracks from other servers are left out).
submit_save_playlist :: proc(app: ^App) {
	name := strings.trim_space(hnoss.input_text(&app.in_name))
	if name == "" { return }
	first, ok := player.queue_current(&app.q)
	if !ok { first = app.q.tracks[0] }
	idx := server_index(app, first.server_id)
	if idx < 0 { return }
	ids := make([dynamic]string, context.temp_allocator)
	for p in app.q.order {
		t := app.q.tracks[p]
		if t.server_id == first.server_id { append(&ids, t.id) }
	}
	spawn({kind = .Save_Playlist, server_idx = idx, server = app.servers[idx], arg = name, ids = ids[:]})
	app.save_open = false
	if len(ids) < len(app.q.order) { toast(app, fmt.tprintf("Saving %d of %d tracks (the rest are on other servers)", len(ids), len(app.q.order)), 5) }
}

// --- favourites -----------------------------------------------------------------

toggle_favorite_entry :: proc(app: ^App, v: ^View, idx: int) {
	if idx < 0 || idx >= len(v.entries) { return }
	e := &v.entries[idx]
	on := !e.user_data.is_favorite
	e.user_data.is_favorite = on
	spawn({kind = .Favorite, server_idx = e.server, server = app.servers[e.server], arg = e.id, flag = on})
	toast(app, fmt.tprintf("%s %s", on ? "Added to favourites:" : "Removed from favourites:", e.name), 2.5)
}

toggle_favorite_current :: proc(app: ^App) {
	if app.q.pos < 0 || app.q.pos >= len(app.q.order) { return }
	t := &app.q.tracks[app.q.order[app.q.pos]]
	idx := server_index(app, t.server_id)
	if idx < 0 { return }
	t.favorite = !t.favorite
	spawn({kind = .Favorite, server_idx = idx, server = app.servers[idx], arg = t.id, flag = t.favorite})
	toast(app, fmt.tprintf("%s %s", t.favorite ? "Added to favourites:" : "Removed from favourites:", t.title), 2.5)
}

// --- scrobbling -------------------------------------------------------------------

clear_scrobble :: proc(app: ^App) {
	delete(app.scrobble_key); delete(app.scrobble_server); delete(app.scrobble_item)
	app.scrobble_key, app.scrobble_server, app.scrobble_item = "", "", ""
}

send_report :: proc(app: ^App, event: jellyfin.Report_Event, server_id, item: string, pos: f64, paused: bool) {
	idx := server_index(app, server_id)
	if idx < 0 { return }
	spawn({kind = .Report, server_idx = idx, server = app.servers[idx], arg = item,
		event = event, ticks = i64(pos * 1e7), flag = paused})
}

// Tells the server when a track starts, every 10 s while it plays (and on pause or
// resume), and when it stops, which is what updates play counts and "recently played".
update_scrobble :: proc(app: ^App) {
	if !app.settings.scrobble || !app.have_mpv { return }
	st := app.pl.state
	cur, has := player.queue_current(&app.q)
	key := ""
	if has && !st.idle { key = fmt.tprintf("%s/%s", cur.server_id, cur.id) }

	if app.scrobble_key != "" && key != app.scrobble_key {
		send_report(app, .Stop, app.scrobble_server, app.scrobble_item, app.last_pos, false)
		clear_scrobble(app)
	}
	if key != "" && app.scrobble_key == "" {
		app.scrobble_key = strings.clone(key)
		app.scrobble_server = strings.clone(cur.server_id)
		app.scrobble_item = strings.clone(cur.id)
		app.last_pos = 0
		app.scrobble_at = app.now
		app.scrobble_paused = st.paused
		send_report(app, .Start, cur.server_id, cur.id, st.position, st.paused)
	} else if key != "" {
		if st.paused != app.scrobble_paused || app.now - app.scrobble_at >= 10 {
			app.scrobble_at = app.now
			app.scrobble_paused = st.paused
			send_report(app, .Progress, cur.server_id, cur.id, st.position, st.paused)
		}
	}
	if st.position > 0 { app.last_pos = st.position }
}

// --- resume ---------------------------------------------------------------------

save_session :: proc(app: ^App) {
	pos := app.pl.state.idle ? app.resume_at : app.pl.state.position
	snap := session.snapshot(&app.q, pos, app.pl.state.volume)
	_ = session.save(snap)
}

// Every 20 s while playing, and whenever the queue changes.
update_session_save :: proc(app: ^App) {
	sig := len(app.q.tracks) * 1_000_003 + app.q.pos * 31 + int(app.q.repeat) * 7 + (app.q.shuffle ? 1 : 0)
	playing := app.have_mpv && !app.pl.state.idle
	if sig != app.saved_sig || (playing && app.now - app.saved_at >= 20) {
		app.saved_sig = sig
		app.saved_at = app.now
		save_session(app)
	}
}

// --- gapless ----------------------------------------------------------------------

// Hands mpv the next track a little before the current one ends, so it can switch
// without a gap. Only within one server: mpv's auth header is a single global.
update_preload :: proc(app: ^App) {
	if !app.have_mpv || app.preloaded_pos >= 0 { return }
	st := app.pl.state
	cur, has := player.queue_current(&app.q)
	if !has || st.idle || st.paused { return }
	length := st.duration > 0 ? st.duration : cur.length
	if length <= 0 || length - st.position > 12 { return }
	next_pos, ok := player.queue_peek_next(&app.q)
	if !ok { return }
	next := app.q.tracks[app.q.order[next_pos]]
	if next.server_id != cur.server_id { return }
	s, found := find_server(app, next.server_id)
	if !found { return }
	url := jellyfin.stream_url(s, next.id)
	defer delete(url)
	player.preload(&app.pl, url)
	app.preloaded_pos = next_pos
}

// --- lyrics -----------------------------------------------------------------------

// Cache key of the current track ("server id:track id"), for per-track data like lyrics.
current_track_key :: proc(app: ^App) -> (key: string, ok: bool) {
	t, has := player.queue_current(&app.q)
	if !has || !app.started { return }
	return fmt.tprintf("%s:%s", t.server_id, t.id), true
}

current_lyrics :: proc(app: ^App) -> []jellyfin.Lyric_Line {
	key, ok := current_track_key(app)
	if !ok { return nil }
	r := app.lyrics[key] or_else nil
	if r == nil { return nil }
	return r.lyrics
}

// Fetches lyrics when the track changes, and eases the scroll position toward the
// line being sung.
update_lyrics :: proc(app: ^App, dt: f64) {
	t, has := player.queue_current(&app.q)
	if !has || !app.started { return }
	key := fmt.tprintf("%s:%s", t.server_id, t.id)
	if key != app.lyric_key {
		delete(app.lyric_key)
		app.lyric_key = strings.clone(key)
		app.lyric_scroll = 0
	}
	if !(key in app.lyrics) && !(key in app.lyrics_pending) {
		if s, found := find_server(app, t.server_id); found {
			app.lyrics_pending[strings.clone(key)] = true
			spawn({kind = .Lyrics, server_idx = -1, server = s, arg = t.id, key = key})
		}
	}
	lines := app.lyrics[key] or_else nil
	if lines != nil && len(lines.lyrics) > 0 {
		target := f64(current_lyric_index(lines.lyrics, app.pl.state.position))
		app.lyric_scroll += (target - app.lyric_scroll) * clamp(dt * 8, 0, 1)
	}
}

// Index of the line being sung at `position` seconds (-1 before the first line).
current_lyric_index :: proc(lines: []jellyfin.Lyric_Line, position: f64) -> int {
	ticks := i64(position * 1e7)
	idx := -1
	for l, i in lines {
		if l.start <= ticks { idx = i } else { break }
	}
	return idx
}

// Lyrics are synced when any line has a start time other than the first's.
lyrics_synced :: proc(lines: []jellyfin.Lyric_Line) -> bool {
	for l in lines[min(1, len(lines)):] { if l.start > 0 { return true } }
	return false
}

on_lyrics :: proc(app: ^App, r: ^Result) {
	key := strings.clone(r.key)
	if pk, _ := delete_key(&app.lyrics_pending, key); pk != "" { delete(pk) }
	if r.err == .None && len(r.lyrics) > 0 {
		app.lyrics[key] = r
	} else {
		app.lyrics[key] = nil
		free_result(r)
	}
}

// --- themes -----------------------------------------------------------------------

apply_theme :: proc(app: ^App, name: string) {
	app.palette_idx = palette_index(name)
	apply_palette(app.palette_idx)
	app.pinned_accent = nil
	if a, ok := parse_hex_color(app.settings.accent); ok && app.settings.accent != "" {
		app.pinned_accent = a
	}
}

next_theme :: proc(app: ^App) {
	app.palette_idx = (app.palette_idx + 1) % len(PALETTES)
	apply_palette(app.palette_idx)
	toast(app, fmt.tprintf("Theme: %s", PALETTES[app.palette_idx].name), 2)
}

// --- spectrum ---------------------------------------------------------------------

update_viz :: proc(app: ^App, dt: f64) {
	playing := app.have_mpv && !app.pl.state.paused && !app.pl.state.idle
	if app.have_mpv && !app.pl.state.idle { viz.try_start(&app.spec, app.now) }
	viz.pump(&app.spec)
	n := clamp(app.viz_n, 8, viz.MAX_BARS)
	viz.analyze(&app.spec, n, dt, viz.volume_gain(app.pl.state.volume))
	if app.spec.active { return }

	// No real audio to look at (no parec, or the stream isn't up yet): a gentle
	// simulation that follows the play state, so the panel is never dead.
	energy := playing ? 1.0 : 0.0
	t := app.now
	for i in 0 ..< n {
		f := f64(i) / f64(n)
		v := (0.5 + 0.5 * math.sin(t * (1.6 + 0.37 * f64(i % 7)) + f64(i) * 0.9)) * (1 - 0.55 * f) * energy
		app.spec.bars[i] += (v * 0.8 - app.spec.bars[i]) * min(dt * 9, 1)
	}
	app.spec.bass = (app.spec.bars[0] + app.spec.bars[1] + app.spec.bars[2]) / 3
}

toggle_playback :: proc(app: ^App) {
	if !app.have_mpv { return }
	if app.pl.state.idle { play_current(app) } else { player.toggle(&app.pl) }
}

// --- media keys (MPRIS) ---------------------------------------------------------------

// A D-Bus object path from a Jellyfin id (letters, digits and underscores only).
object_path :: proc(id: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "/org/tendril/track/")
	for c in id {
		switch c {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_': strings.write_rune(&b, c)
		case: strings.write_byte(&b, '_')
		}
	}
	return strings.to_string(b)
}

mpris_snapshot :: proc(app: ^App) -> mpris.Snapshot {
	st := app.pl.state
	sn: mpris.Snapshot
	switch {
	case !app.have_mpv || st.idle: sn.status = "Stopped"
	case st.paused:                sn.status = "Paused"
	case:                          sn.status = "Playing"
	}
	if t, ok := player.queue_current(&app.q); ok && app.started {
		sn.title, sn.artist, sn.album = t.title, t.artist, t.album
		sn.track_id = object_path(t.id)
		length := t.length > 0 ? t.length : st.duration
		sn.length_us = i64(length * 1e6)
	}
	sn.position_us = i64(st.position * 1e6)
	sn.volume = clamp(st.volume / 100, 0, 1)
	sn.shuffle = app.q.shuffle
	switch app.q.repeat {
	case .Off: sn.loop = "None"
	case .One: sn.loop = "Track"
	case .All: sn.loop = "Playlist"
	}
	sn.can_play = len(app.q.tracks) > 0
	sn.can_next = app.q.pos >= 0 && (app.q.pos + 1 < len(app.q.order) || app.q.repeat == .All)
	sn.can_prev = app.q.pos >= 0
	return sn
}

update_mpris :: proc(app: ^App) {
	if !app.mpris_on { return }
	cmds: [dynamic]mpris.Command
	cmds.allocator = context.temp_allocator
	mpris.pump(&app.mpris_svc, mpris_snapshot(app), &cmds)
	if !app.mpris_svc.active {
		app.mpris_on = false
		return
	}
	for c in cmds {
		st := app.pl.state
		switch c.kind {
		case .Play:       if app.have_mpv && (st.idle || st.paused) { toggle_playback(app) }
		case .Pause:      if app.have_mpv && !st.idle && !st.paused { player.toggle(&app.pl) }
		case .Play_Pause: toggle_playback(app)
		case .Stop:       stop_playback(app)
		case .Next:       skip_next(app)
		case .Previous:   skip_prev(app)
		case .Seek:       if app.have_mpv { player.seek_by(&app.pl, f64(c.value) / 1e6) }
		case .Set_Position: if app.have_mpv { player.seek_to(&app.pl, f64(c.value) / 1e6) }
		case .Set_Volume: if app.have_mpv { player.set_volume(&app.pl, c.vol * 100) }
		case .Set_Shuffle:
			if (c.value != 0) != app.q.shuffle { player.queue_toggle_shuffle(&app.q); preload_clear(app) }
		case .Set_Loop:
			switch c.value { // 0 none, 1 track, 2 playlist
			case 1:  app.q.repeat = .One
			case 2:  app.q.repeat = .All
			case:    app.q.repeat = .Off
			}
			preload_clear(app)
		case .Quit:       app.quit = true
		}
	}
}
