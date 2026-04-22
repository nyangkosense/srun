srun
====

srun reads a list of entries from stdin, displays them in an X11
window, and lets you filter by typing. Press enter to launch the
selected command. Designed to be piped into e.g:

    ls /usr/bin | srun

In order to build srun you need:
- Zig
- X11 (libx11-dev)
- Xft (libxft-dev)
- fontconfig (libfontconfig-dev)

Build
-----
    zig build

The binary is written to zig-out/bin/srun.

Options
-------
    -l lines    number of visible match lines (default: 20)
    -fn font    Xft font string (default: monospace:size=11)
    -p prompt   prompt string (default: "> ")
    -w width    window width in pixels (default: 600)
    -nb color   normal background (default: #1e1e2e)
    -nf color   normal foreground (default: #cdd6f4)
    -sb color   selected background (default: #45475a)
    -sf color   selected foreground (default: #f5e0dc)
    -bc color   border + prompt color (default: #89b4fa)

Key bindings
------------
    Up / Ctrl+P     move selection up
    Down / Ctrl+N   move selection down
    Home            select first match
    End             select last match
    Backspace       delete last character
    Ctrl+U          clear input
    Enter           launch selected command
    Escape          quit without launching


How it works
------------
The window is created with override_redirect at the top-center of the
screen. Keyboard is grabbed on spawn. Entries are read into a static
buffer (512 KB, max 4096 entries). Filtering is case-insensitive
substring match. Selected commands are run via /bin/sh -c.


License
-------
MIT
