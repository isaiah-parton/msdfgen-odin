package msdfgen

import "core:math"
import "core:math/linalg"

// Specifies which color channel(s) an edge belongs to. Bitwise combination
// of Red/Green/Blue; White (all channels) is the default for uncolored edges.
Edge_Color :: distinct u8
COLOR_BLACK   :: Edge_Color(0)
COLOR_RED     :: Edge_Color(1)
COLOR_GREEN   :: Edge_Color(2)
COLOR_YELLOW  :: Edge_Color(3)
COLOR_BLUE    :: Edge_Color(4)
COLOR_MAGENTA :: Edge_Color(5)
COLOR_CYAN    :: Edge_Color(6)
COLOR_WHITE   :: Edge_Color(7)

// A signed distance together with an alignment dot product, which together
// let two candidate distances be compared to find the true closest edge
// (ties on |distance| are broken by whichever edge the point is more
// directly in front of).
Signed_Distance :: struct {
	distance: f64,
	dot:      f64,
}

signed_distance_min :: proc() -> Signed_Distance {
	return {-math.F64_MAX, 0}
}

sd_less :: proc(a, b: Signed_Distance) -> bool {
	ad, bd := abs(a.distance), abs(b.distance)
	return ad < bd || (ad == bd && a.dot < b.dot)
}

Edge_Kind :: enum u8 {
	Linear,
	Quadratic,
	Cubic,
}

// A single edge segment of a contour: a line, quadratic Bézier, or cubic
// Bézier curve. Only the first 2/3/4 entries of p are meaningful, matching
// Kind.
Edge_Segment :: struct {
	kind:  Edge_Kind,
	color: Edge_Color,
	p:     [4]Vec2,
}

edge_linear :: proc(p0, p1: Vec2, color := COLOR_WHITE) -> Edge_Segment {
	return {kind = .Linear, color = color, p = {p0, p1, {}, {}}}
}

edge_quadratic :: proc(p0, p1, p2: Vec2, color := COLOR_WHITE) -> Edge_Segment {
	return {kind = .Quadratic, color = color, p = {p0, p1, p2, {}}}
}

edge_cubic :: proc(p0, p1, p2, p3: Vec2, color := COLOR_WHITE) -> Edge_Segment {
	return {kind = .Cubic, color = color, p = {p0, p1, p2, p3}}
}

// Constructs an edge, collapsing it to a simpler type if it is degenerate
// (e.g. a quadratic curve with collinear control points becomes a line).
// Mirrors EdgeSegment::create.
edge_make :: proc {
	edge_make_linear,
	edge_make_quadratic,
	edge_make_cubic,
}

edge_make_linear :: proc(p0, p1: Vec2, color := COLOR_WHITE) -> Edge_Segment {
	return edge_linear(p0, p1, color)
}

edge_make_quadratic :: proc(p0, p1, p2: Vec2, color := COLOR_WHITE) -> Edge_Segment {
	if linalg.cross(p1 - p0, p2 - p1) == 0 {
		return edge_linear(p0, p2, color)
	}
	return edge_quadratic(p0, p1, p2, color)
}

edge_make_cubic :: proc(p0, p1, p2, p3: Vec2, color := COLOR_WHITE) -> Edge_Segment {
	p12 := p2 - p1
	if linalg.cross(p1 - p0, p12) == 0 && linalg.cross(p12, p3 - p2) == 0 {
		return edge_linear(p0, p3, color)
	}
	a := 1.5 * p1 - 0.5 * p0
	b := 1.5 * p2 - 0.5 * p3
	if a == b {
		return edge_quadratic(p0, a, p3, color)
	}
	return edge_cubic(p0, p1, p2, p3, color)
}

edge_point :: proc(e: Edge_Segment, t: f64) -> Vec2 {
	switch e.kind {
	case .Linear:
		return mix(e.p[0], e.p[1], t)
	case .Quadratic:
		return mix(mix(e.p[0], e.p[1], t), mix(e.p[1], e.p[2], t), t)
	case .Cubic:
		p12 := mix(e.p[1], e.p[2], t)
		return mix(mix(mix(e.p[0], e.p[1], t), p12, t), mix(p12, mix(e.p[2], e.p[3], t), t), t)
	}
	return {}
}

