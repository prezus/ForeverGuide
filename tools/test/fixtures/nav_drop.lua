-- A plateau 20 yd up and a field below it east, joined only by a drop down off the plateau's edge (#800).
-- Written by codex's packer from test/nav-router.test.ts's fixture: map 9998, tile 32_32.
-- from (-418.333, -408.333) on the plateau to (-348.333, -408.333) on the field: 70.00 yd, 4 points
local ns = ...
ns.NavMap9998 = {
  version = 3,
  hash = "2c74bd8146137389",
  tiles = {
    ["32_32"] = "eNrt2bERgCAQRcF/GGkllmEZ9l+GkWBGC7J7czMwBK8AtpaWnKkMVbnq+fbs171y9+PY/pYjADCpafT19VfSptHX11+pDwAAAEB+89OT5AWcGwYu",
  },
}

return { hash = "2c74bd8146137389", tiles = 1, from = { x = -418.333, y = -408.333 }, to = { x = -348.333, y = -408.333 }, yards = 70.00, points = 4 }
