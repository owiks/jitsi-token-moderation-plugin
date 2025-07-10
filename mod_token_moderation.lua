local log = module._log;
local jid_bare = require "util.jid".bare;
local json = require "cjson";
local basexx = require "basexx";
local os_time = require "util.time".now;

log('info', 'Loaded token moderation plugin');

function setupAffiliation(room, origin, jid)
    jid = jid_bare(jid);

    if origin.is_moderator ~= nil then return; end
    log('info', '[%s] CACHE-MISS. Starting initial affiliation setup from token.', jid);

    if not origin.auth_token then
        origin.is_moderator = false;
        return;
    end

    local dotFirst = origin.auth_token:find("%.");
    local dotSecond = dotFirst and origin.auth_token:sub(dotFirst + 1):find("%.");
    if not dotSecond then
        origin.is_moderator = false;
        return;
    end

    local bodyB64 = origin.auth_token:sub(dotFirst + 1, dotFirst + dotSecond - 1);
    local success, decoded = pcall(function() return json.decode(basexx.from_url64(bodyB64)); end);

    if not success or type(decoded) ~= "table" then
        origin.is_moderator = false;
        return;
    end

    local now = os_time();
    if (decoded.nbf and now < decoded.nbf) or (decoded.exp and now >= decoded.exp) then
        origin.is_moderator = false;
        return;
    end

    local moderator_value = (decoded.context and decoded.context.user and decoded.context.user.moderator) or
        decoded.moderator;
    local moderator_flag = (moderator_value == true);

    origin.is_moderator = moderator_flag;
    log('info', '[%s] CACHE-WRITE. Determined affiliation: is_moderator=%s', jid, tostring(moderator_flag));

    if moderator_flag then
        room:set_affiliation("token_plugin", jid, "owner");
    else
        room:set_affiliation("token_plugin", jid, "member");
    end
end

module:hook("muc-room-created", function(event)
    local room = event.room;
    for k, v in pairs(event) do
        log('info', 'event[%s] = %s', tostring(k), tostring(v));
    end

    log('info', 'Room created: %s — enabling token moderation logic v14', room.jid);

    local _handle_first_presence = room.handle_first_presence;
    room.handle_first_presence = function(thisRoom, origin, stanza)
        for k, v in pairs(event) do
            log('info', 'handle_first_presence[%s] = %s', tostring(k), tostring(v));
        end

        log('info', 'thisRoom %s', tostring(thisRoom))
        log('info', 'origin %s', tostring(origin))
        log('info', 'is_moderator %s', tostring(origin.is_moderator))
        log('info', 'is_moderator_cached %s', tostring(origin.is_moderator_cached))
        log('info', 'stanza %s', tostring(stanza))
        log('info', 'stanza %s', tostring(stanza))
        local pres = _handle_first_presence(thisRoom, origin, stanza);
        setupAffiliation(thisRoom, origin, stanza.attr.from);
        return pres;
    end;

    local _set_affiliation = room.set_affiliation;
    room.set_affiliation = function(room, actor, jid, affiliation, reason)
        local actor_str = tostring(actor);

        if not room or not room.jid then
            return _set_affiliation(room, actor, jid, affiliation, reason);
        end

        local current_affiliation = room:get_affiliation(jid);
        if current_affiliation == affiliation then
            return true;
        end

        local hasOwnerAff = false

        for jid_aff, aff_name in room:each_affiliation() do
            log('info', 'JID: %s aff: %s', jid_aff, aff_name)

            if jid_aff:match("^focus@") then
                return
            end

            if aff_name and aff_name == "owner" then
                hasOwnerAff = true
            end
        end

        log('info', 'Has owner aff: %s', tonumber(hasOwnerAff))
        log('info', 'Has owner aff: %s', tonumber(hasOwnerAff))

        if hasOwnerAff and current_affiliation == "member" and affiliation == "owner" then
            log('info', 'Current aff denied owner')
            return _set_affiliation(room, actor, jid, affiliation, reason);
        end


        log('info', '--> set_affiliation: jid=%s, new_role=%s, actor=%s, current_role=%s', jid, affiliation, actor_str,
            tostring(current_affiliation));

        local occupant = room.occupants and room.occupants[jid_bare(jid)];
        log('info', 'occupant %s', tostring(occupant))
        local is_moderator_cached = (occupant and occupant.origin and occupant.origin.is_moderator);
        log('info', 'is_moderator_cached %d', tonumber(is_moderator_cached))

        if affiliation == "owner" and current_affiliation == "member" and is_moderator_cached then
            return false;
        end

        if actor == "token_plugin" then
            return _set_affiliation(room, actor, jid, affiliation, reason);
        end


        if actor_str:match("^focus@") and affiliation == "owner" then
            log('warn', '[FOCUS-HANDLER] Jicofo promotes user. Allowing temporarily.', jid);
            local success, err, code = _set_affiliation(room, actor, jid, affiliation, reason);
            if success and is_moderator_cached == false then
                log('warn', '[FOCUS-HANDLER] --> ACTION: Token cache says NOT moderator. Downgrading %s.', jid);
                _set_affiliation(room, "token_plugin", jid, "member", "Role restored from token cache");
            end
            return success, err, code;
        end

        if is_moderator_cached == true and affiliation ~= "owner" then
            log('warn', '[SECURITY-BLOCK] Blocked external attempt by %s to demote a token-verified moderator: %s',
                actor_str, jid);
            return nil, "modify", "not-acceptable";
        end

        if is_moderator_cached == false and affiliation == "owner" then
            log('warn', '[SECURITY-BLOCK] Blocked external attempt by %s to promote a non-moderator: %s', actor_str, jid);
            return nil, "modify", "not-acceptable";
        end

        if is_moderator_cached == nil then
            log('warn', '[GUARD] Cache not ready for %s. Permitting action for stability.', jid);
        end

        log('info', '[PASS-THROUGH] Permitting safe action by %s', actor_str);
        return _set_affiliation(room, actor, jid, affiliation, reason);
    end
end);
