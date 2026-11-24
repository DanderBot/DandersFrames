-- ☠ Companion addon: take the parent's table from the global it publishes
-- (see the same note at the head of Features/Search.lua).
local DF = DandersFrames
local Search = DF.Search

-- ============================================================
-- SETTINGS SEARCH -- SYNONYMS AND TAGS
-- The words a search should also accept for a setting, beyond what its label
-- says. Read by Features/SearchMatch.lua; nothing here is drawn.
--
-- ★ SEARCH DATA, NOT UI TEXT, so nothing here goes through L[...]. No player
-- ever reads these words; they only decide what a typed query reaches. They are
-- English, and they are matched for EVERY client: a label is matched in the
-- client's own language, and these (with the English words inside each
-- setting's key) sit beside it, so an English term still finds a setting on a
-- translated client. A locale that wants its own synonyms adds a group list
-- under Search.LocaleConcepts[<locale>] -- same shape as Search.Concepts.
--
-- ⚠ WRITE EVERY WORD IN ITS PLAIN FORM. Both sides go through the same
-- normaliser (plural, -ing, -ed and a trailing e come off), so "fade", "fading"
-- and "faded" are one word already; listing all three is harmless but noise.
-- ============================================================

-- ------------------------------------------------------------
-- CONCEPT GROUPS -- every word in a group finds every other one.
-- Built against the settings' own label vocabulary (about 420 distinct words).
-- A group is a SYNONYM set: if two words must not find each other (buff and
-- debuff, party and raid, tank and healer), they go in separate groups and a
-- broader word reaches them through Search.Narrower below.
-- ------------------------------------------------------------
Search.Concepts = {
    { "transparency", "transparent", "opacity", "opaque", "alpha", "fade", "translucent", "dim", "faint" },
    { "hide", "hidden", "show", "visible", "visibility", "display", "appear", "invisible", "conditions" },
    { "enable", "disable", "toggle", "activate", "deactivate", "switch" },
    { "size", "scale", "width", "height", "thickness", "thick", "thin", "big", "bigger", "large", "small", "smaller", "tiny", "huge", "zoom", "dimension" },
    { "position", "anchor", "offset", "location", "placement", "place", "nudge", "align", "alignment", "attach", "point" },
    { "color", "colour", "tint", "hue", "rgb" },
    { "font", "typeface", "lettering" },
    { "text", "label", "caption", "wording" },
    { "border", "edge", "outline", "rim" },
    { "background", "backdrop", "bg" },
    { "texture", "statusbar", "skin", "material" },
    { "glow", "glowing", "shine", "highlight" },
    { "hover", "mouseover" },
    { "health", "hp", "life", "hitpoints" },
    { "power", "mana", "resource", "energy", "rage", "runic", "insanity", "fury", "maelstrom", "lunar" },
    { "absorb", "shield", "overshield" },
    { "heal", "healing", "prediction", "incoming", "overheal" },
    { "aura", "effect" },
    { "buff", "blessing" },
    { "debuff", "affliction" },
    { "dispel", "dispellable", "cleanse", "decurse", "purge" },
    { "range", "distance", "oor", "far", "outofrange" },
    { "dead", "death", "ghost", "corpse" },
    { "resurrection", "resurrect", "rez", "res", "revive", "battlerez" },
    { "tank", "tanking" },
    { "healer" },
    { "dps", "damager", "damage" },
    { "sort", "order", "priority", "arrange", "arrangement" },
    { "layout", "grid", "arrangement" },
    { "spacing", "gap", "padding", "margin" },
    { "direction", "orientation", "grow", "growth", "flip" },
    { "animation", "animate", "smooth", "pulse", "flash", "blink", "motion" },
    { "cooldown", "swipe", "cd" },
    { "duration", "time", "timer", "remaining", "countdown", "expire", "expiration", "expiring" },
    { "count", "stack", "charge", "number" },
    { "icon", "symbol", "image", "picture" },
    { "marker", "mark", "skull" },
    { "tooltip", "hint", "popup" },
    { "combat", "fight", "fighting", "ooc" },
    { "click", "mouse", "binding", "bind", "keybind", "clickcast" },
    { "profile", "preset", "import", "export", "share" },
    { "pet", "minion", "companion" },
    { "cast", "casting", "castbar", "channel", "spell" },
    { "threat", "aggro" },
    { "level", "strata", "layer", "layering", "depth", "front", "behind", "above" },
    { "shadow", "dropshadow" },
    { "gradient", "blend" },
    { "status", "state", "offline", "disconnected", "afk" },
    { "name", "nickname" },
    { "class", "spec", "specialization" },
    { "ready", "readycheck" },
    { "leader", "lead", "assist", "assistant" },
    { "solo", "alone", "single" },
    { "vehicle", "mounted", "mount" },
    { "test", "preview", "demo" },
    { "lock", "unlock", "mover", "drag" },
    { "blizzard", "default", "stock", "builtin" },
    { "desaturate", "grey", "gray", "greyscale", "monochrome" },
    { "missing", "absent", "lacking" },
    { "debug", "log", "logging" },
    { "pixel", "crisp", "sharp", "perfect" },
    { "inset", "inner", "inside" },
    { "ping" },
    { "bar", "statusbar" },
    { "personal", "player", "self", "myself", "me" },
    { "portrait", "avatar", "face" },
    { "rested", "resting", "zzz", "sleep", "inn" },
    { "summon", "summoning" },
    { "phase", "phased" },
    { "important", "priority" },
    { "targeted", "incoming" },
    { "kick", "interrupt", "interruptible", "interrupted" },
    { "elite", "rare", "classification", "dragon" },
    { "pvp", "honor", "warmode" },
    { "boss", "encounter" },
}