quadratic_direction :: proc(p0, p1, p2: Vec2, t: f64) -> Vec2 {
	tangent := mix(p1 - p0, p2 - p1, t)
	if tangent == (Vec2{0, 0}) {
		return p2 - p0
	}
	return tangent
}

cubic_direction :: proc(p0, p1, p2, p3: Vec2, t: f64) -> Vec2 {
	tangent := mix(mix(p1 - p0, p2 - p1, t), mix(p2 - p1, p3 - p2, t), t)
	if tangent == (Vec2{0, 0}) {
		if t == 0 do return p2 - p0
		if t == 1 do return p3 - p1
	}
	return tangent
}

edge_direction :: proc(e: Edge_Segment, t: f64) -> Vec2 {
	switch e.kind {
	case .Linear:
		return e.p[1] - e.p[0]
	case .Quadratic:
		return quadratic_direction(e.p[0], e.p[1], e.p[2], t)
	case .Cubic:
		return cubic_direction(e.p[0], e.p[1], e.p[2], e.p[3], t)
	}
	return {}
}

edge_reverse :: proc(e: ^Edge_Segment) {
	switch e.kind {
	case .Linear:
		e.p[0], e.p[1] = e.p[1], e.p[0]
	case .Quadratic:
		e.p[0], e.p[2] = e.p[2], e.p[0]
	case .Cubic:
		e.p[0], e.p[3] = e.p[3], e.p[0]
		e.p[1], e.p[2] = e.p[2], e.p[1]
	}
}

// Splits the edge into three consecutive segments that together represent
// the original edge. Used to make single/double-edge contours colorable.
edge_split_in_thirds :: proc(e: Edge_Segment) -> (Edge_Segment, Edge_Segment, Edge_Segment) {
	switch e.kind {
	case .Linear:
		p0, p1 := e.p[0], e.p[1]
		return edge_linear(p0, edge_point(e, 1.0 / 3), e.color),
			edge_linear(edge_point(e, 1.0 / 3), edge_point(e, 2.0 / 3), e.color),
			edge_linear(edge_point(e, 2.0 / 3), p1, e.color)
	case .Quadratic:
		p0, p1, p2 := e.p[0], e.p[1], e.p[2]
		return edge_quadratic(p0, mix(p0, p1, 1.0 / 3), edge_point(e, 1.0 / 3), e.color),
			edge_quadratic(edge_point(e, 1.0 / 3), mix(mix(p0, p1, 5.0 / 9), mix(p1, p2, 4.0 / 9), 0.5), edge_point(e, 2.0 / 3), e.color),
			edge_quadratic(edge_point(e, 2.0 / 3), mix(p1, p2, 2.0 / 3), p2, e.color)
	case .Cubic:
		p0, p1, p2, p3 := e.p[0], e.p[1], e.p[2], e.p[3]
		part0 := edge_cubic(
			p0,
			p0 == p1 ? p0 : mix(p0, p1, 1.0 / 3),
			mix(mix(p0, p1, 1.0 / 3), mix(p1, p2, 1.0 / 3), 1.0 / 3),
			edge_point(e, 1.0 / 3),
			e.color,
		)
		part1 := edge_cubic(
			edge_point(e, 1.0 / 3),
			mix(mix(mix(p0, p1, 1.0 / 3), mix(p1, p2, 1.0 / 3), 1.0 / 3), mix(mix(p1, p2, 1.0 / 3), mix(p2, p3, 1.0 / 3), 1.0 / 3), 2.0 / 3),
			mix(mix(mix(p0, p1, 2.0 / 3), mix(p1, p2, 2.0 / 3), 2.0 / 3), mix(mix(p1, p2, 2.0 / 3), mix(p2, p3, 2.0 / 3), 2.0 / 3), 1.0 / 3),
			edge_point(e, 2.0 / 3),
			e.color,
		)
		part2 := edge_cubic(
			edge_point(e, 2.0 / 3),
			mix(mix(p1, p2, 2.0 / 3), mix(p2, p3, 2.0 / 3), 2.0 / 3),
			p2 == p3 ? p3 : mix(p2, p3, 2.0 / 3),
			p3,
			e.color,
		)
		return part0, part1, part2
	}
	return {}, {}, {}
}

