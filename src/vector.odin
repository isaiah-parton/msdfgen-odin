package msdfgen

import "core:math/linalg"

// A 2D point or vector. Odin's array-programming rules give us
// component-wise (and scalar-broadcast) +, -, *, /, ==, != for free.
Vec2 :: [2]f64

// Returns a unit vector with the same direction as v. Unlike
// linalg.normalize, a zero-length vector does not produce NaN: it falls
// back to (0, 1) (or (0, 0) when allow_zero is set), matching msdfgen's
// Vector2::normalize and its use as a safe direction default.
normalize :: proc(v: Vec2, allow_zero := false) -> Vec2 {
	len := linalg.length(v)
	if len != 0 {
		return v / len
	}
	return {0, allow_zero ? 0 : 1}
}

// A unit vector orthogonal to v (rotated +90° if polarity, else -90°),
// with the same zero-length fallback behavior as normalize.
orthonormal :: proc(v: Vec2, polarity := true, allow_zero := false) -> Vec2 {
	len := linalg.length(v)
	if len != 0 {
		return polarity ? Vec2{-v.y / len, v.x / len} : Vec2{v.y / len, -v.x / len}
	}
	fallback: f64 = allow_zero ? 0 : 1
	return polarity ? Vec2{0, fallback} : Vec2{0, -fallback}
}

// A vector of the same length orthogonal to v (rotated +90° if polarity, else -90°).
orthogonal :: proc(v: Vec2, polarity := true) -> Vec2 {
	return polarity ? Vec2{-v.y, v.x} : Vec2{v.y, -v.x}
}
