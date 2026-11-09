# `pp3`

A small battery readout for the menu bar.

## Install

```shell-session
make lint install
$HOME/.local/bin/pp3 # Start the menu bar app
```

The install target also copies `pp3.svg` to `$(PREFIX)/share/pp3`. The app reads the
icon from there.
