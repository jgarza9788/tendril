package jellyfin

import "core:encoding/json"
import "core:fmt"
import "core:strings"

PAGE_SIZE :: 200

Kind :: enum { Artist, Album, Playlist, Track }

@(private)
get_json :: proc(s: Server, path: string, out: ^$T) -> Error {
	resp, err := request(s, "GET", path)
	defer delete(resp.body)
	if err != .None { return err }
	if json.unmarshal(resp.body, out) != nil { return .Bad_Json }
	return .None
}

// Logs in with a password and returns a Server carrying the access token.
authenticate :: proc(s: Server, password: string) -> (out: Server, err: Error) {
	body := fmt.tprintf(`{{"Username":"%s","Pw":"%s"}}`, json_escape(s.user), json_escape(password))
	resp, rerr := request(s, "POST", "/Users/AuthenticateByName", body)
	defer delete(resp.body)
	if rerr != .None { return s, rerr }
	auth: Auth_Response
	if json.unmarshal(resp.body, &auth) != nil { return s, .Bad_Json }
	out = s
	out.token = strings.clone(auth.token)
	out.user_id = strings.clone(auth.user.id)
	return
}

@(private)
json_escape :: proc(v: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in v {
		switch c {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case '\r': strings.write_string(&b, `\r`)
		case '\t': strings.write_string(&b, `\t`)
		case:      strings.write_rune(&b, c)
		}
	}
	return strings.to_string(b)
}

// Percent-encode a query value.
@(private)
q :: proc(v: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]byte)v {
		switch c {
		case 'a'..='z', 'A'..='Z', '0'..='9', '-', '_', '.', '~':
			strings.write_byte(&b, c)
		case:
			fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	return strings.to_string(b)
}

// Artists that have albums (the "Album Artists" a music library shows).
artists :: proc(s: Server, start := 0, limit := PAGE_SIZE, search := "", name_from := "") -> (r: Items_Response, err: Error) {
	path := fmt.tprintf("/Artists/AlbumArtists?userId=%s&SortBy=SortName&StartIndex=%d&Limit=%d&Fields=ChildCount", s.user_id, start, limit)
	if search != "" { path = fmt.tprintf("%s&SearchTerm=%s", path, q(search)) }
	if name_from != "" { path = fmt.tprintf("%s&NameStartsWithOrGreater=%s", path, q(name_from)) }
	err = get_json(s, path, &r)
	return
}

albums :: proc(s: Server, artist_id := "", start := 0, limit := PAGE_SIZE, search := "", name_from := "") -> (r: Items_Response, err: Error) {
	path := fmt.tprintf("/Items?userId=%s&IncludeItemTypes=MusicAlbum&Recursive=true&SortBy=SortName&StartIndex=%d&Limit=%d", s.user_id, start, limit)
	if artist_id != "" { path = fmt.tprintf("%s&AlbumArtistIds=%s", path, q(artist_id)) }
	if search != "" { path = fmt.tprintf("%s&SearchTerm=%s", path, q(search)) }
	if name_from != "" { path = fmt.tprintf("%s&NameStartsWithOrGreater=%s", path, q(name_from)) }
	err = get_json(s, path, &r)
	return
}

playlists :: proc(s: Server, start := 0, limit := PAGE_SIZE, name_from := "", search := "") -> (r: Items_Response, err: Error) {
	path := fmt.tprintf("/Items?userId=%s&IncludeItemTypes=Playlist&Recursive=true&SortBy=SortName&StartIndex=%d&Limit=%d", s.user_id, start, limit)
	if name_from != "" { path = fmt.tprintf("%s&NameStartsWithOrGreater=%s", path, q(name_from)) }
	if search != "" { path = fmt.tprintf("%s&SearchTerm=%s", path, q(search)) }
	err = get_json(s, path, &r)
	return
}

album_tracks :: proc(s: Server, album_id: string) -> (r: Items_Response, err: Error) {
	path := fmt.tprintf("/Items?userId=%s&ParentId=%s&IncludeItemTypes=Audio&SortBy=ParentIndexNumber,IndexNumber,SortName", s.user_id, q(album_id))
	err = get_json(s, path, &r)
	return
}

playlist_tracks :: proc(s: Server, playlist_id: string) -> (r: Items_Response, err: Error) {
	path := fmt.tprintf("/Playlists/%s/Items?userId=%s", q(playlist_id), s.user_id)
	err = get_json(s, path, &r)
	return
}

search_tracks :: proc(s: Server, term: string, limit := 50) -> (r: Items_Response, err: Error) {
	path := fmt.tprintf("/Items?userId=%s&IncludeItemTypes=Audio&Recursive=true&SearchTerm=%s&Limit=%d", s.user_id, q(term), limit)
	err = get_json(s, path, &r)
	return
}

// Path (and query) of the audio stream for a track. `universal` lets the server
// direct-play when it can and transcode to MP3 otherwise. It carries no credentials:
// newer servers reject the `api_key` query parameter, so send auth_header(server) as
// an Authorization header.
stream_path :: proc(s: Server, track_id: string, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"/Audio/%s/universal?UserId=%s&DeviceId=%s&Container=opus,mp3,aac,m4a,flac,ogg,wav&TranscodingContainer=mp3&TranscodingProtocol=http&AudioCodec=mp3&MaxStreamingBitrate=140000000",
		q(track_id), s.user_id, s.device_id, allocator = allocator,
	)
}

