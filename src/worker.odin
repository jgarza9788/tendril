package main

import "core:image"
import "base:runtime"
import _ "core:image/jpeg"
import _ "core:image/png"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:thread"
import "jellyfin"

// Network work runs on short-lived threads so the UI never blocks. A thread
// parses into its own arena and posts a Result; the UI thread drains them.

Job_Kind :: enum { Report, Favorite, Favourites, Save_Playlist, Lyrics, Probe, Art, Login, Artists, Albums, Playlists, Album_Tracks, Playlist_Tracks, Search }
Then :: enum { Show, Enqueue, Next, Play }

Entry :: struct {
	using item: jellyfin.Item,
	server:     int, // index into App.servers
}

Job :: struct {
	kind:       Job_Kind,
	server_idx: int,
	server:     jellyfin.Server,
	arg:        string, // item id or search term (owned by the job)
	password:   string, // Login only
	view_id:    int,
	then:       Then,
	key:        string, // Art: cache key, echoed back in the Result
	start:      int,    // paged listings: index of the first item wanted
	name_from:  string, // paged listings: only names >= this (jump to letter)
	search:     string, // search listings: the term
	event:      jellyfin.Report_Event, // Report
	ticks:      i64,    // Report: position in 100 ns ticks
	flag:       bool,   // Report: paused; Favorite: new state
	ids:        []string, // Save_Playlist: track ids
}

// A decoded cover, scaled down so drawing it is cheap.
Art :: struct {
	w, h:     int,
	rgb:      []u8, // w*h*3
	dominant: [3]u8, // vivid average colour, used to tint the UI
}

Result :: struct {
	key:        string,
	art:        Art,
	status:     int, // Probe: HTTP status (0 = unreachable)
	start:      int, // paged listings: index of the first item in `entries`
	total:      int, // paged listings: how many exist on that server
	lyrics:     []jellyfin.Lyric_Line,
	arena:      virtual.Arena,
	kind:       Job_Kind,
	server_idx: int,
	view_id:    int,
	then:       Then,
	err:        jellyfin.Error,
	entries:    []Entry,
	server:     jellyfin.Server, // Login: the authenticated server
}

// Allocator worker threads use for everything that outlives a job (results, strings).
// Threads start with the default context, so main points this at its own allocator
// (e.g. a tracking one) to keep both sides of every alloc/free the same.
worker_allocator: runtime.Allocator

// NOTE: assigning to `context` inside an `if { }` only lasts for that block, so this
// returns the allocator to assign at function level.
job_allocator :: proc() -> runtime.Allocator {
	return worker_allocator.procedure != nil ? worker_allocator : context.allocator
}

@(private="file") results: [dynamic]^Result
@(private="file") results_mu: sync.Mutex

clone_server :: proc(s: jellyfin.Server) -> jellyfin.Server {
	return {
		id = strings.clone(s.id), name = strings.clone(s.name), url = strings.clone(s.url),
		user = strings.clone(s.user), user_id = strings.clone(s.user_id),
		token = strings.clone(s.token), device_id = strings.clone(s.device_id),
	}
}

free_server :: proc(s: jellyfin.Server) {
	delete(s.id); delete(s.name); delete(s.url); delete(s.user)
	delete(s.user_id); delete(s.token); delete(s.device_id)
}

// Jobs own deep copies of everything they use: the caller's strings may live in
// the per-frame temp allocator and be gone by the time the thread runs.
spawn :: proc(job: Job) {
	context.allocator = job_allocator()
	j := new(Job)
	j^ = job
	j.server = clone_server(job.server)
	j.arg = strings.clone(job.arg)
	j.key = strings.clone(job.key)
	j.name_from = strings.clone(job.name_from)
	j.search = strings.clone(job.search)
	if len(job.ids) > 0 {
		j.ids = make([]string, len(job.ids))
		for id, i in job.ids { j.ids[i] = strings.clone(id) }
	}
	j.password = strings.clone(job.password)
	t := thread.create_and_start_with_poly_data(j, run_job, self_cleanup = true)
	_ = t
}

@(private="file")
run_job :: proc(j: ^Job) {
	context.allocator = job_allocator()
	defer {
		free_server(j.server)
		delete(j.arg)
		delete(j.key)
		delete(j.name_from)
		delete(j.search)
		for id in j.ids { delete(id) }
		delete(j.ids)
		delete(j.password)
		free(j)
		free_all(context.temp_allocator)
	}
	r := new(Result)
	_ = virtual.arena_init_growing(&r.arena)
	r.kind, r.server_idx, r.view_id, r.then = j.kind, j.server_idx, j.view_id, j.then
	fetch(j, r)

	// Back on the normal heap allocator: the shared list must never grow inside
	// a result's arena, which is destroyed independently.
	post_result(r)
}

// Hands a finished result to the UI thread.
post_result :: proc(r: ^Result) {
	sync.mutex_guard(&results_mu)
	append(&results, r)
}

