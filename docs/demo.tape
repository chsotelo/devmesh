# devmesh demo — regenerate with: make demo (needs vhs; builds dm-tui first)
Output docs/demo.gif
Require tmux
Set Shell bash
Set FontSize 14
Set Width 820
Set Height 1040
Set Padding 12
Set Theme { "background": "#0f0f0f", "foreground": "#e1e1e1", "black": "#141414", "brightBlack": "#505058", "red": "#e06c75", "green": "#78be8c", "yellow": "#e6b450", "blue": "#7aa2f7", "magenta": "#c678dd", "cyan": "#56b6c2", "white": "#e1e1e1", "brightWhite": "#ffffff", "cursor": "#e1e1e1", "selection": "#242424" }
Set TypingSpeed 60ms

Hide
Type "docs/demo/run.sh"
Enter
Sleep 4s
Show

# The panel on a portrait tablet: cards with a live thumbnail of every terminal and the
# state of the agent in it (waiting for you, working, idle).
Sleep 3s
Right
Sleep 1.5s
Down
Sleep 2s
# Enter opens the full screen detail of the selected terminal.
Left
Enter
Sleep 3s
Escape
Sleep 1s
# New terminal: pick the machine, then a project or type a name.
Type "n"
Sleep 1.5s
Enter
Sleep 2s
Type "mob"
Sleep 2s
Escape
Sleep 1s
Escape
Sleep 1s
# All the shortcuts.
Type "?"
Sleep 2.5s
Escape
Sleep 1s
Hide
Type "q"
Ctrl+C
Type "tmux -L demo kill-server"
Enter
