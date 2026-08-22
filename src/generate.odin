package msdfgen

import "core:math"
import "core:math/linalg"

// The span of signed distance values (in shape units) that gets linearly
// mapped to the [0, 1] pixel output range.
Range :: struct {
	lower, upper: f64,
}

distance_map :: proc(d: f64, r: Range) -> f64 {
	scale := 1 / (r.upper - r.lower)
	translate := -r.lower
	return scale * (d + translate)
}

// Converts a symmetrical pixel-space range (e.g. 4 pixels wide) into the
// shape-space range needed by distance_map, matching msdfgen's handling of
// -pxrange.
px_range_to_range :: proc(range_px: f64, scale: Vec2) -> Range {
	s := min(scale.x, scale.y)
	return {-0.5 * range_px / s, 0.5 * range_px / s}
}

// --- Single-channel true signed distance (generate_sdf) ---

generate_sdf :: proc(pixels: []f32, width, height: int, shape: ^Shape, range_px: f64, scale, translate: Vec2) {
	r := px_range_to_range(range_px, scale)
	for y in 0 ..< height {
		for x in 0 ..< width {
			p := Vec2{f64(x) + .5, f64(y) + .5} / scale - translate
			min_distance := signed_distance_min()
			for &contour in shape.contours {
				for &edge in contour.edges {
					d, _ := edge_signed_distance(edge, p)
					if sd_less(d, min_distance) do min_distance = d
				}
			}
			pixels[y * width + x] = f32(distance_map(min_distance.distance, r))
		}
	}
}

// --- Multi-channel signed distance (generate_msdf) ---
//
// A concise, cache-free reimplementation of msdfgen's MultiDistanceSelector
// / PerpendicularDistanceSelectorBase: for each pixel, every edge is folded
// into a running-minimum accumulator per color channel it belongs to. The
// "EdgeCache" coherency optimization in the original exists purely to skip
// edges that provably can't beat the current minimum when scanning pixels
// in raster order; since addEdgeTrueDistance/addEdgePerpendicularDistance
// are order-independent running minimums, always visiting every edge gives
// identical results without that bookkeeping (just more distance
// evaluations per pixel).
Distance_Selector :: struct {
	min_true_distance:          Signed_Distance,
	min_negative_perpendicular: f64,
	min_positive_perpendicular: f64,
	near_edge:                  ^Edge_Segment,
	near_edge_param:            f64,
}

distance_selector_init :: proc() -> Distance_Selector {
	return {min_true_distance = signed_distance_min(), min_negative_perpendicular = -math.F64_MAX, min_positive_perpendicular = math.F64_MAX}
}

get_perpendicular_distance :: proc(distance: ^f64, ep, edge_dir: Vec2) -> bool {
	ts := linalg.dot(ep, edge_dir)
	if ts > 0 {
		perpendicular_distance := linalg.cross(ep, edge_dir)
		if abs(perpendicular_distance) < abs(distance^) {
			distance^ = perpendicular_distance
			return true
		}
	}
	return false
}

add_edge_true_distance :: proc(sel: ^Distance_Selector, edge: ^Edge_Segment, distance: Signed_Distance, param: f64) {
	if sd_less(distance, sel.min_true_distance) {
		sel.min_true_distance = distance
		sel.near_edge = edge
		sel.near_edge_param = param
	}
}

add_edge_perpendicular_distance :: proc(sel: ^Distance_Selector, distance: f64) {
	if distance <= 0 && distance > sel.min_negative_perpendicular {
		sel.min_negative_perpendicular = distance
	}
	if distance >= 0 && distance < sel.min_positive_perpendicular {
		sel.min_positive_perpendicular = distance
	}
}

distance_selector_compute :: proc(sel: Distance_Selector, p: Vec2) -> f64 {
	min_distance := sel.min_true_distance.distance < 0 ? sel.min_negative_perpendicular : sel.min_positive_perpendicular
	if sel.near_edge != nil {
		distance := sel.min_true_distance
		edge_distance_to_perpendicular_distance(sel.near_edge^, &distance, p, sel.near_edge_param)
		if abs(distance.distance) < abs(min_distance) {
			min_distance = distance.distance
		}
	}
	return min_distance
}

