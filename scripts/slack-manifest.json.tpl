{
  "display_information": {
    "name": "__AGENT_FULL_NAME__",
    "description": "Virtual Agentic Engineer",
    "background_color": "#1a1a2e"
  },
  "features": {
    "app_home": {
      "home_tab_enabled": false,
      "messages_tab_enabled": true,
      "messages_tab_read_only_enabled": false
    },
    "bot_user": {
      "display_name": "__AGENT_DISPLAY_NAME__",
      "always_online": true
    },
    "slash_commands": [
      {
        "command": "/openclaw",
        "description": "Send a message to OpenClaw",
        "should_escape": false
      }
    ],
    "assistant_view": {
      "assistant_description": "Virtual Agentic Engineer",
      "suggested_prompts": []
    }
  },
  "oauth_config": {
    "scopes": {
      "bot": [
        "app_mentions:read",
        "assistant:write",
        "bookmarks:read",
        "bookmarks:write",
        "channels:history",
        "channels:join",
        "channels:read",
        "chat:write",
        "chat:write.customize",
        "chat:write.public",
        "commands",
        "emoji:read",
        "files:read",
        "files:write",
        "groups:history",
        "groups:read",
        "im:history",
        "im:read",
        "im:write",
        "links:read",
        "mpim:history",
        "mpim:read",
        "pins:read",
        "pins:write",
        "reactions:read",
        "reactions:write",
        "search:read.public",
        "team:read",
        "usergroups:read",
        "users:read",
        "users:read.email",
        "users.profile:read"
      ]
    }
  },
  "settings": {
    "event_subscriptions": {
      "bot_events": [
        "assistant_thread_started",
        "app_mention",
        "channel_created",
        "channel_rename",
        "member_joined_channel",
        "member_left_channel",
        "message.channels",
        "message.groups",
        "message.im",
        "message.mpim",
        "pin_added",
        "pin_removed",
        "reaction_added",
        "reaction_removed"
      ]
    },
    "interactivity": {
      "is_enabled": true
    },
    "org_deploy_enabled": false,
    "socket_mode_enabled": true,
    "token_rotation_enabled": false
  }
}
