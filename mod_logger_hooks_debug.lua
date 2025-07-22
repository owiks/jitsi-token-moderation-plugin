local log = module._log
local cjson = require "cjson"

log("info", "[Logger-Hooks] DEBUG ALL HOOKS enabled")

-- Безопасный json encoder
local function encode_json_safe(data)
    local ok, result = pcall(cjson.encode, data)
    if not ok then
        return string.format("{\"error\": \"%s\"}", tostring(result))
    end
    return result
end

-- Отладчик каждого хука
local function debug_hook(event)
    local hook_name = event and event.event or "unknown"

    local out = {
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        hook = hook_name,
        origin = event.origin and event.origin.type or nil,
        stanza = event.stanza and event.stanza.name or nil,
    }

    local json = encode_json_safe(out)
    log("debug", "[Logger-Hooks] Hook triggered: %s", json)
end

-- Логируем абсолютно все хуки
module:hook("*", function(event)
    event.event = event.event or "unknown"
    debug_hook(event)
end, -100)

-- Глобальные хуки тоже
module:hook_global("*", function(event)
    event.event = event.event or "unknown"
    debug_hook(event)
end, -100)
