-- The reference router's ways (codex src/nav/router.ts) over the Nav/ data these tests load:
-- the Lua router must find the same. Written by codex's `nav ways` with the walking data.
return {
    { id = "goldshire", map = 0, from = { x = -9464.893, y = 74.196 }, to = { x = -9846.799, y = 133.200 }, yards = 412.17, points = 10, goalHeight = 38.5 },
    { id = "north-gate", map = 0, from = { x = -4821.780, y = -1155.440, z = 502.210 }, to = { x = -5421.910, y = -2930.010, z = 347.250 }, yards = 3460.12, points = 97, goalHeight = 347 },
    { id = "razor-hill", map = 1, from = { x = 274.958, y = -4738.437 }, to = { x = 1677.590, y = -4315.710, z = 61.170 }, yards = 1688.23, points = 55, goalHeight = 56.5 },
    { id = "fitz", map = 1, from = { x = -783.266, y = -3625.297 }, to = { x = -664.356, y = -3558.417 }, yards = 136.43, points = 2, goalHeight = 93.5 },
    { id = "z1", map = 0, from = { x = 1766.270, y = 66.630, z = -46.240 }, to = { x = 1389.340, y = 347.320, z = -65.960 }, yards = 599.31, points = 20, goalHeight = -69.5 },
    { id = "splintertree", map = 1, from = { x = 1982.292, y = -606.667 }, to = { x = 2302.390, y = -2524.550 }, none = "NoWalk" },
    { id = "sea", map = 0, from = { x = -10937.666, y = 1543.167 }, to = { x = -10000.000, y = 3900.000 }, none = "OffTheMap" },
    { id = "crossroads-alliance", map = 1, from = { x = 126.125, y = -2646.417 }, to = { x = -954.875, y = -2646.417 }, yards = 1166.50, points = 6, goalHeight = 99, faction = "Alliance" },
    { id = "crossroads", map = 1, from = { x = 126.125, y = -2646.417 }, to = { x = -954.875, y = -2646.417 }, yards = 1093.94, points = 13, goalHeight = 99 },
    { id = "durotar-drop", map = 1, from = { x = -828.000, y = -4180.000, z = 87.000 }, to = { x = -785.000, y = -4152.000, z = 53.000 }, yards = 67.41, points = 4, goalHeight = 55 },
    { id = "durotar-up", map = 1, from = { x = -785.000, y = -4152.000, z = 53.000 }, to = { x = -828.000, y = -4180.000, z = 87.000 }, yards = 107.57, points = 5, goalHeight = 62.5 },
}