-- ------------------------------------------------------------
-- PHRASES -- several words that name ONE thing, read as that thing's word
-- before the query is split. The words are what the unit frame pages are
-- called inside (their page names: uf_targettarget_health), so the phrase finds
-- that unit's pages rather than every page that says "target".
-- ------------------------------------------------------------
Search.Phrases = {
    ["target of target"] = "targettarget",
    ["targets target"]   = "targettarget",
    ["focus target"]     = "focustarget",
    ["focus of target"]  = "focustarget",
    ["out of range"]     = "outofrange",
}

-- ------------------------------------------------------------
-- ONE-WAY EXPANSIONS -- a broad word reaches narrower ones, never back.
-- Typing "aura" should find buff and debuff settings; typing "buff" must not
-- find debuff ones (they share every other word, so it would find all of them).
-- ------------------------------------------------------------
Search.Narrower = {
    tot     = { "targettarget" },
    aura    = { "buff", "debuff" },
    role    = { "tank", "healer", "dps" },
    group   = { "party", "raid" },
    frame   = { "party", "raid", "unit" },
    unit    = { "player", "target", "focus", "pet", "boss" },
    visual  = { "glow", "animation", "border", "color" },
    look    = { "texture", "color", "border", "font" },
    style   = { "texture", "border", "font" },
}

-- ------------------------------------------------------------
-- PER-SETTING TAGS, keyed by the setting's db key. For a setting whose label
-- does not carry the words people search for it by. Words, space-separated;
-- a tag scores just below the label. A key missing from the current build is
-- simply never asked for.
-- ------------------------------------------------------------
Search.Tags = {
    -- Fading
    frameFadeEnabled          = "transparency opacity dim whole frame see through",
    frameFadeAlpha            = "transparency opacity dim whole frame",
    frameFadeSplitCombat      = "in combat out of combat transparency",
    rangeFadeAlpha            = "out of range distance oor transparency",
    oorEnabled                = "out of range distance oor element",
    fadeDeadFrames            = "dead ghost corpse transparency",
    healthFadeEnabled         = "full health topped transparency",
    fadeUnhealableEnabled     = "priest angel spirit transparency",

    -- Visibility and frames
    soloMode                  = "alone without group by myself show",
    hidePlayerFrame           = "self me myself own frame remove",
    partyEnabled              = "turn on party frames",
    raidEnabled               = "turn on raid frames",
    hideBlizzardPartyFrames   = "default blizzard frames replace remove",
    hideBlizzardRaidFrames    = "default blizzard frames replace remove compact",
    showBlizzardSideMenu      = "blizzard manager side panel",
    frameScale                = "zoom bigger smaller size",
    raidUseGroups             = "group layout columns",
    permanentMover            = "drag handle move frames unlock",
    restedIndicator           = "zzz sleeping inn",

    -- Sorting
    sortEnabled               = "sort order arrange",
    useFrameSort              = "framesort addon integration",
    sortSelfPosition          = "me myself own position first last",

    -- Bars
    resourceBarEnabled        = "mana power bar",
    healPredictionEnabled     = "incoming heals",
    absorbBarShowOvershield   = "over absorb overshield",
    reducedMaxHealthEnabled   = "healing reduction max health",

    -- Auras
    showBuffs                 = "buff icons auras",
    showDebuffs               = "debuff icons auras",
    buffDeduplicateDefensives = "duplicate twice repeated",
    buffHidePermanent         = "permanent no duration passive",
    debuffHidePermanent       = "permanent no duration passive",
    buffHideSwipe             = "cooldown swipe clock spiral",
    debuffHideSwipe           = "cooldown swipe clock spiral",
    missingBuffIconEnabled    = "raid buff reminder fortitude intellect",
    defensiveIconEnabled      = "defensive cooldown external",
    debuffDispelSymbolEnabled = "dispel type magic curse poison disease",

    -- Indicators
    targetedListEnabled       = "incoming casts targeted spells",
    roleIconShowTank          = "role icon",
    roleIconShowHealer        = "role icon",
    roleIconShowDPS           = "role icon",
    leaderIconEnabled         = "party leader crown",
    raidTargetIconEnabled     = "raid marker skull star",
    readyCheckIconEnabled     = "ready check",
    summonIconEnabled         = "summon portal",
    resurrectionIconEnabled   = "rez res revive",
    phasedIconEnabled         = "phased different phase",

    -- Tooltips
    tooltipFrameEnabled       = "mouseover hover info",
    tooltipBuffEnabled        = "mouseover hover aura info",
    tooltipDebuffEnabled      = "mouseover hover aura info",

    -- Pets
    petEnabled                = "pet frames minion companion",

    -- Unit frames
    restingIconEnabled        = "rested resting zzz inn city sleep",
    castbarEnabled            = "cast bar casting spell channel",
    castbarKickTick           = "kick interrupt ready",
    castbarKickNotReadyColor  = "kick interrupt cooldown",
    portraitEnabled           = "portrait face avatar 3d model",
    classDragonEnabled        = "elite rare boss dragon frame",
}

-- Words that carry no meaning on their own. Dropped from tooltips, keys and the
-- query (unless every query word is one of them).
Search.StopWords = {
    ["the"] = true, ["of"] = true, ["a"] = true, ["an"] = true, ["to"] = true,
    ["in"] = true, ["on"] = true, ["for"] = true, ["by"] = true, ["and"] = true,
    ["or"] = true, ["is"] = true, ["it"] = true, ["its"] = true, ["this"] = true,
    ["that"] = true, ["with"] = true, ["from"] = true, ["at"] = true, ["as"] = true,
    ["be"] = true, ["are"] = true, ["when"] = true, ["your"] = true, ["you"] = true,
    ["will"] = true, ["can"] = true, ["if"] = true, ["than"] = true, ["only"] = true,
}
