package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:mem"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "core:unicode"
import hnoss "../libs/hnoss"
import "../libs/hnoss/backend"
import "../libs/hnoss/buffer"
import "../libs/hnoss/input"
import "../libs/hnoss/layout"
import "../libs/hnoss/style"
import "jellyfin"
import "player"

// Build with -define:TENDRIL_TRACK=true to print leaked allocations at exit.
TRACK :: #config(TENDRIL_TRACK, false)
Tracker :: mem.Tracking_Allocator

VERSION :: #config(TENDRIL_VERSION, "dev")

USAGE :: `tendril: a Jellyfin music player for the terminal

usage: tendril [--version | --help]

Needs mpv and curl on the PATH. On first run it asks for a server URL, username and
password. Press ? inside for the key list.

  servers + login tokens   ~/.config/tendril/servers.json   (private, mode 0600)
  settings + key bindings  ~/.config/tendril/config.json    (optional)
  last queue               ~/.local/state/tendril/session.json
`

main :: proc() {
	if len(os.args) > 1 {
		switch os.args[1] {
		case "--version", "-V", "version": fmt.println("tendril", VERSION); return
		case "--help", "-h", "help":       fmt.print(USAGE); return
		case:
			fmt.eprintfln("tendril: unknown option %q (try --help)", os.args[1])
			os.exit(2)
		}
	}
	context.assertion_failure_proc = backend.assertion_failure_proc

	when TRACK {
		track: Tracker
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			for _, leak in track.allocation_map {
				fmt.eprintfln("LEAK %v bytes at %v", leak.size, leak.location)
			}
			for bad in track.bad_free_array {
				fmt.eprintfln("BAD FREE at %v", bad.location)
			}
			fmt.eprintfln("tracking: %d leaks, %d bad frees", len(track.allocation_map), len(track.bad_free_array))
			mem.tracking_allocator_destroy(&track)
		}
	}
	worker_allocator = context.allocator

	app: App
	app_init(&app)
	defer {
		when TRACK { fmt.eprintfln("gapless: %d tracks rolled over inside mpv, %d explicit loads", app.gapless_hits, app.reloads) }
		app_destroy(&app)
	}

	term, err := hnoss.init(hnoss.DEFAULT_OPTIONS + {.Mouse_Capture})
	if err != .None {
		fmt.eprintfln("tendril: terminal init failed: %v", err)
		os.exit(1)
	}
	defer hnoss.deinit(&term)

	last := time.tick_now()
	events: []hnoss.Event
	if len(app.servers) == 0 { open_login_dialog(&app) }

	loop: for {
		now := time.tick_now()
		dt := time.duration_seconds(time.tick_diff(last, now))
		last = now
		update(&app, dt)
		if app.quit { break loop }

		f := hnoss.begin_frame(&term)
		// the focused border breathes with the bass
		accent := style.lerp_rgb(GLOW[1], FOAM, clamp(app.spec.bass, 0, 1) * 0.45)
		ui := hnoss.ui(f, events, tendril_theme(accent))
		draw(&app, ui, f)
		if !handle_keys(&app, ui) { break loop }
		hnoss.end_frame(&term)
		free_all(context.temp_allocator)
		events = hnoss.poll_events(&term, 16)
		if term.error != .None { break }
	}
}