// Folds one edge's contribution into the R/G/B accumulators. prev_edge and
// next_edge are the edge's cyclic neighbors within its contour, used to
// determine whether the perpendicular distance to this edge's endpoints is
// actually relevant (i.e. the query point falls in this edge's "domain"
// rather than a neighbor's).
process_edge :: proc(r, g, b: ^Distance_Selector, p: Vec2, prev_edge, edge, next_edge: ^Edge_Segment) {
	if edge.color == COLOR_BLACK do return

	distance, param := edge_signed_distance(edge^, p)
	if (edge.color & COLOR_RED) != 0 do add_edge_true_distance(r, edge, distance, param)
	if (edge.color & COLOR_GREEN) != 0 do add_edge_true_distance(g, edge, distance, param)
	if (edge.color & COLOR_BLUE) != 0 do add_edge_true_distance(b, edge, distance, param)

	ap := p - edge_point(edge^, 0)
	bp := p - edge_point(edge^, 1)
	a_dir := normalize(edge_direction(edge^, 0), true)
	b_dir := normalize(edge_direction(edge^, 1), true)
	prev_dir := normalize(edge_direction(prev_edge^, 1), true)
	next_dir := normalize(edge_direction(next_edge^, 0), true)
	add := linalg.dot(ap, normalize(prev_dir + a_dir, true))
	bdd := -linalg.dot(bp, normalize(b_dir + next_dir, true))

	if add > 0 {
		pd := distance.distance
		if get_perpendicular_distance(&pd, ap, -a_dir) {
			pd = -pd
			if (edge.color & COLOR_RED) != 0 do add_edge_perpendicular_distance(r, pd)
			if (edge.color & COLOR_GREEN) != 0 do add_edge_perpendicular_distance(g, pd)
			if (edge.color & COLOR_BLUE) != 0 do add_edge_perpendicular_distance(b, pd)
		}
	}
	if bdd > 0 {
		pd := distance.distance
		if get_perpendicular_distance(&pd, bp, b_dir) {
			if (edge.color & COLOR_RED) != 0 do add_edge_perpendicular_distance(r, pd)
			if (edge.color & COLOR_GREEN) != 0 do add_edge_perpendicular_distance(g, pd)
			if (edge.color & COLOR_BLUE) != 0 do add_edge_perpendicular_distance(b, pd)
		}
	}
}

// Generates a multi-channel signed distance field into pixels (row-major,
// 3 floats per pixel, row 0 = smallest shape-space Y). Edge colors must
// already be assigned (see edge_coloring_simple). scale/translate map shape
// coordinates to pixel coordinates: pixel = scale*(shape_coord+translate).
// range_px is the symmetrical distance range, in output pixels, that the
// [0, 1] output values span.
generate_msdf :: proc(pixels: []f32, width, height: int, shape: ^Shape, range_px: f64, scale, translate: Vec2, correct_errors := true) {
	r := px_range_to_range(range_px, scale)

	for y in 0 ..< height {
		for x in 0 ..< width {
			p := Vec2{f64(x) + .5, f64(y) + .5} / scale - translate

			r_sel := distance_selector_init()
			g_sel := distance_selector_init()
			b_sel := distance_selector_init()

			for &contour in shape.contours {
				n := len(contour.edges)
				for i in 0 ..< n {
					prev := &contour.edges[(i - 1 + n) % n]
					cur := &contour.edges[i]
					next := &contour.edges[(i + 1) % n]
					process_edge(&r_sel, &g_sel, &b_sel, p, prev, cur, next)
				}
			}

			idx := (y * width + x) * 3
			pixels[idx + 0] = f32(distance_map(distance_selector_compute(r_sel, p), r))
			pixels[idx + 1] = f32(distance_map(distance_selector_compute(g_sel, p), r))
			pixels[idx + 2] = f32(distance_map(distance_selector_compute(b_sel, p), r))
		}
	}

	if correct_errors {
		msdf_error_correction_legacy(pixels, width, height, 1.0001 / range_px)
	}
}

