package msdfgen

import "core:math"
import "core:math/linalg"
import "core:slice"

// A single closed contour of a shape: an ordered, cyclic sequence of edges
// where each edge's endpoint coincides with the next edge's start point.
Contour :: struct {
	edges: [dynamic]Edge_Segment,
}

shoelace :: proc(a, b: Vec2) -> f64 {
	return (b.x - a.x) * (a.y + b.y)
}

// The contour's winding direction: 1 for counter-clockwise, -1 for
// clockwise, 0 for a degenerate (edgeless) contour.
contour_winding :: proc(c: Contour) -> int {
	n := len(c.edges)
	if n == 0 do return 0
	total: f64 = 0
	switch n {
	case 1:
		a := edge_point(c.edges[0], 0)
		b := edge_point(c.edges[0], 1.0 / 3)
		cc := edge_point(c.edges[0], 2.0 / 3)
		total += shoelace(a, b) + shoelace(b, cc) + shoelace(cc, a)
	case 2:
		a := edge_point(c.edges[0], 0)
		b := edge_point(c.edges[0], 0.5)
		cc := edge_point(c.edges[1], 0)
		d := edge_point(c.edges[1], 0.5)
		total += shoelace(a, b) + shoelace(b, cc) + shoelace(cc, d) + shoelace(d, a)
	case:
		prev := edge_point(c.edges[n - 1], 0)
		for e in c.edges {
			cur := edge_point(e, 0)
			total += shoelace(prev, cur)
			prev = cur
		}
	}
	return int(total > 0) - int(total < 0)
}

contour_reverse :: proc(c: ^Contour) {
	n := len(c.edges)
	for i in 0 ..< n / 2 {
		c.edges[i], c.edges[n - 1 - i] = c.edges[n - 1 - i], c.edges[i]
	}
	for i in 0 ..< n {
		edge_reverse(&c.edges[i])
	}
}

contour_bound :: proc(c: Contour, min, max: ^Vec2) {
	for e in c.edges {
		edge_bound(e, min, max)
	}
}

// Vector shape representation: an unordered collection of closed contours.
// Fill is determined by the nonzero winding rule.
Shape :: struct {
	contours: [dynamic]Contour,
}

shape_add_contour :: proc(s: ^Shape) -> ^Contour {
	append(&s.contours, Contour{})
	return &s.contours[len(s.contours) - 1]
}

// Assumes the shape's contours are wound arbitrarily (as with hand-authored
// SVG paths, which don't guarantee msdfgen's nonzero-fill convention the way
// TrueType outlines do) and reverses whichever ones are wound backwards, so
// that filling by the nonzero rule reproduces the even-odd fill pattern of
// the original contours. Call this (before shape_normalize) for shapes
// built from build_shape_from_svg_path/load_svg; it's unnecessary for font
// glyphs, which are already wound consistently.
orient_contours :: proc(s: ^Shape) {
	Intersection :: struct {
		x:             f64,
		direction:     int,
		contour_index: int,
	}
	ratio := 0.5 * (math.sqrt(f64(5)) - 1) // an irrational number to minimize the chance of an intersection landing on a corner

	n := len(s.contours)
	orientations := make([]int, n)
	defer delete(orientations)
	intersections := make([dynamic]Intersection, 0, 16)
	defer delete(intersections)

	for i in 0 ..< n {
		if orientations[i] != 0 || len(s.contours[i].edges) == 0 do continue

		// Find a Y that crosses the contour (usually the first edge suffices;
		// fall back to sampling within edges in case all endpoints are collinear).
		y0 := edge_point(s.contours[i].edges[0], 0).y
		y1 := y0
		for e in s.contours[i].edges {
			if y0 != y1 do break
			y1 = edge_point(e, 1).y
		}
		if y0 == y1 {
			for e in s.contours[i].edges {
				if y0 != y1 do break
				y1 = edge_point(e, ratio).y
			}
		}
		y := mix(y0, y1, ratio)

		clear(&intersections)
		for j in 0 ..< n {
			for e in s.contours[j].edges {
				xs, dys, cnt := edge_scanline_intersections(e, y)
				for k in 0 ..< cnt {
					append(&intersections, Intersection{xs[k], dys[k], j})
				}
			}
		}
		if len(intersections) == 0 do continue

		slice.sort_by(intersections[:], proc(a, b: Intersection) -> bool {
			return a.x < b.x
		})
		// Disqualify multiple intersections at the same X.
		for j in 1 ..< len(intersections) {
			if intersections[j].x == intersections[j - 1].x {
				intersections[j].direction = 0
				intersections[j - 1].direction = 0
			}
		}
		// Inspect the scanline and deduce the orientation of each contour it crosses.
		for j in 0 ..< len(intersections) {
			isect := intersections[j]
			if isect.direction != 0 {
				orientations[isect.contour_index] += 2 * (int(j % 2 == 1) ~ int(isect.direction > 0)) - 1
			}
		}
	}
	for i in 0 ..< n {
		if orientations[i] < 0 do contour_reverse(&s.contours[i])
	}
}

// Splits single-edge contours into three so that every contour has enough
// distinct edges for neighbor-aware distance/coloring logic to work.
// (msdfgen also "deconverges" edges that meet at a near-180° cusp for
// numerical robustness; skipped here since real font outlines essentially
// never produce that degenerate case.)
shape_normalize :: proc(s: ^Shape) {
	for &c in s.contours {
		if len(c.edges) == 1 {
			e0, e1, e2 := edge_split_in_thirds(c.edges[0])
			clear(&c.edges)
			append(&c.edges, e0, e1, e2)
		}
	}
}