// Keys no widget claimed. Returns false to quit.
handle_keys :: proc(app: ^App, ui: ^hnoss.Ui) -> bool {
	v := current_view(app)
	for ev in hnoss.unhandled(ui) {
		if app.jump_pending {
			// `g` was pressed: this key is the letter to jump to (anything else cancels).
			app.jump_pending = false
			if k, ok := ev.(input.Key); ok && k.code == .Char && (unicode.is_letter(k.char) || unicode.is_digit(k.char)) {
				jump_to_letter(app, k.char)
			}
			continue
		}
		queue_focused := hnoss.focused(ui, &app.queue_list)
		switch action_for(app.binds[:], ev) {
		case .None:
		case .Quit:         return false
		case .Play_Pause:   toggle_playback(app)
		case .Next:         skip_next(app)
		case .Prev:         skip_prev(app)
		case .Shuffle:      player.queue_toggle_shuffle(&app.q); preload_clear(app)
		case .Repeat:       player.queue_cycle_repeat(&app.q); preload_clear(app)
		case .Vol_Up:       if app.have_mpv { player.set_volume(&app.pl, app.pl.state.volume + 5) }
		case .Vol_Down:     if app.have_mpv { player.set_volume(&app.pl, app.pl.state.volume - 5) }
		case .Seek_Fwd:     if app.have_mpv { player.seek_by(&app.pl, 10) }
		case .Seek_Back:    if app.have_mpv { player.seek_by(&app.pl, -10) }
		case .Tab_1:        set_tab(app, 0)
		case .Tab_2:        set_tab(app, 1)
		case .Tab_3:        set_tab(app, 2)
		case .Tab_4, .Search:
			set_tab(app, 3)
			app.lyrics_open = false
			app.center = .Browse
			hnoss.focus(ui, &app.search)
		case .Tab_5:        set_tab(app, 4)
		case .Tab_Next:     set_tab(app, (app.tab + 1) % len(TAB_TITLES))
		case .Tab_Prev:     set_tab(app, (app.tab + len(TAB_TITLES) - 1) % len(TAB_TITLES))
		case .Add_Server:   open_login_dialog(app)
		case .Remove_Server: remove_server(app, app.servers_list.selected)
		case .Queue_Add:    if v != nil { enqueue_selected(app, v, v.list.selected) }
		case .Play_Next:    if v != nil { play_next_selected(app, v, v.list.selected) }
		case .Queue_Remove: if queue_focused { queue_remove_selected(app) }
		case .Queue_Up:     if queue_focused { queue_move_selected(app, -1) }
		case .Queue_Down:   if queue_focused { queue_move_selected(app, 1) }
		case .Queue_Clear:  queue_clear_all(app)
		case .Save_Playlist: open_save_dialog(app)
		case .Favorite:     if v != nil { toggle_favorite_entry(app, v, v.list.selected) }
		case .Favorite_Current: toggle_favorite_current(app)
		case .Lyrics:       app.lyrics_open = !app.lyrics_open
		case .Retry:        retry(app)
		case .Help:         app.help_open = true
		case .Theme_Next:   next_theme(app)
		case .Jump:
			app.jump_pending = true
			toast(app, "Jump to letter: press a letter or digit (any other key cancels)", 4)
		case .View_Cycle:
			if layout_mode(ui.area.width) == .Wide {
				toast(app, "The side panes are already visible at this width", 3)
			} else {
				app.lyrics_open = false
				app.center = Center_Mode((int(app.center) + 1) % len(Center_Mode))
				if layout_mode(ui.area.width) == .Medium && app.center == .Now_Playing { app.center = .Browse }
			}
		case .Back:
			switch {
			case app.lyrics_open: app.lyrics_open = false
			case app.center != .Browse: app.center = .Browse
			case len(app.stack) > 1: pop_view(app)
			case v != nil && hnoss.is_key(ev, .Esc): hnoss.focus(ui, &v.list) // leave the search box so the number keys work again
			}
		}
	}
	return true
}

clicked :: proc(ui: ^hnoss.Ui, r: hnoss.Rect) -> bool {
	for ev in ui.events {
		if m, ok := ev.(input.Mouse); ok && m.kind == .Press && m.button == .Left && layout.rect_contains(r, m.x, m.y) {
			return true
		}
	}
	return false
}

fmt_time :: proc(s: f64) -> string {
	n := int(max(s, 0))
	return fmt.tprintf("%d:%02d", n / 60, n % 60)
}

// --- drawing ------------------------------------------------------------------

draw :: proc(app: ^App, ui: ^hnoss.Ui, f: ^hnoss.Frame) {
	area := f.area
	buffer.fill(f.buffer, area, style.Style{bg = ABYSS})

	header := hnoss.cut_top(&area, 1)
	transport := hnoss.cut_bottom(&area, 4)
	hints: hnoss.Rect
	if f.area.height >= 14 { hints = hnoss.cut_bottom(&area, 1) }

	draw_header(app, ui, header)
	if hints.height > 0 {
		if app.now < app.toast_until {
			hnoss.label(ui, hints, fmt.tprintf("[#ff3dd8]%s[/]", escape(app.toast)), .Center)
		} else {
			hnoss.label(ui, hints, hint_line(app), .Center)
		}
	}

	mode := layout_mode(f.area.width)
	wide := mode == .Wide
	v := current_view(app)

	// Which panes are on screen decides what Tab can focus.
	show_browser := (wide || app.center == .Browse) && !app.lyrics_open
	show_servers := wide || (app.center == .Servers && !app.lyrics_open)
	show_queue   := wide || (app.center == .Queue && !app.lyrics_open)
	if !app.dlg_open && !app.help_open && !app.save_open {
		order := make([dynamic]rawptr, context.temp_allocator)
		// first, so it wins: while lyrics are open no list behind them should look focused
		if app.lyrics_open { append(&order, &app.lyric_scroll) }
		if v != nil && show_browser {
			if v.kind == .Search && len(app.stack) == 1 { append(&order, &app.search) }
			append(&order, &v.list)
		}
		if show_servers { append(&order, &app.servers_list) }
		if show_queue { append(&order, &app.queue_list) }
		hnoss.focus_order(ui, order[:])
	}

	switch mode {
	case .Wide:
		cols := hnoss.split(area, .Horizontal, {hnoss.fill(3), hnoss.fill(5), hnoss.fill(3)}, gap = 1)
		left := hnoss.split(cols[0], .Vertical, {hnoss.fill(2), hnoss.fill(3)})
		draw_servers(app, ui, left[0])
		draw_queue(app, ui, left[1])
		draw_center(app, ui, cols[1])
		draw_now_playing(app, ui, cols[2])
	case .Medium:
		cols := hnoss.split(area, .Horizontal, {hnoss.fill(5), hnoss.fill(3)}, gap = 1)
		draw_center(app, ui, cols[0])
		draw_now_playing(app, ui, cols[1])
	case .Narrow:
		draw_center(app, ui, area)
	}
	draw_transport(app, ui, transport)
	if app.dlg_open { draw_dialog(app, ui, f) }
	if app.save_open { draw_save_dialog(app, ui, f) }
	if app.help_open { draw_help(app, ui, f) }
}

