package tests

import "core:os"
import "core:testing"
import "core:fmt"
import "core:mem/virtual"
import "../src/config"
import "../src/jellyfin"

tmp_path :: proc(name: string) -> string {
	return fmt.tprintf("/tmp/tendril-test-%d-%s/servers.json", os.get_pid(), name)
}

cleanup :: proc(path: string) {
	os.remove(path)
	// remove the directory too
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' { os.remove(path[:i]); break }
	}
}

@(test)
config_round_trip :: proc(t: ^testing.T) {
	path := tmp_path("rt")
	defer cleanup(path)
	servers := []jellyfin.Server{
		{id = "s1", name = "home", url = "https://jelly.example.com", user = "justin", user_id = "u1", token = "abc123"},
		{id = "s2", name = `we"ird \ name`, url = "http://10.0.0.5:8096", user = "o'brien", user_id = "u2", token = "té"},
	}
	c := config.Config{device_id = "dev-42", servers = servers}
	testing.expect(t, config.save_to(c, path))

	back := config.load_from(path)
	defer {
		for s in back.servers { delete(s.id); delete(s.name); delete(s.url); delete(s.user); delete(s.user_id); delete(s.token) }
		delete(back.servers)
		delete(back.device_id)
	}
	testing.expect_value(t, back.device_id, "dev-42")
	testing.expect_value(t, len(back.servers), 2)
	testing.expect_value(t, back.servers[1].name, `we"ird \ name`)
	testing.expect_value(t, back.servers[1].user, "o'brien")
	testing.expect_value(t, back.servers[0].token, "abc123")
	testing.expect_value(t, back.servers[0].url, "https://jelly.example.com")
	// every server gets the shared device id
	testing.expect_value(t, back.servers[0].device_id, "dev-42")
}

@(test)
config_file_is_private :: proc(t: ^testing.T) {
	path := tmp_path("perm")
	defer cleanup(path)
	testing.expect(t, config.save_to({device_id = "d", servers = {{id = "s1", token = "secret"}}}, path))
	info, err := os.stat(path, context.temp_allocator)
	testing.expect(t, err == nil)
	m := info.mode
	testing.expect(t, .Read_User in m && .Write_User in m)
	testing.expect(t, .Read_Group not_in m && .Read_Other not_in m, "tokens must not be group/world readable")
	testing.expect(t, .Write_Group not_in m && .Write_Other not_in m)
}

@(test)
config_missing_file_gives_empty_config_with_device_id :: proc(t: ^testing.T) {
	c := config.load_from("/tmp/tendril-does-not-exist/servers.json")
	defer delete(c.device_id)
	testing.expect_value(t, len(c.servers), 0)
	testing.expect(t, len(c.device_id) > 0, "a device id is generated on first run")
}

@(test)
config_corrupt_file_does_not_crash :: proc(t: ^testing.T) {
	path := tmp_path("bad")
	defer cleanup(path)
	_ = os.make_directory_all("/tmp")
	dir := path[:len(path) - len("/servers.json")]
	_ = os.make_directory_all(dir)
	testing.expect(t, os.write_entire_file(path, "{ not json") == nil)
	c := config.load_from(path)
	defer delete(c.device_id)
	testing.expect_value(t, len(c.servers), 0)
}

@(test)
settings_defaults_and_partial_override :: proc(t: ^testing.T) {
	path := tmp_path("settings")
	defer cleanup(path)
	_ = os.make_directory_all(path[:len(path) - len("/servers.json")])
	testing.expect(t, os.write_entire_file(path, `{"volume": 30, "keys": {"next": ["N", "ctrl+n"]}}`) == nil)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	s, ok := config.load_settings_from(path, virtual.arena_allocator(&arena))
	testing.expect(t, ok)
	testing.expect_value(t, s.volume, 30)
	testing.expect(t, s.scrobble, "an unset option keeps its default (on)")
	testing.expect_value(t, s.theme, "abyss")
	testing.expect_value(t, len(s.keys["next"]), 2)
}

@(test)
settings_missing_file_is_fine_and_bad_file_falls_back :: proc(t: ^testing.T) {
	s, ok := config.load_settings_from("/tmp/tendril-none/config.json")
	testing.expect(t, ok)
	testing.expect_value(t, s.volume, 70)
	path := tmp_path("badsettings")
	defer cleanup(path)
	_ = os.make_directory_all(path[:len(path) - len("/servers.json")])
	testing.expect(t, os.write_entire_file(path, "[1,2") == nil)
	s, ok = config.load_settings_from(path)
	testing.expect(t, !ok, "a corrupt file is reported")
	testing.expect_value(t, s.volume, 70)
}
