package msdfgen

// Returns 1 for non-negative values and -1 for negative values.
nonzero_sign :: proc(n: f64) -> f64 {
	return n < 0 ? -1 : 1
}

// The weighted average of a and b. Works for both f64 and Vec2 since both
// support the arithmetic operators used here.
mix :: proc(a, b: $T, w: f64) -> T {
	return a * (1 - w) + b * w
}

// The middle of three values.
median :: proc(a, b, c: f64) -> f64 {
	return max(min(a, b), min(max(a, b), c))
}

point_bounds :: proc(p: Vec2, min, max: ^Vec2) {
	if p.x < min.x do min.x = p.x
	if p.y < min.y do min.y = p.y
	if p.x > max.x do max.x = p.x
	if p.y > max.y do max.y = p.y
}
