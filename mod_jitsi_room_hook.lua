-- добавлено логирование везде где только может пригодиться
-- уровень: debug

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
    module:log("debug", "Checking session.auth_token: %s", tostring(token));
    if not token then
        module:log("debug", "No auth_token in session");
        return false;
    end

    local dot1 = token:find("%.");
    local dot2 = token:find("%.", dot1 and (dot1 + 1) or 0);
    module:log("debug", "Parsed token dots: dot1=%s, dot2=%s", tostring(dot1), tostring(dot2));
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
        module:log("debug", "Base64 body string: %s", body);
        return false;
    end

    local now = os_time();
    if (decoded.nbf and now < decoded.nbf) or (decoded.exp and now >= decoded.exp) then
        module:log("warn", "JWT in session is outside of valid timeframe: now=%d, nbf=%s, exp=%s",
            now, tostring(decoded.nbf), tostring(decoded.exp));
        return false;
    end

    local moderator = decoded.moderator == true
        or (decoded.context and decoded.context.user and decoded.context.user.moderator == true);

    module:log("debug", "Decoded JWT: %s", json.encode(decoded));
    module:log("debug", "Session JWT moderator claim = %s", tostring(moderator));
    return moderator;
end

local function parse_jwt(origin)
    local token = origin.auth_token;
    local jid = origin.full_jid or "<unknown>";

    module:log("debug", "JWT parsing started for: %s", jid);
    if not token then
        module:log("debug", "No auth_token found for %s", jid);
        origin.is_moderator = false;
        return;
    end

    module:log("debug", "JWT token for %s: %s", jid, token);

    local dot1 = token:find("%.");
    local dot2 = token:find("%.", dot1 and (dot1 + 1) or 0);
    module:log("debug", "JWT dots: dot1=%s, dot2=%s", tostring(dot1), tostring(dot2));
    if not dot1 or not dot2 then
        module:log("warn", "Invalid JWT format for %s", jid);
        origin.is_moderator = false;
        return;
    end

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
        module:log("warn", "JWT for %s not yet valid: nbf=%d, now=%d", jid, decoded.nbf, now);
        origin.is_moderator = false;
        return;
    end
    if decoded.exp and now >= decoded.exp then
        module:log("warn", "JWT for %s expired: exp=%d, now=%d", jid, decoded.exp, now);
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

    module:log("debug", "muc-occupant-pre-join: %s attempting to join room %s", actor_jid, room.jid);

    if is_admin(actor_jid, module.host) then
        module:log("debug", "%s is admin — skipping checks and allowing", actor_jid);
        return;
    end

    if origin.is_moderator == nil then
        module:log("debug", "JWT not yet parsed for %s — calling parse_jwt()", actor_jid);
        parse_jwt(origin);
    else
        module:log("debug", "origin.is_moderator already set for %s: %s", actor_jid, tostring(origin.is_moderator));
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
        module:log("info", "User %s is not moderator and first to join — redirecting to lobby", actor_jid);
        room:set_affiliation(true, actor_jid, "none");
        return true;
    else
        module:log("debug", "User %s allowed into the room", actor_jid);
    end
end)

module:hook("muc-set-affiliation", function(event)
    local room = event.room;
    local jid = event.jid;
    local affiliation = event.affiliation;

    module:log("debug", "muc-set-affiliation: jid=%s, affiliation=%s, room=%s", jid, affiliation, room and room.jid or "<nil>");

    if not room or not jid or affiliation ~= "owner" then
        module:log("debug", "Skipping — not owner affiliation or missing data");
        return;
    end

    local username, host = jid_split(jid);
    module:log("debug", "Parsed JID split: %s@%s", username or "?", host or "?");

    if is_admin(jid, module.host) then
        module:log("info", "%s is admin — skipping lobby creation", jid);
        return;
    end

    local session = prosody.full_sessions and prosody.full_sessions[jid];
    module:log("debug", "Found session: %s", tostring(session));

    if not session then
        module:log("info", "No session for %s — cannot evaluate JWT moderator", jid);
        return;
    end

    if not is_moderator_from_jwt(session) then
        module:log("info", "User %s is not JWT moderator — skipping lobby creation", jid);
        return;
    end

    if room._data.lobbyroom then
        module:log("info", "Lobby already exists for room %s — not creating again", room.jid);
        return;
    end

    module:log("info", "Creating lobby room for %s (moderator %s became owner)", room.jid, jid);
    prosody.events.fire_event("create-lobby-room", { room = room });
end)
