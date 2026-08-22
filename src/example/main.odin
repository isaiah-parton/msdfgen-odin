// Dev-only smoke test: loads a system TTF, generates an MSDF for one
// glyph, and dumps it as a PNG for visual inspection. Not part of the
// library.
package main

import "core:fmt"
import "core:os"
import stbi "vendor:stb/image"
import msdf "../"

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
		msdf.edge_coloring_simple(&shape)

		width, height := 128, 128
		range_px := 8.0
		bounds := msdf.shape_get_bounds(shape)
		glyph_w := bounds.r - bounds.l
		glyph_h := bounds.t - bounds.b
		fit := max(glyph_w, glyph_h)
		scale_fit := fit > 0 ? (f64(min(width, height)) - 2 * range_px) / fit : 1.0
		scale := msdf.Vec2{scale_fit, scale_fit}
		translate := msdf.Vec2 {
			(f64(width) / scale_fit - glyph_w) / 2 - bounds.l,
			(f64(height) / scale_fit - glyph_h) / 2 - bounds.b,
		}

		pixels := make([]f32, width * height * 3)
		msdf.generate_msdf(pixels, width, height, &shape, range_px, scale, translate)

		// Convert to top-down RGB8 for PNG output (pixels row 0 is
		// shape-space bottom; PNG row 0 is conventionally the top).
		rgb := make([]u8, width * height * 3)
		for y in 0 ..< height {
			src_row := height - 1 - y
			for x in 0 ..< width {
				for c in 0 ..< 3 {
					v := pixels[(src_row * width + x) * 3 + c]
					rgb[(y * width + x) * 3 + c] = u8(clamp(v, 0, 1) * 255 + 0.5)
				}
			}
		}

		out_path := fmt.tprintf("glyph_%d.png", r)
		stbi.write_png(fmt.ctprintf("%s", out_path), i32(width), i32(height), 3, raw_data(rgb), i32(width * 3))
		fmt.println("wrote", out_path)

		// A resolved (median-of-3, thresholded at 0.5) grayscale preview --
		// this is what the MSDF reconstructs to, and is much easier to
		// visually sanity-check than the raw RGB channels above.
		mask := make([]u8, width * height)
		for y in 0 ..< height {
			src_row := height - 1 - y
			for x in 0 ..< width {
				i := (src_row * width + x) * 3
				med := msdf.median(f64(pixels[i]), f64(pixels[i + 1]), f64(pixels[i + 2]))
				mask[y * width + x] = u8(clamp(med, 0, 1) * 255 + 0.5)
			}
		}
		mask_path := fmt.tprintf("glyph_%d_mask.png", r)
		stbi.write_png(fmt.ctprintf("%s", mask_path), i32(width), i32(height), 1, raw_data(mask), i32(width))
		fmt.println("wrote", mask_path)
		delete(mask)

		delete(pixels)
		delete(rgb)
	}
}