// The middle pane: the browser, or (on small terminals) whatever `v` selected.
draw_center :: proc(app: ^App, ui: ^hnoss.Ui, r: hnoss.Rect) {
	wide := layout_mode(ui.area.width) == .Wide
	switch {
	case app.lyrics_open:                draw_lyrics(app, ui, r)
	case wide || app.center == .Browse:  draw_browser(app, ui, r)
	case app.center == .Queue:           draw_queue(app, ui, r)
	case app.center == .Servers:         draw_servers(app, ui, r)
	case app.center == .Now_Playing:     draw_now_playing(app, ui, r)
	}
}

// The hint bar, built from the current key bindings.
hint_line :: proc(app: ^App) -> string {
	k :: proc(app: ^App, a: Action) -> string { return fmt.tprintf("[#6b7aa8]%s[/]", key_label(app.binds[:], a)) }
	return fmt.tprintf("%s play  %s skip  %s shuffle  %s repeat  %s queue  %s fav  %s lyrics  %s back  %s help  %s quit",
		k(app, .Play_Pause), k(app, .Next), k(app, .Shuffle), k(app, .Repeat), k(app, .Queue_Add),
		k(app, .Favorite), k(app, .Lyrics), k(app, .Back), k(app, .Help), k(app, .Quit))
}

draw_header :: proc(app: ^App, ui: ^hnoss.Ui, r: hnoss.Rect) {
	logo := "tendril"
	for ch, i in logo {
		phase := math.mod(app.now * 0.35 + f64(i) * 0.09, 1.0)
		col := style.gradient(GLOW[:], 0.5 + 0.5 * math.sin(phase * math.TAU))
		buffer.set_symbol(ui.buf, r.x + 1 + i, r.y, fmt.tprintf("%c", ch), 1, style.Style{fg = col, add = {.Bold}})
	}
	sel := app.tab
	// "1. Artists" etc.: the number is the key that jumps to the tab.
	labels: [len(TAB_TITLES)]string
	narrow := r.width < 90
	for t, i in TAB_TITLES {
		// on a narrow terminal only the current tab keeps its name
		labels[i] = narrow && i != app.tab ? fmt.tprintf("%d", i + 1) : fmt.tprintf("%d. %s", i + 1, t)
	}
	if hnoss.tabs(ui, {r.x + 12, r.y, max(r.width - 12, 0), 1}, labels[:], &sel) {
		set_tab(app, sel)
	}
}

draw_servers :: proc(app: ^App, ui: ^hnoss.Ui, r: hnoss.Rect) {
	inner := hnoss.box(ui, r, "[b]Servers[/]", {focused = hnoss.focused(ui, &app.servers_list)})
	if len(app.servers) == 0 {
		hnoss.label(ui, inner, "[#6b7aa8]None yet.\nPress [b #2df0ff]N[/] to add one.[/]")
		return
	}
	names := make([]string, len(app.servers), context.temp_allocator)
	for s, i in app.servers {
		glyph: string
		switch app.conn[i] {
		case .Online:     glyph = "[#19d3b0]●[/]"
		case .Connecting: glyph = spinner(app.now)
		case .Failed:     glyph = "[#ff3dd8]✖[/]"
		case .Expired:    glyph = "[#ffcc4d]![/]"
		}
		names[i] = fmt.tprintf("%s %s", glyph, s.name)
	}
	hnoss.list(ui, inner, names[:], &app.servers_list, {markup = true})
	if app.servers_list.activated && app.conn[app.servers_list.selected] == .Expired {
		s := app.servers[app.servers_list.selected]
		open_login_dialog(app, s.url, s.user)
	}
}

