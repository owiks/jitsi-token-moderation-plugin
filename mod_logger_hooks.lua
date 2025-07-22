local log = module._log
local cjson = require "cjson"

module:log("info", "[Logger-Hooks] Module loaded.")

local HOOK_PRIORITY = module:get_option_number("logger_hooks_priority", -100)
local LOG_RAW_EVENT = module:get_option_boolean("logger_hooks_log_raw", false)

local HOOKS_TO_LOG = {
    "user-registered",
    "user-authentication-success",
    "user-authentication-failure",
    "user-authenticated",
    "resource-bind",
    "session-created",
    "session-pre-bind",
    "session-bind",
    "session-started",
    "session-resumed",
    "session-closed",
    "muc-room-pre-create",
    "muc-room-created",
    "muc-room-destroyed",
    "muc-config-submitted",
    "muc-room-config-changed",
    "muc-occupant-pre-join",
    "muc-occupant-joined",
    "muc-occupant-role-changed",
    "muc-occupant-left",
    "muc-set-role",
    "muc-set-affiliation",
    "muc-privilege-request",
    "muc-broadcast-message",
    "muc-privmsg",
    "pre-presence/full",
    "pre-message/full",
    "pre-iq/full",
    "presence/full",
    "message/full",
    "iq/full",
    "jitsi-meet-token-accepted",
    "jitsi-meet-token-rejected",
    "jitsi-meet-token-check",
    "authentication-success",
    "authentication-failure",
}

local function log_info(fmt, ...)
    log("info", "[Logger-Hooks] " .. fmt, ...)
end

-- Рекурсивно очищаем таблицу от функций, userdata и прочего
local function sanitize_for_json(obj, depth)
    depth = depth or 0
    if depth > 10 then
        -- Ограничение по глубине, чтобы избежать бесконечной рекурсии
        return "<max_depth_reached>"
    end
    local t = type(obj)
    if t == "table" then
        local clean = {}
        for k, v in pairs(obj) do
            local kt = type(k)
            local vt = type(v)
            -- Ключ должен быть string или number, иначе пропускаем
            if (kt == "string" or kt == "number") then
                if vt == "table" then
                    clean[k] = sanitize_for_json(v, depth + 1)
                elseif vt == "string" or vt == "number" or vt == "boolean" or vt == "nil" then
                    clean[k] = v
                else
                    clean[k] = "<" .. vt .. ">"
                end
            end
        end
        return clean
    elseif t == "string" or t == "number" or t == "boolean" or t == "nil" then
        return obj
    else
        return "<" .. t .. ">"
    end
end

local function extract_event_metadata(hook_name, event)
    return {
        timestamp    = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        event        = hook_name,
        origin_type  = event.origin and event.origin.type or nil,
        origin_jid   = event.origin and event.origin.full_jid or nil,
        ip           = event.origin and event.origin.conn and event.origin.conn.ip or nil,
        is_admin     = event.origin and event.origin.jitsi_meet_context_user and event.origin.jitsi_meet_context_user.is_admin or nil,
        room_jid     = event.room and event.room.jid or nil,
        room_name    = event.room and event.room._data and event.room._data.name or nil,
        occupant_jid = event.occupant and tostring(event.occupant.nick) or nil,
        actor        = event.actor and tostring(event.actor) or nil,
        role         = event.occupant and event.occupant.role or nil,
        affiliation  = event.occupant and event.occupant.affiliation or nil,
        nick         = event.nick and tostring(event.nick) or nil,
        stanza_name  = event.stanza and event.stanza.name or nil,
        -- Не передаем сюда оригинальный event, передадим "очищенный" ниже
    }
end

local function encode_event_to_json(event_meta, raw_event)
    local clean_event = sanitize_for_json(raw_event)
    local combined = {}
    for k,v in pairs(event_meta) do combined[k] = v end
    combined.raw_event = clean_event
    local ok, encoded = pcall(cjson.encode, combined)
    if not ok then
        log("error", "[Logger-Hooks] Failed to encode event '%s': %s", tostring(event_meta.event), tostring(encoded))
        return nil
    end
    return encoded
end

local function make_hook_logger(hook_name)
    return function(event)
        if type(event) ~= "table" then
            log("warn", "[Logger-Hooks] Invalid event type for %s: %s", hook_name, type(event))
            return
        end

        -- Логируем строковое представление event для дебага
        log("debug", "[Logger-Hooks] %s event debug string: %s", hook_name, tostring(event))

        local metadata = extract_event_metadata(hook_name, event)
        local json_output = encode_event_to_json(metadata, event)
        if not json_output then return end
        log("debug", "[Logger-Hooks] %s %s", hook_name, json_output)
    end
end

log_info("Attaching hooks with priority %d...", HOOK_PRIORITY)

for _, hook in ipairs(HOOKS_TO_LOG) do
    local handler = make_hook_logger(hook)
    module:hook(hook, handler, HOOK_PRIORITY)
    module:hook_global(hook, handler, HOOK_PRIORITY)
end

log_info("All diagnostic hooks attached.")
