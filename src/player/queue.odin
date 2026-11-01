package player

import "core:math/rand"
import "core:strings"

Track :: struct {
	server_id: string,
	id:        string,
	title:     string,
	artist:    string,
	album:     string,
	album_id:  string,
	length:    f64, // seconds
	favorite:  bool,
}

Repeat :: enum { Off, All, One }

// The play queue. `order` maps play position to index in `tracks`, so shuffling
// never reorders what the user sees in the queue view.
Queue :: struct {
	tracks:  [dynamic]Track,
	order:   [dynamic]int,
	pos:     int, // index into `order`; -1 = nothing selected
	shuffle: bool,
	repeat:  Repeat,
}

queue_init :: proc(q: ^Queue) {
	q.pos = -1
}

// The queue owns the strings of every track in it: queue_add copies what it is
// given, and queue_clear / queue_destroy free those copies.
track_clone :: proc(t: Track) -> Track {
	return {
		server_id = strings.clone(t.server_id), id = strings.clone(t.id),
		title = strings.clone(t.title), artist = strings.clone(t.artist),
		album = strings.clone(t.album), album_id = strings.clone(t.album_id),
		length = t.length, favorite = t.favorite,
	}
}

track_free :: proc(t: Track) {
	delete(t.server_id); delete(t.id); delete(t.title)
	delete(t.artist); delete(t.album); delete(t.album_id)
}

queue_destroy :: proc(q: ^Queue) {
	for t in q.tracks { track_free(t) }
	delete(q.tracks)
	delete(q.order)
}

queue_clear :: proc(q: ^Queue) {
	for t in q.tracks { track_free(t) }
	clear(&q.tracks)
	clear(&q.order)
	q.pos = -1
}

// Appends copies of `tracks`. If nothing is selected yet, selects the first one.
queue_add :: proc(q: ^Queue, tracks: []Track) {
	for t in tracks {
		append(&q.tracks, track_clone(t))
		append(&q.order, len(q.tracks) - 1)
	}
	if q.shuffle { reshuffle_tail(q, max(q.pos + 1, 0)) }
	if q.pos < 0 && len(q.order) > 0 { q.pos = 0 }
}

// Replaces the queue and starts at `start`.
queue_set :: proc(q: ^Queue, tracks: []Track, start := 0) {
	queue_clear(q)
	queue_add(q, tracks)
	queue_jump(q, start)
}

// Jumps to the track at index `i` in `tracks` (not play position).
queue_jump :: proc(q: ^Queue, i: int) {
	if i < 0 || i >= len(q.tracks) { return }
	for idx, p in q.order {
		if idx == i {
			q.pos = p
			break
		}
	}
	if q.shuffle {
		// Keep the chosen track as the current one, shuffle everything after it.
		for idx, p in q.order {
			if idx == i {
				q.order[p], q.order[0] = q.order[0], q.order[p]
				break
			}
		}
		q.pos = 0
		reshuffle_tail(q, 1)
	}
}

queue_current :: proc(q: ^Queue) -> (t: Track, ok: bool) {
	if q.pos < 0 || q.pos >= len(q.order) { return {}, false }
	return q.tracks[q.order[q.pos]], true
}

// Advances. `auto` is true when the track ended by itself (Repeat.One replays
// it); a manual skip always moves on. Returns false at the end of the queue.
queue_next :: proc(q: ^Queue, auto := false) -> bool {
	if len(q.order) == 0 { return false }
	if auto && q.repeat == .One { return true }
	if q.pos + 1 < len(q.order) {
		q.pos += 1
		return true
	}
	if q.repeat == .All {
		if q.shuffle { reshuffle_tail(q, 0) }
		q.pos = 0
		return true
	}
	return false
}

queue_prev :: proc(q: ^Queue) -> bool {
	if len(q.order) == 0 { return false }
	if q.pos > 0 {
		q.pos -= 1
		return true
	}
	if q.repeat == .All {
		q.pos = len(q.order) - 1
		return true
	}
	return false
}