edge_bound :: proc(e: Edge_Segment, min, max: ^Vec2) {
	switch e.kind {
	case .Linear:
		point_bounds(e.p[0], min, max)
		point_bounds(e.p[1], min, max)
	case .Quadratic:
		point_bounds(e.p[0], min, max)
		point_bounds(e.p[2], min, max)
		bot := (e.p[1] - e.p[0]) - (e.p[2] - e.p[1])
		if bot.x != 0 {
			t := (e.p[1].x - e.p[0].x) / bot.x
			if t > 0 && t < 1 do point_bounds(edge_point(e, t), min, max)
		}
		if bot.y != 0 {
			t := (e.p[1].y - e.p[0].y) / bot.y
			if t > 0 && t < 1 do point_bounds(edge_point(e, t), min, max)
		}
	case .Cubic:
		point_bounds(e.p[0], min, max)
		point_bounds(e.p[3], min, max)
		a0 := e.p[1] - e.p[0]
		a1 := 2 * ((e.p[2] - e.p[1]) - a0)
		a2 := e.p[3] - 3 * e.p[2] + 3 * e.p[1] - e.p[0]
		tx, nx := solve_quadratic(a2.x, a1.x, a0.x)
		for i in 0 ..< nx {
			if tx[i] > 0 && tx[i] < 1 do point_bounds(edge_point(e, tx[i]), min, max)
		}
		ty, ny := solve_quadratic(a2.y, a1.y, a0.y)
		for i in 0 ..< ny {
			if ty[i] > 0 && ty[i] < 1 do point_bounds(edge_point(e, ty[i]), min, max)
		}
	}
}

// Refines a previously computed signed distance into a perpendicular
// distance when the closest point parameter fell outside [0, 1], i.e. the
// query point is beyond one of the edge's endpoints. This lets neighboring
// edges hand off distance measurement smoothly across shared corners.
edge_distance_to_perpendicular_distance :: proc(e: Edge_Segment, distance: ^Signed_Distance, origin: Vec2, param: f64) {
	if param < 0 {
		dir := normalize(edge_direction(e, 0))
		aq := origin - edge_point(e, 0)
		ts := linalg.dot(aq, dir)
		if ts < 0 {
			perpendicular_distance := linalg.cross(aq, dir)
			if abs(perpendicular_distance) <= abs(distance.distance) {
				distance.distance = perpendicular_distance
				distance.dot = 0
			}
		}
	} else if param > 1 {
		dir := normalize(edge_direction(e, 1))
		bq := origin - edge_point(e, 1)
		ts := linalg.dot(bq, dir)
		if ts > 0 {
			perpendicular_distance := linalg.cross(bq, dir)
			if abs(perpendicular_distance) <= abs(distance.distance) {
				distance.distance = perpendicular_distance
				distance.dot = 0
			}
		}
	}
}

edge_signed_distance :: proc(e: Edge_Segment, origin: Vec2) -> (Signed_Distance, f64) {
	switch e.kind {
	case .Linear:
		return linear_signed_distance(e.p[0], e.p[1], origin)
	case .Quadratic:
		return quadratic_signed_distance(e.p[0], e.p[1], e.p[2], origin)
	case .Cubic:
		return cubic_signed_distance(e.p[0], e.p[1], e.p[2], e.p[3], origin)
	}
	return {}, 0
}