spinner :: proc(t: f64) -> string {
	frames := [?]string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
	return fmt.tprintf("[#2df0ff]%s[/]", frames[int(t * 12) % len(frames)])
}

draw_queue :: proc(app: ^App, ui: ^hnoss.Ui, r: hnoss.Rect) {
	n := len(app.q.order)
	title := n > 0 ? fmt.tprintf("[b]Queue[/] [#6b7aa8]%d[/]", n) : "[b]Queue[/]"
	inner := hnoss.box(ui, r, title, {focused = hnoss.focused(ui, &app.queue_list)})
	if n == 0 {
		hnoss.label(ui, inner, "[#6b7aa8]Empty. Play something, or press [b #2df0ff]a[/] to add.[/]")
		return
	}
	rows := make([]string, n, context.temp_allocator)
	for idx, p in app.q.order {
		t := app.q.tracks[idx]
		mark := p == app.q.pos ? "♪ " : "  "
		heart := t.favorite ? " ♥" : ""
		rows[p] = fmt.tprintf("%s%s — %s%s", mark, t.title, t.artist, heart)
	}
	hnoss.list(ui, inner, rows, &app.queue_list, {scrollbar = true})
	if app.queue_list.activated {
		app.q.pos = app.queue_list.selected
		play_current(app)
	}
}

entry_label :: proc(app: ^App, e: Entry, show_type := false) -> string {
	badge := ""
	if len(app.servers) > 1 { badge = fmt.tprintf("   ‹%s›", app.servers[e.server].name) }
	heart := e.user_data.is_favorite ? "♥ " : ""
	kind := ""
	if show_type {
		switch e.type {
		case "MusicArtist": kind = "   · artist"
		case "MusicAlbum":  kind = "   · album"
		case "Playlist":    kind = "   · playlist"
		case "Audio":       kind = "   · track"
		}
	}
	switch e.type {
	case "MusicArtist":
		return fmt.tprintf("%s%s%s%s", heart, e.name, kind, badge)
	case "MusicAlbum":
		year := e.year > 0 ? fmt.tprintf(" (%d)", e.year) : ""
		return fmt.tprintf("%s%s  ·  %s%s%s%s", heart, e.name, e.album_artist, year, kind, badge)
	case "Playlist":
		return fmt.tprintf("%s%s  ·  %d tracks%s%s", heart, e.name, e.child_count, kind, badge)
	case "Audio":
		artist := e.album_artist
		if len(e.artists) > 0 { artist = e.artists[0] }
		num := e.index > 0 ? fmt.tprintf("%2d", e.index) : "  "
		return fmt.tprintf("%s%s  %s  ·  %s   %s%s%s", heart, num, e.name, artist, fmt_time(jellyfin.seconds(e.item)), kind, badge)
	}
	return e.name
}

draw_browser :: proc(app: ^App, ui: ^hnoss.Ui, r: hnoss.Rect) {
	v := current_view(app)
	crumbs := strings.builder_make(context.temp_allocator)
	for sv, i in app.stack {
		if i > 0 { strings.write_string(&crumbs, " › ") }
		strings.write_string(&crumbs, sv.title)
	}
	inner := hnoss.box(ui, r, fmt.tprintf("[b]%s[/]", strings.to_string(crumbs)), {focused = v != nil && hnoss.focused(ui, &v.list)})
	if v == nil { return }
	if v.id != app.last_view_id {
		app.last_view_id = v.id
		app.fade_start = app.now
	}

	if len(app.servers) == 0 {
		hnoss.label(ui, hnoss.center(inner, min(inner.width, 44), 3), "[b #e6f1ff]Welcome to tendril[/]\n[#6b7aa8]Press [b #2df0ff]N[/] to connect a Jellyfin server[/]", .Center)
		return
	}
	body := inner
	if v.kind == .Search && len(app.stack) == 1 {
		row := hnoss.cut_top(&body, 1)
		hnoss.cut_top(&body, 1)
		hnoss.label(ui, {row.x, row.y, 2, 1}, "[#2df0ff]/ [/]")
		hnoss.input(ui, {row.x + 2, row.y, max(row.width - 2, 0), 1}, &app.search, {placeholder = "search artists, albums, playlists and tracks, then Enter"})
		if app.search.submitted { submit_search(app) }
		if len(v.entries) == 0 { return }
	}
	loaded, total := page_totals(v)
	switch {
	case v.pending > 0 && v.paged && total > 0:
		hnoss.label(ui, hnoss.cut_top(&body, 1), fmt.tprintf("%s [#6b7aa8]loading… %d of %d[/]", spinner(app.now), loaded, total))
	case v.pending > 0:
		hnoss.label(ui, hnoss.cut_top(&body, 1), fmt.tprintf("%s [#6b7aa8]loading…[/]", spinner(app.now)))
	case v.paged && total > loaded:
		hnoss.label(ui, hnoss.cut_top(&body, 1), fmt.tprintf("[#6b7aa8]%d of %d loaded · scroll for more · g+letter to jump[/]", loaded, total))
	}
	if len(v.entries) == 0 {
		if v.pending == 0 {
			msg := v.errors > 0 ? "[#ff3dd8]Couldn't reach the server.[/] [#6b7aa8]Press R to retry, or check the Servers list.[/]" : "[#6b7aa8]Nothing here.[/]"
			hnoss.label(ui, body, msg)
		}
		return
	}
	labels := make([]string, len(v.entries), context.temp_allocator)
	show_type := v.grouped || v.kind == .Favourites
	for e, i in v.entries { labels[i] = entry_label(app, e, show_type) }
	hnoss.list(ui, body, labels, &v.list, {scrollbar = true})
	if v.list.activated { activate(app, v, v.list.selected) }
	load_more_if_needed(app, v)
	fade_region(ui.buf, body, clamp((app.now - app.fade_start) * 5, 0, 1))
}

