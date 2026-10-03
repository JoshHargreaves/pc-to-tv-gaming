# PC to TV Gaming

One-click **Windows PC → TV** switching for couch gaming.

Switches your display from the PC monitor to the TV, then launches:

- **Xbox mode** on Windows 11, or
- **Steam Big Picture**

Bind the launchers to a Stream Deck, keyboard macro, or controller button.

## Requirements

- Windows 10/11
- PowerShell 5.1+ (built into Windows)
- TV powered on and set to the PC HDMI input before switching
- **Xbox mode:** Windows 11 with Xbox mode enabled (Settings → Gaming → Xbox mode)
- **Steam Big Picture:** [Steam](https://store.steampowered.com/about/) installed

## Setup

1. Clone or download this repo.
2. Copy the example config:

   ```powershell
   Copy-Item display-switch.config.example.ps1 display-switch.config.ps1
   ```

3. List your displays and copy the short ids:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\List-Displays.ps1
   ```

   Example output line:

   ```text
   Config:   'ABC1234'
   ```

4. Edit `display-switch.config.ps1`:

   | Setting | Meaning |
   |---|---|
   | `MonitorMatch` | Short id of your PC monitor |
   | `MonitorWidth` / `MonitorHeight` | Native resolution (e.g. `3440` × `1440`) |
   | `TvMatch` | Short id of your TV |
   | `TvWidth` / `TvHeight` | Native resolution (e.g. `3840` × `2160`) |
   | `TvMode` | `'Xbox'` or `'BigPicture'` |
   | `ModeDelaySeconds` | Wait after the display switch before launching the couch UI |
   | `MonitorLabel` / `TvLabel` | Names used in the log only |

5. Run the `.bat` launchers (or bind them to a keyboard macro / Stream Deck):

   | Launcher | Action |
   |---|---|
   | `Switch-ToTV.bat` | TV only → launch Xbox mode or Steam Big Picture |
   | `Switch-ToMonitor.bat` | Exit couch UI → PC monitor only |

## Privacy

- `display-switch.config.ps1` is **gitignored** — keep your hardware ids there, not in the scripts.
- Runtime files (`.tv-mode`, `.xbox-mode`, `.display-target`, `display-switch.log`) are also ignored.
- Publish only the example config, not your local one.

## Notes

- Xbox mode uses the official **Win+F11** shortcut; the scripts confirm Windows switch prompts when they appear.
- Steam Big Picture is opened with `steam://open/bigpicture` and closed with `steam://close/bigpicture`.
- After Xbox mode, Windows sometimes mislabels displays. The switch logic prefers the path that supports your configured resolution, not only the EDID name.
- If the TV is not found, turn it on, select the PC input, wait a few seconds, then run the TV switch again.