linear_signed_distance :: proc(p0, p1, origin: Vec2) -> (Signed_Distance, f64) {
	aq := origin - p0
	ab := p1 - p0
	param := linalg.dot(aq, ab) / linalg.dot(ab, ab)
	eq := (param > 0.5 ? p1 : p0) - origin
	endpoint_distance := linalg.length(eq)
	if param > 0 && param < 1 {
		ortho_distance := linalg.dot(orthonormal(ab, false), aq)
		if abs(ortho_distance) < endpoint_distance {
			return {ortho_distance, 0}, param
		}
	}
	d := Signed_Distance {
		nonzero_sign(linalg.cross(aq, ab)) * endpoint_distance,
		abs(linalg.dot(normalize(ab), normalize(eq))),
	}
	return d, param
}

quadratic_signed_distance :: proc(p0, p1, p2, origin: Vec2) -> (Signed_Distance, f64) {
	qa := p0 - origin
	ab := p1 - p0
	br := (p2 - p1) - ab
	a := linalg.dot(br, br)
	b := 3 * linalg.dot(ab, br)
	c := 2 * linalg.dot(ab, ab) + linalg.dot(qa, br)
	d := linalg.dot(qa, ab)
	t, solutions := solve_cubic(a, b, c, d)

	ep_dir := quadratic_direction(p0, p1, p2, 0)
	min_distance := nonzero_sign(linalg.cross(ep_dir, qa)) * linalg.length(qa)
	param := -linalg.dot(qa, ep_dir) / linalg.dot(ep_dir, ep_dir)
	{
		distance := linalg.length(p2 - origin)
		if distance < abs(min_distance) {
			ep_dir = quadratic_direction(p0, p1, p2, 1)
			min_distance = nonzero_sign(linalg.cross(ep_dir, p2 - origin)) * distance
			param = linalg.dot(origin - p1, ep_dir) / linalg.dot(ep_dir, ep_dir)
		}
	}
	for i in 0 ..< solutions {
		if t[i] > 0 && t[i] < 1 {
			qe := qa + 2 * t[i] * ab + t[i] * t[i] * br
			distance := linalg.length(qe)
			if distance <= abs(min_distance) {
				min_distance = nonzero_sign(linalg.cross(ab + t[i] * br, qe)) * distance
				param = t[i]
			}
		}
	}

	if param >= 0 && param <= 1 {
		return {min_distance, 0}, param
	}
	if param < 0.5 {
		return {min_distance, abs(linalg.dot(normalize(quadratic_direction(p0, p1, p2, 0)), normalize(qa)))}, param
	}
	return {min_distance, abs(linalg.dot(normalize(quadratic_direction(p0, p1, p2, 1)), normalize(p2 - origin)))}, param
}

CUBIC_SEARCH_STARTS :: 4
CUBIC_SEARCH_STEPS :: 4