// --- Error correction ---
//
// A simplified, self-contained port of msdfgen's legacy error correction
// (msdfErrorCorrection_legacy): scans neighboring pixels for a channel
// "clash" -- a sign of the classic MSDF interpolation artifact -- and
// flattens the offending pixel to its median (making it behave like a
// plain SDF there). This is a good deal simpler than msdfgen's current
// default (MSDFErrorCorrection, which additionally needs the source shape
// and a rasterizer to precisely protect real edges/corners), at the cost of
// being a coarser heuristic. threshold is in normalized [0, 1] output units;
// generate_msdf derives a default from range_px.
msdf_error_correction_legacy :: proc(pixels: []f32, width, height: int, threshold: f64) {
	Coord :: struct {
		x, y: int,
	}
	clashes := make([dynamic]Coord, 0, 64)
	defer delete(clashes)

	find_and_flatten :: proc(pixels: []f32, width, height: int, threshold: f64, clashes: ^[dynamic]Coord) {
		clear(clashes)
		for y in 0 ..< height {
			for x in 0 ..< width {
				p := pixel_at(pixels, width, x, y)
				clash :=
					(x > 0 && detect_clash(p, pixel_at(pixels, width, x - 1, y), threshold)) ||
					(x < width - 1 && detect_clash(p, pixel_at(pixels, width, x + 1, y), threshold)) ||
					(y > 0 && detect_clash(p, pixel_at(pixels, width, x, y - 1), threshold)) ||
					(y < height - 1 && detect_clash(p, pixel_at(pixels, width, x, y + 1), threshold))
				if clash do append(clashes, Coord{x, y})
			}
		}
		for c in clashes {
			p := pixel_at(pixels, width, c.x, c.y)
			med := f32(median(f64(p[0]), f64(p[1]), f64(p[2])))
			p[0], p[1], p[2] = med, med, med
		}
	}

	find_and_flatten(pixels, width, height, threshold, &clashes)

	// Diagonal neighbors use a looser (summed) threshold, matching msdfgen.
	clear(&clashes)
	diag_threshold := 2 * threshold
	for y in 0 ..< height {
		for x in 0 ..< width {
			p := pixel_at(pixels, width, x, y)
			clash :=
				(x > 0 && y > 0 && detect_clash(p, pixel_at(pixels, width, x - 1, y - 1), diag_threshold)) ||
				(x < width - 1 && y > 0 && detect_clash(p, pixel_at(pixels, width, x + 1, y - 1), diag_threshold)) ||
				(x > 0 && y < height - 1 && detect_clash(p, pixel_at(pixels, width, x - 1, y + 1), diag_threshold)) ||
				(x < width - 1 && y < height - 1 && detect_clash(p, pixel_at(pixels, width, x + 1, y + 1), diag_threshold))
			if clash do append(&clashes, Coord{x, y})
		}
	}
	for c in clashes {
		p := pixel_at(pixels, width, c.x, c.y)
		med := f32(median(f64(p[0]), f64(p[1]), f64(p[2])))
		p[0], p[1], p[2] = med, med, med
	}
}

pixel_at :: proc(pixels: []f32, width, x, y: int) -> []f32 {
	idx := (y * width + x) * 3
	return pixels[idx:idx + 3]
}

detect_clash :: proc(a, b: []f32, threshold: f64) -> bool {
	a0, a1, a2 := a[0], a[1], a[2]
	b0, b1, b2 := b[0], b[1], b[2]
	if abs(b0 - a0) < abs(b1 - a1) {
		a0, a1 = a1, a0
		b0, b1 = b1, b0
	}
	if abs(b1 - a1) < abs(b2 - a2) {
		a1, a2 = a2, a1
		b1, b2 = b2, b1
		if abs(b0 - a0) < abs(b1 - a1) {
			a0, a1 = a1, a0
			b0, b1 = b1, b0
		}
	}
	return(
		f64(abs(b1 - a1)) >= threshold &&
		!(b0 == b1 && b0 == b2) && // Ignore if the other pixel has already been equalized.
		abs(a2 - .5) >= abs(b2 - .5) \
	) // Out of the pair, only flag the pixel farther from a shape edge.
}
