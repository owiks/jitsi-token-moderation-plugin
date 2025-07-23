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

local function clear_user_roles(room) if room and room._data then room._data.user_roles = nil; end end
local function get_nested_value(data, path)
    if type(data) ~= "table" or type(path) ~= "string" then return nil; end
    local current = data; for key in path:gmatch("([^%.]+)") do
        if type(current) ~= "table" or current[key] == nil then return nil; end
        current = current[key];
    end
    return current;
end
local function has_moderator(room)
    if not room or not room._data or type(room._data.user_roles) ~= "table" then return false; end
    for _, ri in pairs(room._data.user_roles) do if ri.is_moderator then return true; end end
    return false;
end
local function get_actor_jid(origin)
    return origin.full_jid or
        (origin.username and origin.host and origin.resource and jid.join(origin.username, origin.host, origin.resource)) or
        "<unknown>";
end
local function log_event(level, room, event_name, details)
    local room_name = jid.node(room.jid); module:log(level, "%s [room:%s] event:%s | %s", LOG_PREFIX, room_name,
        event_name, details or "-");
end

local function parse_jwt(origin)
    local actor_jid = get_actor_jid(origin);
    local token = origin.auth_token;
    if not token then
        origin.is_moderator = nil; return;
    end
    local dot1, dot2 = token:find("%.", 1, true), token:find("%.", (token:find("%.", 1, true) or 0) + 1, true);
    if not dot2 then
        origin.is_moderator = nil; return;
    end
    local body = token:sub(dot1 + 1, dot2 - 1);
    if #body > max_jwt_body_size then
        origin.is_moderator = nil; return;
    end
    local ok_b64, b64 = pcall(basexx.from_url64, body);
    if not ok_b64 or not b64 then
        origin.is_moderator = nil; return;
    end
    local ok_json, decoded = pcall(json.decode, b64);
    if not ok_json or type(decoded) ~= "table" then
        origin.is_moderator = nil; return;
    end
    local now = os_time();
    if (decoded.nbf and now < decoded.nbf) or (decoded.exp and now >= decoded.exp) then
        origin.is_moderator = nil; return;
    end

    local moderator_value = get_nested_value(decoded, jwt_moderator_claim_path);
    origin.is_moderator = (moderator_value == true or tostring(moderator_value):lower() == "true");

    log_event("debug", { jid = actor_jid }, "parse_jwt", "Moderator claim: " .. tostring(origin.is_moderator));
end

module:hook("muc-occupant-pre-join", function(event)
    local room, origin, occupant = event.room, event.origin, event.occupant;
    if not origin or origin.type ~= "c2s" or is_admin(origin.full_jid) then return; end

    if origin.is_moderator == nil then parse_jwt(origin); end

    local occupant_nick = occupant.nick;
    room._data.user_roles = room._data.user_roles or {};
    room._data.user_roles[occupant_nick] = { is_moderator = origin.is_moderator, full_jid = origin.full_jid };

    if origin.is_moderator then
        if room.create_lobby and not room._data.lobbyroom then
            room:create_lobby();
            log_event("info", room, "lobby_created", "Triggered by moderator " .. get_actor_jid(origin));
        end
        room:set_affiliation(true, origin.full_jid, "owner");
        log_event("info", room, "moderator_joined", get_actor_jid(origin));
        return;
    end
end, 10);

module:hook("muc-occupant-pre-join", function(event)
    local room, origin = event.room, event.origin;
    if not origin or origin.type ~= "c2s" or is_admin(origin.full_jid) or origin.is_moderator then
        return;
    end

    if room.create_lobby and not room._data.lobbyroom then
        room:create_lobby();
        log_event("info", room, "lobby_created", "Triggered by participant " .. get_actor_jid(origin));
    end

    log_event("info", room, "participant_to_lobby", get_actor_jid(origin));
    return true;
end, -10);

module:hook("muc-occupant-left", function(event)
    local room, occupant = event.room, event.occupant;
    local occupant_nick = occupant and occupant.nick;
    if not room or not occupant_nick or not room._data or not room._data.user_roles then return; end

    local role_info = room._data.user_roles[occupant_nick];
    if not role_info then return; end

    local was_moderator = role_info.is_moderator;
    room._data.user_roles[occupant_nick] = nil;
    log_event("debug", room, "user_left", string.format("%s (was_moderator: %s)", occupant_nick, tostring(was_moderator)));

    if next(room._data.user_roles) == nil then clear_user_roles(room); end
    if not was_moderator or has_moderator(room) then return; end

    log_event("info", room, "last_moderator_left", "Moving all to lobby");
    local moved_count = 0;
    for occ in room:each_occupant() do
        if not is_admin(occ.jid) then
            local ok, err = pcall(room.set_affiliation, room, true, occ.jid, "none");
            if ok then
                moved_count = moved_count + 1;
            else
                log_event("warn", room, "move_to_lobby_failed",
                    string.format("User: %s, Error: %s", occ.jid, tostring(err)));
            end
        end
    end
    if moved_count > 0 then log_event("info", room, "moved_to_lobby_summary", "Count: " .. moved_count); end
end);

module:hook("muc-room-destroyed", function(event)
    local room = event.room;
    if not room or not room._data then
        clear_user_roles(room); return;
    end

    local lobby_jid = room._data.lobbyroom;
    if not lobby_jid then
        clear_user_roles(room); return;
    end

    local lobby_room = util.get_room_from_jid(lobby_jid);
    if not lobby_room then
        clear_user_roles(room); return;
    end

    for occ in lobby_room:each_occupant() do
        if not is_admin(occ.jid) then
            log_event("warn", room, "destroy_cancelled", "User " .. occ.jid .. " in lobby");
            return true;
        end
    end

    log_event("info", room, "room_destroyed", "Lobby was empty");
    clear_user_roles(room);
end);
