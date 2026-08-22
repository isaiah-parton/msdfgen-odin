// Dev-only smoke test: loads a system TTF and a couple of hand-written SVG
// icons, generates MSDFs, and dumps them as PNGs for visual inspection. Not
// part of the library.
package main

import "core:fmt"
import "core:os"
import stbi "vendor:stb/image"
import msdf "../"

// Renders shape into a width x height MSDF and writes both the raw RGB
// channels and a resolved (median-of-3) grayscale preview as PNGs.
// flip_vertical should be true for shapes in Y-up space (font glyphs) and
// false for shapes already in Y-down space (SVG), so the output PNG (which
// is always top-down) comes out right-side up either way.
render_shape :: proc(shape: ^msdf.Shape, name: string, flip_vertical: bool) {
	msdf.edge_coloring_simple(shape)

	width, height := 128, 128
	range_px := 8.0
	bounds := msdf.shape_get_bounds(shape^)
	w := bounds.r - bounds.l
	h := bounds.t - bounds.b
	fit := max(w, h)
	scale_fit := fit > 0 ? (f64(min(width, height)) - 2 * range_px) / fit : 1.0
	scale := msdf.Vec2{scale_fit, scale_fit}
	translate := msdf.Vec2 {
		(f64(width) / scale_fit - w) / 2 - bounds.l,
		(f64(height) / scale_fit - h) / 2 - bounds.b,
	}

	pixels := make([]f32, width * height * 3)
	defer delete(pixels)
	msdf.generate_msdf(pixels, width, height, shape, range_px, scale, translate)

	src_row_for :: proc(y, height: int, flip: bool) -> int {
		return flip ? height - 1 - y : y
	}

	rgb := make([]u8, width * height * 3)
	defer delete(rgb)
	mask := make([]u8, width * height)
	defer delete(mask)
	for y in 0 ..< height {
		src_row := src_row_for(y, height, flip_vertical)
		for x in 0 ..< width {
			i := (src_row * width + x) * 3
			for c in 0 ..< 3 {
				rgb[(y * width + x) * 3 + c] = u8(clamp(pixels[i + c], 0, 1) * 255 + 0.5)
			}
			med := msdf.median(f64(pixels[i]), f64(pixels[i + 1]), f64(pixels[i + 2]))
			mask[y * width + x] = u8(clamp(med, 0, 1) * 255 + 0.5)
		}
	}

	stbi.write_png(fmt.ctprintf("%s.png", name), i32(width), i32(height), 3, raw_data(rgb), i32(width * 3))
	stbi.write_png(fmt.ctprintf("%s_mask.png", name), i32(width), i32(height), 1, raw_data(mask), i32(width))
	fmt.printfln("wrote %s.png / %s_mask.png", name, name)
}

// A small icon combining a <path> and a non-overlapping <circle>, to check
// that multiple elements correctly union into one shape.
ICON_SVG :: `<svg width="64" height="64" viewBox="0 0 64 64">
	<path d="M8 32 L24 8 L40 32 L24 56 Z"/>
	<circle cx="48" cy="48" r="10"/>
</svg>`

// Two concentric same-winding circles: without orient_contours this would
// render as a solid disk (nonzero fill doesn't care about winding
// magnitude); with it, the inner circle should become a hole.
RING_SVG :: `<svg width="64" height="64" viewBox="0 0 64 64">
	<circle cx="32" cy="32" r="28"/>
	<circle cx="32" cy="32" r="14"/>
</svg>`

main :: proc() {
	font_path := "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf"
	data, err := os.read_entire_file_from_path(font_path, context.allocator)
	if err != nil {
		fmt.eprintln("failed to read font:", font_path, err)
		os.exit(1)
	}
	defer delete(data)

	font, font_ok := msdf.font_load(data)
	if !font_ok {
		fmt.eprintln("failed to parse font")
		os.exit(1)
	}

	for r in ([]rune{'A', 'O', 'g', '&'}) {
		glyph_index := msdf.font_find_glyph_index(&font, r)
		shape := msdf.font_load_glyph(&font, glyph_index)
		render_shape(&shape, fmt.tprintf("glyph_%d", r), true)
	}

	icon_shape, _, icon_ok := msdf.load_svg(transmute([]byte)string(ICON_SVG))
	if !icon_ok {
		fmt.eprintln("failed to load icon SVG")
		os.exit(1)
	}
	render_shape(&icon_shape, "icon", false)

	ring_shape, _, ring_ok := msdf.load_svg(transmute([]byte)string(RING_SVG))
	if !ring_ok {
		fmt.eprintln("failed to load ring SVG")
		os.exit(1)
	}
	render_shape(&ring_shape, "ring", false)
}