cubic_signed_distance :: proc(p0, p1, p2, p3, origin: Vec2) -> (Signed_Distance, f64) {
	qa := p0 - origin
	ab := p1 - p0
	br := (p2 - p1) - ab
	a3 := ((p3 - p2) - (p2 - p1)) - br

	ep_dir := cubic_direction(p0, p1, p2, p3, 0)
	min_distance := nonzero_sign(linalg.cross(ep_dir, qa)) * linalg.length(qa)
	param := -linalg.dot(qa, ep_dir) / linalg.dot(ep_dir, ep_dir)
	{
		distance := linalg.length(p3 - origin)
		if distance < abs(min_distance) {
			ep_dir = cubic_direction(p0, p1, p2, p3, 1)
			min_distance = nonzero_sign(linalg.cross(ep_dir, p3 - origin)) * distance
			param = linalg.dot(ep_dir - (p3 - origin), ep_dir) / linalg.dot(ep_dir, ep_dir)
		}
	}
	// Iterative minimum distance search (Newton's method).
	for i in 0 ..= CUBIC_SEARCH_STARTS {
		t := (1.0 / CUBIC_SEARCH_STARTS) * f64(i)
		qe := qa + 3 * t * ab + 3 * t * t * br + t * t * t * a3
		d1 := 3 * ab + 6 * t * br + 3 * t * t * a3
		d2 := 6 * br + 6 * t * a3
		improved_t := t - linalg.dot(qe, d1) / (linalg.dot(d1, d1) + linalg.dot(qe, d2))
		if improved_t > 0 && improved_t < 1 {
			remaining_steps := CUBIC_SEARCH_STEPS
			for {
				t = improved_t
				qe = qa + 3 * t * ab + 3 * t * t * br + t * t * t * a3
				d1 = 3 * ab + 6 * t * br + 3 * t * t * a3
				remaining_steps -= 1
				if remaining_steps == 0 do break
				d2 = 6 * br + 6 * t * a3
				improved_t = t - linalg.dot(qe, d1) / (linalg.dot(d1, d1) + linalg.dot(qe, d2))
				if !(improved_t > 0 && improved_t < 1) do break
			}
			distance := linalg.length(qe)
			if distance < abs(min_distance) {
				min_distance = nonzero_sign(linalg.cross(d1, qe)) * distance
				param = t
			}
		}
	}

	if param >= 0 && param <= 1 {
		return {min_distance, 0}, param
	}
	if param < 0.5 {
		return {min_distance, abs(linalg.dot(normalize(cubic_direction(p0, p1, p2, p3, 0)), normalize(qa)))}, param
	}
	return {min_distance, abs(linalg.dot(normalize(cubic_direction(p0, p1, p2, p3, 1)), normalize(p3 - origin)))}, param
}

// Solves ax^2 + bx + c = 0. Returns the number of real solutions (-1 means
// every x is a solution, i.e. the equation is identically zero).
solve_quadratic :: proc(a, b, c: f64) -> (x: [2]f64, n: int) {
	if a == 0 || abs(b) > 1e12 * abs(a) {
		if b == 0 {
			if c == 0 do return x, -1
			return x, 0
		}
		x[0] = -c / b
		return x, 1
	}
	dscr := b * b - 4 * a * c
	if dscr > 0 {
		dscr = math.sqrt(dscr)
		x[0] = (-b + dscr) / (2 * a)
		x[1] = (-b - dscr) / (2 * a)
		return x, 2
	} else if dscr == 0 {
		x[0] = -b / (2 * a)
		return x, 1
	}
	return x, 0
}

solve_cubic_normed :: proc(a_in, b, c: f64) -> (x: [3]f64, n: int) {
	a := a_in
	a2 := a * a
	q := (1.0 / 9.0) * (a2 - 3 * b)
	r := (1.0 / 54.0) * (a * (2 * a2 - 9 * b) + 27 * c)
	r2 := r * r
	q3 := q * q * q
	a = a / 3.0
	if r2 < q3 {
		t := r / math.sqrt(q3)
		t = clamp(t, -1, 1)
		t = math.acos(t)
		q = -2 * math.sqrt(q)
		x[0] = q * math.cos((1.0 / 3.0) * t) - a
		x[1] = q * math.cos((1.0 / 3.0) * (t + 2 * math.PI)) - a
		x[2] = q * math.cos((1.0 / 3.0) * (t - 2 * math.PI)) - a
		return x, 3
	}
	u := (r < 0 ? 1.0 : -1.0) * math.pow(abs(r) + math.sqrt(r2 - q3), 1.0 / 3.0)
	v := u == 0 ? 0 : q / u
	x[0] = (u + v) - a
	if u == v || abs(u - v) < 1e-12 * abs(u + v) {
		x[1] = -0.5 * (u + v) - a
		return x, 2
	}
	return x, 1
}

// Solves ax^3 + bx^2 + cx + d = 0. Returns the number of real solutions.
solve_cubic :: proc(a, b, c, d: f64) -> (x: [3]f64, n: int) {
	if a != 0 {
		bn := b / a
		if abs(bn) < 1e6 {
			return solve_cubic_normed(bn, c / a, d / a)
		}
	}
	x2, n2 := solve_quadratic(b, c, d)
	x[0], x[1] = x2[0], x2[1]
	return x, n2
}
