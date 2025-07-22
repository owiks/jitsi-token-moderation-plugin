local jid_split = require "util.jid".split;
local json = require "cjson";
local basexx = require "basexx";
local util = module:require "util";
local is_admin = util.is_admin;
local os_time = os.time;

local function is_moderator_from_jwt(session)
    if not session then
        module:log("debug", "Session is nil in is_moderator_from_jwt");
        return false;
    end

    local token = session.auth_token;
    if not token then
        module:log("debug", "No auth_token in session");
        return false;
    end

    local dot1 = token:find("%.");
    local dot2 = token:find("%.", dot1 and (dot1 + 1) or 0);
    if not dot1 or not dot2 then
        module:log("warn", "Invalid JWT format in session token");
        return false;
    end

    local body = token:sub(dot1 + 1, dot2 - 1);
    local ok, decoded = pcall(function()
        return json.decode(basexx.from_url64(body));
    end);
    if not ok or type(decoded) ~= "table" then
        module:log("warn", "Failed to decode JWT in is_moderator_from_jwt");
        return false;
    end

    local now = os_time();
    if (decoded.nbf and now < decoded.nbf) or (decoded.exp and now >= decoded.exp) then
        module:log("warn", "JWT in session is outside of valid timeframe");
        return false;
    end

    local moderator = decoded.moderator == true
        or (decoded.context and decoded.context.user and decoded.context.user.moderator == true);

    module:log("debug", "Session JWT moderator claim = %s", tostring(moderator));
    return moderator;
end

local function parse_jwt(origin)
    local token = origin.auth_token;
    local jid = origin.full_jid or "<unknown>";

    if not token then
        module:log("debug", "No auth_token found for %s", jid);
        origin.is_moderator = false;
        return;
    end

    module:log("debug", "Parsing JWT for %s: %s", jid, token);

    local dot1 = token:find("%.");
    local dot2 = token:find("%.", dot1 and (dot1 + 1) or 0);
    if not dot1 or not dot2 then
        module:log("warn", "Invalid JWT format for %s (dot1=%s, dot2=%s)", jid, tostring(dot1), tostring(dot2));
        origin.is_moderator = false;
        return;
    end

    module:log("debug", "JWT structure OK (dot1=%d, dot2=%d)", dot1, dot2);

    local body = token:sub(dot1 + 1, dot2 - 1);
    local base64_decoded;
    local ok, decoded = pcall(function()
        base64_decoded = basexx.from_url64(body);
        return json.decode(base64_decoded);
    end);

    if not ok or type(decoded) ~= "table" then
        module:log("warn", "Failed to decode JWT payload for %s", jid);
        module:log("debug", "Base64-decoded body: %s", tostring(base64_decoded));
        origin.is_moderator = false;
        return;
    end

    module:log("debug", "Decoded JWT payload for %s: %s", jid, json.encode(decoded));

    local now = os_time();
    if decoded.nbf and now < decoded.nbf then
        module:log("warn", "JWT for %s not yet valid (nbf=%d, now=%d)", jid, decoded.nbf, now);
        origin.is_moderator = false;
        return;
    end
    if decoded.exp and now >= decoded.exp then
        module:log("warn", "JWT for %s expired (exp=%d, now=%d)", jid, decoded.exp, now);
        origin.is_moderator = false;
        return;
    end

    local moderator_value = (decoded.context and decoded.context.user and decoded.context.user.moderator)
        or decoded.moderator;

    origin.is_moderator = moderator_value == true;

    module:log("debug", "Moderator claim for %s: %s → is_moderator = %s",
        jid, tostring(moderator_value), tostring(origin.is_moderator));
end

module:hook("muc-occupant-pre-join", function(event)
    local room = event.room;
    local origin = event.origin;
    local occupant = event.occupant;
    local actor_jid = origin.full_jid;

    module:log("debug", "muc-occupant-pre-join: %s joining room %s", actor_jid, room.jid);

    if is_admin(actor_jid, module.host) then
        module:log("debug", "%s is an admin — allowing entry", actor_jid);
        return;
    end

    if origin.is_moderator == nil then
        module:log("debug", "JWT not parsed yet for %s — parsing now", actor_jid);
        parse_jwt(origin);
    end

    local is_moderator = origin.is_moderator == true;
    module:log("debug", "Final is_moderator status for %s: %s", actor_jid, tostring(is_moderator));

    local real_participants = 0;
    for _, o in pairs(room._occupants) do
        for _, p in pairs(o.sessions) do
            if not p.nick or not p.nick:match("^focus@") then
                real_participants = real_participants + 1;
            end
        end
    end
    module:log("debug", "Room %s has %d non-focus occupants", room.jid, real_participants);

    if real_participants == 0 and not is_moderator then
        module:log("info", "User %s is not a moderator and is first to join — sending to lobby", actor_jid);
        room:set_affiliation(true, actor_jid, "none");
        return true;
    else
        module:log("debug", "User %s allowed to join the room", actor_jid);
    end
end)

module:hook("muc-set-affiliation", function(event)
    local room = event.room;
    local jid = event.jid;
    local affiliation = event.affiliation;

    if not room or not jid or affiliation ~= "owner" then
        return;
    end

    local username, host = jid_split(jid);
    
    if is_admin(jid, module.host) then
        module:log("info", "User %s is admin — skipping lobby creation", jid);
        return;
    end

    local session = prosody.full_sessions and prosody.full_sessions[jid];
    if not session then
        module:log("info", "No session found for %s — cannot check moderator status", jid);
        return;
    end

    if not is_moderator_from_jwt(session) then
        module:log("info", "Skipping lobby creation: %s is not a JWT moderator", jid);
        return;
    end

    if room._data.lobbyroom then
        module:log("info", "Lobby already exists for %s — not creating", room.jid);
        return;
    end

    module:log("info", "Creating lobby for %s because %s became owner and is moderator", room.jid, jid);
    prosody.events.fire_event("create-lobby-room", { room = room });
end)
