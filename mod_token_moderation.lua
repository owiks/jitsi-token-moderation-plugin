local log = module._log;
local jid_bare = require "util.jid".bare;
local json = require "cjson";
local basexx = require "basexx";

log('info', 'Loaded token moderation plugin');

module:hook("muc-room-created", function(event)
    local room = event.room;
    log('info', 'Room created: %s — enabling token moderation logic', room.jid);

    local _handle_normal_presence = room.handle_normal_presence;
    local _handle_first_presence = room.handle_first_presence;

    room.handle_normal_presence = function(thisRoom, origin, stanza)
        local pres = _handle_normal_presence(thisRoom, origin, stanza);
        setupAffiliation(thisRoom, origin, stanza);
        return pres;
    end;

    room.handle_first_presence = function(thisRoom, origin, stanza)
        local pres = _handle_first_presence(thisRoom, origin, stanza);
        setupAffiliation(thisRoom, origin, stanza);
        return pres;
    end;

    local _set_affiliation = room.set_affiliation;
    room.set_affiliation = function(room, actor, jid, affiliation, reason)
        log('debug', 'set_affiliation called: actor=%s jid=%s affiliation=%s', tostring(actor), tostring(jid), tostring(affiliation));
        if actor == "token_plugin" then
            log('debug', 'Setting affiliation via token_plugin: %s → %s', jid, affiliation);
            return _set_affiliation(room, true, jid, affiliation, reason);
        elseif affiliation == "owner" then
            log('warn', 'Blocked external attempt to assign owner to %s', jid);
            return nil, "modify", "not-acceptable";
        else
            return _set_affiliation(room, actor, jid, affiliation, reason);
        end;
    end;
end);

function setupAffiliation(room, origin, stanza)
    local jid = jid_bare(stanza.attr.from);
    log('debug', '[%s] Starting affiliation setup', jid);

    if not origin.auth_token then
        log('debug', '[%s] No auth_token found in session', jid);
        return;
    end

    log('debug', '[%s] JWT token: %s', jid, origin.auth_token);

    local dotFirst = origin.auth_token:find("%.");
    if not dotFirst then
        log('warn', '[%s] Malformed token: no first dot', jid);
        return;
    end

    local dotSecond = origin.auth_token:sub(dotFirst + 1):find("%.");
    if not dotSecond then
        log('warn', '[%s] Malformed token: no second dot', jid);
        return;
    end

    local bodyB64 = origin.auth_token:sub(dotFirst + 1, dotFirst + dotSecond - 1);
    log('debug', '[%s] Encoded JWT body (base64url): %s', jid, bodyB64);

    local success, decoded = pcall(function()
        return json.decode(basexx.from_url64(bodyB64));
    end);

    if not success or type(decoded) ~= "table" then
        log('error', '[%s] Failed to decode token body', jid);
        return;
    end

    local raw_json = json.encode(decoded);
    log('debug', '[%s] Decoded JWT body: %s', jid, raw_json);

    local moderator_flag = false;
    if decoded.context and decoded.context.user and decoded.context.user.moderator == true then
        moderator_flag = true;
    end

    log('info', '[%s] moderator flag = %s', jid, tostring(moderator_flag));

    if moderator_flag then
        log('info', '[%s] moderator=true — assigning owner', jid);
        room:set_affiliation("token_plugin", jid, "owner");
    else
        log('info', '[%s] moderator=false or missing — assigning member', jid);
        room:set_affiliation("token_plugin", jid, "member");
    end
end
