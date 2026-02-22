# Foreman

**Direct your Claude Code agents from your phone.**

Foreman is a mobile app (iOS & Android) that lets you manage multiple Claude Code agent sessions running on your machine — from anywhere, using a clean iMessage-style chat interface.

No cloud backend. No third-party relay. Your agents run on your machine, your data stays on your network.

## The Problem

Claude Code is powerful, but it's tied to your desk. If you want to kick off a refactor, review what an agent is working on, or redirect a task while you're away from your computer, you're out of luck — unless you're comfortable living in a terminal SSH session on a phone keyboard.

## What Foreman Does

- **Chat interface** — talk to your Claude Code agents the same way you'd send an iMessage. Clean bubbles, tool call cards, thinking indicators.
- **Multiple agents** — switch between agents scoped to different projects or repos, the way you switch conversations in a messaging app.
- **Push notifications** — get notified on your lock screen when an agent finishes a task or needs your input. No polling, no babysitting.
- **Async by default** — fire off a task, put your phone down, get pinged when it's done.
- **Secure** — all traffic flows over Tailscale (WireGuard). The relay daemon only binds to your local Tailscale interface. Nothing is exposed to the internet.

## How It Works

```
Mobile App (React Native)
  └── Tailscale (WireGuard, OS-level)
        └── WebSocket → Relay Daemon (Node.js, your machine)
                              ├── Claude session: "frontend"  (tmux + stream-json)
                              ├── Claude session: "backend"
                              └── Claude session: "infra"
```

A lightweight relay daemon runs on your machine and manages Claude Code processes. Each agent session lives in its own tmux window so it keeps working even if your connection drops. Claude's `--output-format stream-json` output is parsed into structured events and streamed to the app in real time.

Push notifications are handled by [ntfy.sh](https://ntfy.sh) — Claude Code hooks fire when an agent finishes or needs input, and a push lands on your phone.

## Stack

| Layer | Technology |
|---|---|
| Mobile app | React Native + Expo |
| Transport | Tailscale (WireGuard) |
| Relay daemon | Node.js + TypeScript |
| Agent communication | `claude --output-format stream-json` |
| Session persistence | tmux |
| Push notifications | ntfy.sh |
| State management | Zustand |

## Project Status

Early development. See [`plans/`](./plans) for the detailed implementation plan.
