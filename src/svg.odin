package msdfgen

import "core:encoding/xml"
import "core:math"
import "core:math/linalg"
import "core:strconv"

// --- SVG path data (`d` attribute) parsing ---
//
// Ported from msdfgen's buildShapeFromSvgPath: a small recursive-descent
// parser for the SVG path mini-language. No dependency beyond number
// parsing, so it works directly on a path string with no XML involved.

Svg_Cursor :: struct {
	s: string,
	i: int,
}

svg_skip_extra :: proc(c: ^Svg_Cursor) {
	for c.i < len(c.s) {
		switch c.s[c.i] {
		case ',', ' ', '\t', '\r', '\n':
			c.i += 1
		case:
			return
		}
	}
}

svg_read_node_type :: proc(c: ^Svg_Cursor) -> (byte, bool) {
	svg_skip_extra(c)
	if c.i >= len(c.s) do return 0, false
	ch := c.s[c.i]
	if ch != '+' && ch != '-' && ch != '.' && ch != ',' && !(ch >= '0' && ch <= '9') {
		c.i += 1
		return ch, true
	}
	return 0, false
}

svg_read_double :: proc(c: ^Svg_Cursor) -> (f64, bool) {
	svg_skip_extra(c)
	v, n, ok := strconv.parse_f64_prefix(c.s[c.i:])
	if !ok || n == 0 do return 0, false
	c.i += n
	return v, true
}

svg_read_coord :: proc(c: ^Svg_Cursor) -> (Vec2, bool) {
	x, ok_x := svg_read_double(c)
	if !ok_x do return {}, false
	y, ok_y := svg_read_double(c)
	if !ok_y do return {}, false
	return {x, y}, true
}

// SVG elliptical-arc flags (large-arc/sweep) are specified as a single 0/1
// digit, but are historically read with strtol-like laxness; a leading
// sign and multiple digits are tolerated.
svg_read_flag :: proc(c: ^Svg_Cursor) -> (bool, bool) {
	svg_skip_extra(c)
	start := c.i
	if c.i < len(c.s) && (c.s[c.i] == '+' || c.s[c.i] == '-') do c.i += 1
	digits_start := c.i
	for c.i < len(c.s) && c.s[c.i] >= '0' && c.s[c.i] <= '9' do c.i += 1
	if c.i == digits_start {
		c.i = start
		return false, false
	}
	v, _ := strconv.parse_i64_of_base(c.s[start:c.i], 10)
	return v != 0, true
}

svg_arc_angle :: proc(u, v: Vec2) -> f64 {
	return nonzero_sign(linalg.cross(u, v)) * math.acos(clamp(linalg.dot(u, v) / (linalg.length(u) * linalg.length(v)), -1, 1))
}

svg_rotate_vector :: proc(v, direction: Vec2) -> Vec2 {
	return {direction.x * v.x - direction.y * v.y, direction.y * v.x + direction.x * v.y}
}

ARC_SEGMENTS_PER_PI :: 2.0

