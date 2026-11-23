-- A region wrapping round a sheer cliff, start and goal in it (codex #1165): as nav_crooked.lua, the strips 4 yd apart,
-- so that no straight line from the ground's portal climbs onto the upper strip near its west end. Written by codex's
-- packer from test/nav-router.test.ts's fixture: map 9996, tile 32_32. From the foot to the upper strip over it the walk
-- goes round by the ramp (east, past x = -378.333); down, straight off the face (a safe fall); along a strip, straight.
-- up: 109.59 yd, 4 points; down: 15.81 yd, 2 points; along: 45 yd, 2 points
local ns = ...
ns.NavMap9996 = {
  version = 4,
  hash = "9e1347637f2d2ce3",
  tiles = {
    ["32_32"] = "eNrt2L0JgDAUReF7k1hp6RCOkfEdwtIhLH0PsbQOwvlIxPzAKQVbVZHWfFizS/eh7lPFzp1lmapj8Q7liP2wKa/sOmLuuaHmeLlinnEYy6IveVI1Dn369OnTH8PvR4Q+ffoD+h7aBwAAAAAAAAD83fOX+QZanwnw",
  },
}

return {
  hash = "9e1347637f2d2ce3", tiles = 1,
  foot = { x = -428.333, y = -428.333 }, top = { x = -423.333, y = -413.333, z = 20 }, along = { x = -383.333, y = -428.333 },
  ways = { up = { yards = 109.59, points = 4 }, down = { yards = 15.81, points = 2 }, along = { yards = 45, points = 2 } },
}
