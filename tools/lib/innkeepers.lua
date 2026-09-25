-- ============================================================
-- ForeverGuide / tools/lib/innkeepers.lua
-- Innkeepers the route planner may bind the hearthstone at: every NPC whose
-- subname is "Innkeeper" in Questie's database (Questie/QuestieDB
-- b6f5b07b), first spawn only.
--   f     A / H / AH: the factions it serves
--   bind  the inn's name as GetBindLocation() reports it; a HEARTH step
--         compares against it
-- Forever-only inns (Zephras Isle) are not in Questie yet; add them here by
-- hand with a comment.
-- Data (c) the Questie project, https://github.com/Questie/Questie.
-- ============================================================
return {
    { id = 295, n = "Innkeeper Farley", f = "A", area = 12, x = 43.77, y = 65.8, bind = "Goldshire" },
    { id = 1247, n = "Innkeeper Belm", f = "A", area = 1, x = 47.38, y = 52.52, bind = "Kharanos" },
    { id = 1464, n = "Innkeeper Helbrek", f = "A", area = 11, x = 10.7, y = 60.95, bind = "Menethil Harbor" },
    { id = 2352, n = "Innkeeper Anderson", f = "A", area = 267, x = 51.17, y = 58.93, bind = "Southshore" },
    { id = 2388, n = "Innkeeper Shay", f = "H", area = 267, x = 62.78, y = 19.03, bind = "Tarren Mill" },
    { id = 3934, n = "Innkeeper Boorand Plainswind", f = "H", area = 17, x = 51.99, y = 29.89, bind = "The Crossroads" },
    { id = 5111, n = "Innkeeper Firebrew", f = "A", area = 1537, x = 18.15, y = 51.45, bind = "Ironforge" },
    { id = 5688, n = "Innkeeper Renee", f = "H", area = 85, x = 61.71, y = 52.05, bind = "Brill" },
    { id = 5814, n = "Innkeeper Thulbek", f = "H", area = 33, x = 31.49, y = 29.75, bind = "Grom'gol Base" },
    { id = 6272, n = "Innkeeper Janene", f = "A", area = 15, x = 66.59, y = 45.22, bind = "Theramore Isle" },
    { id = 6727, n = "Innkeeper Brianna", f = "A", area = 44, x = 21.92, y = 44.82, bind = "Lakeshire" },
    { id = 6734, n = "Innkeeper Hearthstove", f = "A", area = 38, x = 35.53, y = 48.4, bind = "Thelsamar" },
    { id = 6735, n = "Innkeeper Saelienne", f = "A", area = 1657, x = 67.42, y = 15.65, bind = "Darnassus" },
    { id = 6736, n = "Innkeeper Keldamyr", f = "A", area = 141, x = 55.62, y = 59.79, bind = "Dolanaar" },
    { id = 6737, n = "Innkeeper Shaussiy", f = "A", area = 148, x = 37.04, y = 44.13, bind = "Auberdine" },
    { id = 6738, n = "Innkeeper Kimlya", f = "A", area = 331, x = 36.99, y = 49.22, bind = "Astranaar" },
    { id = 6739, n = "Innkeeper Bates", f = "H", area = 130, x = 43.18, y = 41.28, bind = "The Sepulcher" },
    { id = 6740, n = "Innkeeper Allison", f = "A", area = 1519, x = 60.39, y = 75.27, bind = "Stormwind City" },
    { id = 6741, n = "Innkeeper Norman", f = "H", area = 1497, x = 67.74, y = 37.89, bind = "Undercity" },
    { id = 6746, n = "Innkeeper Pala", f = "H", area = 1638, x = 45.81, y = 64.71, bind = "Thunder Bluff" },
    { id = 6747, n = "Innkeeper Kauth", f = "H", area = 215, x = 45.93, y = 64.16, bind = "Bloodhoof Village" },
    { id = 6790, n = "Innkeeper Trelayne", f = "A", area = 10, x = 73.87, y = 44.41, bind = "Darkshire" },
    { id = 6791, n = "Innkeeper Wiley", f = "AH", area = 17, x = 62.05, y = 39.41, bind = "Ratchet" },
    { id = 6807, n = "Innkeeper Skindle", f = "AH", area = 33, x = 27.04, y = 77.31, bind = "Booty Bay" },
    { id = 6928, n = "Innkeeper Grosk", f = "H", area = 14, x = 51.51, y = 41.64, bind = "Razor Hill" },
    { id = 6929, n = "Innkeeper Gryshka", f = "H", area = 1637, x = 54.1, y = 68.41, bind = "Orgrimmar" },
    { id = 6930, n = "Innkeeper Karakul", f = "H", area = 8, x = 45.16, y = 56.66, bind = "Stonard" },
    { id = 7714, n = "Innkeeper Byula", f = "H", area = 17, x = 45.58, y = 59.04, bind = "Camp Taurajo" },
    { id = 7731, n = "Innkeeper Jayka", f = "H", area = 406, x = 47.47, y = 62.13, bind = "Sun Rock Retreat" },
    { id = 7733, n = "Innkeeper Fizzgrimble", f = "AH", area = 440, x = 52.51, y = 27.91, bind = "Gadgetzan" },
    { id = 7736, n = "Innkeeper Shyria", f = "A", area = 357, x = 30.97, y = 43.49, bind = "Feathermoon Stronghold" },
    { id = 7737, n = "Innkeeper Greul", f = "H", area = 357, x = 74.8, y = 45.18, bind = "Camp Mojache" },
    { id = 7744, n = "Innkeeper Thulfram", f = "A", area = 47, x = 14.15, y = 41.57, bind = "Aerie Peak" },
    { id = 8931, n = "Innkeeper Heather", f = "A", area = 40, x = 52.86, y = 53.71, bind = "Sentinel Hill" },
    { id = 9356, n = "Innkeeper Shul'kar", f = "H", area = 3, x = 2.82, y = 45.86, bind = "Kargath" },
    { id = 9501, n = "Innkeeper Adegwa", f = "H", area = 45, x = 73.84, y = 32.46, bind = "Hammerfall" },
    { id = 11103, n = "Innkeeper Lyshaerya", f = "A", area = 405, x = 66.27, y = 6.55, bind = "Nijel's Point" },
    { id = 11106, n = "Innkeeper Sikewa", f = "H", area = 405, x = 24.09, y = 68.21, bind = "Shadowprey Village" },
    { id = 11116, n = "Innkeeper Abeqwa", f = "H", area = 400, x = 46.07, y = 51.52, bind = "Freewind Post" },
    { id = 11118, n = "Innkeeper Vizzie", f = "AH", area = 618, x = 61.36, y = 38.83, bind = "Everlook" },
    { id = 12196, n = "Innkeeper Kaylisk", f = "H", area = 331, x = 73.99, y = 60.65, bind = "Splintertree Post" },
    { id = 14731, n = "Lard", f = "H", area = 47, x = 78.14, y = 81.38, bind = "Revantusk Village" },
    { id = 15174, n = "Calandrath", f = "AH", area = 1377, x = 51.89, y = 39.16, bind = "Cenarion Hold" },
    { id = 16256, n = "Jessica Chambers", f = "AH", area = 139, x = 71.8, y = 48.52, bind = "Light's Hope Chapel" },
    { id = 16458, n = "Innkeeper Faralia", f = "A", area = 406, x = 35.79, y = 5.74, bind = "Stonetalon Peak" },
}
