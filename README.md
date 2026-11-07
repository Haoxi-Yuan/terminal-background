# terminal_background

One command sets the background of every macOS Terminal window to a color or a picture. The text always stays readable.

```sh
terminal_background '#1E2030'               # a color (the # is optional, #FFF works too)
terminal_background ~/Pictures/photo.jpg    # a picture
terminal_background                         # asks; type a color or drag a picture in
terminal_background reset                   # back to the profile you used before
```

The change applies to every open window and tab, and to new windows.

## Readable text

The text must keep a contrast of at least 7:1 against the background. 7:1 is the highest (AAA) level of the WCAG accessibility guidelines.

- **Colors.** A color that is too light is darkened just enough to reach 7:1. The hue stays the same. The command prints the color it used. For example, `#FFD700` (gold) becomes `#584A00`, while `#1E2030` is dark enough already and is used as is.
- **Pictures.** A dark layer goes over the picture. Its strength is measured for each picture, so that 98% of the picture reaches 7:1 (at least 35%). A bright wallpaper typically gets about 65-70%.

If your Terminal profile uses dark text, the text is switched to light gray so that this works.

## How it works

Terminal's scripting interface cannot set background pictures, so the command writes a Terminal profile named "Custom Background" (a copy of the profile you used before, with the new background) and imports it. Terminal opens a window for each imported profile. The command closes that window after a moment, so you will see a window flash briefly. It then makes the profile the default and switches every tab to it.

Terminal stretches background pictures to the shape of the window. The command therefore crops the picture to the shape of your open windows (the median width/height), darkens it, and saves the result in `~/Library/Application Support/terminal_background`. Your original picture is not changed. Windows of a very different shape show the picture slightly stretched. Run the command again after resizing to crop for the new shape.

## Requirements

- macOS 13 or newer, using Apple's Terminal app (not iTerm2 or other terminals).
- Apple's Command Line Tools, for the Swift compiler. If they are missing, run `xcode-select --install`.

## Install

```sh
git clone https://github.com/Haoxi-Yuan/terminal-background.git
cd terminal-background
zsh install.sh
```

This builds the command on your Mac and puts it in `~/.local/bin`. If that folder is not on your PATH, the installer adds it to `~/.zshrc`. Open a new Terminal window afterwards.

## Uninstall

```sh
zsh uninstall.sh
```

This puts every window back on your previous profile and removes the command and its saved pictures.

## Troubleshooting

- **"Terminal did not import the profile"**: Terminal is probably showing an alert. Close it and run the command again.
- **An extra window stays open**: close it. It is the window Terminal opened for the import.
- **macOS asks whether Terminal may control Terminal**: allow it. The command uses AppleScript to apply the profile.

## License

MIT, see [LICENSE](LICENSE).
