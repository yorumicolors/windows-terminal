# Yorumi for windows-terminal

Seven flavours of the [yorumi](https://github.com/yorumicolors) palette for windows-terminal, generated from
`primitives.json` + `ansi-themes.json`.

| file | mode |
|---|---|
| yorumi-ether.json | dark |
| yorumi-abyss.json | dark |
| yorumi-bifrost.json | light |
| yorumi-kraken.json | dark |
| yorumi-kabocha.json | dark |
| yorumi-cosmic.json | dark |
| yorumi-ryujin.json | dark |

## Install

```sh
./install.sh
```

Activate:

```
paste the object into the "schemes" array of settings.json, then set "colorScheme"
```

## Palette

Every value is a token from the shared palette; nothing is hand-tuned per emulator.
The contract (background/surface/text/dim slots per mode, selection ink) is
enforced by `dev/generators/build-terminals.mjs` before any file is written — see `dev/theming/THEMING.md`.
