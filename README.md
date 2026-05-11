# MacTMUX

MacTMUX is a native macOS menu bar utility for tmux sessions.

V1 features:

- Shows the five newest tmux sessions in the menu bar.
- Opens a selected session in Terminal.app.
- Shows all sessions in a SwiftUI window.
- Displays recent pane output in memory only.
- Stops sessions with confirmation.
- Restarts the active pane conservatively when tmux can resolve the target.
- Provides settings for tmux path and refresh interval.

## Install

```sh
brew tap 0xtlt/tap
brew install mactmux
```

## Build

```sh
swift test
./Scripts/build-app.sh
open MacTMUX.app
```

## Safety

MacTMUX uses `Process` argument arrays for tmux commands. It does not call `kill-server`, does not persist logs, and redacts common secret patterns in displayed output.