queue_toggle_shuffle :: proc(q: ^Queue) {
	q.shuffle = !q.shuffle
	if q.shuffle {
		cur := q.pos >= 0 ? q.order[q.pos] : -1
		if cur >= 0 {
			// Current track first, the rest shuffled.
			for idx, p in q.order {
				if idx == cur {
					q.order[p], q.order[0] = q.order[0], q.order[p]
					break
				}
			}
			q.pos = 0
			reshuffle_tail(q, 1)
		} else {
			reshuffle_tail(q, 0)
		}
	} else {
		cur := q.pos >= 0 ? q.order[q.pos] : -1
		for i in 0 ..< len(q.order) { q.order[i] = i }
		q.pos = cur >= 0 ? cur : (len(q.order) > 0 ? 0 : -1)
	}
}

queue_cycle_repeat :: proc(q: ^Queue) {
	q.repeat = Repeat((int(q.repeat) + 1) % len(Repeat))
}

@(private)
reshuffle_tail :: proc(q: ^Queue, from: int) {
	if from >= len(q.order) { return }
	rand.shuffle(q.order[from:])
}

// --- editing ----------------------------------------------------------------

// Removes the track at play position `p`. Returns true if it was the current one
// (the caller decides what to play next; `pos` then points at the track that
// followed it, or at the new last track, or -1 when the queue is empty).
queue_remove :: proc(q: ^Queue, p: int) -> (was_current: bool) {
	if p < 0 || p >= len(q.order) { return false }
	idx := q.order[p]
	track_free(q.tracks[idx])
	ordered_remove(&q.tracks, idx)
	ordered_remove(&q.order, p)
	for &o in q.order { if o > idx { o -= 1 } }
	switch {
	case p < q.pos:
		q.pos -= 1
	case p == q.pos:
		was_current = true
		if q.pos >= len(q.order) { q.pos = len(q.order) - 1 }
	}
	return
}

// Moves the track at play position `p` up (-1) or down (+1). Returns its new position.
queue_move :: proc(q: ^Queue, p, delta: int) -> int {
	np := p + delta
	if p < 0 || p >= len(q.order) || np < 0 || np >= len(q.order) { return p }
	q.order[p], q.order[np] = q.order[np], q.order[p]
	switch q.pos {
	case p:  q.pos = np
	case np: q.pos = p
	}
	return np
}

// Inserts copies of `tracks` right after the current track, in order.
queue_insert_next :: proc(q: ^Queue, tracks: []Track) {
	at := q.pos + 1
	for t in tracks {
		append(&q.tracks, track_clone(t))
		inject_at(&q.order, at, len(q.tracks) - 1)
		at += 1
	}
	if q.pos < 0 && len(q.order) > 0 { q.pos = 0 }
}

// The play position the queue would move to on its own at the end of the current
// track, if that is already known. False at the end of the queue, and with repeat
// one or a wrap-around (a reshuffle makes the next track unknowable in advance).
queue_peek_next :: proc(q: ^Queue) -> (pos: int, ok: bool) {
	if q.pos < 0 || q.repeat == .One || q.pos + 1 >= len(q.order) { return 0, false }
	return q.pos + 1, true
}

// Replaces the queue with a saved one. Falls back to the natural order if `order`
// is not a permutation of the tracks.
queue_restore :: proc(q: ^Queue, tracks: []Track, order: []int, pos: int, shuffle: bool, repeat: Repeat) {
	queue_clear(q)
	q.shuffle = false // add in natural order; the saved order is applied below
	queue_add(q, tracks)
	q.shuffle, q.repeat = shuffle, repeat
	if len(order) == len(tracks) {
		seen := make([]bool, len(tracks), context.temp_allocator)
		valid := true
		for o in order {
			if o < 0 || o >= len(tracks) || seen[o] { valid = false; break }
			seen[o] = true
		}
		if valid { copy(q.order[:], order) }
	}
	q.pos = len(tracks) == 0 ? -1 : clamp(pos, 0, len(tracks) - 1)
}