// Runs the request with everything it allocates (strings, slices) landing in
// the result's arena.
@(private="file")
fetch :: proc(j: ^Job, r: ^Result) {
	context.allocator = virtual.arena_allocator(&r.arena)
	s := j.server
	resp: jellyfin.Items_Response

	switch j.kind {
	case .Probe:           r.status, r.err = jellyfin.probe_stream(s, j.arg)
	case .Art:             fetch_art(s, j, r)
	case .Login:           r.server, r.err = jellyfin.authenticate(s, j.password)
	case .Report:          r.err = jellyfin.report(s, j.event, j.arg, j.ticks, j.flag)
	case .Favorite:        r.err = jellyfin.set_favorite(s, j.arg, j.flag)
	case .Favourites:      resp, r.err = jellyfin.favourites(s, j.start, name_from = j.name_from)
	case .Save_Playlist:   r.err = jellyfin.save_playlist(s, j.arg, j.ids); r.total = len(j.ids)
	case .Lyrics:
		r.key = strings.clone(j.key)
		lr: jellyfin.Lyrics_Response
		lr, r.err = jellyfin.lyrics(s, j.arg)
		r.lyrics = lr.lyrics
	case .Artists:         resp, r.err = jellyfin.artists(s, j.start, j.search != "" ? 25 : jellyfin.PAGE_SIZE, j.search, j.name_from)
	case .Albums:          resp, r.err = jellyfin.albums(s, artist_id = j.arg, start = j.start, limit = j.search != "" ? 25 : jellyfin.PAGE_SIZE, search = j.search, name_from = j.name_from)
	case .Playlists:       resp, r.err = jellyfin.playlists(s, j.start, j.search != "" ? 25 : jellyfin.PAGE_SIZE, j.name_from, j.search)
	case .Album_Tracks:    resp, r.err = jellyfin.album_tracks(s, j.arg)
	case .Playlist_Tracks: resp, r.err = jellyfin.playlist_tracks(s, j.arg)
	case .Search:          resp, r.err = jellyfin.search_tracks(s, j.arg)
	}
	r.start, r.total = j.start, resp.total
	if j.kind == .Login {
		r.server = clone_server(r.server) // into the arena: j.server is freed with the job
	}
	if r.err == .None && len(resp.items) > 0 {
		r.entries = make([]Entry, len(resp.items))
		for it, i in resp.items { r.entries[i] = {item = it, server = j.server_idx} }
	}
}

// Takes everything the workers have posted since the last call.
drain_results :: proc(into: ^[dynamic]^Result) {
	sync.mutex_guard(&results_mu)
	append(into, ..results[:])
	clear(&results)
}

// Releases the shared result list's buffer. Call once, at shutdown, after draining.
results_destroy :: proc() {
	sync.mutex_guard(&results_mu)
	delete(results)
	results = nil
}

free_result :: proc(r: ^Result) {
	virtual.arena_destroy(&r.arena)
	free(r)
}

@(private="file")
fetch_art :: proc(s: jellyfin.Server, j: ^Job, r: ^Result) {
	r.key = strings.clone(j.key)
	data, err := jellyfin.image(s, j.arg)
	if err != .None { r.err = err; return }
	img, ierr := image.load_from_bytes(data)
	if ierr != nil || img == nil || img.width < 1 || img.height < 1 { r.err = .Bad_Json; return }

	// Box-downscale so the longest side is at most ART_MAX pixels.
	ART_MAX :: 64
	scale := max(f64(img.width) / ART_MAX, f64(img.height) / ART_MAX, 1)
	ow, oh := max(int(f64(img.width) / scale), 1), max(int(f64(img.height) / scale), 1)
	out := make([]u8, ow * oh * 3)
	bpc := img.depth > 8 ? 2 : 1 // bytes per channel
	ch := img.channels
	px := img.pixels.buf[:]
	sum: [3]f64
	weight: f64
	for oy in 0 ..< oh {
		for ox in 0 ..< ow {
			x0, x1 := int(f64(ox) * scale), max(int(f64(ox + 1) * scale), int(f64(ox) * scale) + 1)
			y0, y1 := int(f64(oy) * scale), max(int(f64(oy + 1) * scale), int(f64(oy) * scale) + 1)
			acc: [3]f64
			n := 0
			for yy in y0 ..< min(y1, img.height) {
				for xx in x0 ..< min(x1, img.width) {
					o := (yy * img.width + xx) * ch * bpc
					if o + (ch - 1) * bpc >= len(px) { continue }
					if ch >= 3 {
						acc += {f64(px[o]), f64(px[o + bpc]), f64(px[o + 2 * bpc])}
					} else {
						v := f64(px[o])
						acc += {v, v, v}
					}
					n += 1
				}
			}
			if n == 0 { continue }
			c := acc / f64(n)
			i := (oy * ow + ox) * 3
			out[i], out[i + 1], out[i + 2] = u8(c.r), u8(c.g), u8(c.b)
			// Weight by saturation so a mostly-grey cover still yields its accent.
			hi, lo := max(c.r, c.g, c.b), min(c.r, c.g, c.b)
			w := (hi - lo) * (hi - lo) + 1
			sum += c * w
			weight += w
		}
	}
	dom := sum / max(weight, 1)
	hi := max(dom.r, dom.g, dom.b, 1)
	boost := hi < 170 ? 170 / hi : 1 // keep the tint bright enough to glow
	r.art = {w = ow, h = oh, rgb = out, dominant = {u8(min(dom.r * boost, 255)), u8(min(dom.g * boost, 255)), u8(min(dom.b * boost, 255))}}
}
