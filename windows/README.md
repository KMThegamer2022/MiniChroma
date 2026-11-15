# MiniChroma for Windows (early build)

Windows version of MiniChroma. It will drive keyboards and mice through [OpenRGB](https://openrgb.org/), which must be running with its SDK server enabled.

Status: project skeleton only. Effects, the OpenRGB connection and the tray UI are not built yet.

## Setting up Claude Code agent lights (Windows)

The Claude agent effect lights your keyboard while Claude Code works: orange while thinking, purple while editing files, green when done, fast blue when it needs you, white when idle. It works by Claude Code calling a small script that sends the state to MiniChroma on your PC.

1. **Install OpenRGB** and turn on its SDK server (Settings → SDK Server).
2. **Download** `MiniChroma.exe` from the latest `windows-v*` release and put it in `C:\MiniChroma\`.
3. **Copy the script:** put `scripts\agent-status.ps1` in `C:\MiniChroma\scripts\`.
4. **Add the hooks:** open `%USERPROFILE%\.claude\settings.json` (create it if it doesn't exist). Copy the `"hooks"` section from `scripts\claude-hooks.json` into it. If the file already has settings, add the `"hooks"` entry next to them rather than replacing the file.
5. **Start a new Claude Code session.** Hooks load when a session starts.
6. **Run MiniChroma** and choose **Claude agent** from the effect list.

If the lights don't change, check that MiniChroma is running, that OpenRGB's SDK server is on, and that the paths in `settings.json` match where you put the files.
