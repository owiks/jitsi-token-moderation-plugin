local json = require "cjson";
local util = module:require "util";
local jid = require "util.jid";
local is_admin = util.is_admin;
local os_time = os.time;

local ok_basexx, basexx = pcall(require, "basexx");
if not ok_basexx then
    module:log("error", "Required dependency 'basexx' not found. This module will not work.");
    return;
end

local max_jwt_body_size = 4096;
local jwt_moderator_claim_path = module:get_option_string("jwt_moderator_claim_path", "moderator");

local LOG_PREFIX = "[token_moderation]";

local function clear_user_roles(room)
    if room and room._data then
        room._data.user_roles = nil;
    end
end

local function has_moderator(room)
    if not room then
        module:log("debug", "%s has_moderator: room is nil", LOG_PREFIX);
        return false;
    end

    module:log("debug", "%s has_moderator: checking room %s", LOG_PREFIX, tostring(room.jid));

    if not room._data then
        module:log("debug", "%s has_moderator: room._data is nil", LOG_PREFIX);
        return false;
    end

    if type(room._data.user_roles) ~= "table" then
        module:log("debug", "%s has_moderator: user_roles is not a table", LOG_PREFIX);
        return false;
    end

    local found = false;
    for occupant_jid, role_info in pairs(room._data.user_roles) do
        module:log("debug", "%s has_moderator: %s → is_moderator = %s", LOG_PREFIX, occupant_jid,
            tostring(role_info.is_moderator));
        if role_info.is_moderator then
            found = true;
            break;
        end
    end

    module:log("debug", "%s has_moderator: result = %s", LOG_PREFIX, tostring(found));
    return found;
end

local function get_nested_value(data, path)
    if type(data) ~= "table" or type(path) ~= "string" then
        return nil;
    end
    local current = data;
    for key in path:gmatch("([^%.]+)") do
        if type(current) ~= "table" or current[key] == nil then
            return nil;
        end
        current = current[key];
    end
    return current;
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

local function handle_new_join(room, origin)
    local actor_jid = origin.full_jid
        or (origin.username and origin.host and origin.resource and jid.join(origin.username, origin.host, origin.resource))
        or "<unknown>";
    local room_name = room.jid:match("^(.-)@") or room.jid;

    if origin.is_moderator == nil then
        parse_jwt(origin);
    end

    room._data.user_roles = room._data.user_roles or {};
    room._data.user_roles[actor_jid] = { is_moderator = origin.is_moderator };

    if not room._data.lobbyroom then
        prosody.events.fire_event("create-lobby-room", { room = room });
        module:log("info", "%s [room:%s] Lobby created", LOG_PREFIX, room_name);
    end

    if origin.is_moderator then
        module:log("info", "%s [room:%s] User %s is moderator — assigning owner", LOG_PREFIX, room_name, actor_jid);
        room:set_affiliation(true, actor_jid, "owner");
        -- 4. Добавить явный лог
        module:log("info", "%s [room:%s] Moderator %s successfully joined the room.", LOG_PREFIX, room_name, actor_jid);
        return;
    end

    module:log("info", "%s [room:%s] User %s is not moderator — sending to lobby", LOG_PREFIX, room_name, actor_jid);
    return true;
end

module:hook("muc-occupant-pre-join", function(event)
    if is_admin(event.origin.full_jid) then return; end
    return handle_new_join(event.room, event.origin);
end);

module:hook("muc-occupant-left", function(event)
    local room = event.room;
    local full_jid = event.jid;
    local room_name = room.jid:match("^(.-)@") or room.jid;

    if not room or not full_jid or not room._data or not room._data.user_roles then
        return;
    end

    local role_info = room._data.user_roles[full_jid];
    if not role_info then
        return;
    end

    local was_moderator = role_info.is_moderator;
    room._data.user_roles[full_jid] = nil;

    module:log("debug", "%s [room:%s] User %s left (was_moderator = %s)", LOG_PREFIX, room_name, full_jid,
        tostring(was_moderator));

    if next(room._data.user_roles) == nil then
        clear_user_roles(room);
    end

    if not was_moderator or has_moderator(room) then
        return;
    end

    module:log("info", "%s [room:%s] Last moderator left. Moving participants to lobby.", LOG_PREFIX, room_name);
    local moved_count = 0;
    for occupant in room:each_occupant() do
        if not is_admin(occupant.jid) then
            local ok, err = pcall(room.set_affiliation, room, true, occupant.jid, "none");
            if ok then
                moved_count = moved_count + 1;
            else
                module:log("warn", "%s [room:%s] Failed to move %s to lobby: %s", LOG_PREFIX, room_name, occupant.jid,
                    tostring(err));
            end
        end
    end

    if moved_count > 0 then
        module:log("info", "%s [room:%s] Moved %d participant(s) to the lobby.", LOG_PREFIX, room_name, moved_count);
    end
end);

module:hook("muc-room-destroyed", function(event)
    local room = event.room;
    if not room or not room._data then
        clear_user_roles(room);
        return;
    end
    local room_name = room.jid:match("^(.-)@") or room.jid;

    local lobby_jid = room._data.lobbyroom;
    if not lobby_jid then
        module:log("debug", "%s [room:%s] Has no lobby, allowing destroy.", LOG_PREFIX, room_name);
        clear_user_roles(room);
        return;
    end

    local lobby_room = util.get_room_from_jid(lobby_jid);
    if not lobby_room then
        module:log("debug", "%s [room:%s] Lobby room not found, allowing destroy.", LOG_PREFIX, room_name);
        clear_user_roles(room);
        return;
    end

    for occupant in lobby_room:each_occupant() do
        if not is_admin(occupant.jid) then
            module:log("warn", "%s [room:%s] Destruction cancelled: user %s is in the lobby.", LOG_PREFIX, room_name,
                occupant.jid);
            return true;
        end
    end

    module:log("info", "%s [room:%s] Lobby is empty, proceeding with destroy.", LOG_PREFIX, room_name);
    clear_user_roles(room);
end);
