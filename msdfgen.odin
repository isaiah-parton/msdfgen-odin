package msdfgen

import "core:c"

foreign import msdfgen "lib/linux/msdfgen.a"

Contour :: struct {}
Shape :: struct {}
Charset :: struct {}
Glyph_Geometry :: struct {}
Glyph_Range :: struct {
	first_glyph: ^Glyph_Geometry,
	glyph_count: c.size_t,
}
Font_Handle :: struct {
	font: rawptr,
	owned: c.bool,
}
Font_Geometry :: struct {}
Immediate_Atlas_Generator :: struct {}
Packer :: struct {}
Dimensions_Constraint :: enum {
	None,
	Square,
	Even_Square,
	Multiple_Of_Four_Square,
	Power_Of_Two_Rectangle,
	Power_Of_Two_Square,
}
Edge_Coloring_Function :: enum {
	Simple,
	Ink_Trap,
	By_Distance,
}

@(default_calling_convention="c")
foreign msdfgen {
	@(link_name="msaPackerCreate")
	make_packer :: proc() -> ^Packer ---

	@(link_name="msaPackerDestroy")
	packer_destroy :: proc(self: ^Packer) ---

	@(link_name="msaPackerPack")
	packer_pack :: proc(self: ^Packer, range: Glyph_Range) -> c.int ---

	@(link_name="msaPackerSetDimensions")
	packer_set_dimensions :: proc(self: ^Packer, width, height: c.int) ---

	@(link_name="msaPackerUnsetDimensions")
	packer_unset_dimensions :: proc(self: ^Packer) ---

	@(link_name="msaPackerSetDimensionsConstraint")
	packer_set_dimensions_constraint :: proc(self: ^Packer, dimensions_constraint: Dimensions_Constraint) ---

	@(link_name="msaPackerSetSpacing")
	packer_set_spacing :: proc(self: ^Packer, spacing: c.int) ---

	@(link_name="msaPackerSetScale")
	packer_set_scale :: proc(self: ^Packer, scale: c.double) ---

	@(link_name="msaSetMinimumScale")
	packer_set_minimum_scale :: proc(self: ^Packer, min_scale: c.double) ---

	@(link_name="msaPackerSetUnitRange")
	packer_set_unit_range :: proc(self: ^Packer, unit_lower, unit_upper: c.double) ---

	@(link_name="msaPackerSetPixelRange")
	packer_set_pixel_range :: proc(self: ^Packer, px_lower, px_upper: c.double) ---

	@(link_name="msaPackerSetMiterLimit")
	packer_set_miter_limit :: proc(self: ^Packer, miter_limit: c.double) ---

	@(link_name="msaPackerSetOriginPixelAlignment")
	packer_set_origin_pixel_alignment :: proc(self: ^Packer, align: c.bool) ---

	@(link_name="msaPackerSetOriginPixelAlignmentXY")
	packer_set_origin_pixel_alignment_xy :: proc(self: ^Packer, align_x, align_y: c.bool) ---

	@(link_name="msaPackerSetInnerUnitPadding")
	packer_set_inner_unit_padding :: proc(self: ^Packer, l, b, r, t: c.double) ---

	@(link_name="msaPackerSetOuterUnitPadding")
	packer_set_outer_unit_padding :: proc(self: ^Packer, l, b, r, t: c.double) ---

	@(link_name="msaPackerSetInnerPixelPadding")
	packer_set_inner_pixel_padding :: proc(self: ^Packer, l, b, r, t: c.double) ---

	@(link_name="msaPackerSetOuterPixelPadding")
	packer_set_outer_pixel_padding :: proc(self: ^Packer, l, b, r, t: c.double) ---

	@(link_name="msaPackerGetDimensions")
	packer_get_dimensions :: proc(self: ^Packer, width, height: ^c.int) ---

	@(link_name="msaPackerGetScale")
	packer_get_scale :: proc(self: ^Packer) -> c.double ---

	@(link_name="msaPackerGetPixelRange")
	packer_get_pixel_range :: proc(self: ^Packer, px_lower, px_upper: ^c.double) ---

	@(link_name="msaImmediateAtlasGeneratorCreate")
	make_immediate_atlas_generator :: proc(width, height: c.uint32_t) -> ^Immediate_Atlas_Generator ---

	@(link_name="msaImmediateAtlasGeneratorDestroy")
	immediate_atlas_generator_destroy :: proc(self: ^Immediate_Atlas_Generator) ---

	@(link_name="msaImmediateAtlasGeneratorSetThreadCount")
	immediate_atlas_generator_set_thread_count :: proc(self: ^Immediate_Atlas_Generator, thread_count: c.int) ---

	@(link_name="msaImmediateAtlasGeneratorGenerate")
	immediate_atlas_generator_generate :: proc(self: ^Immediate_Atlas_Generator, range: Glyph_Range) ---

	@(link_name="msaImmediateAtlasGeneratorGetBitmap")
	immediate_atlas_generator_get_bitmap :: proc(self: ^Immediate_Atlas_Generator, width, height: c.int) -> [^]c.float ---

	@(link_name="msaFontGeometryCreate")
	make_font_geometry :: proc() -> ^Font_Geometry ---

	@(link_name="msaFontGeometryDestroy")
	font_geometry_destroy :: proc(self: ^Font_Geometry) ---

	@(link_name="msaFontGeometryLoadCharset")
	font_geometry_load_charset :: proc(self: ^Font_Geometry, font: ^Font_Handle, font_scale: c.double, charset: ^Charset) -> c.int ---

	@(link_name="msaFontGeometryGetGlyphs")
	font_geometry_get_glyphs :: proc(self: ^Font_Geometry) -> Glyph_Range ---

	@(link_name="msaCharsetCreate")
	make_charset :: proc() -> ^Charset ---

	@(link_name="msaCharsetASCII")
	make_charset_ascii :: proc() -> ^Charset ---

	@(link_name="msaCharsetDestroy")
	charset_destroy :: proc(self: ^Charset) ---

	@(link_name="msaCharsetAdd")
	charset_add :: proc(self: ^Charset, cp: c.uint32_t) ---

	@(link_name="msaCharsetRemove")
	charset_remove :: proc(self: ^Charset, cp: c.uint32_t) ---

	@(link_name="msaCharsetSize")
	charset_size :: proc(self: ^Charset) -> c.size_t ---

	@(link_name="msaGlyphRangeSetEdgeColoring")
	glyph_range_set_edge_coloring :: proc(self: Glyph_Range, index: c.size_t, fn: Edge_Coloring_Function, angle_threshold: c.double, seed: c.ulonglong) ---

	@(link_name="msaGlyphRangeGetAdvance")
	glyph_range_get_advance :: proc(self: Glyph_Range, index: c.size_t) -> f32 ---

	@(link_name="msaGlyphRangeGetQuadPlaneBounds")
	glyph_range_get_quad_plane_bounds :: proc(self: Glyph_Range, index: c.size_t, l, b, r, t: ^c.double) ---

	@(link_name="msaGlyphRangeGetGlyphIndex")
	glyph_range_get_glyph_index :: proc(self: Glyph_Range, index: c.size_t) -> c.size_t ---

	@(link_name="msaGlyphRangeGetCodepoint")
	glyph_range_get_codepoint :: proc(self: Glyph_Range, index: c.size_t) -> c.uint32_t ---

	@(link_name="msShapeCreate")
	make_shape :: proc() -> Shape ---

	@(link_name="msShapeDestroy")
	shape_destroy :: proc(self: ^Shape) ---

	@(link_name="msShapeAddContour")
	shape_add_contour :: proc(self: ^Shape) -> ^Contour ---

	@(link_name="msShapeNormalize")
	shape_normalize :: proc(self: ^Shape) ---

	@(link_name="msShapeOrientContours")
	shape_orient_contours :: proc(self: ^Shape) ---

	@(link_name="msEdgeColoringSimple")
	edge_coloring_simple :: proc(self: ^Shape, angle_threshold: c.double, seed: c.ulonglong) ---

	@(link_name="msContourAddLinearEdge")
	contour_add_linear_edge :: proc(self: ^Contour, x1, y1, x2, y2: c.double) ---

	@(link_name="msContourAddQuadraticEdge")
	contour_add_quadratic_edge :: proc(self: ^Contour, x1, y1, x2, y2, x3, y3: c.double) ---

	@(link_name="msContourAddCubicEdge")
	contour_add_cubic_edge :: proc(self: ^Contour, x1, y1, x2, y2, x3, y3, x4, y4: c.double) ---

	@(link_name="msGenerateSDF")
	generate_sdf :: proc(data: [^]f32, w, h: c.int, shape: ^Shape, range: c.double, sx, sy, dx, dy: c.double) ---

	@(link_name="msGeneratePseudoSDF")
	generate_pseudo_sdf :: proc(data: [^]f32, w, h: c.int, shape: ^Shape, range: c.double, sx, sy, dx, dy: c.double) ---

	@(link_name="msGenerateMSDF")
	generate_msdf :: proc(data: [^]f32, w, h: c.int, shape: ^Shape, range: c.double, sx, sy, dx, dy: c.double) ---

	@(link_name="msGenerateMTSDF")
	generate_mtsdf :: proc(data: [^]f32, w, h: c.int, shape: ^Shape, range: c.double, sx, sy, dx, dy: c.double) ---
}
