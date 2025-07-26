local log = module._log;
local jid_bare = require "util.jid".bare;
local json = require "cjson";
local basexx = require "basexx";
local os_time = require "util.time".now;
local util = module:require 'util';
local is_admin = util.is_admin;

local TOKEN_ACTOR = "token_plugin";
local TAG = "[TOKEN_MODERATION]";

log('info', TAG .. ' Loaded token moderation plugin');

local function decode_token(token)
    local dot1 = token:find("%.");
    local dot2 = dot1 and token:sub(dot1 + 1):find("%.");
    if not dot1 or not dot2 then
        log('warn', TAG .. ' [TOKEN] Invalid JWT structure');
        return nil;
    end

    local payload = token:sub(dot1 + 1, dot1 + dot2 - 1);
    local ok, decoded = pcall(function()
        return json.decode(basexx.from_url64(payload));
    end);
    if not ok or type(decoded) ~= "table" then
        log('warn', TAG .. ' [TOKEN] Failed to decode payload');
        return nil;
    end

    local now = os_time();
    if decoded.nbf and now < decoded.nbf then
        log('warn', TAG .. ' [TOKEN] Token not yet valid (nbf in future): %d > %d', decoded.nbf, now);
        return nil;
    end
    if decoded.exp and now >= decoded.exp then
        log('warn', TAG .. ' [TOKEN] Token expired: %d <= %d', decoded.exp, now);
        return nil;
    end

    return decoded;
end

local function setupAffiliation(room, origin, jid)
    if not room then
        log('error', TAG .. ' setupAffiliation: room is nil');
        return;
    end

    if not origin then
        log('warn', TAG .. ' setupAffiliation: origin is nil');
        return;
    end

    log('debug', TAG .. ' setupAffiliation: origin type=' .. tostring(origin.type)
        .. ', full_jid=' .. tostring(origin.full_jid)
        .. ', is_moderator=' .. tostring(origin.is_moderator)
        .. ', auth_token=' .. tostring(origin.auth_token));

    jid = jid_bare(jid or "");

    if origin.is_moderator == true or origin.is_moderator == false then
        log('debug', TAG .. ' [' .. jid .. '] setupAffiliation called repeatedly — skipping');
        return;
    end

    log('info', TAG .. ' [' .. jid .. '] CACHE-MISS. Starting affiliation setup from token');

    if not origin.auth_token then
        log('warn', TAG .. ' [' .. jid .. '] No auth_token found in session');
        origin.is_moderator = false;
        return;
    end

    local decoded = decode_token(origin.auth_token);
    if not decoded then
        log('warn', TAG .. ' [' .. jid .. '] Token invalid or failed validation');
        origin.is_moderator = false;
        return;
    end

    local moderator_value = (decoded.context and decoded.context.user and decoded.context.user.moderator)
        or decoded.moderator;
    local moderator_flag = (moderator_value == true);

    log('info', TAG .. ' [' .. jid .. '] Parsed moderator flag from token: ' .. tostring(moderator_flag));
    origin.is_moderator = moderator_flag;

    room._data.user_roles = room._data.user_roles or {};
    room._data.user_roles[jid] = moderator_flag;

    local ok, err = pcall(function()
        local affiliation = moderator_flag and "owner" or "member";
        log('info', TAG .. ' [' .. jid .. '] Setting initial affiliation to: ' .. affiliation);
        room:set_affiliation(TOKEN_ACTOR, jid, affiliation);
    end);
    if not ok then
        log('error', TAG .. ' [' .. jid .. '] Failed to set affiliation: ' .. tostring(err));
    end
end

module:hook("muc-room-created", function(event)
    local room = event.room;
    local origin = event.origin;

    if not room then
        log('error', TAG .. ' muc-room-created: room is nil');
        return;
    end

    if not origin then
        log('warn', TAG .. ' muc-room-created: origin is nil for room ' .. tostring(room.jid));
        return;
    end

    log('debug', TAG .. ' muc-room-created: origin type=' .. tostring(origin.type)
        .. ', full_jid=' .. tostring(origin.full_jid)
        .. ', is_moderator=' .. tostring(origin.is_moderator)
        .. ', auth_token=' .. tostring(origin.auth_token));

    if not origin.full_jid then
        log('warn', TAG .. ' muc-room-created: origin.full_jid is nil');
        return;
    end

    local bare_jid = jid_bare(origin.full_jid);

    if origin.is_moderator then
        log('info', TAG .. string.format(' [SETUP_AFF] Pre-creating affiliation=owner for %s', bare_jid));
        room:set_affiliation(TOKEN_ACTOR, bare_jid, "owner");
    else
        log('info', TAG .. string.format(' [SETUP_AFF] Pre-creating affiliation=member for %s', bare_jid));
        room:set_affiliation(TOKEN_ACTOR, bare_jid, "member");
    end
end, math.huge);

module:hook("muc-occupant-pre-join", function(event)
    local room = event.room;
    local origin = event.origin;
    local occupant = event.occupant;

    if not occupant or not origin or not room then
        log('warn', TAG .. ' muc-occupant-pre-join: missing room, origin, or occupant');
        return;
    end

    local bare_jid = jid_bare(occupant.nick);
    if not bare_jid then
        log('error', TAG .. ' occupant.nick is malformed or nil — skipping affiliation check');
        return;
    end

    log('debug', TAG .. ' muc-occupant-pre-join: occupant.nick=' .. tostring(occupant.nick)
        .. ', origin.type=' .. tostring(origin.type)
        .. ', origin.full_jid=' .. tostring(origin.full_jid)
        .. ', room.jid=' .. tostring(room.jid)
        .. ', user_roles[bare_jid]=' .. tostring(room._data.user_roles and room._data.user_roles[bare_jid])
        .. ', is_moderator=' .. tostring(origin.is_moderator));

    setupAffiliation(room, origin, occupant.nick);

    local affiliation = room:get_affiliation(bare_jid);
    local role = occupant.role or "nil";
    log('info', TAG .. string.format(' [PREJOIN] %s affiliation=%s role=%s', bare_jid, affiliation or "nil", role));
end, 1000);

module:hook("muc-occupant-left", function(event)
    local occupant = event.occupant;
    local room = event.room;
    if not (room and room._data and room._data.user_roles and occupant) then
        log('debug', TAG .. ' muc-occupant-left: missing room._data or occupant');
        return;
    end

    local bare_jid = jid_bare(occupant.jid);
    if room._data.user_roles[bare_jid] ~= nil then
        log('info', TAG .. string.format(' [CACHE-CLEANUP] Removing cached role for %s', bare_jid));
        room._data.user_roles[bare_jid] = nil;
    end
end, 1);
