package tests

import "core:encoding/json"
import "core:mem/virtual"
import "core:testing"
import jf "../src/jellyfin"

ALBUMS_JSON :: `{"Items":[{"Id":"a1","Name":"Medusa","Type":"MusicAlbum","AlbumArtist":"Cnidaria","ProductionYear":2024,"ChildCount":9,"Extra":"ignored"},{"Id":"a2","Name":"Pressure","Type":"MusicAlbum","AlbumArtist":"Hadal","Artists":["Hadal","Guest"],"RunTimeTicks":2130000000}],"TotalRecordCount":2,"StartIndex":0}`

@(test)
parse_items :: proc(t: ^testing.T) {
	arena: virtual.Arena // everything unmarshal allocates goes here and is freed at once
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	r: jf.Items_Response
	err := json.unmarshal_string(ALBUMS_JSON, &r, allocator = virtual.arena_allocator(&arena))
	testing.expect_value(t, err, nil)
	testing.expect_value(t, r.total, 2)
	testing.expect_value(t, len(r.items), 2)
	testing.expect_value(t, r.items[0].name, "Medusa")
	testing.expect_value(t, r.items[0].year, 2024)
	testing.expect_value(t, len(r.items[1].artists), 2)
	testing.expect_value(t, jf.seconds(r.items[1]), 213.0)
}

@(test)
parse_auth :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a: jf.Auth_Response
	err := json.unmarshal_string(`{"AccessToken":"tok","ServerId":"s","User":{"Id":"u1","Name":"justin"}}`, &a, allocator = virtual.arena_allocator(&arena))
	testing.expect_value(t, err, nil)
	testing.expect_value(t, a.token, "tok")
	testing.expect_value(t, a.user.id, "u1")
}

@(test)
split_status_ok :: proc(t: ^testing.T) {
	r, err := jf.split_status(transmute([]byte)string(`{"a":1}` + "\n200"))
	testing.expect_value(t, err, jf.Error.None)
	testing.expect_value(t, r.status, 200)
	testing.expect_value(t, string(r.body), `{"a":1}`)
}

@(test)
split_status_unauthorized :: proc(t: ^testing.T) {
	_, err := jf.split_status(transmute([]byte)string("\n401"))
	testing.expect_value(t, err, jf.Error.Unauthorized)
	_, err = jf.split_status(transmute([]byte)string("oops\n500"))
	testing.expect_value(t, err, jf.Error.Http)
	_, err = jf.split_status(transmute([]byte)string("garbage"))
	testing.expect_value(t, err, jf.Error.Network)
}
