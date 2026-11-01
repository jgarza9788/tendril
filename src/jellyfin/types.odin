package jellyfin

// One configured Jellyfin server. `token` is the access token from login;
// the password is never stored.
Server :: struct {
	id:        string, // stable local id, used to tag items
	name:      string,
	url:       string, // e.g. https://jelly.example.com (no trailing slash)
	user:      string,
	user_id:   string,
	token:     string,
	device_id: string,
}

User_Data :: struct {
	is_favorite: bool `json:"IsFavorite"`,
}

// A music item as Jellyfin returns it from /Items: artist, album, playlist or track.
Item :: struct {
	id:           string `json:"Id"`,
	name:         string `json:"Name"`,
	type:         string `json:"Type"`,
	album:        string `json:"Album"`,
	album_id:     string `json:"AlbumId"`,
	album_artist: string `json:"AlbumArtist"`,
	artists:      []string `json:"Artists"`,
	run_ticks:    i64 `json:"RunTimeTicks"`,
	index:        int `json:"IndexNumber"`,
	disc:         int `json:"ParentIndexNumber"`,
	year:         int `json:"ProductionYear"`,
	child_count:  int `json:"ChildCount"`,
	song_count:   int `json:"SongCount"`,
	album_count:  int `json:"AlbumCount"`,
	user_data:    User_Data `json:"UserData"`,
}

Items_Response :: struct {
	items: []Item `json:"Items"`,
	total: int `json:"TotalRecordCount"`,
	start: int `json:"StartIndex"`,
}

User :: struct {
	id:   string `json:"Id"`,
	name: string `json:"Name"`,
}

Auth_Response :: struct {
	token:     string `json:"AccessToken"`,
	server_id: string `json:"ServerId"`,
	user:      User `json:"User"`,
}

// Jellyfin stores durations in 100 ns ticks.
seconds :: proc(it: Item) -> f64 {
	return f64(it.run_ticks) / 10_000_000.0
}

// One line of lyrics. `start` is in 100 ns ticks; it is 0 for every line of unsynced lyrics.
Lyric_Line :: struct {
	start: i64 `json:"Start"`,
	text:  string `json:"Text"`,
}

Lyrics_Response :: struct {
	lyrics: []Lyric_Line `json:"Lyrics"`,
}

// Playback events reported to the server (what makes play counts update).
Report_Event :: enum { Start, Progress, Stop }
