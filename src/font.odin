package msdfgen

import "core:c"
import "core:math/linalg"
import stbtt "vendor:stb/truetype"

// Thin wrapper around vendor:stb/truetype, used in place of msdfgen's
// FreeType-based ext/import-font.cpp. stb_truetype already ships with the
// Odin distribution (prebuilt vendor/stb/lib/stb_truetype.a), so this adds
// no new dependency to install.
Font :: struct {
	info: stbtt.fontinfo,
}

// Parses a TrueType/OpenType font from file data (the first font, for font
// collections). `data` must stay alive for the lifetime of Font: stb_truetype
// keeps a pointer into it rather than copying it.
font_load :: proc(data: []byte) -> (font: Font, ok: bool) {
	if len(data) == 0 do return {}, false
	offset := stbtt.GetFontOffsetForIndex(raw_data(data), 0)
	if offset < 0 do return {}, false
	if !stbtt.InitFont(&font.info, raw_data(data), offset) do return {}, false
	return font, true
}

// Returns the glyph index for a Unicode codepoint, or 0 if the font has no
// glyph for it (0 is also the "not found"/.notdef glyph per the TrueType spec).
font_find_glyph_index :: proc(font: ^Font, codepoint: rune) -> int {
	return int(stbtt.FindGlyphIndex(&font.info, codepoint))
}

// The scale factor that converts raw font-unit coordinates to em-normalized
// coordinates (1 unit = 1 em), matching msdfgen's FONT_SCALING_EM_NORMALIZED.
font_em_scale :: proc(font: ^Font) -> f64 {
	return f64(stbtt.ScaleForMappingEmToPixels(&font.info, 1))
}

// Advance width and left side bearing of a glyph, in em units.
font_glyph_advance :: proc(font: ^Font, glyph_index: int) -> (advance, left_bearing: f64) {
	adv, lsb: c.int
	stbtt.GetGlyphHMetrics(&font.info, c.int(glyph_index), &adv, &lsb)
	s := font_em_scale(font)
	return f64(adv) * s, f64(lsb) * s
}

// The glyph's visible bounding box, in em units.
font_glyph_bounds :: proc(font: ^Font, glyph_index: int) -> Bounds {
	x0, y0, x1, y1: c.int
	stbtt.GetGlyphBox(&font.info, c.int(glyph_index), &x0, &y0, &x1, &y1)
	s := font_em_scale(font)
	return {f64(x0) * s, f64(y0) * s, f64(x1) * s, f64(y1) * s}
}

// Font-wide vertical metrics, in em units: the ascender/descender extents
// and recommended line spacing.
font_metrics :: proc(font: ^Font) -> (ascent, descent, line_gap: f64) {
	a, d, lg: c.int
	stbtt.GetFontVMetrics(&font.info, &a, &d, &lg)
	s := font_em_scale(font)
	return f64(a) * s, f64(d) * s, f64(lg) * s
}

// Decomposes a glyph's outline into a Shape, in em units scaled by em_size
// (pass 1.0 for plain em-normalized coordinates), already normalized and
// ready for edge_coloring_simple + generate_msdf.
font_load_glyph :: proc(font: ^Font, glyph_index: int, em_size: f64 = 1) -> Shape {
	shape: Shape

	verts: [^]stbtt.vertex
	n := stbtt.GetGlyphShape(&font.info, c.int(glyph_index), &verts)
	if n <= 0 do return shape
	defer stbtt.FreeShape(&font.info, verts)

	scale := em_size * font_em_scale(font)

	contour: ^Contour
	pos: Vec2
	for i in 0 ..< int(n) {
		v := verts[i]
		p := Vec2{f64(v.x), f64(v.y)} * scale
		switch stbtt.vmove(v.type) {
		case .none:
		// Unreachable: every vertex stb_truetype emits carries a real command.
		case .vmove:
			contour = shape_add_contour(&shape)
			pos = p
		case .vline:
			if p != pos {
				append(&contour.edges, edge_make_linear(pos, p))
				pos = p
			}
		case .vcurve:
			ctrl := Vec2{f64(v.cx), f64(v.cy)} * scale
			if p != pos {
				append(&contour.edges, edge_make_quadratic(pos, ctrl, p))
				pos = p
			}
		case .vcubic:
			ctrl0 := Vec2{f64(v.cx), f64(v.cy)} * scale
			ctrl1 := Vec2{f64(v.cx1), f64(v.cy1)} * scale
			if p != pos || linalg.cross(ctrl0 - p, ctrl1 - p) != 0 {
				append(&contour.edges, edge_make_cubic(pos, ctrl0, ctrl1, p))
				pos = p
			}
		}
	}
	if len(shape.contours) > 0 && len(shape.contours[len(shape.contours) - 1].edges) == 0 {
		pop(&shape.contours)
	}

	shape_normalize(&shape)
	return shape
}