// Approximates an SVG elliptical arc (the "A"/"a" path command) with a
// sequence of cubic Bézier edges appended to contour.
svg_add_arc_approximate :: proc(contour: ^Contour, start_point, end_point: Vec2, radius_in: Vec2, rotation: f64, large_arc, sweep: bool) {
	if end_point == start_point do return
	if radius_in.x == 0 || radius_in.y == 0 {
		append(&contour.edges, edge_make_linear(start_point, end_point))
		return
	}

	radius := Vec2{abs(radius_in.x), abs(radius_in.y)}
	axis := Vec2{math.cos(rotation), math.sin(rotation)}

	rm := svg_rotate_vector(.5 * (start_point - end_point), Vec2{axis.x, -axis.y})
	rm2 := rm * rm
	radius2 := radius * radius
	radius_gap := rm2.x / radius2.x + rm2.y / radius2.y
	if radius_gap > 1 {
		radius *= math.sqrt(radius_gap)
		radius2 = radius * radius
	}
	dq := radius2.x * rm2.y + radius2.y * rm2.x
	pq := radius2.x * radius2.y / dq - 1
	q := (large_arc == sweep ? -1.0 : 1.0) * math.sqrt(max(pq, 0))
	rc := Vec2{q * radius.x * rm.y / radius.y, -q * radius.y * rm.x / radius.x}
	center := .5 * (start_point + end_point) + svg_rotate_vector(rc, axis)

	angle_start := svg_arc_angle(Vec2{1, 0}, (rm - rc) / radius)
	angle_extent := svg_arc_angle((rm - rc) / radius, (-rm - rc) / radius)
	if !sweep && angle_extent > 0 {
		angle_extent -= 2 * math.PI
	} else if sweep && angle_extent < 0 {
		angle_extent += 2 * math.PI
	}

	// Guards against a degenerate (angle_extent == 0) arc dividing by zero below;
	// upstream doesn't hit this case in practice either since it's excluded above.
	segments := max(int(math.ceil(ARC_SEGMENTS_PER_PI / math.PI * abs(angle_extent))), 1)
	angle_increment := angle_extent / f64(segments)
	cl := 4.0 / 3.0 * math.sin(.5 * angle_increment) / (1 + math.cos(.5 * angle_increment))

	prev_node := start_point
	angle := angle_start
	for i in 0 ..< segments {
		d := Vec2{math.cos(angle), math.sin(angle)}
		cp0 := center + svg_rotate_vector(Vec2{d.x - cl * d.y, d.y + cl * d.x} * radius, axis)
		angle += angle_increment
		d = Vec2{math.cos(angle), math.sin(angle)}
		cp1 := center + svg_rotate_vector(Vec2{d.x + cl * d.y, d.y - cl * d.x} * radius, axis)
		node := i == segments - 1 ? end_point : center + svg_rotate_vector(d * radius, axis)
		append(&contour.edges, edge_make_cubic(prev_node, cp0, cp1, node))
		prev_node = node
	}
}

