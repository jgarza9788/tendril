// A real audio spectrum for the visualizer: records mpv's own audio stream (via
// parec) and runs an FFT over it. Everything degrades quietly: if parec or the
// stream is missing, `active` stays false and the caller falls back to a simulation.
package viz

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:sys/linux"

SAMPLE_RATE :: 44100
FFT_SIZE    :: 2048
MAX_BARS    :: 160

Spectrum :: struct {
	bars:     [MAX_BARS]f64, // 0..1, smoothed, low frequencies first
	n:        int,           // how many bars are valid
	bass:     f64,           // 0..1, energy in the lowest bars (for beat pulses)
	active:   bool,          // true while real audio is being captured

	// capture
	proc_:    os.Process,
	rd:       linux.Fd,
	running:  bool,
	ring:     [FFT_SIZE]f32,
	filled:   int,           // total samples ever written (index = filled % FFT_SIZE)
	next_try: f64,           // time of the next attempt to find mpv's stream
	partial:  [dynamic]u8,   // a trailing odd byte between reads
}

// Client name Tendril gives mpv (--audio-client-name), so its stream can be told
// apart from any other mpv that happens to be running.
CLIENT_NAME :: "tendril"

// Looks up the PipeWire/Pulse sink-input that belongs to Tendril's mpv.
find_sink_input :: proc() -> (index: int, ok: bool) {
	state, out, _, err := os.process_exec({command = {"pactl", "--format=json", "list", "sink-inputs"}}, context.temp_allocator)
	if err != nil || state.exit_code != 0 { return 0, false }
	val, jerr := json.parse(out, allocator = context.temp_allocator)
	if jerr != nil { return 0, false }
	arr, is_arr := val.(json.Array)
	if !is_arr { return 0, false }
	for item in arr {
		obj := item.(json.Object) or_continue
		props := obj["properties"].(json.Object) or_continue
		name, _ := props["application.name"].(json.String)
		if name != CLIENT_NAME { continue }
		idx := obj["index"].(json.Float) or_continue
		return int(idx), true
	}
	return 0, false
}

// Starts recording mpv's stream. `now` is the app clock (seconds); attempts are
// throttled to one a second because the stream only exists while mpv is playing.
try_start :: proc(s: ^Spectrum, now: f64) {
	if s.running || now < s.next_try { return }
	s.next_try = now + 1
	idx, ok := find_sink_input()
	if !ok { return }
	r, w, perr := os.pipe()
	if perr != nil { return }
	proc_, err := os.process_start({
		command = {"parec", fmt.tprintf("--monitor-stream=%d", idx), "--format=s16le",
			fmt.tprintf("--rate=%d", SAMPLE_RATE), "--channels=1", "--latency-msec=25"},
		stdout = w,
	})
	os.close(w)
	if err != nil { os.close(r); return }
	s.proc_ = proc_
	s.rd = linux.Fd(os.fd(r))
	_ = linux.fcntl_setfl(s.rd, .SETFL, {.NONBLOCK})
	s.running = true
}

stop :: proc(s: ^Spectrum) {
	if s.running {
		_ = os.process_kill(s.proc_)
		_, _ = os.process_wait(s.proc_)
		linux.close(s.rd)
		s.running = false
	}
	s.active = false
	delete(s.partial)
	s.partial = nil
}

// Reads whatever audio has arrived into the ring buffer. Never blocks.
pump :: proc(s: ^Spectrum) {
	if !s.running { return }
	buf: [8192]u8
	for {
		n, err := linux.read(s.rd, buf[:])
		if err == .EAGAIN { break }
		if err != .NONE || n == 0 {
			// the stream went away (mpv reopened its output, or parec died)
			stop(s)
			return
		}
		feed_bytes(s, buf[:n])
		if n < len(buf) { break }
	}
}

// Appends s16le samples (handling a sample split across two reads).
feed_bytes :: proc(s: ^Spectrum, data: []u8) {
	d := data
	if len(s.partial) > 0 && len(d) > 0 {
		push_sample(s, i16(u16(s.partial[0]) | u16(d[0]) << 8))
		clear(&s.partial)
		d = d[1:]
	}
	i := 0
	for ; i + 1 < len(d); i += 2 { push_sample(s, i16(u16(d[i]) | u16(d[i + 1]) << 8)) }
	if i < len(d) { append(&s.partial, d[i]) }
}

