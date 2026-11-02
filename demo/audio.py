"""The soundtrack for the Tendril demo, synthesized with numpy: calm pads for the hook, a groove that builds into a driving
synthwave beat at 120 BPM, a sonar ping and a bell on the logo, key clicks on the actions and a whoosh on every wipe.

The instruments (kick, snare, hat, pluck, bass, pad, ping, bell, click, whoosh, riser, the mixer and the reverb) come from
the CaptainFM trailer synth; the arrangement below is Tendril's own. A beat is 0.5 s, so every cut lands on a beat."""
import math, wave
import numpy as np

SR = 48000
BEAT = 0.5
RNG = np.random.default_rng(3)

def note(n):  # MIDI note number to Hz
    return 440.0 * 2 ** ((n - 69) / 12)

def env_exp(n, decay, attack=0.002):
    t = np.arange(n) / SR
    a = np.minimum(1.0, t / max(attack, 1e-4))
    return a * np.exp(-t / decay)

def saw(freq, n, harmonics=14, detune=0.0, phase=0.0):
    t = np.arange(n) / SR
    out = np.zeros(n)
    for k in range(1, harmonics + 1):
        if freq * k > 9000:
            break
        out += np.sin(2 * math.pi * freq * (1 + detune) * k * t + phase * k) / k
    return out * (2 / math.pi)

def moving_average(x, w):
    w = max(1, int(w))
    if w == 1:
        return x
    c = np.cumsum(np.insert(x, 0, 0.0))
    y = (c[w:] - c[:-w]) / w
    return np.concatenate([np.full(w - 1, y[0] if len(y) else 0.0), y])[: len(x)]

class Mix:
    def __init__(self, seconds):
        self.n = int(seconds * SR)
        self.dry = np.zeros((self.n, 2))
        self.wet = np.zeros((self.n, 2))     # goes through the reverb
        self.duck = np.ones(self.n)          # sidechain from the kick

    def add(self, sig, t0, gain=1.0, pan=0.0, wet=0.0, ducked=False):
        i = int(t0 * SR)
        if i >= self.n or i + len(sig) <= 0:
            return
        if i < 0:
            sig = sig[-i:]; i = 0
        sig = sig[: self.n - i]
        l, r = gain * math.cos((pan + 1) * math.pi / 4), gain * math.sin((pan + 1) * math.pi / 4)
        if ducked:
            seg = sig * self.duck[i:i + len(sig)]
        else:
            seg = sig
        self.dry[i:i + len(seg), 0] += seg * l * (1 - wet)
        self.dry[i:i + len(seg), 1] += seg * r * (1 - wet)
        self.wet[i:i + len(seg), 0] += seg * l * wet
        self.wet[i:i + len(seg), 1] += seg * r * wet

def reverb(x, seconds=1.8):
    n = int(seconds * SR)
    t = np.arange(n) / SR
    ir = np.stack([RNG.standard_normal(n) * np.exp(-t / (seconds / 4.5)) for _ in range(2)], axis=1)
    ir[:int(0.012 * SR)] *= np.linspace(0, 1, int(0.012 * SR))[:, None]
    ir /= np.sqrt((ir ** 2).sum(axis=0, keepdims=True))      # unit energy, so the wet level means what it says
    out = np.zeros_like(x)
    size = 1 << int(math.ceil(math.log2(len(x) + n)))
    for ch in range(2):
        out[:, ch] = np.fft.irfft(np.fft.rfft(x[:, ch], size) * np.fft.rfft(ir[:, ch], size), size)[: len(x)]
    return out * 0.9

# ---- one-shots ------------------------------------------------------------------------------------------------

def kick():
    n = int(0.34 * SR)
    t = np.arange(n) / SR
    f = 46 + 90 * np.exp(-t / 0.035)
    return np.sin(2 * math.pi * np.cumsum(f) / SR) * np.exp(-t / 0.13) * 1.0

def snare():
    n = int(0.28 * SR)
    t = np.arange(n) / SR
    noise = np.diff(RNG.standard_normal(n + 1)) * np.exp(-t / 0.07)
    tone = np.sin(2 * math.pi * 185 * t) * np.exp(-t / 0.05)
    return 0.55 * noise + 0.5 * tone

def hat(open_=False):
    n = int(0.22 * SR) if open_ else int(0.06 * SR)
    t = np.arange(n) / SR
    return np.diff(RNG.standard_normal(n + 1)) * np.exp(-t / (0.09 if open_ else 0.018)) * 0.35