// Parses an SVG path `d` attribute into one or more contours appended to
// shape. endpoint_snap_range controls how close an unclosed contour's last
// point must be to its first to be snapped shut rather than closed with an
// extra line edge (pass a small fraction of the image's overall size, or 0
// to always add the closing edge).
build_shape_from_svg_path :: proc(shape: ^Shape, path_def: string, endpoint_snap_range: f64 = 0) -> bool {
	c := Svg_Cursor{s = path_def}
	node_type: byte = 0
	prev_node_type: byte = 0
	prev_node: Vec2
	node_type_preread := false

	outer: for {
		if !node_type_preread {
			nt, ok := svg_read_node_type(&c)
			if !ok do break outer
			node_type = nt
		}
		node_type_preread = false

		contour := shape_add_contour(shape)
		contour_start := true
		start_point: Vec2
		control: [2]Vec2
		node: Vec2

		for c.i < len(c.s) {
			next_contour := false
			switch node_type {
			case 'M', 'm':
				if !contour_start {
					node_type_preread = true
					next_contour = true
					break
				}
				p, ok := svg_read_coord(&c)
				if !ok do return false
				node = node_type == 'm' ? p + prev_node : p
				start_point = node
				node_type = node_type == 'm' ? 'l' : 'L'
			case 'Z', 'z':
				if contour_start do return false
				next_contour = true
			case 'L', 'l':
				p, ok := svg_read_coord(&c)
				if !ok do return false
				node = node_type == 'l' ? p + prev_node : p
				append(&contour.edges, edge_make_linear(prev_node, node))
			case 'H', 'h':
				v, ok := svg_read_double(&c)
				if !ok do return false
				node = Vec2{node_type == 'h' ? v + prev_node.x : v, prev_node.y}
				append(&contour.edges, edge_make_linear(prev_node, node))
			case 'V', 'v':
				v, ok := svg_read_double(&c)
				if !ok do return false
				node = Vec2{prev_node.x, node_type == 'v' ? v + prev_node.y : v}
				append(&contour.edges, edge_make_linear(prev_node, node))
			case 'Q', 'q':
				p0, ok0 := svg_read_coord(&c)
				p1, ok1 := svg_read_coord(&c)
				if !(ok0 && ok1) do return false
				if node_type == 'q' {
					control[0] = p0 + prev_node
					node = p1 + prev_node
				} else {
					control[0] = p0
					node = p1
				}
				append(&contour.edges, edge_make_quadratic(prev_node, control[0], node))
			case 'T', 't':
				if prev_node_type == 'Q' || prev_node_type == 'q' || prev_node_type == 'T' || prev_node_type == 't' {
					control[0] = node + node - control[0]
				} else {
					control[0] = node
				}
				p, ok := svg_read_coord(&c)
				if !ok do return false
				node = node_type == 't' ? p + prev_node : p
				append(&contour.edges, edge_make_quadratic(prev_node, control[0], node))
			case 'C', 'c':
				p0, ok0 := svg_read_coord(&c)
				p1, ok1 := svg_read_coord(&c)
				p2, ok2 := svg_read_coord(&c)
				if !(ok0 && ok1 && ok2) do return false
				if node_type == 'c' {
					control[0] = p0 + prev_node
					control[1] = p1 + prev_node
					node = p2 + prev_node
				} else {
					control[0] = p0
					control[1] = p1
					node = p2
				}
				append(&contour.edges, edge_make_cubic(prev_node, control[0], control[1], node))
			case 'S', 's':
				if prev_node_type == 'C' || prev_node_type == 'c' || prev_node_type == 'S' || prev_node_type == 's' {
					control[0] = node + node - control[1]
				} else {
					control[0] = node
				}
				p1, ok1 := svg_read_coord(&c)
				p2, ok2 := svg_read_coord(&c)
				if !(ok1 && ok2) do return false
				if node_type == 's' {
					control[1] = p1 + prev_node
					node = p2 + prev_node
				} else {
					control[1] = p1
					node = p2
				}
				append(&contour.edges, edge_make_cubic(prev_node, control[0], control[1], node))
			case 'A', 'a':
				radius, ok_r := svg_read_coord(&c)
				angle, ok_a := svg_read_double(&c)
				large_arc, ok_l := svg_read_flag(&c)
				sweep, ok_s := svg_read_flag(&c)
				p, ok_p := svg_read_coord(&c)
				if !(ok_r && ok_a && ok_l && ok_s && ok_p) do return false
				node = node_type == 'a' ? p + prev_node : p
				svg_add_arc_approximate(contour, prev_node, node, radius, angle * math.PI / 180, large_arc, sweep)
			case:
				return false
			}

			if next_contour do break
			contour_start = contour_start && (node_type == 'M' || node_type == 'm')
			prev_node = node
			prev_node_type = node_type
			nt, ok := svg_read_node_type(&c)
			if !ok do break
			node_type = nt
		}

		// Close the contour if it isn't already.
		if len(contour.edges) > 0 && prev_node != start_point {
			last := &contour.edges[len(contour.edges) - 1]
			first_point := contour.edges[0].p[0]
			if linalg.length(edge_point(last^, 1) - first_point) < endpoint_snap_range {
				edge_move_end_point(last, first_point)
			} else {
				append(&contour.edges, edge_make_linear(prev_node, start_point))
			}
		}
		prev_node = start_point
		prev_node_type = 0
	}
	return true
}

// --- Basic shape elements ---
//
// Upstream only supports these via Skia (a full geometry/boolean-ops
// library, far out of scope here); without it, it just flags them as
// "incomplete" and skips them. Rect/circle/ellipse/polygon are simple
// enough to turn directly into contours ourselves.

