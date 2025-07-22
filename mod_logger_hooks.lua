local log = module._log
local cjson = require "cjson"

module:log("info", "[Logger-Hooks] Module loaded.")

-- --- CONFIGURATION ---
local HOOK_PRIORITY = module:get_option_number("logger_hooks_priority", -100)
local LOG_RAW_EVENT = module:get_option_boolean("logger_hooks_log_raw", false)

-- --- HOOKS TO LOG ---
local HOOKS_TO_LOG = {
    -- Сессии и аутентификация
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

    -- MUC: создание, удаление, конфиг
    "muc-room-pre-create",
    "muc-room-created",
    "muc-room-destroyed",
    "muc-config-submitted",
    "muc-room-config-changed",

    -- MUC: участники
    "muc-occupant-pre-join",
    "muc-occupant-joined",
    "muc-occupant-role-changed",
    "muc-occupant-left",

    -- MUC: модерация
    "muc-set-role",
    "muc-set-affiliation",
    "muc-privilege-request",

    -- MUC: сообщения
    "muc-broadcast-message",
    "muc-privmsg",

    -- STANZAS: приём перед обработкой
    "pre-presence/full",
    "pre-message/full",
    "pre-iq/full",

    -- STANZAS: после обработки
    "presence/full",
    "message/full",
    "iq/full",

    -- Отладочные/специфичные
    "jitsi-meet-token-accepted",
    "jitsi-meet-token-rejected",
    "jitsi-meet-token-check",
    "authentication-success",
    "authentication-failure",
}

-- --- LOG WRAPPER ---
local function log_info(fmt, ...)
    log("info", "[Logger-Hooks] " .. fmt, ...)
end

-- --- METADATA EXTRACTION ---
local function extract_event_metadata(event)
    return {
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        event = event.event or "unknown_event",
        origin_type = event.origin and event.origin.type or nil,
        stanza_type = event.stanza and event.stanza.name or nil,
        raw = LOG_RAW_EVENT and event or nil
    }
end

-- --- JSON ENCODER ---
local function encode_event_to_json(event_meta)
    local clean = {
        timestamp = event_meta.timestamp,
        event = event_meta.event,
        origin_type = event_meta.origin_type,
        stanza_type = event_meta.stanza_type,
    }
    if LOG_RAW_EVENT and event_meta.raw then
        clean.raw = "[raw event removed for safety]" -- не сериализуем
    end
    local ok, encoded = pcall(cjson.encode, clean)
    if not ok then
        log("error", "[Logger-Hooks] Failed to encode event '%s' to JSON: %s", tostring(event_meta.event), tostring(encoded))
        return nil
    end
    return encoded
end

-- --- MAIN LOGIC ---
local function log_hook_event(event)
    if type(event) ~= "table" then
        log("warn", "[Logger-Hooks] Invalid event type: %s", type(event))
        return
    end

    local metadata = extract_event_metadata(event)
    local json_output = encode_event_to_json(metadata)
    if not json_output then return end

    log("debug", "\n---[ HOOK: %s ]---\n%s\n---[ END HOOK: %s ]---",
        metadata.event, json_output, metadata.event)
end

log_info("Attaching hooks with priority %d...", HOOK_PRIORITY)

for _, hook in ipairs(HOOKS_TO_LOG) do
    module:hook(hook, log_hook_event, HOOK_PRIORITY)
    module:hook_global(hook, log_hook_event, HOOK_PRIORITY)
end

log_info("All diagnostic hooks attached.")
