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

# The layout on a portrait tablet: machines as tabs on top (laptop, desktop, and builder which
# is off), the terminals of the machine on the left, the live terminal on the right.
Sleep 3s
# Ctrl+a then an arrow moves to the list; down + enter shows another terminal.
Ctrl+a
Left
Sleep 1s
Down
Sleep 1s
Enter
Sleep 2.5s
# + new terminal: type a name, it opens on this machine.
Ctrl+a
Type "+"
Sleep 1.5s
Type "mobile"
Sleep 1.5s
Enter
Sleep 2.5s
# Another machine: the next tab.
Ctrl+a
Type "n"
Sleep 3s
Ctrl+a
Type "n"
Sleep 2.5s
Ctrl+a
Type "n"
Sleep 2s
# Leave: everything keeps running.
Ctrl+a
Type "d"
Sleep 1.5s
Hide
Type "tmux -L demo kill-server"
Enter