draw_now_playing :: proc(app: ^App, ui: ^hnoss.Ui, r: hnoss.Rect) {
	t, has := player.queue_current(&app.q)
	playing := app.have_mpv && has && app.started && !app.pl.state.paused && !app.pl.state.idle
	inner := hnoss.box(ui, r, "[b]Now Playing[/]", {focused = playing})
	rows := hnoss.split(inner, .Vertical, {hnoss.fill(5), hnoss.fill(3), hnoss.fill(2)})

	// Album art: the real cover when we have it, cross-faded in over a drifting
	// plasma placeholder (which is all you see until the cover arrives).
	// A cell is about twice as tall as wide, so a square is 2N cells wide by N tall.
	side := min(rows[0].width / 2, rows[0].height)
	art := hnoss.center(rows[0], side * 2, side)
	energy := playing ? 1.0 : 0.25
	tt := app.now * energy
	cover, have_cover := current_art(app)
	fade := have_cover ? app.art_fade : 0
	for y in 0 ..< art.height {
		for x in 0 ..< art.width {
			a := math.sin(f64(x) * 0.35 + tt * 0.8) + math.sin(f64(y) * 0.7 - tt * 0.6)
			b := math.sin(f64(x + y * 2) * 0.2 + tt * 0.4)
			top := style.gradient(GLOW[:], 0.5 + 0.25 * a)
			bot := style.gradient(GLOW[:], 0.5 + 0.25 * b)
			if fade > 0 {
				u := (f64(x) + 0.5) / f64(art.width)
				vt := (f64(y * 2) + 0.5) / f64(art.height * 2)
				vb := (f64(y * 2) + 1.5) / f64(art.height * 2)
				top = style.lerp_rgb(top.(style.Rgb), sample_art(cover, u, vt), fade)
				bot = style.lerp_rgb(bot.(style.Rgb), sample_art(cover, u, vb), fade)
			}
			buffer.set_symbol(ui.buf, art.x + x, art.y + y, "▀", 1, style.Style{fg = top, bg = bot})
		}
	}

	if has && app.started {
		pos := fmt.tprintf("%d / %d", app.q.pos + 1, len(app.q.order))
		modes := fmt.tprintf("%s%s", app.q.shuffle ? "  shuffle" : "", app.q.repeat == .Off ? "" : (app.q.repeat == .One ? "  repeat one" : "  repeat all"))
		next_line := ""
		if app.q.pos + 1 < len(app.q.order) {
			n := app.q.tracks[app.q.order[app.q.pos + 1]]
			next_line = fmt.tprintf("\n\n[#6b7aa8]up next[/]\n[#e6f1ff]%s[/]", escape(n.title))
		}
		heart := t.favorite ? "[#ff3dd8]♥[/] " : ""
		hnoss.label(ui, rows[1], fmt.tprintf("[b #e6f1ff]%s%s[/]\n[#2df0ff]%s[/]\n[#6b7aa8]%s[/]\n[#6b7aa8]%s%s[/]%s", heart, escape(t.title), escape(t.artist), escape(t.album), pos, modes, next_line), .Center)
	} else {
		hnoss.label(ui, rows[1], "[#6b7aa8]Nothing playing[/]\n\n[#6b7aa8]Pick a track and press Enter[/]", .Center)
	}
	app.viz_n = rows[2].width
	draw_spectrum(app, ui, rows[2])
}