def pluck(freq, dur=0.3, bright=1.0):
    n = int(dur * SR)
    t = np.arange(n) / SR
    s = (np.sin(2 * math.pi * freq * t) + 0.35 * bright * np.sin(2 * math.pi * 2 * freq * t) + 0.12 * bright * np.sin(2 * math.pi * 3 * freq * t))
    return s * env_exp(n, dur / 3.2, 0.002)

def bass_note(freq, dur):
    n = int(dur * SR)
    s = saw(freq, n, harmonics=9)
    s = moving_average(s, SR / (freq * 7))
    return (s + 0.6 * np.sin(2 * math.pi * freq * np.arange(n) / SR)) * env_exp(n, dur * 0.9, 0.004)

def pad_chord(freqs, dur):
    n = int(dur * SR)
    out = np.zeros(n)
    for f in freqs:
        for d in (-0.004, 0.0, 0.004):
            out += saw(f, n, harmonics=8, detune=d, phase=RNG.uniform(0, 6.28))
    out = moving_average(out, SR / 900)
    t = np.arange(n) / SR
    return out * np.minimum(1, t / 0.5) * np.minimum(1, (dur - t) / 0.6) * 0.07

def ping():
    n = int(2.6 * SR)
    t = np.arange(n) / SR
    s = np.sin(2 * math.pi * 1175 * t) * np.exp(-t / 0.55) + 0.25 * np.sin(2 * math.pi * 2350 * t) * np.exp(-t / 0.25)
    echo = np.zeros(n)
    for k, g in ((0.42, 0.35), (0.84, 0.18)):
        d = int(k * SR)
        echo[d:] += s[: n - d] * g
    return (s + echo) * 0.55

