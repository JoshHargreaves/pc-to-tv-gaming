# Copy this file to display-switch.config.ps1 and edit for your PC.
# display-switch.config.ps1 is gitignored so your hardware ids stay private.
#
# Find ids by running:  .\List-Displays.ps1
# Use a short unique piece of the DeviceId shown by List-Displays.ps1.

@{
    # Desktop / PC monitor
    MonitorMatch  = 'MONITOR_ID'
    MonitorWidth  = 3440
    MonitorHeight = 1440
    MonitorLabel  = 'PC Monitor'

    # TV / living-room display
    TvMatch       = 'TV_ID'
    TvWidth       = 3840
    TvHeight      = 2160
    TvLabel       = 'TV'

    # Couch UI after switching to the TV:
    #   'Xbox'        - Windows Xbox mode (Win+F11)
    #   'BigPicture'  - Steam Big Picture
    TvMode        = 'Xbox'

    # Seconds to wait after the display switch before launching the couch UI
    ModeDelaySeconds = 1
}
