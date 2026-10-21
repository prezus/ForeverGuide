-- A region wrapping round a cliff (#809): a strip on the ground and one 20 yd up, 10 yd apart across a face and
-- joined at their east end by a ramp, each with a strip of its own region west of it. Written by codex's packer from
-- test/nav-router.test.ts's fixture: map 9997, tile 32_32. Up from the foot to the strip beyond the top the walk goes round
-- by the ramp; down, straight off the face (a safe fall).
-- up: 175.34 yd, 4 points; down: 66.06 yd, 3 points
local ns = ...
ns.NavMap9997 = {
  version = 4,
  hash = "23ab7c8af086a31f",
  tiles = {
    ["32_32"] = "eNrt2LENgDAMRNE7h5IOhmAMxs8QDMEI2KSmjpD+ixwptqXrszSFtNdlbY7Tl07fCrs669oWK2JUbWUzHap515XVq6Fc63l13TnMZ+hLTVqeWcgnn3zyyZ/Db5l88smfku+p+QAAAAAAAACAvxt/zA9/YglH",
  },
}

return { hash = "23ab7c8af086a31f", tiles = 1, foot = { x = -428.333, y = -428.333 }, west = { x = -483.333, y = -408.333, z = 20 }, up = { yards = 175.34, points = 4 }, down = { yards = 66.06, points = 3 } }
