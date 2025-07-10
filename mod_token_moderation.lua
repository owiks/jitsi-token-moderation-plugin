local log = module._log;
local jid_bare = require "util.jid".bare;
local json = require "cjson";
local basexx = require "basexx";
local os_time = require "util.time".now;

log('info', 'Loaded token moderation plugin v9 (Final & Production Ready)');

function setupAffiliation(room, origin, jid)
    jid = jid_bare(jid);
    if origin.is_moderator ~= nil then return; end
    log('info', '[%s] Starting initial affiliation setup from token', jid);
    if not origin.auth_token then
        log('warn', '[%s] No auth_token in session', jid);
        origin.is_moderator = false;
        return;
    end
    local dotFirst = origin.auth_token:find("%.");
    local dotSecond = dotFirst and origin.auth_token:sub(dotFirst + 1):find("%.");
    if not dotSecond then
        log('warn', '[%s] Malformed token', jid);
        origin.is_moderator = false;
        return;
    end
    local bodyB64 = origin.auth_token:sub(dotFirst + 1, dotFirst + dotSecond - 1);
    local success, decoded = pcall(function() return json.decode(basexx.from_url64(bodyB64)); end);
    if not success or type(decoded) ~= "table" then
        log('error', '[%s] Failed to decode token body', jid);
        origin.is_moderator = false;
        return;
    end
    local now = os_time();
    if decoded.nbf and now < decoded.nbf then
        log('error', '[%s] Token is not yet valid (nbf)', jid);
        origin.is_moderator = false;
        return;
    end
    if decoded.exp and now >= decoded.exp then
        log('error', '[%s] Token has expired (exp)', jid);
        origin.is_moderator = false;
        return;
    end
    local moderator_value = (decoded.context and decoded.context.user and decoded.context.user.moderator) or decoded.moderator;
    local moderator_flag = (moderator_value == true);
    if moderator_value == nil then
        log('warn', '[%s] "moderator" flag not found in token.', jid);
    end
    origin.is_moderator = moderator_flag;
    log('info', '[%s] Determined affiliation: is_moderator=%s', jid, tostring(moderator_flag));
    if moderator_flag then
        room:set_affiliation("token_plugin", jid, "owner");
    else
        room:set_affiliation("token_plugin", jid, "member");
    end
end

module:hook("muc-room-created", function(event)
    local room = event.room;
    log('info', 'Room created: %s — enabling token moderation logic v9', room.jid);

    local _handle_first_presence = room.handle_first_presence;
    room.handle_first_presence = function(thisRoom, origin, stanza)
        local pres = _handle_first_presence(thisRoom, origin, stanza);
        setupAffiliation(thisRoom, origin, stanza.attr.from);
        return pres;
    end;

    local _set_affiliation = room.set_affiliation;
    room.set_affiliation = function(room, actor, jid, affiliation, reason)
        if not room or not room.jid then
             return _set_affiliation(room, actor, jid, affiliation, reason);
        end
        local current_affiliation = room:get_affiliation(jid);
        if current_affiliation == affiliation then
            return true;
        end
        local actor_str = tostring(actor);
        log('info', '--> set_affiliation: jid=%s, new_role=%s, actor=%s, current_role=%s', jid, affiliation, actor_str, tostring(current_affiliation));

        if actor == "token_plugin" then
            log('info', '[ACTION] Call from our plugin. Executing.', jid);
            return _set_affiliation(room, actor, jid, affiliation, reason);
        end

        if actor_str:match("^focus@") and affiliation == "owner" then
            log('warn', '[FOCUS-HANDLER] Jicofo tries to promote. Allowing temporarily.', jid);
            local success, err, code = _set_affiliation(room, actor, jid, affiliation, reason);
            if success and room.occupants then
                local occupant = room.occupants[jid_bare(jid)];
                if occupant and occupant.origin and occupant.origin.is_moderator == false then
                    log('warn', '[FOCUS-HANDLER] --> ACTION: Token says NOT moderator. Downgrading %s back to member.', jid);
                    _set_affiliation(room, "token_plugin", jid, "member", "Role restored from token");
                end
            end
            return success, err, code;
        end
        
        local is_external_actor = (actor ~= "token_plugin");
        
        if affiliation == "owner" and is_external_actor then
            log('warn', '[SECURITY-BLOCK] Blocked external attempt by %s to promote a user to owner: %s', actor_str, jid);
            return nil, "modify", "not-acceptable";
        end
        
        if current_affiliation == "owner" and affiliation ~= "owner" and is_external_actor then
             if room.occupants then
                local occupant = room.occupants[jid_bare(jid)];
                if occupant and occupant.origin and occupant.origin.is_moderator == true then
                    log('warn', '[SECURITY-BLOCK] Blocked external attempt by %s to demote a token-verified moderator: %s', actor_str, jid);
                    return nil, "modify", "not-acceptable";
                end
             end
        end

        log('info', '[PASS-THROUGH] Permitting safe external action by %s', actor_str);
        return _set_affiliation(room, actor, jid, affiliation, reason);
    end
end);
