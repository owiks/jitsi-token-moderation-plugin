local log = module._log;
local host = module.host;
local st = require "util.stanza";
local jid_split = require 'util.jid'.split;
local jid_bare = require 'util.jid'.bare;

local util = module:require 'util';
local is_admin = util.is_admin;

local DEBUG = true;

local measure_success = module:measure('success', 'counter');
local measure_fail = module:measure('fail', 'counter');

local parentHostName = string.match(tostring(host), "^%w+%.(.+)$");
if not parentHostName then
    module:log("error", "Failed to extract parent hostname from %s", tostring(host));
    return;
end

local parentCtx = module:context(parentHostName);
if not parentCtx then
    module:log("error", "Failed to get parent context for host: %s", tostring(parentHostName));
    return;
end

local token_util = module:require "token/util".new(parentCtx);
if not token_util then
    module:log("error", "Token utility not initialized. Check mod_auth_token configuration.");
    return;
end

if not token_util.appId or token_util.appId == "" then
    module:log("error", "'app_id' must not be empty");
end
if not token_util.appSecret or token_util.appSecret == "" then
    module:log("error", "'app_secret' must not be empty");
end

module:log("info",
    "Token verification init: app_id=%s, allow_empty=%s, accepted_issuers=%s",
    tostring(token_util.appId), tostring(token_util.allowEmptyToken), tostring(token_util.acceptedIssuers));

local require_token_for_moderation;
local allowlist;
local function load_config()
    require_token_for_moderation = module:get_option_boolean("token_verification_require_token_for_moderation");
    allowlist = module:get_option_set('token_verification_allowlist', {});
end
load_config();

local function verify_user(session, stanza)
    local user_jid = stanza.attr.from;
    local bare = jid_bare(user_jid);
    local _, domain = jid_split(user_jid);

    if DEBUG then
        module:log("debug", "Verifying user: %s room: %s", tostring(user_jid), tostring(stanza.attr.to));
        module:log("debug", "JWT token: %s", tostring(session.auth_token));
    end

    if is_admin(user_jid) then
        if DEBUG then module:log("debug", "Admin user, skipping token check: %s", user_jid); end
        return true;
    end

    if allowlist:contains(domain) or allowlist:contains(bare) then
        if DEBUG then module:log("debug", "Allowlisted user: %s", user_jid); end
        return true;
    end

    if not token_util:verify_room(session, stanza.attr.to) then
        module:log("error", "Token verification failed: token=%s room=%s",
            tostring(session.auth_token), tostring(stanza.attr.to));
        session.send(
            st.error_reply(
                stanza, "cancel", "not-allowed", "Room and token mismatch"
            )
        );
        return false;
    end

    if DEBUG then module:log("debug", "Token verified for: %s", user_jid); end
    return true;
end

module:hook("muc-room-pre-create", function(event)
    local origin, stanza = event.origin, event.stanza;
    if not verify_user(origin, stanza) then
        measure_fail(1);
        return true;
    end
    measure_success(1);
end, 99);

module:hook("muc-occupant-pre-join", function(event)
    local origin, room, stanza = event.origin, event.room, event.stanza;
    if not verify_user(origin, stanza) then
        measure_fail(1);
        return true;
    end
    measure_success(1);
end, 99);

for event_name, method in pairs {
    ["iq-set/bare/http://jabber.org/protocol/muc#owner:query"] = "handle_owner_query_set_to_room",
    ["iq-set/host/http://jabber.org/protocol/muc#owner:query"] = "handle_owner_query_set_to_room"
} do
    module:hook(event_name, function(event)
        local session, stanza = event.origin, event.stanza;

        if not require_token_for_moderation or is_admin(stanza.attr.from) then
            return;
        end

        if not session.auth_token or not session.jitsi_meet_room then
            session.send(
                st.error_reply(
                    stanza, "cancel", "not-allowed", "Room modification disabled for guests"
                )
            );
            return true;
        end
    end, -1);
end

module:hook_global('config-reloaded', load_config);