// The URL mpv should open.
stream_url :: proc(s: Server, track_id: string, allocator := context.allocator) -> string {
	path := stream_path(s, track_id, context.temp_allocator)
	return fmt.aprintf("%s%s", s.url, path, allocator = allocator)
}

// Asks the server for the first byte of a track, to find out why playback failed.
// Returns the HTTP status (0 if the server could not be reached).
probe_stream :: proc(s: Server, track_id: string) -> (status: int, err: Error) {
	path := stream_path(s, track_id, context.temp_allocator)
	resp: Response
	resp, err = request(s, "GET", path, probe = true)
	delete(resp.body)
	return resp.status, err
}

image_url :: proc(s: Server, item_id: string, max_width := 400, allocator := context.allocator) -> string {
	return fmt.aprintf("%s/Items/%s/Images/Primary?maxWidth=%d", s.url, q(item_id), max_width, allocator = allocator)
}

// Raw cover image bytes (PNG preferred; some servers answer with JPEG).
image :: proc(s: Server, item_id: string, max_width := 256, allocator := context.allocator) -> (data: []byte, err: Error) {
	path := fmt.tprintf("/Items/%s/Images/Primary?maxWidth=%d&format=Png", q(item_id), max_width)
	resp: Response
	resp, err = request(s, "GET", path, allocator = allocator)
	if err != .None {
		delete(resp.body, allocator)
		return nil, err
	}
	return resp.body, .None
}

// Everything the user has marked as a favourite: tracks, albums, artists, playlists.
favourites :: proc(s: Server, start := 0, limit := PAGE_SIZE, name_from := "") -> (r: Items_Response, err: Error) {
	path := fmt.tprintf("/Items?userId=%s&Filters=IsFavorite&IncludeItemTypes=Audio,MusicAlbum,MusicArtist,Playlist&Recursive=true&SortBy=SortName&StartIndex=%d&Limit=%d", s.user_id, start, limit)
	if name_from != "" { path = fmt.tprintf("%s&NameStartsWithOrGreater=%s", path, q(name_from)) }
	err = get_json(s, path, &r)
	return
}

set_favorite :: proc(s: Server, item_id: string, on: bool) -> Error {
	path := fmt.tprintf("/Users/%s/FavoriteItems/%s", s.user_id, q(item_id))
	resp, err := request(s, on ? "POST" : "DELETE", path)
	delete(resp.body)
	return err
}

// Tells the server what is playing. Position is in 100 ns ticks.
report :: proc(s: Server, event: Report_Event, item_id: string, ticks: i64, paused: bool) -> Error {
	path: string
	switch event {
	case .Start:    path = "/Sessions/Playing"
	case .Progress: path = "/Sessions/Playing/Progress"
	case .Stop:     path = "/Sessions/Playing/Stopped"
	}
	id := json_escape(item_id)
	body := fmt.tprintf(`{{"ItemId":"%s","MediaSourceId":"%s","PositionTicks":%d,"IsPaused":%v,"CanSeek":true,"PlayMethod":"DirectPlay"}}`, id, id, ticks, paused)
	resp, err := request(s, "POST", path, body)
	delete(resp.body)
	return err
}

// Creates a playlist on the server from track ids.
save_playlist :: proc(s: Server, name: string, ids: []string) -> Error {
	b := strings.builder_make(context.temp_allocator)
	for id, i in ids {
		if i > 0 { strings.write_byte(&b, ',') }
		fmt.sbprintf(&b, `"%s"`, json_escape(id))
	}
	body := fmt.tprintf(`{{"Name":"%s","Ids":[%s],"UserId":"%s","MediaType":"Audio"}}`, json_escape(name), strings.to_string(b), s.user_id)
	resp, err := request(s, "POST", "/Playlists", body)
	delete(resp.body)
	return err
}

// Lyrics for a track (404 when it has none, which comes back as `.Http`).
lyrics :: proc(s: Server, track_id: string) -> (r: Lyrics_Response, err: Error) {
	err = get_json(s, fmt.tprintf("/Audio/%s/Lyrics", q(track_id)), &r)
	return
}
