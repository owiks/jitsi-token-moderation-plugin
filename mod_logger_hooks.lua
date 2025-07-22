local log = module._log
local cjson = require "cjson"

log("info", "[Logger-Hooks] Module loaded.")

-- --- CONFIGURATION ---
local HOOK_PRIORITY     = module:get_option_number("logger_hooks_priority", -100)
local LOG_RAW_EVENT     = module:get_option_boolean("logger_hooks_log_raw", false)
local LOG_FULL_OBJECT   = module:get_option_boolean("logger_hooks_log_full_object", false)

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
    "authentication-failure",}

-- --- METADATA EXTRACTION ---
local function extract_event_metadata(event)
    local meta = {
        timestamp     = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        event         = event.event or "unknown_event",
        origin_type   = event.origin and event.origin.type or nil,
        session_jid   = event.session and event.session.full_jid or nil,
        stanza_name   = event.stanza and event.stanza.name or nil,
        stanza_type   = event.stanza and event.stanza.attr and event.stanza.attr.type or nil,
        room_jid      = event.room and tostring(event.room.jid) or nil,
        occupant_jid  = event.occupant and tostring(event.occupant.nick) or nil,
        role          = event.occupant and event.occupant.role or nil,
        affiliation   = event.occupant and event.occupant.affiliation or nil,
        nick          = event.nick and tostring(event.nick) or nil,
        actor         = event.actor and tostring(event.actor.nick or event.actor) or nil,
        reason        = event.reason or nil,
    }

    if LOG_RAW_EVENT then
        meta.event_raw = tostring(event)
    end

    if LOG_FULL_OBJECT then
        meta.full = "[full event omitted]" -- в Kafka или UDP можно вставить сериализацию вручную
    end

    return meta
end

-- --- JSON ENCODER ---
local function encode_event_to_json(meta)
    local ok, json = pcall(cjson.encode, meta)
    if not ok then
        log("error", "[Logger-Hooks] Failed to encode event '%s': %s", tostring(meta.event), tostring(json))
        return nil
    end
    return json
end

-- --- HOOK HANDLER ---
local function log_hook_event(event)
    if type(event) ~= "table" then
        log("warn", "[Logger-Hooks] Event is not a table: %s", type(event))
        return
    end

    local meta = extract_event_metadata(event)
    local json = encode_event_to_json(meta)
    if not json then return end

    log("debug", "[Logger-Hooks] %s %s", meta.event, json)
end

-- --- HOOK REGISTRATION ---
log("info", "[Logger-Hooks] Attaching hooks with priority %d...", HOOK_PRIORITY)

for _, hook in ipairs(HOOKS_TO_LOG) do
    local function wrap_hook_handler(hook_name)
        return function(event)
            event.event = hook_name -- <-- вставляем имя хука прямо в событие
            log_hook_event(event)
        end
    end
    module:hook(hook, wrap_hook_handler(hook), HOOK_PRIORITY)
    module:hook_global(hook, wrap_hook_handler(hook), HOOK_PRIORITY)
end

log("info", "[Logger-Hooks] All diagnostic hooks attached.")