shape_bound :: proc(s: Shape, min, max: ^Vec2) {
	for c in s.contours {
		contour_bound(c, min, max)
	}
}

Bounds :: struct {
	l, b, r, t: f64,
}

// The minimum bounding box that fits the shape.
shape_get_bounds :: proc(s: Shape) -> Bounds {
	LARGE :: 1e240
	lo := Vec2{LARGE, LARGE}
	hi := Vec2{-LARGE, -LARGE}
	shape_bound(s, &lo, &hi)
	return {lo.x, lo.y, hi.x, hi.y}
}

// --- Simple edge coloring ---
//
// Ported from msdfgen's edgeColoringSimple: assigns each edge to one or two
// of the R/G/B channels so that sharp corners always have a channel
// discontinuity between them, which is what lets the MSDF reconstruct sharp
// corners. Must be called after shape_normalize and before generate_msdf.

symmetrical_trichotomy :: proc(position, n: int) -> int {
	return int(3 + 2.875 * f64(position) / f64(n - 1) - 1.4375 + .5) - 3
}

is_corner :: proc(a_dir, b_dir: Vec2, cross_threshold: f64) -> bool {
	return linalg.dot(a_dir, b_dir) <= 0 || abs(linalg.cross(a_dir, b_dir)) > cross_threshold
}

seed_extract2 :: proc(seed: ^u64) -> int {
	v := int(seed^ & 1)
	seed^ >>= 1
	return v
}

seed_extract3 :: proc(seed: ^u64) -> int {
	v := int(seed^ % 3)
	seed^ /= 3
	return v
}

init_color :: proc(seed: ^u64) -> Edge_Color {
	colors := [3]Edge_Color{COLOR_CYAN, COLOR_MAGENTA, COLOR_YELLOW}
	return colors[seed_extract3(seed)]
}

switch_color :: proc(color: ^Edge_Color, seed: ^u64) {
	shifted := u8(color^) << u8(1 + seed_extract2(seed))
	color^ = Edge_Color((shifted | (shifted >> 3)) & u8(COLOR_WHITE))
}

switch_color_banned :: proc(color: ^Edge_Color, seed: ^u64, banned: Edge_Color) {
	combined := Edge_Color(u8(color^) & u8(banned))
	if combined == COLOR_RED || combined == COLOR_GREEN || combined == COLOR_BLUE {
		color^ = Edge_Color(u8(combined) ~ u8(COLOR_WHITE))
	} else {
		switch_color(color, seed)
	}
}

edge_coloring_simple :: proc(s: ^Shape, angle_threshold: f64 = 3.0, seed: u64 = 0) {
	cross_threshold := math.sin(angle_threshold)
	seed := seed
	color := init_color(&seed)
	corners := make([dynamic]int, 0, 8)
	defer delete(corners)

	for &contour in s.contours {
		n := len(contour.edges)
		if n == 0 do continue
		clear(&corners)
		prev_direction := edge_direction(contour.edges[n - 1], 1)
		for i in 0 ..< n {
			if is_corner(normalize(prev_direction), normalize(edge_direction(contour.edges[i], 0)), cross_threshold) {
				append(&corners, i)
			}
			prev_direction = edge_direction(contour.edges[i], 1)
		}

		switch len(corners) {
		case 0:
			// Smooth contour: entirely one color.
			switch_color(&color, &seed)
			for &e in contour.edges do e.color = color

		case 1:
			// "Teardrop" case: a single corner splits the contour into two
			// smooth arcs sharing the middle color.
			colors: [3]Edge_Color
			switch_color(&color, &seed)
			colors[0] = color
			colors[1] = COLOR_WHITE
			switch_color(&color, &seed)
			colors[2] = color
			corner := corners[0]
			if n >= 3 {
				m := n
				for i in 0 ..< m {
					contour.edges[(corner + i) % m].color = colors[1 + symmetrical_trichotomy(i, m)]
				}
			} else {
				// Fewer than three edges for three colors: edges must be split.
				p0a, p0b, p0c := edge_split_in_thirds(contour.edges[0])
				new_edges := make([dynamic]Edge_Segment, 0, 6)
				if n >= 2 {
					p1a, p1b, p1c := edge_split_in_thirds(contour.edges[1])
					if corner == 0 {
						p0a.color, p0b.color = colors[0], colors[0]
						p0c.color, p1a.color = colors[1], colors[1]
						p1b.color, p1c.color = colors[2], colors[2]
						append(&new_edges, p0a, p0b, p0c, p1a, p1b, p1c)
					} else {
						p1a.color, p1b.color = colors[0], colors[0]
						p1c.color, p0a.color = colors[1], colors[1]
						p0b.color, p0c.color = colors[2], colors[2]
						append(&new_edges, p1a, p1b, p1c, p0a, p0b, p0c)
					}
				} else {
					p0a.color, p0b.color, p0c.color = colors[0], colors[1], colors[2]
					append(&new_edges, p0a, p0b, p0c)
				}
				clear(&contour.edges)
				append(&contour.edges, ..new_edges[:])
				delete(new_edges)
			}

		case:
			// Multiple corners: color each spline (run of edges between two
			// corners) a distinct color, alternating so adjacent splines
			// never share a channel.
			corner_count := len(corners)
			spline := 0
			start := corners[0]
			m := n
			switch_color(&color, &seed)
			initial_color := color
			for i in 0 ..< m {
				index := (start + i) % m
				if spline + 1 < corner_count && corners[spline + 1] == index {
					spline += 1
					banned: Edge_Color = spline == corner_count - 1 ? initial_color : COLOR_BLACK
					switch_color_banned(&color, &seed, banned)
				}
				contour.edges[index].color = color
			}
		}
	}
}
