#!/usr/bin/env python3
"""Render the Slack app manifest for your install.

Paste the output into https://api.slack.com/apps -> Create New App -> From a manifest.

  ./render-manifest.py                                   # socket mode (default), "Agent Relay"
  ./render-manifest.py --name "Acme Agents"              # your own app and bot name
  ./render-manifest.py --mode http --url https://slack.example.com/slack/events
"""
import argparse
import json
import pathlib
import sys

p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
p.add_argument("--name", default="Agent Relay", help="app name shown in Slack (max 35 chars)")
p.add_argument("--bot-name", help="bot display name (default: --name)")
p.add_argument("--mode", choices=["socket", "http"], default="socket")
p.add_argument("--url", help="http mode: https://<host>/slack/events")
a = p.parse_args()

if len(a.name) > 35:
    sys.exit("--name must be 35 characters or fewer")
m = json.loads((pathlib.Path(__file__).parent / "slack-app-manifest.json").read_text())
m["display_information"]["name"] = a.name
m["display_information"]["long_description"] = m["display_information"]["long_description"].replace("Agent Relay connects", f"{a.name} connects", 1)
m["features"]["bot_user"]["display_name"] = (a.bot_name or a.name)[:80]
if a.mode == "http":
    if not a.url or not a.url.startswith("https://") or not a.url.endswith("/slack/events"):
        sys.exit("--mode http needs --url https://<host>/slack/events")
    m["settings"]["socket_mode_enabled"] = False
    m["settings"]["event_subscriptions"] = {"request_url": a.url, **m["settings"]["event_subscriptions"]}
json.dump(m, sys.stdout, indent=2)
print()