svg_add_rect :: proc(shape: ^Shape, pos, dims, radius_in: Vec2) {
	if dims.x <= 0 || dims.y <= 0 do return
	rx := clamp(radius_in.x, 0, dims.x / 2)
	ry := clamp(radius_in.y, 0, dims.y / 2)
	x0, y0 := pos.x, pos.y
	x1, y1 := pos.x + dims.x, pos.y + dims.y
	contour := shape_add_contour(shape)
	if rx <= 0 || ry <= 0 {
		append(
			&contour.edges,
			edge_make_linear({x0, y0}, {x1, y0}),
			edge_make_linear({x1, y0}, {x1, y1}),
			edge_make_linear({x1, y1}, {x0, y1}),
			edge_make_linear({x0, y1}, {x0, y0}),
		)
		return
	}
	r := Vec2{rx, ry}
	append(&contour.edges, edge_make_linear({x0 + rx, y0}, {x1 - rx, y0}))
	svg_add_arc_approximate(contour, {x1 - rx, y0}, {x1, y0 + ry}, r, 0, false, true)
	append(&contour.edges, edge_make_linear({x1, y0 + ry}, {x1, y1 - ry}))
	svg_add_arc_approximate(contour, {x1, y1 - ry}, {x1 - rx, y1}, r, 0, false, true)
	append(&contour.edges, edge_make_linear({x1 - rx, y1}, {x0 + rx, y1}))
	svg_add_arc_approximate(contour, {x0 + rx, y1}, {x0, y1 - ry}, r, 0, false, true)
	append(&contour.edges, edge_make_linear({x0, y1 - ry}, {x0, y0 + ry}))
	svg_add_arc_approximate(contour, {x0, y0 + ry}, {x0 + rx, y0}, r, 0, false, true)
}

svg_add_ellipse :: proc(shape: ^Shape, center, radius: Vec2) {
	if radius.x <= 0 || radius.y <= 0 do return
	contour := shape_add_contour(shape)
	p0 := center + Vec2{-radius.x, 0}
	p1 := center + Vec2{radius.x, 0}
	svg_add_arc_approximate(contour, p0, p1, radius, 0, false, true)
	svg_add_arc_approximate(contour, p1, p0, radius, 0, false, true)
}

// Parses a `points="x,y x,y ..."` attribute (as used by <polygon>/<polyline>).
svg_add_polygon :: proc(shape: ^Shape, points: string, close: bool) -> bool {
	c := Svg_Cursor{s = points}
	first, ok := svg_read_coord(&c)
	if !ok do return false
	contour := shape_add_contour(shape)
	prev := first
	for {
		p, ok2 := svg_read_coord(&c)
		if !ok2 do break
		append(&contour.edges, edge_make_linear(prev, p))
		prev = p
	}
	if close && prev != first do append(&contour.edges, edge_make_linear(prev, first))
	return len(contour.edges) > 0
}

// --- SVG document loading ---

// Parses a leading number off s, ignoring any trailing unit suffix (e.g.
// "24px"); returns 0 if s doesn't start with a number.
svg_parse_len :: proc(s: string) -> f64 {
	v, _, ok := strconv.parse_f64_prefix(s)
	return ok ? v : 0
}

svg_attr_len :: proc(doc: ^xml.Document, id: xml.Element_ID, key: string) -> f64 {
	v, found := xml.find_attribute_val_by_key(doc, id, key)
	return found ? svg_parse_len(v) : 0
}

