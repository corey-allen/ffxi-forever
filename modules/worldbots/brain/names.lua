-----------------------------------
-- Lore-accurate names for world bots (owner decision: Vana'diel and Ivalice).
--
-- Original names written in each race's in-lore naming style; none is a
-- canonical NPC (the server also refuses any NPC or monster name, so a clash
-- is skipped, never used). Letters only, 3-15 characters, as the server requires.
--
--   Hume      Western-European given names (San d'Oria and Bastok Humes),
--             with Ivalice Hume names in the style of Dalmasca and Archadia.
--   Elvaan    French-styled, as San d'Orian nobility and knights.
--   Tarutaru  Reduplicated syllables, Windurstian ("Kupipi" style).
--   Mithra    Two-part Mithran names written as one word, since the server
--             allows letters only ("Mishi-Ahhim" becomes "Mishiahhim").
--   Galka     Single names with Galkan roots, and Ivalice Bangaa/Seeq-like
--             heavy names that fit a Galka.
-----------------------------------
local names = {}

names.byRace =
{
    -- 1 Hume male
    [1] =
    {
        'Aldric', 'Berenger', 'Corwin', 'Dorian', 'Edmund', 'Falric', 'Garrick', 'Halvard',
        'Isembard', 'Jorund', 'Kendrick', 'Leofric', 'Merrick', 'Norbert', 'Osric', 'Percival',
        'Roderic', 'Sigmund', 'Tobias', 'Ulric', 'Wendell', 'Aldous', 'Bastien', 'Castor',
        -- Ivalice (Dalmascan / Archadian style)
        'Vossler', 'Ardys', 'Dalan', 'Rozzan', 'Halim', 'Ezel', 'Raminas', 'Ondre',
    },
    -- 2 Hume female
    [2] =
    {
        'Adela', 'Brigida', 'Cecily', 'Daphne', 'Edith', 'Freya', 'Gisela', 'Helena',
        'Ingrid', 'Juliana', 'Katrin', 'Liesel', 'Matilde', 'Nerys', 'Odette', 'Rosalind',
        'Sabine', 'Theda', 'Ursula', 'Wilhelmina', 'Yvaine', 'Margery', 'Elinor', 'Beatrix',
        -- Ivalice
        'Ashara', 'Lenora', 'Amalia', 'Mirela', 'Tasha', 'Seliara', 'Rasha', 'Elza',
    },
    -- 3 Elvaan male
    [3] =
    {
        'Aubertin', 'Baudoin', 'Clairmont', 'Dauphin', 'Enguerrand', 'Fervaux', 'Gaultier', 'Hardouin',
        'Isarnaud', 'Jourdain', 'Lamberval', 'Marcelin', 'Norvaux', 'Ombrevaux', 'Perceval', 'Quentrel',
        'Raoulin', 'Sevestre', 'Thibaudin', 'Valcourt', 'Yvonnet', 'Arnoux', 'Bellerose', 'Corentin',
        'Valfroy', 'Rochemaure', 'Gervaise', 'Morvandel', 'Esclarmond', 'Theodoric',
    },
    -- 4 Elvaan female
    [4] =
    {
        'Aliette', 'Blanchefleur', 'Clemence', 'Desiree', 'Eglantine', 'Faustine', 'Genevieve', 'Hermine',
        'Isabeau', 'Josseline', 'Laurette', 'Mireille', 'Noemie', 'Orlaine', 'Perrine', 'Roselaine',
        'Severine', 'Thessaly', 'Valentine', 'Ysoline', 'Amaurine', 'Berangere', 'Corisande', 'Delphine',
        'Elodiane', 'Fleurance', 'Ghislaine', 'Maelys',
    },
    -- 5 Tarutaru male
    [5] =
    {
        'Babazuru', 'Chachaku', 'Dodomaro', 'Fafanoru', 'Gogotaku', 'Hahamuro', 'Jajaduko', 'Kokoroku',
        'Mamanoto', 'Nanakuto', 'Pupukoro', 'Rarazuko', 'Sasabaku', 'Tatamuro', 'Wawaroku', 'Yoyokaru',
        'Bobonaru', 'Chichitoru', 'Dadakaru', 'Gugumaro', 'Kakaburo', 'Momokuto', 'Nonotaru', 'Popopuru',
        'Ruruboko', 'Totonaru', 'Zazadoko', 'Mimikaro',
    },
    -- 6 Tarutaru female
    [6] =
    {
        'Apapipi', 'Bebeloko', 'Chocopi', 'Dedekiri', 'Fifimuni', 'Gigipini', 'Hihikula', 'Kikiruni',
        'Lalapiri', 'Mimiluna', 'Ninipoko', 'Pipitapa', 'Ririkosi', 'Sisimopi', 'Titiwopa', 'Yuyukipa',
        'Bibilola', 'Chuchumi', 'Doduripi', 'Kukurina', 'Lulumopi', 'Memesiri', 'Nunupiki', 'Rorolapi',
        'Tatawini', 'Wiwipuni', 'Zuzukiki', 'Pepekami',
    },
    -- 7 Mithra (two-part names written as one word)
    [7] =
    {
        'Mishiahhim', 'Nanayakhom', 'Purerasha', 'Sahrakimri', 'Yolajhoma', 'Kezhamahan', 'Lilitoshar', 'Mayamahai',
        'Rikatsuhrr', 'Senaroahi', 'Tsunatikhal', 'Zahrikoma', 'Fhalijiru', 'Ahkalinui', 'Jahrimasha', 'Kohmalira',
        'Naliyashi', 'Rhoyakhan', 'Shamorihri', 'Yahrikola', 'Ehanomari', 'Hanijhaoi', 'Ojirahan', 'Wazhimaki',
        -- Ivalice (Viera-like)
        'Fhranaya', 'Mjerrah', 'Kyrielle', 'Jotehra',
    },
    -- 8 Galka
    [8] =
    {
        'Gorvolt', 'Dhaszuk', 'Brannvok', 'Ghorlaze', 'Kragmund', 'Thudrek', 'Volgrath', 'Zherkand',
        'Bhuldorm', 'Garmholt', 'Haszkar', 'Jorvlak', 'Mhorgan', 'Rhokzel', 'Skarvold', 'Tharnog',
        'Urzhan', 'Varkrod', 'Wolgrim', 'Zalvohr', 'Drakthor', 'Grumvald', 'Kholzar', 'Orvhazz',
        -- Ivalice (Bangaa / Seeq-like)
        'Grazzhan', 'Bhuzzrak', 'Vharoth', 'Ozmonde',
    },
}

-- Syllables for the fallback generator when a race's list is used up.
local syllables =
{
    [1] = { 'al', 'ber', 'cor', 'dor', 'ed', 'gar', 'hal', 'len', 'mer', 'ric', 'ton', 'win' },
    [2] = { 'a', 'bel', 'cel', 'da', 'el', 'ise', 'la', 'mar', 'na', 'ra', 'sa', 'wen' },
    [3] = { 'au', 'ber', 'claire', 'deau', 'gaut', 'mont', 'reau', 'seve', 'thi', 'val', 'vaux', 'ron' },
    [4] = { 'a', 'blan', 'clai', 'elle', 'fleur', 'ine', 'lise', 'mi', 'rette', 'ro', 'se', 'ys' },
    [5] = { 'ba', 'cha', 'do', 'fa', 'go', 'ka', 'ma', 'na', 'po', 'ra', 'ta', 'wa' },
    [6] = { 'bi', 'chi', 'di', 'ki', 'li', 'mi', 'ni', 'pi', 'ri', 'si', 'ti', 'yu' },
    [7] = { 'ah', 'ja', 'ka', 'li', 'mi', 'na', 'ra', 'sha', 'shi', 'ya', 'zha', 'hri' },
    [8] = { 'dor', 'gor', 'gra', 'kar', 'mor', 'rok', 'tha', 'vok', 'zar', 'zek', 'hold', 'grim' },
}

local function capitalize(s)
    return s:sub(1, 1):upper() .. s:sub(2):lower()
end

-- A generated name in the race's style (Tarutaru reduplicate the first syllable).
function names.generate(race)
    local pool = syllables[race] or syllables[1]
    local n    = (race == 5 or race == 6) and 3 or math.random(2, 3)
    local parts = {}
    for i = 1, n do
        parts[i] = pool[math.random(#pool)]
    end
    if race == 5 or race == 6 then
        parts[1] = parts[1] .. parts[1]
    end
    local name = table.concat(parts)
    while #name < 4 do -- the server wants 3+ letters; short syllable pairs ("a" + "a") need one more
        name = name .. pool[math.random(#pool)]
    end
    if #name > 15 then
        name = name:sub(1, 15)
    end
    return capitalize(name)
end

-- Candidates for a race in a stable shuffled order: the curated list first, then generated names.
function names.candidates(race, seed)
    local list = {}
    for _, name in ipairs(names.byRace[race] or {}) do
        table.insert(list, name)
    end
    math.randomseed(seed or os.time())
    for i = #list, 2, -1 do
        local j = math.random(i)
        list[i], list[j] = list[j], list[i]
    end
    for _ = 1, 40 do
        table.insert(list, names.generate(race))
    end
    return list
end

return names
