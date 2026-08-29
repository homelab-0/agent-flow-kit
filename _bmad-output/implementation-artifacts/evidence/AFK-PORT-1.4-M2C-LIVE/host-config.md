# Declared host configuration

- `AGENT_ROUTER_URL=https://agent-router.homelab0.org`
- `AGENT_ROUTER_TOKEN`: obtained via 1Password service account; never echoed or persisted
- `AFK_ORCA_BIN=orca-ide`

The three declarations above were exported in the shell that ran every live verification command. `~/.op-agent-env` was sourced only to obtain the 1Password service-account environment needed for the token lookup.