// Vertical bars with eighth-cell resolution, tinted along the live gradient.
draw_spectrum :: proc(app: ^App, ui: ^hnoss.Ui, r: hnoss.Rect) {
	if r.width <= 0 || r.height <= 0 { return }
	glyphs := [?]string{"▁", "▂", "▃", "▄", "▅", "▆", "▇"}
	for x in 0 ..< r.width {
		v := x < app.spec.n ? clamp(app.spec.bars[x], 0, 1) : 0
		h := v * f64(r.height * 8)
		col := style.gradient(GLOW[:], f64(x) / f64(max(r.width - 1, 1)))
		for row in 0 ..< r.height {
			base := f64(row * 8)
			if h <= base { break }
			y := r.y + r.height - 1 - row
			// brighter toward the tip of the bar
			c := style.lerp_rgb(col.(style.Rgb), FOAM, clamp(f64(row) / f64(max(r.height, 1)) * 0.35, 0, 0.35))
			if h >= base + 8 {
				buffer.set_symbol(ui.buf, r.x + x, y, "█", 1, style.Style{fg = c})
			} else {
				buffer.set_symbol(ui.buf, r.x + x, y, glyphs[clamp(int(h - base) - 1, 0, 6)], 1, style.Style{fg = c})
			}
		}
	}
}

// Blends the foreground and background of everything in `r` toward the page
// background: t = 0 is invisible, 1 is untouched. Used to fade views in.
fade_region :: proc(b: ^buffer.Buffer, r: hnoss.Rect, t: f64) {
	if t >= 1 { return }
	for y in r.y ..< r.y + r.height {
		for x in r.x ..< r.x + r.width {
			c := buffer.get(b, x, y)
			if c == nil { continue }
			if fg, ok := c.fg.(style.Rgb); ok { c.fg = style.lerp_rgb(ABYSS, fg, t) }
			if bg, ok := c.bg.(style.Rgb); ok { c.bg = style.lerp_rgb(ABYSS, bg, t) }
		}
	}
}

// Lyrics for the current track. Synced lyrics highlight the line being sung and
// scroll with it; unsynced ones are shown from the top.
draw_lyrics :: proc(app: ^App, ui: ^hnoss.Ui, r: hnoss.Rect) {
	inner := hnoss.box(ui, r, "[b]Lyrics[/]", {focused = true})
	lines := current_lyrics(app)
	key, has_key := current_track_key(app)
	switch {
	case !has_key:
		hnoss.label(ui, inner, "[#6b7aa8]Nothing playing.[/]")
		return
	case len(lines) == 0:
		pending := key in app.lyrics_pending
		hnoss.label(ui, hnoss.center(inner, min(inner.width, 40), 1), pending ? "[#6b7aa8]looking for lyrics…[/]" : "[#6b7aa8]No lyrics for this track.[/]", .Center)
		return
	}
	synced := lyrics_synced(lines)
	cur := synced ? current_lyric_index(lines, app.pl.state.position) : -1
	focus_row := int(math.round(app.lyric_scroll))
	mid := inner.height / 2
	for row in 0 ..< inner.height {
		idx := synced ? focus_row - mid + row : row
		if idx < 0 || idx >= len(lines) { continue }
		text := lines[idx].text
		if text == "" { continue }
		if synced && idx == cur { text = fmt.tprintf("♪  %s  ♪", text) }
		x := inner.x + max((inner.width - utf8.rune_count_in_string(text)) / 2, 0)
		col: style.Rgb
		bold := false
		switch {
		case !synced:    col = FOAM
		case idx == cur: col, bold = style.lerp_rgb(GLOW[1], FOAM, 0.2), true
		case:
			d := f64(abs(idx - max(cur, 0))) / 9 // before the first timestamp, fade from the top line
			col = style.lerp_rgb(FOAM, ABYSS, clamp(0.38 + d * 0.5, 0, 0.82))
		}
		buffer.set_string(ui.buf, x, inner.y + row, text, style.Style{fg = col, add = bold ? {.Bold} : {}}, inner.width)
	}
}

// Keeps '[' in titles from being read as markup.
escape :: proc(s: string) -> string {
	if !strings.contains(s, "[") { return s }
	r, _ := strings.replace_all(s, "[", "(", context.temp_allocator)
	return r
}

