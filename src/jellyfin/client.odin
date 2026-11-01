package jellyfin

import "core:fmt"
import "core:os"
import "core:strings"

CLIENT_NAME    :: "Tendril"
CLIENT_VERSION :: "0.1.0"

Error :: enum {
	None,
	Spawn_Failed, // curl missing or could not start
	Network,      // curl exited non-zero (DNS, refused, timeout, TLS)
	Http,         // server answered with a non-2xx status
	Unauthorized, // 401: bad credentials or expired token
	Bad_Json,
}

Response :: struct {
	status: int,
	body:   []byte,
}

// Escape a value for use inside a curl config file's quoted string.
@(private)
cfg_quote :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for c in s {
		switch c {
		case '\\': strings.write_string(&b, "\\\\")
		case '"':  strings.write_string(&b, "\\\"")
		case '\n': strings.write_string(&b, "\\n")
		case:      strings.write_rune(&b, c)
		}
	}
	return strings.to_string(b)
}

auth_header :: proc(s: Server) -> string {
	if s.token == "" {
		return fmt.tprintf(`MediaBrowser Client="%s", Device="Linux", DeviceId="%s", Version="%s"`, CLIENT_NAME, s.device_id, CLIENT_VERSION)
	}
	return fmt.tprintf(`MediaBrowser Client="%s", Device="Linux", DeviceId="%s", Version="%s", Token="%s"`, CLIENT_NAME, s.device_id, CLIENT_VERSION, s.token)
}

// Runs curl against `server`. The URL, auth header and body go through a
// config piped to curl's stdin (`curl -K -`), so the token never appears in
// the process list. Blocking: call from a worker thread.
request :: proc(s: Server, method, path: string, body := "", allocator := context.allocator, probe := false) -> (resp: Response, err: Error) {
	cfg := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&cfg, `url = "%s%s"`, cfg_quote(s.url), cfg_quote(path))
	fmt.sbprintfln(&cfg, `request = "%s"`, method)
	fmt.sbprintfln(&cfg, `header = "Authorization: %s"`, cfg_quote(auth_header(s)))
	fmt.sbprintfln(&cfg, `header = "Accept: application/json"`)
	if probe {
		// Ask for one byte; servers that ignore ranges would stream the whole file.
		fmt.sbprintfln(&cfg, `range = "0-0"`)
	}
	if body != "" {
		fmt.sbprintfln(&cfg, `header = "Content-Type: application/json"`)
		fmt.sbprintfln(&cfg, `data = "%s"`, cfg_quote(body))
	}

	r, w, perr := os.pipe()
	if perr != nil { return {}, .Spawn_Failed }
	_, werr := os.write_string(w, strings.to_string(cfg))
	os.close(w)
	if werr != nil { os.close(r); return {}, .Spawn_Failed }
	defer os.close(r)

	// -w appends the HTTP status on its own final line; -f is deliberately not used
	// so a 401 body still comes back and we can classify it.
	cmd := []string{"curl", "-sS", "-K", "-", "--max-time", probe ? "8" : "20", "--connect-timeout", "6", "-w", "\n%{http_code}"}
	state, out, errout, xerr := os.process_exec({command = cmd, stdin = r}, allocator)
	defer delete(errout, allocator)
	if xerr != nil {
		delete(out, allocator)
		return {}, .Spawn_Failed
	}
	// A probe only needs the status line: cutting the transfer short (curl exit 28
	// timeout, 63 size limit) after the headers arrived is fine.
	cut_short := probe && (state.exit_code == 28 || state.exit_code == 63)
	if state.exit_code != 0 && !cut_short {
		delete(out, allocator)
		return {}, .Network
	}
	return split_status(out)
}

// Splits curl's `body\nSTATUS` output into its parts.
split_status :: proc(out: []byte) -> (resp: Response, err: Error) {
	i := len(out) - 1
	for i >= 0 && out[i] != '\n' { i -= 1 }
	if i < 0 { return {}, .Network }
	status := 0
	for c in out[i + 1:] {
		if c < '0' || c > '9' { return {}, .Network }
		status = status * 10 + int(c - '0')
	}
	resp = {status = status, body = out[:i]}
	switch {
	case status == 401: err = .Unauthorized
	case status < 200 || status >= 300: err = .Http
	}
	return
}
