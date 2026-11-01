package config

import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "../jellyfin"

Config :: struct {
	device_id: string,
	servers:   []jellyfin.Server,
}

default_path :: proc() -> (path: string, ok: bool) {
	dir, err := os.user_config_dir(context.allocator)
	if err != nil { return "", false }
	defer delete(dir)
	joined, jerr := filepath.join({dir, "tendril", "servers.json"})
	return joined, jerr == nil
}

load :: proc() -> Config {
	path, ok := default_path()
	if !ok { return load_from("") }
	defer delete(path)
	return load_from(path)
}

// Reads `path` (a missing or unreadable file gives an empty config) and makes
// sure there is a device id.
load_from :: proc(path: string) -> (c: Config) {
	if path != "" {
		if data, rerr := os.read_entire_file(path, context.allocator); rerr == nil {
			defer delete(data)
			_ = json.unmarshal(data, &c)
		}
	}
	if c.device_id == "" {
		c.device_id = fmt.aprintf("tendril-%016x", rand.uint64())
	}
	for &s in c.servers {
		delete(s.device_id) // the copy saved in the file; every server shares the config's
		s.device_id = c.device_id
	}
	return
}

save :: proc(c: Config) -> bool {
	path, ok := default_path()
	if !ok { return false }
	defer delete(path)
	return save_to(c, path)
}

// Writes the config readable by the owner only: it holds access tokens.
save_to :: proc(c: Config, path: string) -> bool {
	_ = os.make_directory_all(filepath.dir(path), {.Read_User, .Write_User, .Execute_User})
	data, merr := json.marshal(c, {pretty = true}, context.temp_allocator)
	if merr != nil { return false }
	return os.write_entire_file(path, data, {.Read_User, .Write_User}) == nil
}
