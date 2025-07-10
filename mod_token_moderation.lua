local log = module._log;
local jid_bare = require "util.jid".bare;
local json = require "cjson";
local basexx = require "basexx";

log('info', 'Loaded token moderation plugin v4 (stable hook)');

function setupAffiliation(room, origin, jid)
    jid = jid_bare(jid);

    if origin.is_moderator ~= nil then
        return;
    end

    log('info', '[%s] Starting initial affiliation setup from token', jid);

    if not origin.auth_token then
        log('warn', '[%s] No auth_token found in session', jid);
        origin.is_moderator = false; -- Кэшируем результат
        return;
    end

    local dotFirst = origin.auth_token:find("%.");
    local dotSecond = dotFirst and origin.auth_token:sub(dotFirst + 1):find("%.");

    if not dotSecond then
        log('warn', '[%s] Malformed token, could not parse.', jid);
        origin.is_moderator = false;
        return;
    end

    local bodyB64 = origin.auth_token:sub(dotFirst + 1, dotFirst + dotSecond - 1);
    local success, decoded = pcall(function()
        return json.decode(basexx.from_url64(bodyB64));
    end);

    if not success or type(decoded) ~= "table" then
        log('error', '[%s] Failed to decode token body', jid);
        origin.is_moderator = false;
        return;
    end

    local moderator_flag = (decoded.context and decoded.context.user and decoded.context.user.moderator == true) or (decoded.moderator == true);

    origin.is_moderator = moderator_flag;
    log('info', '[%s] Determined and cached affiliation: is_moderator=%s', jid, tostring(moderator_flag));

    if moderator_flag then
        room:set_affiliation("token_plugin", jid, "owner");
    else
        room:set_affiliation("token_plugin", jid, "member");
    end
end

module:hook("muc-room-created", function(event)
    local room = event.room;
    log('info', 'Room created: %s — enabling token moderation logic v4', room.jid);

    local _handle_first_presence = room.handle_first_presence;
    room.handle_first_presence = function(thisRoom, origin, stanza)
        local pres = _handle_first_presence(thisRoom, origin, stanza);
        setupAffiliation(thisRoom, origin, stanza.attr.from);
        return pres;
    end;

    local _set_affiliation = room.set_affiliation;
    room.set_affiliation = function(room, actor, jid, affiliation, reason)
        local actor_str = tostring(actor);
        log('debug', 'set_affiliation called: actor=%s jid=%s affiliation=%s', actor_str, jid, affiliation);

        local is_external_actor = (actor ~= "token_plugin");

        if actor_str:match("^focus@") and affiliation == "owner" then
            log('warn', 'Jicofo tries to promote %s to owner. Allowing temporarily.', jid);
            local success, err, code = _set_affiliation(room, actor, jid, affiliation, reason);
            if success then
                log('info', 'Jicofo promotion succeeded. Re-evaluating for %s based on token cache.', jid);
                local occupant = room.occupants[jid_bare(jid)];
                if occupant and occupant.origin and occupant.origin.is_moderator == false then
                    log('info', 'Re-evaluating: token cache says NOT moderator. Downgrading %s to member.', jid);
                    _set_affiliation(room, "token_plugin", jid, "member", "Role restored from token cache");
                end
            end
            return success, err, code;
        end

        local occupant = room.occupants[jid_bare(jid)];
        local is_moderator_cached = (occupant and occupant.origin and occupant.origin.is_moderator);
        
        local current_affiliation = room:get_affiliation(jid);

        if current_affiliation == "owner" and affiliation ~= "owner" and is_moderator_cached and is_external_actor then
            log('warn', 'Blocked external attempt by %s to demote a token-verified moderator: %s', actor_str, jid);
            return nil, "modify", "not-acceptable";
        end

        if affiliation == "owner" and is_external_actor then
            log('warn', 'Blocked external attempt by %s to promote a user to owner: %s', actor_str, jid);
            return nil, "modify", "not-acceptable";
        end

        return _set_affiliation(room, actor, jid, affiliation, reason);
    end
end);
