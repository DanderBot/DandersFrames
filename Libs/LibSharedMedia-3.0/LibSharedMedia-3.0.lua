--[[
Name: LibSharedMedia-3.0
Revision: $Revision: 133 $
Author: Elkano (elkano@gmx.de)
Inspired By: SurfaceLib by Haste/Otravia
Website: http://www.wowace.com/projects/libsharedmedia-3-0/
Description: Shared handling of media data (fonts, sounds, textures, ...) between addons.
Dependencies: LibStub, CallbackHandler-1.0
License: LGPL v2.1
]]

local MAJOR, MINOR = "LibSharedMedia-3.0", 8020003 -- 8.2.0 v3 / increase manually on changes
local lib = LibStub:NewLibrary(MAJOR, MINOR)

if not lib then return end

local _G = getfenv(0)

local pairs		= _G.pairs
local type		= _G.type

local band			= _G.bit.band

local table_sort	= _G.table.sort

local RESTRICTED_FILE_ACCESS = WOW_PROJECT_ID == WOW_PROJECT_MAINLINE

lib.callbacks		= lib.callbacks			or LibStub:GetLibrary("CallbackHandler-1.0"):New(lib)

lib.DefaultMedia	= lib.DefaultMedia		or {}
lib.MediaList		= lib.MediaList			or {}
lib.MediaTable		= lib.MediaTable		or {}
lib.MediaType		= lib.MediaType			or {}
lib.OverrideMedia	= lib.OverrideMedia		or {}

local defaultMedia = lib.DefaultMedia
local mediaList = lib.MediaList
local mediaTable = lib.MediaTable
local overrideMedia = lib.OverrideMedia


-- CONSTANTS
lib.MediaType.BACKGROUND	= "background"			-- background textures
lib.MediaType.BORDER		= "border"				-- border textures
lib.MediaType.FONT			= "font"				-- fonts
lib.MediaType.STATUSBAR		= "statusbar"			-- statusbar textures
lib.MediaType.SOUND			= "sound"				-- sound files

-- Needed for the math and iteration
local MediaType = lib.MediaType

if not lib.MediaList[MediaType.BACKGROUND] then lib.MediaList[MediaType.BACKGROUND] = {} end
if not lib.MediaList[MediaType.BORDER] then lib.MediaList[MediaType.BORDER] = {} end
if not lib.MediaList[MediaType.FONT] then lib.MediaList[MediaType.FONT] = {} end
if not lib.MediaList[MediaType.STATUSBAR] then lib.MediaList[MediaType.STATUSBAR] = {} end
if not lib.MediaList[MediaType.SOUND] then lib.MediaList[MediaType.SOUND] = {} end

if not lib.MediaTable[MediaType.BACKGROUND] then lib.MediaTable[MediaType.BACKGROUND] = {} end
if not lib.MediaTable[MediaType.BORDER] then lib.MediaTable[MediaType.BORDER] = {} end
if not lib.MediaTable[MediaType.FONT] then lib.MediaTable[MediaType.FONT] = {} end
if not lib.MediaTable[MediaType.STATUSBAR] then lib.MediaTable[MediaType.STATUSBAR] = {} end
if not lib.MediaTable[MediaType.SOUND] then lib.MediaTable[MediaType.SOUND] = {} end

if not lib.DefaultMedia[MediaType.BACKGROUND] then lib.DefaultMedia[MediaType.BACKGROUND] = "Blizzard Dialog Background" end
if not lib.DefaultMedia[MediaType.BORDER] then lib.DefaultMedia[MediaType.BORDER] = "Blizzard Tooltip" end
if not lib.DefaultMedia[MediaType.FONT] then lib.DefaultMedia[MediaType.FONT] = "Friz Quadrata TT" end
if not lib.DefaultMedia[MediaType.STATUSBAR] then lib.DefaultMedia[MediaType.STATUSBAR] = "Blizzard" end
if not lib.DefaultMedia[MediaType.SOUND] then lib.DefaultMedia[MediaType.SOUND] = "None" end


local locale = GetLocale()
local locale_is_western
local LOCALE_MASK = 0
lib.LOCALE_BIT_koKR		= 1
lib.LOCALE_BIT_ruRU		= 2
lib.LOCALE_BIT_zhCN		= 4
lib.LOCALE_BIT_zhTW		= 8
lib.LOCALE_BIT_western	= 128

local CallbackError
do
	local pcall = pcall
	local geterrorhandler = geterrorhandler
	function CallbackError(err)
		local handler = geterrorhandler()
		if handler then
			local ok, err2 = pcall(handler, err)
			if not ok then
				print(("CallbackHandler: Error in error handler: %s"):format(err2))
			end
		end
	end
end

if locale == "koKR" then
	LOCALE_MASK = lib.LOCALE_BIT_koKR
elseif locale == "ruRU" then
	LOCALE_MASK = lib.LOCALE_BIT_ruRU
