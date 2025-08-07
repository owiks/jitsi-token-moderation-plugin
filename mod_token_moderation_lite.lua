-- Token moderation
-- This module looks for a field on incoming JWT tokens called "moderator". 
-- If it is true, the user is added to the room as a moderator, otherwise as a participant.
-- WARNING: This may interfere with other affiliation-based features like banning or admin login.

local log = module._log;
local jid_bare = require "util.jid".bare;
local json = require "cjson";
local basexx = require "basexx";

log('info', 'Loaded token moderation plugin');

local function is_admin(jid)
    return module:may("admin", jid);
end

-- Hook into room creation to wrap affiliation logic
module:hook("muc-room-created", function(event)
    log('info', 'room created, adding token moderation logic');
    local room = event.room;

    -- Save original methods
    local _handle_normal_presence = room.handle_normal_presence;
    local _handle_first_presence = room.handle_first_presence;
    local _set_affiliation = room.set_affiliation;

    -- Wrap presence handlers
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

    -- Wrap set_affiliation to block external owner assignment
    room.set_affiliation = function(room, actor, jid, affiliation, reason)
        if actor == "token_plugin" then
            return _set_affiliation(room, true, jid, affiliation, reason);
        elseif affiliation == "owner" then
            return nil, "modify", "not-acceptable";
        else
            return _set_affiliation(room, actor, jid, affiliation, reason);
        end
    end;
end);

function setupAffiliation(room, origin, stanza)
    if not origin or not origin.auth_token then return end

    local token = origin.auth_token;
    local dot1 = token:find("%.");
    if not dot1 then return end

    local dot2 = token:sub(dot1 + 1):find("%.");
    if not dot2 then return end

    local b64body = token:sub(dot1 + 1, dot1 + dot2 - 1);
    local body_json = basexx.from_url64(b64body);
    local ok, body = pcall(json.decode, body_json);
    if not ok then
        log("warn", "Failed to decode token body: %s", tostring(body));
        return;
    end

    local jid = jid_bare(stanza.attr.from);
    local moderator_value = (body.context and body.context.user and body.context.user.moderator);
    log("warn", "Body: %s", tostring(body));
    log("warn", "ModeratorValue %s", tostring(moderator_value));
    local moderator_flag = (moderator_value == true);
    
    if moderator_flag == true or is_admin(jid) then
        room:set_affiliation("token_plugin", jid, "owner");
    else
        room:set_affiliation("token_plugin", jid, "member");
    end;
end