def bell(freq=659.3):
    n = int(5.0 * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    for ratio, amp, dec in ((1.0, 1.0, 2.6), (2.0, 0.5, 1.8), (2.76, 0.6, 1.5), (5.4, 0.35, 0.9), (8.93, 0.2, 0.5)):
        out += amp * np.sin(2 * math.pi * freq * ratio * t + 0.5 * np.sin(2 * math.pi * freq * 0.5 * t) * np.exp(-t / 0.2)) * np.exp(-t / dec)
    return out * 0.32 * np.minimum(1, t / 0.004)

def click():
    n = int(0.05 * SR)
    t = np.arange(n) / SR
    noise = np.diff(RNG.standard_normal(n + 1)) * np.exp(-t / 0.004)
    return (0.5 * noise + 0.5 * np.sin(2 * math.pi * 1900 * t) * np.exp(-t / 0.012)) * 0.35

def tick():
    n = int(0.03 * SR)
    t = np.arange(n) / SR
    return np.sin(2 * math.pi * 2600 * t) * np.exp(-t / 0.004) * 0.3

def whoosh(dur=0.7):
    n = int(dur * SR)
    t = np.arange(n) / SR
    noise = RNG.standard_normal(n)
    out = np.zeros(n)
    parts = 10
    for k in range(parts):
        a, b = k * n // parts, (k + 1) * n // parts
        cutoff = 300 + 5200 * math.sin(math.pi * (k + 0.5) / parts) ** 2
        seg = moving_average(noise, SR / cutoff)[a:b]
        out[a:b] = seg
    env = np.sin(math.pi * np.clip(t / dur, 0, 1)) ** 2
    return out * env * 0.9

def riser(dur):
    n = int(dur * SR)
    t = np.arange(n) / SR
    noise = np.diff(RNG.standard_normal(n + 1))
    return noise * (t / dur) ** 2.2 * 0.5

# ---- the arrangement --------------------------------------------------------------------------------------------------

CHORDS = [  # A minor: Am F C G, as (root, third, fifth, seventh-ish) MIDI notes
    (57, 60, 64, 67), (53, 57, 60, 64), (48, 55, 60, 64), (55, 59, 62, 66),
]

def make(path, total, hook, outro_at, wipes, keys, hearts):
    """hook: seconds of intro; outro_at: when the outro starts; wipes/keys/hearts: video times of whooshes, key clicks, hearts."""
    def intensity(t):
        if t < hook: return 0.0
        if t < hook + 5: return 0.5
        if t < hook + 13: return 0.75
        if t < outro_at: return 1.0
        return 0.0

    mix = Mix(total + 1.0)
    bar = 4 * BEAT
    n_bars = int(math.ceil(total / bar)) + 1
    kicks = []

    # hook: sonar ping as the ring goes out, a bell on the name, a riser into the first beat
    mix.add(bell(659.3), 1.55, 0.7, pan=0.1, wet=0.5)
    mix.add(ping(), 3.2, 0.85, pan=0.0, wet=0.35)
    mix.add(riser(hook - 3.2), 3.2, 0.55, wet=0.15)
    for k in range(8):
        mix.add(snare(), hook - 0.5 + k * 0.0625, 0.22 + 0.04 * k, wet=0.15)

    for b in range(n_bars):
        for beat in range(4):
            t0 = b * bar + beat * BEAT
            if t0 >= total: continue
            inten = intensity(t0)
            if inten <= 0: continue
            four = inten >= 1.0
            if four or beat in (0, 2):
                kicks.append(t0)
                mix.add(kick(), t0, 0.9 if four else 0.6 * inten, pan=0.0)
            if beat in (1, 3) and inten >= 0.7:
                mix.add(snare(), t0, 0.5 * inten, pan=0.05, wet=0.2)
            mix.add(hat(), t0 + BEAT / 2, 0.55 * inten, pan=-0.2 + 0.4 * (beat % 2))
            if inten >= 0.7: mix.add(hat(), t0, 0.28 * inten, pan=0.2)
            if four and beat == 3: mix.add(hat(True), t0 + BEAT / 2, 0.4, pan=0.25)
    mix.add(kick(), hook, 1.0)
    for kt in kicks + [hook]:
        i = int(kt * SR); n = int(0.26 * SR)
        if i < mix.n:
            curve = 1 - 0.62 * np.exp(-np.arange(min(n, mix.n - i)) / SR / 0.09)
            mix.duck[i:i + len(curve)] = np.minimum(mix.duck[i:i + len(curve)], curve)

    for b in range(n_bars):
        t0 = b * bar
        if t0 >= total: break
        chord = CHORDS[b % 4]
        inten = intensity(t0 + 0.1)
        mix.add(pad_chord([note(n) for n in chord], bar + 0.5), t0, 0.22 if inten == 0 else 0.42, pan=0.0, wet=0.3, ducked=True)
        mix.add(pad_chord([note(n + 12) for n in chord[1:]], bar + 0.5), t0, 0.09 if inten == 0 else 0.2, pan=0.3, wet=0.4, ducked=True)
        if inten >= 0.45:
            root = note(chord[0] - 12)
            for e in range(8):
                te = t0 + e * BEAT / 2
                if inten < 1.0 and e % 2: continue
                oct_up = 2 if e in (3, 7) and inten >= 1.0 else 1
                mix.add(bass_note(root * oct_up, BEAT / 2 * 0.95), te, 0.62 * min(1.0, inten + 0.2), pan=0.0, ducked=True)
            tones = [note(n + 12) for n in chord] + [note(chord[1] + 24)]
            pattern = [0, 2, 1, 3, 2, 4, 3, 2, 0, 2, 1, 3, 2, 4, 3, 1]
            for s in range(16):
                ts = t0 + s * BEAT / 4
                if inten < 1.0 and s % 2: continue
                f = tones[pattern[s] % len(tones)] * (2 if pattern[s] >= 4 else 1)
                p = -0.4 + 0.8 * ((s % 4) / 3)
                mix.add(pluck(f, 0.32), ts, 0.16 * inten, pan=p, wet=0.25, ducked=True)
                mix.add(pluck(f, 0.32), ts + 0.375, 0.07 * inten, pan=-p, wet=0.35, ducked=True)

    for w in wipes:   mix.add(whoosh(0.7), w - 0.35, 0.28, pan=0.0, wet=0.2)
    for k in keys:    mix.add(click(), k, 0.9, pan=-0.15 + 0.3 * (int(k * 10) % 2))
    for h in hearts:  mix.add(bell(1318.5), h, 0.35, pan=0.3, wet=0.5)

    # outro: the beat drops out, the sea settles, two last bells
    mix.add(bell(659.3 / 2), outro_at + 0.15, 0.55, wet=0.5)
    mix.add(bell(), outro_at + 1.4, 0.35, pan=-0.2, wet=0.5)
    mix.add(ping(), outro_at + 4.0, 0.3, pan=0.2, wet=0.5)

    out = mix.dry + reverb(mix.wet)
    fade = np.ones(len(out))
    n_fade = int(1.6 * SR); end = int(total * SR)
    fade[end - n_fade:end] = np.linspace(1, 0, n_fade); fade[end:] = 0
    fade[: int(0.05 * SR)] *= np.linspace(0, 1, int(0.05 * SR))
    out = out * fade[:, None]
    peak = np.max(np.abs(out))
    out = np.tanh(out / peak * 1.25) / np.tanh(1.25) * 0.89
    pcm = (out[: int(total * SR)] * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    return path
