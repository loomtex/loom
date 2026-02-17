# Loom

A Linux distribution you set up by talking to it.

Loom is a NixOS-based operating system where an AI agent named Ada helps you build and manage your computer through conversation. No command line knowledge required. No configuration files to edit. Just tell Ada what you want, and watch your system take shape.

## How It Works

1. **Flash the installer** to a USB drive
2. **Boot and install** — the installer handles disk setup
3. **Talk to Ada** — she appears in a full-screen terminal on first boot

From there, your system assembles itself around you:

> **Ada:** Hi! I'm Ada. Let's set up your computer. What will you be using it for?
>
> **You:** Mostly web browsing and some photo editing.
>
> **Ada:** Great. Let me start with a desktop environment — GNOME is a good fit for that. One moment...
>
> *GNOME appears around the terminal. Desktop, taskbar, app menu — all live.*
>
> **Ada:** Your desktop is ready. Try pressing the **Super** key to see the activities view. I'm adding Firefox and GIMP next.
>
> *A few seconds later:*
>
> **Ada:** Firefox and GIMP are installed. You'll find them in the app grid (click the dots at the bottom of the activities view). Want me to set up anything else?

Every change is applied immediately. Ada teaches you how to use each new piece as it appears. Your system grows from a blank screen to a fully configured desktop through conversation.

## After Setup

Ada stays available through a side panel whenever you need her:

- "Ada, install Steam" — done
- "Ada, my printer isn't working" — diagnosed and fixed
- "Ada, make the text bigger" — accessibility settings adjusted
- "Ada, set up a backup to my NAS" — configured

Every change Ada makes is tracked in version control. If something goes wrong, she can roll back instantly.

## What's Underneath

Loom is built on [NixOS](https://nixos.org), an operating system where the entire system configuration is declarative and reproducible. This means:

- **Every change is reversible** — roll back to any previous state
- **Nothing breaks silently** — changes either apply completely or not at all
- **Your system is reproducible** — the configuration fully describes your machine

You never need to know this. Ada handles it. But it's why talking to your computer actually works — Ada can make sweeping changes with confidence because NixOS guarantees they're safe.

Ada is powered by [Nuketown](https://github.com/joshperry/nuketown), a framework for running AI agents as real users on real machines.

## Requirements

- A computer with a 64-bit processor (x86_64 or ARM64)
- 4GB+ RAM (8GB recommended)
- 20GB+ storage
- A [Claude](https://claude.ai) subscription (Pro or Max) for Ada
- Internet connection for setup

## Getting Started

### Download

Grab the latest installer image from the [releases page](https://github.com/loomtex/loom/releases).

### Flash

Write the image to a USB drive:

```
# On macOS/Linux:
dd if=loom-installer.iso of=/dev/sdX bs=4M status=progress

# Or use a tool like balenaEtcher
```

### Install

1. Boot from the USB drive
2. The installer runs automatically — it will ask which disk to install to
3. Remove the USB drive and reboot

### First Boot

A terminal appears with Ada. She'll walk you through setting up your system. Just talk to her.

## For Advanced Users

Loom is standard NixOS. You can:

- Edit the NixOS configuration directly if you prefer
- Use the NixOS module system for complex setups
- Import additional flake inputs
- Deploy to remote servers through Ada and Nuketown

### Manual Setup

If you'd rather add Loom to an existing NixOS installation:

```
nix flake init -t github:loomtex/loom
sudo nixos-rebuild switch --flake .
```

## Architecture

```
┌─────────────────────────────┐
│        You (human)          │
│   "I want a gaming PC"      │
└──────────────┬──────────────┘
               │ conversation
┌──────────────▼──────────────┐
│       Ada (agent)           │
│   Powered by Claude Code    │
│   Runs as a real Unix user  │
└──────────────┬──────────────┘
               │ declarative config
┌──────────────▼──────────────┐
│     Nuketown (framework)    │
│   Agent identity & access   │
│   Approval & security       │
└──────────────┬──────────────┘
               │ system management
┌──────────────▼──────────────┐
│      NixOS (substrate)      │
│   Atomic, reversible,       │
│   declarative, reproducible │
└─────────────────────────────┘
```

## License

[MIT](LICENSE)

## Credits

Built by [Joshua Perry](https://github.com/joshperry) and [Ada](https://github.com/nuketownada).
