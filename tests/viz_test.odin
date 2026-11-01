package tests

import "core:math"
import "core:testing"
import "../src/viz"

// Fills the spectrum's ring with a pure sine and returns which of `n` bars is tallest.
loudest_bar :: proc(freq: f64, n: int) -> (bar: int, level: f64) {
	s: viz.Spectrum
	for i in 0 ..< viz.FFT_SIZE * 2 {
		v := i16(12000 * math.sin(2 * math.PI * freq * f64(i) / viz.SAMPLE_RATE))
		viz.push_sample(&s, v)
	}
	s.running = true // pretend a capture is live so analyze() reads the ring
	viz.analyze(&s, n, 1.0)
	s.running = false
	for i in 0 ..< n {
		if s.bars[i] > level { level, bar = s.bars[i], i }
	}
	return
}

@(test)
fft_finds_the_right_band_for_a_sine :: proc(t: ^testing.T) {
	N :: 64
	prev := -1
	for f in ([]f64{100, 440, 1000, 4000, 10000}) {
		bar, level := loudest_bar(f, N)
		testing.expectf(t, level > 0.5, "%v Hz should be clearly visible, got level %v", f, level)
		testing.expectf(t, bar > prev, "%v Hz should land above the previous (higher-pitch) band: bar %d after %d", f, bar, prev)
		// the log-spaced band centre should be near the tone
		centre := 40.0 * math.pow(14000.0 / 40.0, (f64(bar) + 0.5) / N)
		testing.expectf(t, centre > f / 1.4 && centre < f * 1.4, "bar %d (≈%.0f Hz) for a %v Hz tone", bar, centre, f)
		prev = bar
	}
}

@(test)
silence_gives_flat_bars :: proc(t: ^testing.T) {
	s: viz.Spectrum
	for _ in 0 ..< viz.FFT_SIZE * 2 { viz.push_sample(&s, 0) }
	s.running = true
	viz.analyze(&s, 32, 1.0)
	s.running = false
	for i in 0 ..< 32 { testing.expect(t, s.bars[i] < 0.01, "silence must not light any bar") }
}

@(test)
bars_fall_gradually :: proc(t: ^testing.T) {
	s: viz.Spectrum
	s.n = 8
	for i in 0 ..< 8 { s.bars[i] = 1 }
	viz.analyze(&s, 8, 0.1) // no audio: should decay, not drop to zero at once
	testing.expect(t, s.bars[0] < 1 && s.bars[0] > 0.5, "gravity, not a cliff")
}

@(test)
split_samples_are_reassembled :: proc(t: ^testing.T) {
	s: viz.Spectrum
	defer delete(s.partial)
	// 0x1234 little-endian, split across two reads
	viz.feed_bytes(&s, {0x34})
	viz.feed_bytes(&s, {0x12, 0x01, 0x00})
	testing.expect_value(t, s.filled, 2)
	testing.expect_value(t, s.ring[0], f32(0x1234) / 32768)
	testing.expect_value(t, s.ring[1], f32(1) / 32768)
}
