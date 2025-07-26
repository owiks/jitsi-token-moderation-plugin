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

function setupAffiliation(room, origin, jid)
    jid = jid_bare(jid);

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
    log('info', TAG .. ' Room created: ' .. room.jid .. ' — enabling token moderation v14');

    local _handle_first_presence = room.handle_first_presence;
    room.handle_first_presence = function(thisRoom, origin, stanza)
        log('debug', TAG .. ' [' .. stanza.attr.from .. '] handle_first_presence triggered');
        setupAffiliation(thisRoom, origin, stanza.attr.from);
        return _handle_first_presence(thisRoom, origin, stanza);
    end;

    local _set_affiliation = room.set_affiliation;
    room.set_affiliation = function(room, actor, jid, affiliation, reason)
        local actor_str = tostring(actor);
        local actor_bare = jid_bare(actor_str);
        jid = jid_bare(jid);

        log('info', TAG .. string.format(' [SET_AFF] actor=%s, target=%s, role=%s', actor_str, jid, affiliation));

        if not room or not room.jid then
            log('error', TAG .. ' Room invalid, bypassing');
            return _set_affiliation(room, actor, jid, affiliation, reason);
        end

        local current_affiliation = room:get_affiliation(jid);
        if current_affiliation == affiliation then
            log('debug', TAG .. ' [' .. jid .. '] Affiliation already ' .. affiliation .. ', skipping');
            return true;
        end

        if actor == TOKEN_ACTOR then
            log('debug', TAG .. ' [' .. jid .. '] Token plugin managing affiliation');
            return _set_affiliation(room, actor, jid, affiliation, reason);
        end

        local hasOwnerAff = false;
        for jid_aff, aff_name in room:each_affiliation() do
            if aff_name == "owner" and not is_admin(jid_aff) then
                hasOwnerAff = true;
                log('debug', TAG .. ' Owner already exists: ' .. jid_aff);
                break;
            end
        end

        if hasOwnerAff and current_affiliation == "member" and affiliation == "owner" then
            log('warn', TAG .. ' [' .. jid .. '] Promotion to owner denied: room already has non-admin owner');
            return nil, "cancel", "not-allowed";
        end

        local is_moderator_cached = room._data.user_roles and room._data.user_roles[jid];
        log('debug', TAG .. ' [' .. jid .. '] Cached is_moderator: ' .. tostring(is_moderator_cached));

        if affiliation == "owner" and current_affiliation == "member" and is_moderator_cached then
            log('debug', TAG .. ' [' .. jid .. '] Already has correct role, ignoring');
            return false;
        end

        if is_admin(actor_bare) and affiliation == "owner" then
            log('warn', TAG .. string.format(' [FOCUS-HANDLER] Admin %s promotes %s. Allowing.', actor_str, jid));
            local success, err, code = _set_affiliation(room, actor, jid, affiliation, reason);
            if success and is_moderator_cached == false then
                log('warn', TAG .. string.format(' [FOCUS-HANDLER] Reverting %s to member — not moderator per token', jid));
                _set_affiliation(room, TOKEN_ACTOR, jid, "member", "Role restored from token cache");
            end
            return success, err, code;
        end

        if is_moderator_cached == true and affiliation ~= "owner" then
            log('error', TAG .. string.format(' [SECURITY] %s tried to demote token-moderator %s — BLOCKED', actor_str, jid));
            return nil, "modify", "not-acceptable";
        end

        if is_moderator_cached == false and affiliation == "owner" then
            log('error', TAG .. string.format(' [SECURITY] %s tried to promote non-moderator %s — BLOCKED', actor_str, jid));
            return nil, "modify", "not-acceptable";
        end

        if is_moderator_cached == nil then
            log('warn', TAG .. string.format(' [GUARD] No cache yet for %s — allowing for now', jid));
        end

        log('info', TAG .. string.format(' [PASS] Allowing affiliation set for %s by %s', jid, actor_str));
        return _set_affiliation(room, actor, jid, affiliation, reason);
    end
end);

module:hook("muc-occupant-left", function(event)
    local occupant = event.occupant;
    local room = event.room;
    if not (room._data and room._data.user_roles and occupant) then
        return;
    end

    local bare_jid = jid_bare(occupant.jid);

    if room._data.user_roles[bare_jid] ~= nil then
        log('info', TAG .. string.format(' [CACHE-CLEANUP] Removing cached role for %s', bare_jid));
        room._data.user_roles[bare_jid] = nil;
    end
end, 1);