draw_transport :: proc(app: ^App, ui: ^hnoss.Ui, r: hnoss.Rect) {
	t, has := player.queue_current(&app.q)
	st := app.pl.state
	inner := hnoss.box(ui, r, "", {})
	rows := hnoss.split(inner, .Vertical, {hnoss.fill(), hnoss.fill()})

	// Controls, each with its own click target.
	Ctl :: enum { Shuffle, Prev, Play, Next, Repeat }
	paused := st.paused || st.idle
	glyphs := [Ctl]string{
		.Shuffle = "⇄", .Prev = "⏮", .Play = paused ? "▶" : "⏸", .Next = "⏭",
		.Repeat = app.q.repeat == .One ? "↻¹" : "↻",
	}
	total := 5 + 4 * 5 + 1
	x := rows[0].x + max((rows[0].width - total) / 2, 0)
	for c in Ctl {
		col: style.Rgb
		switch c {
		case .Shuffle: col = app.q.shuffle ? MAGENTA : MIST
		case .Repeat:  col = app.q.repeat != .Off ? MAGENTA : MIST
		case .Play:    col = GLOW[1]
		case .Prev, .Next: col = FOAM
		}
		pad := hnoss.Rect{x - 1, rows[0].y, 4, 1}
		hit := clicked(ui, pad)
		buffer.set_string(ui.buf, x, rows[0].y, glyphs[c], style.Style{fg = col, add = c == .Play ? {.Bold} : {}})
		if hit {
			switch c {
			case .Shuffle: player.queue_toggle_shuffle(&app.q)
			case .Repeat:  player.queue_cycle_repeat(&app.q)
			case .Prev:    skip_prev(app)
			case .Next:    skip_next(app)
			case .Play:
				toggle_playback(app)
			}
		}
		x += 6
	}
	vol := fmt.tprintf("vol %d%%", int(st.volume))
	buffer.set_string(ui.buf, rows[0].x + rows[0].width - len(vol) - 1, rows[0].y, vol, style.Style{fg = VIOLET})
	if has && app.started {
		info := fmt.tprintf("%s — %s", escape(t.title), escape(t.artist))
		buffer.set_string(ui.buf, rows[0].x + 1, rows[0].y, info, style.Style{fg = MIST}, max(rows[0].width / 3, 0))
	}

	// Seek bar.
	length := has && t.length > 0 ? t.length : st.duration
	label_l := fmt_time(st.position)
	label_r := fmt_time(length)
	bar := rows[1]
	hnoss.cut_left(&bar, 1)
	hnoss.cut_right(&bar, 1)
	left := hnoss.cut_left(&bar, len(label_l) + 1)
	right := hnoss.cut_right(&bar, len(label_r) + 1)
	hnoss.label(ui, left, fmt.tprintf("[#6b7aa8]%s[/]", label_l))
	hnoss.label(ui, right, fmt.tprintf("[#6b7aa8]%s[/]", label_r), .Right)
	if bar.width <= 0 { return }
	ratio := length > 0 ? clamp(st.position / length, 0, 1) : 0
	for ev in ui.events {
		if m, ok := ev.(input.Mouse); ok && m.kind == .Press && m.button == .Left && layout.rect_contains(bar, m.x, m.y) && length > 0 && app.have_mpv {
			player.seek_to(&app.pl, f64(m.x - bar.x) / f64(bar.width) * length)
		}
	}
	head := int(ratio * f64(bar.width))
	for bx in 0 ..< bar.width {
		u := f64(bx) / f64(max(bar.width - 1, 1))
		switch {
		case bx < head:
			buffer.set_symbol(ui.buf, bar.x + bx, bar.y, "━", 1, style.Style{fg = style.gradient(GLOW[:], u)})
		case bx == head && length > 0:
			pulse := 0.6 + 0.4 * math.sin(app.now * 6)
			buffer.set_symbol(ui.buf, bar.x + bx, bar.y, "●", 1, style.Style{fg = style.lerp_rgb(GLOW[1], FOAM, pulse), add = {.Bold}})
		case:
			buffer.set_symbol(ui.buf, bar.x + bx, bar.y, "─", 1, style.Style{fg = TRENCH})
		}
	}
}