elseif locale == "zhCN" then
	LOCALE_MASK = lib.LOCALE_BIT_zhCN
elseif locale == "zhTW" then
	LOCALE_MASK = lib.LOCALE_BIT_zhTW
else
	locale_is_western = true
	LOCALE_MASK = lib.LOCALE_BIT_western
end


-- the meat
function lib:Register(mediatype, key, data, langmask)
	if type(mediatype) ~= "string" then
		error(MAJOR..":Register(mediatype, key, data, langmask) - mediatype must be string, got "..type(mediatype))
	end
	if type(key) ~= "string" then
		error(MAJOR..":Register(mediatype, key, data, langmask) - key must be string, got "..type(key))
	end
	mediatype = mediatype:lower()
	if not mediaTable[mediatype] then return false end
	if langmask and band(langmask, LOCALE_MASK) == 0 then return false end
	mediaTable[mediatype][key] = data
	-- add the key to the MediaList
	for i = 1, #mediaList[mediatype] do
		if mediaList[mediatype][i] == key then return false end -- already in the list
	end
	mediaList[mediatype][#mediaList[mediatype] + 1] = key
	table_sort(mediaList[mediatype])
	self.callbacks:Fire("LibSharedMedia_Registered", mediatype, key)
	return true
end

function lib:Fetch(mediatype, key, noDefault)
	local mtt = mediaTable[mediatype]
	local overridekey = overrideMedia[mediatype]
	local result = mtt and ((overridekey and mtt[overridekey] or mtt[key]) or (not noDefault and mtt[defaultMedia[mediatype]] or nil))
	return result
end

function lib:IsValid(mediatype, key)
	return mediaTable[mediatype] and (not key or mediaTable[mediatype][key]) and true or false
end

function lib:HashTable(mediatype)
	return mediaTable[mediatype]
end

function lib:List(mediatype)
	return mediaList[mediatype]
end

function lib:GetGlobal(mediatype)
	return overrideMedia[mediatype]
end

function lib:SetGlobal(mediatype, key)
	if mediaTable[mediatype] then
		overrideMedia[mediatype] = mediaTable[mediatype][key] and key or nil
		self.callbacks:Fire("LibSharedMedia_SetGlobal", mediatype, overrideMedia[mediatype])
		return true
	else
		return false
	end
end

function lib:GetDefault(mediatype)
	return defaultMedia[mediatype]
end

function lib:SetDefault(mediatype, key)
	if mediaTable[mediatype] and mediaTable[mediatype][key] then
		defaultMedia[mediatype] = key
		return true
	else
		return false
	end
end

-- register some basic media
-- BACKGROUND
lib:Register(MediaType.BACKGROUND, "Blizzard Dialog Background",		[[Interface\DialogFrame\UI-DialogBox-Background]])
lib:Register(MediaType.BACKGROUND, "Blizzard Dialog Background Dark",	[[Interface\DialogFrame\UI-DialogBox-Background-Dark]])
lib:Register(MediaType.BACKGROUND, "Blizzard Dialog Background Gold",	[[Interface\DialogFrame\UI-DialogBox-Gold-Background]])
lib:Register(MediaType.BACKGROUND, "Blizzard Garrison Background",		[[Interface\Garrison\GarrisonUIBackground]])
lib:Register(MediaType.BACKGROUND, "Blizzard Garrison Background 2",	[[Interface\Garrison\GarrisonUIBackground2]])
lib:Register(MediaType.BACKGROUND, "Blizzard Low Health",				[[Interface\FullScreenTextures\LowHealth]])
lib:Register(MediaType.BACKGROUND, "Blizzard Marble",					[[Interface\FrameGeneral\UI-Background-Marble]])
lib:Register(MediaType.BACKGROUND, "Blizzard Out of Control",			[[Interface\FullScreenTextures\OutOfControl]])
lib:Register(MediaType.BACKGROUND, "Blizzard Parchment",				[[Interface\AchievementFrame\UI-Achievement-Parchment-Horizontal]])
lib:Register(MediaType.BACKGROUND, "Blizzard Parchment 2",				[[Interface\AchievementFrame\UI-GuildAchievement-Parchment-Horizontal]])
lib:Register(MediaType.BACKGROUND, "Blizzard Rock",						[[Interface\FrameGeneral\UI-Background-Rock]])
lib:Register(MediaType.BACKGROUND, "Blizzard Tabard Background",		[[Interface\TabardFrame\TabardFrameBackground]])
lib:Register(MediaType.BACKGROUND, "Blizzard Tooltip",					[[Interface\Tooltips\UI-Tooltip-Background]])
lib:Register(MediaType.BACKGROUND, "Solid",								[[Interface\Buttons\WHITE8X8]])

-- BORDER
lib:Register(MediaType.BORDER, "Blizzard Achievement Wood",				[[Interface\AchievementFrame\UI-Achievement-WoodBorder]])
lib:Register(MediaType.BORDER, "Blizzard Chat Bubble",					[[Interface\Tooltips\ChatBubble-Backdrop]])
lib:Register(MediaType.BORDER, "Blizzard Dialog",						[[Interface\DialogFrame\UI-DialogBox-Border]])
lib:Register(MediaType.BORDER, "Blizzard Dialog Gold",					[[Interface\DialogFrame\UI-DialogBox-Gold-Border]])
lib:Register(MediaType.BORDER, "Blizzard Party",						[[Interface\CHARACTERFRAME\UI-Party-Border]])
lib:Register(MediaType.BORDER, "Blizzard Tooltip",						[[Interface\Tooltips\UI-Tooltip-Border]])
lib:Register(MediaType.BORDER, "None",									[[Interface\None]])

-- FONT
lib:Register(MediaType.FONT, "2002",									[[Fonts\2002.TTF]],							lib.LOCALE_BIT_koKR)
lib:Register(MediaType.FONT, "2002 Bold",								[[Fonts\2002B.TTF]],						lib.LOCALE_BIT_koKR)
lib:Register(MediaType.FONT, "AR CrystalzcuheiGBK Demibold",			[[Fonts\ARKai_C.TTF]],						lib.LOCALE_BIT_zhCN)
lib:Register(MediaType.FONT, "AR ZhongkaiGBK Medium (Combat)",			[[Fonts\ARKai_T.TTF]],						lib.LOCALE_BIT_zhCN)
lib:Register(MediaType.FONT, "Arial Narrow",							[[Fonts\ARIALN.TTF]],						lib.LOCALE_BIT_western)
lib:Register(MediaType.FONT, "Friz Quadrata TT",						[[Fonts\FRIZQT__.TTF]],						lib.LOCALE_BIT_western)
lib:Register(MediaType.FONT, "Morpheus",								[[Fonts\MORPHEUS.TTF]],						lib.LOCALE_BIT_western)
lib:Register(MediaType.FONT, "Nimrod MT",								[[Fonts\NIM_____.TTF]],						lib.LOCALE_BIT_western)
lib:Register(MediaType.FONT, "Skurri",									[[Fonts\SKURRI.TTF]],						lib.LOCALE_BIT_western)

-- Korean
lib:Register(MediaType.FONT, "굵은 글꼴",								[[Fonts\2002B.TTF]],						lib.LOCALE_BIT_koKR)
lib:Register(MediaType.FONT, "기본 글꼴",								[[Fonts\2002.TTF]],							lib.LOCALE_BIT_koKR)
lib:Register(MediaType.FONT, "데미지 글꼴",								[[Fonts\K_Damage.TTF]],						lib.LOCALE_BIT_koKR)
lib:Register(MediaType.FONT, "퀘스트 글꼴",								[[Fonts\K_Pagetext.TTF]],					lib.LOCALE_BIT_koKR)

-- Russian
lib:Register(MediaType.FONT, "Arial Narrow",							[[Fonts\ARIALN.TTF]],						lib.LOCALE_BIT_ruRU)
lib:Register(MediaType.FONT, "Friz Quadrata TT",						[[Fonts\FRIZQT___CYR.TTF]],					lib.LOCALE_BIT_ruRU)
lib:Register(MediaType.FONT, "Morpheus",								[[Fonts\MORPHEUS_CYR.TTF]],					lib.LOCALE_BIT_ruRU)
lib:Register(MediaType.FONT, "Nimrod MT",								[[Fonts\NIM_____.TTF]],						lib.LOCALE_BIT_ruRU)
lib:Register(MediaType.FONT, "Skurri",									[[Fonts\SKURRI_CYR.TTF]],					lib.LOCALE_BIT_ruRU)

-- Traditional Chinese
lib:Register(MediaType.FONT, "提示訊息",								[[Fonts\bHEI00M.TTF]],						lib.LOCALE_BIT_zhTW)
lib:Register(MediaType.FONT, "聊天",									[[Fonts\bHEI01B.TTF]],						lib.LOCALE_BIT_zhTW)
lib:Register(MediaType.FONT, "傷害數字",								[[Fonts\bKAI00M.TTF]],						lib.LOCALE_BIT_zhTW)
lib:Register(MediaType.FONT, "預設",									[[Fonts\bLEI00D.TTF]],						lib.LOCALE_BIT_zhTW)

-- STATUSBAR
lib:Register(MediaType.STATUSBAR, "Blizzard",							[[Interface\TargetingFrame\UI-StatusBar]])
lib:Register(MediaType.STATUSBAR, "Blizzard Character Skills Bar",		[[Interface\PaperDollInfoFrame\UI-Character-Skills-Bar]])
lib:Register(MediaType.STATUSBAR, "Blizzard Raid Bar",					[[Interface\RaidFrame\Raid-Bar-Hp-Fill]])
lib:Register(MediaType.STATUSBAR, "Solid",								[[Interface\Buttons\WHITE8X8]])

-- SOUND
lib:Register(MediaType.SOUND, "None",									[[Interface\Quiet.ogg]])
