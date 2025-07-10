local log = module._log;
local jid_bare = require "util.jid".bare;
local json = require "cjson";
local basexx = require "basexx";
local os_time = require "util.time".now;

log('info', 'Loaded token moderation plugin v7 (SUPER-VERBOSE DEBUGGING)');

function setupAffiliation(room, origin, jid)
    jid = jid_bare(jid);
    
    log('info', '-> ENTERING setupAffiliation for %s', jid);

    if not origin.auth_token then
        log('warn', '[%s] No auth_token found in session. Cannot determine roles.', jid);
        origin.is_moderator = false;
        return;
    end
    
    log('info', '[%s] Raw JWT found: %s', jid, origin.auth_token);

    local dotFirst = origin.auth_token:find("%.");
    local dotSecond = dotFirst and origin.auth_token:sub(dotFirst + 1):find("%.");

    if not dotSecond then
        log('warn', '[%s] Malformed token, could not parse.', jid);
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
    
    log('info', '[%s] >> Decoded JWT Body: %s', jid, json.encode(decoded));

    local now = os_time();
    if decoded.nbf and now < decoded.nbf then
        log('error', '[%s] Token validity check FAILED. Token is not yet valid (nbf). nbf: %s, now: %s', jid, tostring(decoded.nbf), tostring(now));
        origin.is_moderator = false;
        return;
    end
    if decoded.exp and now >= decoded.exp then
        log('error', '[%s] Token validity check FAILED. Token has expired (exp). exp: %s, now: %s', jid, tostring(decoded.exp), tostring(now));
        origin.is_moderator = false;
        return;
    end

    local moderator_value = (decoded.context and decoded.context.user and decoded.context.user.moderator) or decoded.moderator;
    local moderator_flag = (moderator_value == true);

    log('info', '[%s] Moderator value from token is: %s', jid, tostring(moderator_value));

    if moderator_value == nil then
        log('warn', '[%s] "moderator" flag not found in token. Defaulting to regular user.', jid);
    end

    origin.is_moderator = moderator_flag;
    log('info', '[%s] Determined and cached affiliation: is_moderator=%s', jid, tostring(moderator_flag));

    if moderator_flag then
        log('info', '[%s] --> ACTION: Calling set_affiliation with role: owner', jid);
        room:set_affiliation("token_plugin", jid, "owner", "Assigned by token");
    else
        log('info', '[%s] --> ACTION: Calling set_affiliation with role: member', jid);
        room:set_affiliation("token_plugin", jid, "member", "Assigned by token");
    end
    log('info', '<- LEAVING setupAffiliation for %s', jid);
end

module:hook("muc-room-created", function(event)
    local room = event.room;
    log('info', 'Room created: %s — enabling token moderation logic v7', room.jid);

    local _handle_first_presence = room.handle_first_presence;
    room.handle_first_presence = function(thisRoom, origin, stanza)
        local pres = _handle_first_presence(thisRoom, origin, stanza);
        setupAffiliation(thisRoom, origin, stanza.attr.from);
        return pres;
    end;
    
    local _handle_normal_presence = room.handle_normal_presence;
    room.handle_normal_presence = function(thisRoom, origin, stanza)
        local pres = _handle_normal_presence(thisRoom, origin, stanza);
        setupAffiliation(thisRoom, origin, stanza.attr.from);
        return pres;
    end

    local _set_affiliation = room.set_affiliation;
    room.set_affiliation = function(room, actor, jid, affiliation, reason)
        local actor_str = tostring(actor);
        log('info', '--> ENTERING custom set_affiliation hook for jid=%s, new_affiliation=%s, actor=%s', jid, affiliation, actor_str);
        
        if not room or not room.jid then
             log('warn', '[GUARD] set_affiliation called on a nil room object. Calling original function to prevent crash.', actor_str);
             return _set_affiliation(room, actor, jid, affiliation, reason);
        end

        local current_affiliation = room:get_affiliation(jid);
        log('info', '[STATE] Current affiliation for %s is: %s', jid, tostring(current_affiliation));
        
        if current_affiliation == affiliation then
            log('info', '[SKIP] Skipping redundant affiliation set for %s to %s', jid, affiliation);
            return true;
        end

        local is_external_actor = (actor ~= "token_plugin");
        log('info', '[CHECK] Is actor external? %s', tostring(is_external_actor));

        if actor_str:match("^focus@") and affiliation == "owner" then
            log('warn', '[FOCUS-HANDLER] Jicofo is trying to promote user. Entering special logic block.', jid);
            local success, err, code = _set_affiliation(room, actor, jid, affiliation, reason);
            if success then
                log('info', '[FOCUS-HANDLER] Jicofo promotion succeeded. Re-evaluating based on token cache.', jid);
                if room.occupants then
                    local occupant = room.occupants[jid_bare(jid)];
                    if occupant and occupant.origin then
                        log('info', '[FOCUS-HANDLER] Checking cached token status: is_moderator = %s', tostring(occupant.origin.is_moderator));
                        if occupant.origin.is_moderator == false then
                            log('warn', '[FOCUS-HANDLER] --> ACTION: Token says NOT moderator. Downgrading %s back to member.', jid);
                            _set_affiliation(room, "token_plugin", jid, "member", "Role restored from token cache");
                        end
                    end
                else
                    log('warn', '[FOCUS-HANDLER] room.occupants not available during re-evaluation for %s', jid);
                end
            end
            return success, err, code;
        end

        if not room.occupants then
             log('warn', '[GUARD] set_affiliation called before room.occupants is ready by %s. Calling original function.', actor_str);
             return _set_affiliation(room, actor, jid, affiliation, reason);
        end

        local occupant = room.occupants[jid_bare(jid)];
        local is_moderator_cached = (occupant and occupant.origin and occupant.origin.is_moderator);
        log('info', '[CHECK] Is user a cached moderator? %s', tostring(is_moderator_cached));

        if current_affiliation == "owner" and affiliation ~= "owner" and is_moderator_cached and is_external_actor then
            log('warn', '[SECURITY-BLOCK] Blocked external attempt by %s to demote a token-verified moderator: %s', actor_str, jid);
            return nil, "modify", "not-acceptable";
        end

        if affiliation == "owner" and is_external_actor then
            log('warn', '[SECURITY-BLOCK] Blocked external attempt by %s to promote a user to owner: %s', actor_str, jid);
            return nil, "modify", "not-acceptable";
        end
        
        log('info', '<-- PASSING-THROUGH: All checks passed. Calling original _set_affiliation for %s.', jid);
        return _set_affiliation(room, actor, jid, affiliation, reason);
    end
end);
