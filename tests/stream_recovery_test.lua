-- tests/stream_recovery_test.lua
--
-- Runs driver.lua under a stubbed Control4 runtime (no controller, no Plex
-- server) and replays engine event sequences against the stream-recovery
-- logic: session ids, direct-play eligibility, transcode fallback, mid-song
-- resume, retry caps. It checks the driver's DECISIONS (what it selects and
-- arms), not real audio, so it is no substitute for a bench test.
--
-- Run from the repo root with Lua 5.1 (what Control4 ships):
--   lua5.1 tests/stream_recovery_test.lua .
local ROOT = assert (arg [1], 'repo root')
package.path = ROOT .. '/common/?.lua;' .. ROOT .. '/src/plex_music/?.lua;' .. package.path

-- ---- stub runtime -----------------------------------------------------------
SENT = {}      -- every SendToProxy call
TIMERS = {}
URLS = {}      -- every C4:url Get/Post
local function noop () end

C4 = setmetatable ({
	SendToProxy = function (self, b, cmd, p) SENT[#SENT + 1] = {b = b, cmd = cmd, p = p} end,
	SetTimer = function (self, delay, fn, rep)
		local t = {delay = delay, fn = fn, rep = rep, dead = false}
		t.Cancel = function (s) s.dead = true end
		TIMERS[#TIMERS + 1] = t
		return t
	end,
	url = function ()
		local x = {}
		function x:SetOptions () end
		function x:OnDone (cb) self.cb = cb end
		function x:Get (u) URLS[#URLS + 1] = u end
		function x:Post (u) URLS[#URLS + 1] = u end
		return x
	end,
	GetDeviceID = function () return 777 end,
	GetProxyDevices = function () return 778 end,
	DebugLog = function (self, m) end,
}, {__index = function () return noop end})

Properties = {
	['Plex Server Address'] = '192.168.1.10', ['Plex Server Port'] = '32400',
	['Plex Token'] = 'SECRETTOKEN', ['Playback'] = 'Direct Play When Possible',
	['Music Library'] = '', ['Check for Updates'] = 'Off', ['Auto Rename Driver'] = 'Off',
}

-- three tracks: a FLAC (direct), an AAC in .mka (must transcode), an MP3 (direct)
PersistData = {
	queue = {
		{rk = '101', title = 'Song A', artist = 'X', album = 'Y', durSec = 200, thumb = '',
			codec = 'flac', container = 'flac', partKey = '/library/parts/1/1/file.flac'},
		{rk = '102', title = 'Song B', artist = 'X', album = 'Y', durSec = 180, thumb = '',
			codec = 'aac', container = 'mka', partKey = '/library/parts/2/1/file.mka'},
		{rk = '103', title = 'Song C', artist = 'X', album = 'Y', durSec = 240, thumb = '',
			codec = 'mp3', container = 'mp3', partKey = '/library/parts/3/1/file.mp3'},
		-- persisted by 1.0.0: no container field at all
		{rk = '104', title = 'Song D', artist = 'X', album = 'Y', durSec = 150, thumb = '',
			codec = 'mp3', partKey = '/library/parts/4/1/file.mp3'},
	},
	qIndex = 0, selectGen = 0, rooms = '25',
}

-- load the driver, exposing a few chunk locals for white-box checks
local f = assert (io.open (ROOT .. '/src/plex_music/driver.lua'))
local src = f:read ('*a') f:close ()
src = src .. '\n_T = {trackFromRow = trackFromRow, directPlayable = directPlayable}\n'
assert (loadstring (src, '=driver.lua')) ()
local Plex = require ('plex')

OnDriverInit ()
OnDriverLateInit ()

-- ---- helpers ------------------------------------------------------------------
local pass, fail = 0, 0
local function check (cond, name)
	if (cond) then pass = pass + 1 print ('  ok   ' .. name)
	else fail = fail + 1 print ('  FAIL ' .. name) end
end

local function last (cmd)
	for i = #SENT, 1, -1 do if (SENT[i].cmd == cmd) then return SENT[i].p, i end end
end
local function countSince (mark, cmd)
	local n = 0
	for i = mark + 1, #SENT do if (SENT[i].cmd == cmd) then n = n + 1 end end
	return n
end
local function isDirect (url) return url and url:find ('/library/parts/', 1, true) ~= nil end
local function isTranscode (url) return url and url:find ('transcode/universal/start.mp3', 1, true) ~= nil end
local function param (url, k) return url and url:match ('[?&]' .. k .. '=([^&]*)') end

local qn = 0
-- engine acks the last select and starts playing it
local function engineStarts ()
	local p = last ('SELECT_AUDIO_URL')
	qn = qn + 1
	local qid = 'q' .. qn
	RFP.AUDIO_URL_SELECTED (5001, 'AUDIO_URL_SELECTED', {QUEUE_ID = qid, QUEUE_INFO = p.QUEUE_INFO})
	RFP.QUEUE_STATE_CHANGED (5001, 'QUEUE_STATE_CHANGED', {QUEUE_ID = qid, STATE = 'PLAY'})
	return qid
end
-- run the 1-second progress ticker n times
local function tick (n)
	for _ = 1, n do
		for _, t in ipairs (TIMERS) do
			if (not t.dead and t.rep and t.delay == 1000) then t.fn (t, 0) end
		end
	end
end
local function engineEnds (qid) RFP.QUEUE_STATE_CHANGED (5001, 'QUEUE_STATE_CHANGED', {QUEUE_ID = qid, STATE = 'END'}) end
local function toasts (mark)
	local out = {}
	for i = mark + 1, #SENT do
		local s = SENT[i]
		if (s.cmd == 'SEND_EVENT' and s.p.NAME == 'DriverNotification') then out[#out + 1] = s.p.EVTARGS end
	end
	return out
end

-- ---- 1. transcode session ids ---------------------------------------------------
print ('1. transcode session ids are unique per URL')
local u1, u2 = Plex.TranscodeUrl ('101', 320), Plex.TranscodeUrl ('101', 320)
check (param (u1, 'session') ~= param (u2, 'session'), 'same track twice -> two different sessions')
check (param (u1, 'session'):find ('^c4plex%-777%-101%-') ~= nil, 'session still carries client id + rating key')
check (not (u1:find ('SECRETTOKEN', 1, true) and param (u1, 'session'):find ('SECRET', 1, true)), 'token not leaked into session')

-- ---- 2. direct-play eligibility ---------------------------------------------------
print ('2. direct-play eligibility checks the container')
local dp = _T.directPlayable
check (dp ({codec = 'flac', container = 'flac', partKey = '/p'}), 'flac in .flac -> direct')
check (not dp ({codec = 'aac', container = 'mka', partKey = '/p'}), 'aac in .mka -> transcode')
check (not dp ({codec = 'flac', container = 'ogg', partKey = '/p'}), 'flac in .ogg -> transcode')
check (dp ({codec = 'aac', container = 'mp4', partKey = '/p'}), 'aac in .mp4 (m4a) -> direct')
check (dp ({codec = 'mp3', partKey = '/p'}), 'no container (1.0.0 persisted) -> old behavior')
check (not dp ({codec = 'mp3', container = 'mp3', partKey = '/p', forceTranscode = true}), 'forceTranscode wins')
check (not dp ({codec = 'alac', container = 'mp4', partKey = '/p'}), 'alac -> transcode')
local row = {tag = 'Track', attrs = {ratingKey = '9', title = 't', duration = '1000'}, children = {
	{tag = 'Media', attrs = {audioCodec = 'FLAC', container = 'flac'}, children = {
		{tag = 'Part', attrs = {key = '/library/parts/9/1/file.ogg', container = 'ogg'}, children = {}}}}}}
local tr = _T.trackFromRow (row)
check (tr.codec == 'flac' and tr.container == 'ogg', 'trackFromRow: lowercases codec, Part container wins')

-- ---- 3. start: direct for A, armed next B is a transcode ----------------------------
print ('3. playback start')
RFP.SKIP_FWD (5001, 'SKIP_FWD', {ROOMID = '25'})
local sel = last ('SELECT_AUDIO_URL')
check (isDirect (sel.STATION_URL), 'Song A (flac) selected as direct play')
local nxt = last ('SET_NEXT_AUDIO_URL')
check (isTranscode (nxt.NEXT_URL), 'Song B (aac in .mka) armed as a transcode, not direct')

-- ---- 4. direct select refused -> transcode retry, once --------------------------------
print ('4. SELECT_AUDIO_URL_ERROR on a direct stream')
local mark = #SENT
RFP.SELECT_AUDIO_URL_ERROR (5001, 'SELECT_AUDIO_URL_ERROR', {QUEUE_INFO = sel.QUEUE_INFO, ERROR = 'boom'})
local resel = last ('SELECT_AUDIO_URL')
check (countSince (mark, 'SELECT_AUDIO_URL') == 1 and isTranscode (resel.STATION_URL), 'retried Song A as a transcode')
check (param (resel.STATION_URL, 'path') == '%2Flibrary%2Fmetadata%2F101', 'retry targets the same track')
check (#toasts (mark) == 0, 'no "could not start" toast while retrying')
check (gQueue[1].forceTranscode == true, 'Song A flagged forceTranscode')
mark = #SENT
RFP.SELECT_AUDIO_URL_ERROR (5001, 'SELECT_AUDIO_URL_ERROR', {QUEUE_INFO = resel.QUEUE_INFO, ERROR = 'boom'})
check (countSince (mark, 'SELECT_AUDIO_URL') == 0, 'a failing transcode is not retried again')
check (#toasts (mark) == 1, 'user gets the toast once recovery is exhausted')

-- ---- 5. transcode drops mid-song -> resume at the drop point --------------------------
print ('5. transcode stream drops mid-song')
RFP.SKIP_FWD (5001, 'SKIP_FWD', {ROOMID = '25'}) -- Song B (transcode)
check (gIndex == 2 and isTranscode (last ('SELECT_AUDIO_URL').STATION_URL), 'Song B playing as transcode')
local q = engineStarts ()
tick (60)
mark = #SENT
engineEnds (q)
local r = last ('SELECT_AUDIO_URL')
check (countSince (mark, 'SELECT_AUDIO_URL') == 1 and gIndex == 2, 'stayed on Song B instead of skipping')
check (param (r.STATION_URL, 'offset') == '58', 'resumed at 58s (60s minus backup)')
-- drop again, still within budget
q = engineStarts ()
tick (20)
mark = #SENT
engineEnds (q)
check (gIndex == 2 and param (last ('SELECT_AUDIO_URL').STATION_URL, 'offset') == '76', 'second drop resumes too (78-2)')
-- third drop: budget spent, queue moves on
q = engineStarts ()
tick (20)
mark = #SENT
engineEnds (q)
check (gIndex == 3, 'third drop: RECOVER_MAX reached, advanced to Song C')

-- ---- 6. natural end advances normally -------------------------------------------------
print ('6. natural end')
q = engineStarts () -- Song C, direct mp3
check (isDirect (last ('SELECT_AUDIO_URL').STATION_URL), 'Song C selected as direct')
tick (238)
mark = #SENT
engineEnds (q)
check (gIndex == 4 and countSince (mark, 'SELECT_AUDIO_URL') == 1, 'END near the end of the song just advances')

-- ---- 7. direct stream ends early -> transcode retry ------------------------------------
print ('7. direct stream dies early (END)')
q = engineStarts () -- Song D, direct (no container)
check (isDirect (last ('SELECT_AUDIO_URL').STATION_URL), 'Song D (1.0.0 track, no container) selected direct')
tick (1)
mark = #SENT
engineEnds (q)
check (gIndex == 4 and isTranscode (last ('SELECT_AUDIO_URL').STATION_URL), 'retried Song D as a transcode')
check (gQueue[4].forceTranscode == true, 'Song D flagged forceTranscode')

-- ---- 8. transcode that never started is not retried ------------------------------------
print ('8. transcode that never played')
q = engineStarts ()
mark = #SENT
-- Song D is the last track; turn repeat on so there is a next to fall to
RFP.ToggleRepeat (5001, 'ToggleRepeat', {ROOMID = '25'})
mark = #SENT
engineEnds (q)
check (gIndex == 1, 'no retry; advanced (wrapped) to the next track')

-- ---- 9. gapless: direct next track dies early -> flagged for next time ------------------
print ('9. gapless advance away from a dead direct track')
gQueue[3].forceTranscode = nil
RFP.SKIP_FWD (5001, 'SKIP_FWD', {ROOMID = '25'}) -- Song B (2)
q = engineStarts ()
RFP.SKIP_FWD (5001, 'SKIP_FWD', {ROOMID = '25'}) -- Song C (3), direct, next = D armed
q = engineStarts ()
check (gIndex == 3 and gCurMode == 'direct', 'Song C playing direct')
tick (2)
local arm = last ('SET_NEXT_AUDIO_URL')
RFP.QUEUE_NEED_NEXT (5001, 'QUEUE_NEED_NEXT', {QUEUE_ID = q, QUEUE_INFO = arm.QUEUE_INFO})
check (gIndex == 4, 'moved on to Song D (not yanked back)')
check (gQueue[3].forceTranscode == true, 'Song C flagged to transcode next time')
check (gCurMode == 'transcode', 'Song D mode tracked from the arm (it was flagged in step 7)')

-- ---- 10. seek on a transcode uses a fresh session --------------------------------------
print ('10. seek / restart of the same track')
RFP.SKIP_REV (5001, 'SKIP_REV', {ROOMID = '25'}) -- back to Song C (now transcode)
q = engineStarts ()
local i1 = gIndex
local s1 = param (last ('SELECT_AUDIO_URL').STATION_URL, 'session')
tick (10)
RFP.SKIP_REV (5001, 'SKIP_REV', {ROOMID = '25'}) -- >5s in: restart the same track
local s2 = param (last ('SELECT_AUDIO_URL').STATION_URL, 'session')
check (gIndex == i1, 'restart stayed on the same track')
check (s1 and s2 and s1 ~= s2, 'two selects of the same track never share a session')
-- repeat on with a one-track queue: armed next == current track, different session
gQueue = {gQueue[2]} gIndex = 1
RFP.SKIP_REV (5001, 'SKIP_REV', {ROOMID = '25'})
q = engineStarts ()
local cur = param (last ('SELECT_AUDIO_URL').STATION_URL, 'session')
local nx = param (last ('SET_NEXT_AUDIO_URL').NEXT_URL, 'session')
check (cur and nx and cur ~= nx, 'repeat-one: prefetched next does not reuse the playing session')

print (string.format ('\n%d passed, %d failed', pass, fail))
os.exit (fail == 0 and 0 or 1)
