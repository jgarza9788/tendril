package main

import hnoss "../libs/hnoss"
import "../libs/hnoss/style"

// The live palette. These are variables, not constants, so a theme can swap them
// at runtime (see apply_palette). MIST (secondary text) stays the same everywhere.
ABYSS   := style.Rgb{0x07, 0x0b, 0x1a}
DEEP    := style.Rgb{0x0d, 0x16, 0x2e}
TRENCH  := style.Rgb{0x16, 0x23, 0x45}
MIST    := style.Rgb{0x6b, 0x7a, 0xa8}
FOAM    := style.Rgb{0xe6, 0xf1, 0xff}
TEAL    := style.Rgb{0x19, 0xd3, 0xb0}
CYAN    := style.Rgb{0x2d, 0xf0, 0xff}
VIOLET  := style.Rgb{0x8b, 0x5c, 0xff}
MAGENTA := style.Rgb{0xff, 0x3d, 0xd8}

DEFAULT_GLOW := [4]style.Rgb{TEAL, CYAN, VIOLET, MAGENTA}

// The live gradient. It drifts toward the current cover's colours (see update_glow).
GLOW := DEFAULT_GLOW

Palette :: struct {
	name:                       string,
	abyss, deep, trench, foam:  style.Rgb, // background, input background, borders, text
	glow:                       [4]style.Rgb,
}

PALETTES := [?]Palette{
	{"abyss",  {0x07, 0x0b, 0x1a}, {0x0d, 0x16, 0x2e}, {0x16, 0x23, 0x45}, {0xe6, 0xf1, 0xff},
		{{0x19, 0xd3, 0xb0}, {0x2d, 0xf0, 0xff}, {0x8b, 0x5c, 0xff}, {0xff, 0x3d, 0xd8}}},
	{"sunset", {0x16, 0x0a, 0x12}, {0x24, 0x10, 0x1a}, {0x45, 0x1f, 0x2c}, {0xff, 0xf1, 0xe6},
		{{0xff, 0xb3, 0x47}, {0xff, 0x7a, 0x59}, {0xff, 0x3d, 0x81}, {0xb8, 0x4d, 0xff}}},
	{"forest", {0x08, 0x12, 0x0c}, {0x10, 0x1f, 0x16}, {0x1c, 0x38, 0x28}, {0xe9, 0xf7, 0xea},
		{{0x7c, 0xe3, 0x8f}, {0x3d, 0xe0, 0xa5}, {0xc9, 0xe8, 0x4d}, {0x5c, 0xc8, 0xff}}},
	{"mono",   {0x0b, 0x0b, 0x0b}, {0x16, 0x16, 0x16}, {0x2e, 0x2e, 0x2e}, {0xee, 0xee, 0xee},
		{{0x9a, 0x9a, 0x9a}, {0xe0, 0xe0, 0xe0}, {0xbd, 0xbd, 0xbd}, {0xff, 0xff, 0xff}}},
}

palette_index :: proc(name: string) -> int {
	for p, i in PALETTES { if p.name == name { return i } }
	return 0
}

apply_palette :: proc(idx: int) {
	p := PALETTES[idx % len(PALETTES)]
	ABYSS, DEEP, TRENCH, FOAM = p.abyss, p.deep, p.trench, p.foam
	TEAL, CYAN, VIOLET, MAGENTA = p.glow[0], p.glow[1], p.glow[2], p.glow[3]
	DEFAULT_GLOW = p.glow
}

// "#rrggbb" or "rrggbb".
parse_hex_color :: proc(s: string) -> (c: style.Rgb, ok: bool) {
	h := s[1:] if len(s) > 0 && s[0] == '#' else s
	if len(h) != 6 { return {}, false }
	v: u32
	for ch in transmute([]byte)h {
		d: u32
		switch ch {
		case '0'..='9': d = u32(ch - '0')
		case 'a'..='f': d = u32(ch - 'a' + 10)
		case 'A'..='F': d = u32(ch - 'A' + 10)
		case: return {}, false
		}
		v = v * 16 + d
	}
	return style.hex(v), true
}

tendril_theme :: proc(accent: style.Rgb) -> hnoss.Theme {
	t := hnoss.DEFAULT_THEME
	t.text               = {fg = FOAM}
	t.muted              = {fg = MIST}
	t.accent             = {fg = accent}
	t.border_kind        = .Rounded
	t.border             = {fg = TRENCH}
	t.border_focused     = {fg = accent}
	t.title              = {fg = FOAM, add = {.Bold}}
	t.selected           = {fg = ABYSS, bg = accent, add = {.Bold}}
	t.selected_unfocused = {fg = FOAM, bg = TRENCH}
	t.header             = {fg = VIOLET, add = {.Bold}}
	t.gauge_filled       = {fg = accent}
	t.gauge_empty        = {bg = TRENCH}
	t.tab                = {fg = MIST}
	t.tab_selected       = {fg = accent, add = {.Bold, .Underlined}}
	t.input              = {fg = FOAM, bg = DEEP}
	t.scrollbar_track    = {fg = TRENCH}
	t.scrollbar_thumb    = {fg = VIOLET}
	return t
}