draw_dialog :: proc(app: ^App, ui: ^hnoss.Ui, f: ^hnoss.Frame) {
	inner := hnoss.modal(ui, hnoss.center(f.area, 58, 15), &app.dlg_open, "[b]Connect to Jellyfin[/]")
	inner = hnoss.inset(inner, 1)
	field :: proc(ui: ^hnoss.Ui, r: ^hnoss.Rect, name: string, st: ^hnoss.Input_State, opts: hnoss.Input_Options) {
		hnoss.label(ui, hnoss.cut_top(r, 1), fmt.tprintf("[#6b7aa8]%s[/]", name))
		hnoss.input(ui, hnoss.cut_top(r, 1), st, opts)
		hnoss.cut_top(r, 1)
	}
	hnoss.focus_order(ui, {&app.in_url, &app.in_user, &app.in_pass})
	if app.dlg_focus_pending {
		app.dlg_focus_pending = false
		hnoss.focus(ui, len(hnoss.input_text(&app.in_url)) > 0 ? &app.in_pass : &app.in_url)
	}
	field(ui, &inner, "Server URL", &app.in_url, {placeholder = "https://jellyfin.example.com"})
	field(ui, &inner, "Username", &app.in_user, {})
	field(ui, &inner, "Password", &app.in_pass, {mask = "•"})
	if app.dlg_busy {
		hnoss.label(ui, hnoss.cut_top(&inner, 1), fmt.tprintf("%s [#6b7aa8]connecting…[/]", spinner(app.now)))
	} else {
		hnoss.label(ui, hnoss.cut_top(&inner, 1), "[#6b7aa8]Enter to connect · Tab next field · Esc cancel[/]")
	}
	if !app.dlg_busy && (app.in_pass.submitted || app.in_user.submitted || app.in_url.submitted) { submit_login(app) }
}

draw_save_dialog :: proc(app: ^App, ui: ^hnoss.Ui, f: ^hnoss.Frame) {
	inner := hnoss.modal(ui, hnoss.center(f.area, 56, 8), &app.save_open, "[b]Save the queue as a playlist[/]")
	inner = hnoss.inset(inner, 1)
	if app.save_focus_pending {
		app.save_focus_pending = false
		hnoss.focus(ui, &app.in_name)
	}
	hnoss.label(ui, hnoss.cut_top(&inner, 1), "[#6b7aa8]Playlist name[/]")
	hnoss.input(ui, hnoss.cut_top(&inner, 1), &app.in_name, {placeholder = "name"})
	hnoss.cut_top(&inner, 1)
	hnoss.label(ui, hnoss.cut_top(&inner, 1), fmt.tprintf("[#6b7aa8]%d tracks · Enter to save · Esc cancel[/]", len(app.q.order)))
	if app.in_name.submitted { submit_save_playlist(app) }
}

draw_help :: proc(app: ^App, ui: ^hnoss.Ui, f: ^hnoss.Frame) {
	inner := hnoss.modal(ui, hnoss.center(f.area, 70, 30), &app.help_open, "[b]Keys[/]")
	inner = hnoss.inset(inner, 1)
	k :: proc(app: ^App, a: Action) -> string { return fmt.tprintf("[#2df0ff]%s[/]", key_label(app.binds[:], a)) }
	hnoss.label(ui, inner, fmt.tprintf(
`[b #8b5cff]Playback[/]
  %s play / pause    %s %s next / previous    %s shuffle    %s repeat
  %s %s volume    %s %s seek 10s    %s favourite the playing track
  %s lyrics    %s theme

[b #8b5cff]Browsing[/]
  %s %s %s %s %s  tabs   %s %s  previous / next tab   %s search
  tab  change pane       %s  back (in the search box: back to the list)
  %s  add to queue       %s  play next        %s  favourite
  %s then a letter: jump       %s  reload / retry

[b #8b5cff]Queue (when its pane is focused)[/]
  %s  remove      %s %s  move up / down      %s  clear      %s  save as playlist

[b #8b5cff]Servers[/]
  %s  add       %s  remove the selected one       enter on a [#ffcc4d]![/] server: log in again

[b #8b5cff]Small terminals[/]
  %s  cycle the middle pane: browser, queue, servers, now playing

[#6b7aa8]Rebind any key in ~/.config/tendril/config.json.  The mouse works too.  esc closes this.[/]`,
		k(app, .Play_Pause), k(app, .Next), k(app, .Prev), k(app, .Shuffle), k(app, .Repeat),
		k(app, .Vol_Up), k(app, .Vol_Down), k(app, .Seek_Back), k(app, .Seek_Fwd), k(app, .Favorite_Current),
		k(app, .Lyrics), k(app, .Theme_Next),
		k(app, .Tab_1), k(app, .Tab_2), k(app, .Tab_3), k(app, .Tab_4), k(app, .Tab_5), k(app, .Tab_Prev), k(app, .Tab_Next), k(app, .Search),
		k(app, .Back),
		k(app, .Queue_Add), k(app, .Play_Next), k(app, .Favorite),
		k(app, .Jump), k(app, .Retry),
		k(app, .Queue_Remove), k(app, .Queue_Up), k(app, .Queue_Down), k(app, .Queue_Clear), k(app, .Save_Playlist),
		k(app, .Add_Server), k(app, .Remove_Server),
		k(app, .View_Cycle)))
}