push_sample :: proc(s: ^Spectrum, v: i16) {
	s.ring[s.filled % FFT_SIZE] = f32(v) / 32768
	s.filled += 1
}

// Turns the latest audio into `n` bars. Call once per frame with the frame time.
// Rises fast and falls with gravity, like a classic spectrum analyser.
// `gain` undoes mpv's volume (applied before we can hear the stream), so the bars
// keep their size when you turn the volume down.
analyze :: proc(s: ^Spectrum, want: int, dt: f64, gain := 1.0) {
	n := clamp(want, 1, MAX_BARS)
	s.n = n
	target: [MAX_BARS]f64
	have_audio := s.running && s.filled >= FFT_SIZE
	if have_audio {
		re, im: [FFT_SIZE]f32
		for i in 0 ..< FFT_SIZE {
			// oldest -> newest, with a Hann window
			x := s.ring[(s.filled + i) % FFT_SIZE]
			w := 0.5 - 0.5 * math.cos(2 * math.PI * f32(i) / f32(FFT_SIZE - 1))
			re[i] = x * w
		}
		fft(re[:], im[:])
		bands(re[:], im[:], target[:n], gain)
		s.active = true
	} else {
		s.active = false
	}
	fall := dt * 1.6
	for i in 0 ..< n {
		if target[i] > s.bars[i] { s.bars[i] = s.bars[i] + (target[i] - s.bars[i]) * min(dt * 28, 1) } else { s.bars[i] = max(s.bars[i] - fall, target[i]) }
	}
	b := 0.0
	cnt := max(n / 8, 1)
	for i in 0 ..< cnt { b += s.bars[i] }
	s.bass = b / f64(cnt)
}

// Magnitudes in log-spaced bands from 40 Hz to 14 kHz, as 0..1 on a 60 dB scale.
bands :: proc(re, im: []f32, out: []f64, gain := 1.0) {
	n := len(out)
	lo, hi := 40.0, 14000.0
	bin_hz := f64(SAMPLE_RATE) / f64(FFT_SIZE)
	for b in 0 ..< n {
		f0 := lo * math.pow(hi / lo, f64(b) / f64(n))
		f1 := lo * math.pow(hi / lo, f64(b + 1) / f64(n))
		k0 := max(int(f0 / bin_hz), 1)
		k1 := max(int(f1 / bin_hz), k0 + 1)
		peak := 0.0
		for k in k0 ..< min(k1, FFT_SIZE / 2) {
			m := f64(math.sqrt(re[k] * re[k] + im[k] * im[k])) / f64(FFT_SIZE / 4) * gain
			peak = max(peak, m)
		}
		db := 20 * math.log10(max(peak, 1e-9))
		out[b] = clamp((db + 60) / 60, 0, 1)
	}
}

// In-place radix-2 FFT. len(re) == len(im) must be a power of two.
fft :: proc(re, im: []f32) {
	n := len(re)
	j := 0
	for i in 1 ..< n {
		bit := n >> 1
		for ; j & bit != 0; bit >>= 1 { j ~= bit }
		j ~= bit
		if i < j {
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		}
	}
	for length := 2; length <= n; length <<= 1 {
		ang := -2 * math.PI / f32(length)
		wr, wi := math.cos(ang), math.sin(ang)
		for i := 0; i < n; i += length {
			cr, ci: f32 = 1, 0
			for k in 0 ..< length / 2 {
				a, b := i + k, i + k + length / 2
				tr := re[b] * cr - im[b] * ci
				ti := re[b] * ci + im[b] * cr
				re[b], im[b] = re[a] - tr, im[a] - ti
				re[a], im[a] = re[a] + tr, im[a] + ti
				cr, ci = cr * wr - ci * wi, cr * wi + ci * wr
			}
		}
	}
}


// How much to boost the captured audio to undo mpv's volume (0-100, roughly cubic).
volume_gain :: proc(volume: f64) -> f64 {
	v := clamp(volume / 100, 0.04, 1)
	return min(1 / (v * v * v), 40)
}
