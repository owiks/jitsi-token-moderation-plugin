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

-- Decode JWT token
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

-- Set up affiliation based on token
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

-- Hook for muc-room-pre-create
module:hook("muc-room-pre-create", function(event)
    local room = event.room;
    local origin = event.origin;

    if not room then
        log('error', TAG .. ' muc-room-pre-create: room is nil');
        return;
    end

    if not origin then
        log('warn', TAG .. ' muc-room-pre-create: origin is nil for room ' .. tostring(room.jid));
        return;
    end

    log('debug', TAG .. ' muc-room-pre-create: origin.full_jid=' .. tostring(origin.full_jid));
    setupAffiliation(room, origin, origin.full_jid);
end, math.huge);

-- Hook for muc-room-created
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

    if not origin.full_jid then
        log('warn', TAG .. ' muc-room-created: origin.full_jid is nil');
        return;
    end

    local bare_jid = jid_bare(origin.full_jid);

    if is_admin(bare_jid) then
        log('info', TAG .. string.format(' [SETUP_AFF] %s is admin — skipping affiliation overwrite', bare_jid));
        return;
    end

    local affiliation = origin.is_moderator and "owner" or "member";
    log('info', TAG .. string.format(' [SETUP_AFF] Pre-creating affiliation=%s for %s', affiliation, bare_jid));
    room:set_affiliation(TOKEN_ACTOR, bare_jid, affiliation);

    -- Override set_affiliation to prevent external role changes
    local original_set_affiliation = room.set_affiliation;
    room.set_affiliation = function(actor, jid, affiliation)
        local bare_jid = jid_bare(jid)

        log('warn', TAG .. string.format(
            '[AFFILIATION] set_affiliation called: actor=%s, jid=%s, affiliation=%s',
            tostring(actor), tostring(bare_jid), tostring(affiliation)
        ))

        log('warn', TAG .. 'Stacktrace:\n' .. debug.traceback("", 2))

        local info = debug.getinfo(2, "nSl")
        log('warn', TAG .. string.format(
            'Called from: %s:%d (%s)',
            info.short_src, info.currentline, tostring(info.name)
        ))

        if actor ~= TOKEN_ACTOR and room._data.user_roles and room._data.user_roles[bare_jid] ~= nil then
            log('warn', TAG .. string.format(
                'Blocked external set_affiliation from %s for %s to %s',
                tostring(actor), tostring(bare_jid), tostring(affiliation)
            ))
            return nil, "not-allowed"
        end

        return original_set_affiliation(actor, jid, affiliation)
    end
end, math.huge);

-- Hook for muc-occupant-pre-join
module:hook("muc-occupant-pre-join", function(event)
    local room, origin, occupant = event.room, event.origin, event.occupant;

    if not room or not origin or not occupant then
        log('warn', TAG .. ' muc-occupant-pre-join: missing room, origin, or occupant');
        return;
    end

    local bare_jid = jid_bare(origin.full_jid); -- Use origin.full_jid
    if not bare_jid then
        log('error', TAG .. ' origin.full_jid is malformed or nil — skipping affiliation check');
        return;
    end

    log('debug', TAG .. ' muc-occupant-pre-join: occupant.jid=' .. tostring(occupant.jid)
        .. ', occupant.nick=' .. tostring(occupant.nick)
        .. ', origin.type=' .. tostring(origin.type)
        .. ', origin.full_jid=' .. tostring(origin.full_jid)
        .. ', room.jid=' .. tostring(room.jid)
        .. ', user_roles[bare_jid]=' .. tostring(room._data.user_roles and room._data.user_roles[bare_jid])
        .. ', is_moderator=' .. tostring(origin.is_moderator));

    setupAffiliation(room, origin, origin.full_jid); -- Set affiliation using origin.full_jid

    local affiliation = room:get_affiliation(bare_jid);
    local is_moderator = room._data.user_roles and room._data.user_roles[bare_jid] or false;

    if is_moderator or affiliation == "owner" then
        occupant.role = "moderator"; -- Force role to moderator
        log('info',
            TAG ..
            string.format(' [PREJOIN] Forcing role=moderator for %s (is_moderator=%s, affiliation=%s)', bare_jid,
                tostring(is_moderator), tostring(affiliation)));
    end

    local role = occupant.role or "nil";
    log('info', TAG .. string.format(
        ' [PREJOIN] %s affiliation=%s role=%s (cache: %s)',
        bare_jid, affiliation or "nil", role, tostring(room._data.user_roles and room._data.user_roles[bare_jid])
    ));
end, 1000);

-- Hook for muc-occupant-joined
module:hook("muc-occupant-joined", function(event)
    local room, occupant, origin = event.room, event.occupant, event.origin;

    log('debug', TAG .. ' [JOINED] Hook triggered');

    if not room then
        log('error', TAG .. ' [JOINED] room is nil');
        return;
    end
    if not occupant then
        log('error', TAG .. ' [JOINED] occupant is nil');
        return;
    end
    if not origin then
        log('error', TAG .. ' [JOINED] origin is nil');
        return;
    end

    log('debug', TAG .. ' [JOINED] origin.full_jid = ' .. tostring(origin.full_jid));
    log('debug', TAG .. ' [JOINED] occupant.jid = ' .. tostring(occupant.jid));
    log('debug', TAG .. ' [JOINED] occupant.nick = ' .. tostring(occupant.nick));
    log('debug', TAG .. ' [JOINED] occupant.role = ' .. tostring(occupant.role));

    local bare_jid = jid_bare(origin.full_jid); -- Use origin.full_jid for consistency
    if not bare_jid then
        log('error', TAG .. ' [JOINED] origin.full_jid is malformed or nil — skipping role check');
        return;
    end

    local affiliation = room:get_affiliation(bare_jid);
    log('debug', TAG .. ' [JOINED] got affiliation = ' .. tostring(affiliation));

    local cache = room._data.user_roles and room._data.user_roles[bare_jid];
    log('debug', TAG .. ' [JOINED] cache for ' .. bare_jid .. ' = ' .. tostring(cache));

    -- Force role to moderator if affiliation is owner
    if affiliation == "owner" and occupant.role ~= "moderator" then
        log('info', TAG .. string.format(
            ' [JOINED] Forcing role=moderator for %s (was %s)',
            bare_jid, tostring(occupant.role)
        ));
        occupant.role = "moderator";
    else
        log('debug', TAG .. string.format(
            ' [JOINED] No role change needed for %s (affiliation=%s, role=%s)',
            bare_jid, tostring(affiliation), tostring(occupant.role)
        ));
    end

    log('info', TAG .. string.format(
        ' [JOINED] Final — %s affiliation=%s role=%s (cache: %s, occupant.jid=%s, nick=%s)',
        bare_jid,
        affiliation or "nil",
        occupant.role or "nil",
        tostring(cache),
        tostring(occupant.jid),
        tostring(occupant.nick)
    ));
end, 1000);

-- Hook for muc-occupant-left
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

-- Hook for muc-room-destroyed
module:hook("muc-room-destroyed", function(event)
    local room = event.room;
    if room and room._data and room._data.user_roles then
        log('info', TAG .. ' [CLEANUP] Clearing user_roles cache for destroyed room ' .. tostring(room.jid));
        room._data.user_roles = nil;
    end
end);