// Recurses into <g> elements (transforms are not applied -- same documented
// limitation as upstream's non-Skia SVG import) and appends every supported
// drawable element's contours to shape.
svg_collect_elements :: proc(doc: ^xml.Document, parent: xml.Element_ID, shape: ^Shape, snap_range: f64, found: ^bool) {
	for value in doc.elements[parent].value {
		child_id, is_elem := value.(xml.Element_ID)
		if !is_elem do continue
		child := doc.elements[child_id]
		if child.kind != .Element do continue

		switch child.ident {
		case "g":
			svg_collect_elements(doc, child_id, shape, snap_range, found)
		case "path":
			if d, has_d := xml.find_attribute_val_by_key(doc, child_id, "d"); has_d {
				if build_shape_from_svg_path(shape, d, snap_range) do found^ = true
			}
		case "rect":
			rx := svg_attr_len(doc, child_id, "rx")
			ry := svg_attr_len(doc, child_id, "ry")
			if rx == 0 do rx = ry
			if ry == 0 do ry = rx
			svg_add_rect(
				shape,
				{svg_attr_len(doc, child_id, "x"), svg_attr_len(doc, child_id, "y")},
				{svg_attr_len(doc, child_id, "width"), svg_attr_len(doc, child_id, "height")},
				{rx, ry},
			)
			found^ = true
		case "circle":
			r := svg_attr_len(doc, child_id, "r")
			svg_add_ellipse(shape, {svg_attr_len(doc, child_id, "cx"), svg_attr_len(doc, child_id, "cy")}, {r, r})
			found^ = true
		case "ellipse":
			svg_add_ellipse(
				shape,
				{svg_attr_len(doc, child_id, "cx"), svg_attr_len(doc, child_id, "cy")},
				{svg_attr_len(doc, child_id, "rx"), svg_attr_len(doc, child_id, "ry")},
			)
			found^ = true
		case "polygon":
			if pts, has_pts := xml.find_attribute_val_by_key(doc, child_id, "points"); has_pts {
				if svg_add_polygon(shape, pts, true) do found^ = true
			}
		case "polyline":
			if pts, has_pts := xml.find_attribute_val_by_key(doc, child_id, "points"); has_pts {
				if svg_add_polygon(shape, pts, false) do found^ = true
			}
		}
	}
}

// Loads an SVG document (e.g. a UI icon file) into a single Shape, ready
// for edge_coloring_simple + generate_msdf. Unlike upstream msdfgen without
// Skia (which reads only one <path> and skips basic shapes entirely), this
// collects every <path>/<rect>/<circle>/<ellipse>/<polygon>/<polyline> in
// the document (recursing into <g>) into one shape -- correct as long as
// the icon's shapes don't overlap in ways that need true boolean union,
// which covers the vast majority of hand-authored UI icons.
//
// Not supported (same as upstream's non-Skia path): transform attributes,
// <use>, <mask>, <clipPath>, gradients/CSS styling, and the fill-rule
// attribute (fill is always resolved as even-odd via orient_contours).
//
// Note SVG coordinates are Y-down, unlike the Y-up convention font glyphs
// (see font_load_glyph) come out in -- pick scale/translate signs to match
// when mixing the two.
load_svg :: proc(data: []byte) -> (shape: Shape, view_box: Bounds, ok: bool) {
	doc, err := xml.parse(data)
	if err != .None do return {}, {}, false
	defer xml.destroy(doc)

	root: xml.Element_ID = 0
	if doc.element_count == 0 || doc.elements[root].ident != "svg" do return {}, {}, false

	dims := Vec2{svg_attr_len(doc, root, "width"), svg_attr_len(doc, root, "height")}
	view_box = {0, 0, dims.x, dims.y}
	if vb, has_vb := xml.find_attribute_val_by_key(doc, root, "viewBox"); has_vb {
		vc := Svg_Cursor{s = vb}
		l, _ := svg_read_double(&vc)
		t, _ := svg_read_double(&vc)
		w, _ := svg_read_double(&vc)
		h, _ := svg_read_double(&vc)
		view_box = {l, t, l + w, t + h}
		dims = {w, h}
	}
	snap_range := (1.0 / 16384.0) * linalg.length(dims)

	found := false
	svg_collect_elements(doc, root, &shape, snap_range, &found)
	if !found do return {}, {}, false

	orient_contours(&shape)
	shape_normalize(&shape)
	return shape, view_box, true
}
