<h1 align="center" valign="middle">
  <img height="40px" src="https://github.com/yorumicolors/.github/blob/main/res/seal_sots.gif?raw=true">
  <sup>yorumi for windows terminal - deep code, quiet sea</sup>
</h1>

<p align="center">
  A calming deep sea colorscheme for <strong>Windows Terminal</strong>, in seven flavours.
</p>

---

Yorumi keeps visual noise low with mellow, low-contrast chrome while text and syntax stay
sharp: body text measures 9.6-19.5:1 against its background, and the lowest-contrast palette
token is 5.6:1. Every value comes from the shared palette.

## Available Flavours

| flavour | mode | background | text |
|---|---|---|---|
| `ether` | dark | `#02040e` | `#ebedf1` |
| `abyss` | dark | `#060914` | `#bdbfcb` |
| `bifrost` | light | `#ebedf1` | `#191b25` |
| `kraken` | dark | `#0e0d17` | `#bfafdf` |
| `kabocha` | dark | `#150b03` | `#f5c5b0` |
| `cosmic` | dark | `#150718` | `#ffffff` |
| `ryujin` | dark | `#0b0b19` | `#afb9df` |

## Install

```powershell
irm https://raw.githubusercontent.com/yorumicolors/windows-terminal/main/install.ps1 | iex
```

It asks two questions: whether to set a yorumi scheme as the `profiles.defaults` colour scheme, and
whether to also theme the PowerShell prompt. `profiles.defaults` is the default a profile inherits;
a profile with its own `colorScheme` keeps it. A flavour is only needed when either answer is yes — a
plain install writes all seven schemes and asks for nothing.

To answer ahead of time, pass arguments through `scriptblock`:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/yorumicolors/windows-terminal/main/install.ps1))) -Flavour kraken -Activate
```

`-Activate` and `-NoActivate` answer the first question; `-InstallPowerShell` and
`-NoInstallPowerShell` answer the second.

Two marked blocks in `settings.json`: all seven schemes in `"schemes"`, and the chosen one as
`profiles.defaults.colorScheme` — the default for profiles without a choice of their own. Nothing
outside them is edited — a scheme of your own that merely starts with
"Yorumi" stays — the file is parsed back before writing, and `settings.json.yorumi-backup` keeps
the previous copy.

`-SettingsPath <file>` targets a specific `settings.json`, and naming one is also what lets the
script run off Windows (WSL, CI). `-NoActivate` installs the schemes without writing a scheme
choice; `-NonInteractive` asks nothing at all.

## Changing flavour

```powershell
irm https://raw.githubusercontent.com/yorumicolors/windows-terminal/main/install.ps1 | iex
```

Re-running the one-liner asks again; the `scriptblock` form above takes `-Flavour <name> -Activate`.

## Manual installation

Paste a `yorumi-<flavour>.json` object into the `"schemes"` array of `settings.json`
(<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>,</kbd> in Windows Terminal opens it), then pick the
scheme in **Settings → profile → Appearance → Colour scheme**.

## Notes

- Windows Terminal runs on Windows only; the installer says so and stops elsewhere.
- `settings.json` is JSONC. The installer never re-serialises it: schemes are inserted or
  replaced as text, so a file Windows Terminal would still open is a file you get back.
- On Windows PowerShell 5.1 the TLS 1.2 line is needed first:
  `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12`.

## For AI Agents

1. **Install**: `irm https://raw.githubusercontent.com/yorumicolors/windows-terminal/main/install.ps1 | iex`,
   or the `scriptblock` form with `-Flavour <name>`.
2. **Never rewrite `settings.json` wholesale.** Merge into `"schemes"`, keep the file textual,
   validate by parsing it back, and leave a `.yorumi-backup`.
3. **Verify**: `"schemes"` contains `Yorumi Ether` … `Yorumi Ryujin`; the file still parses as
   JSON once `//` comments and trailing commas are removed; `profiles.defaults.colorScheme`
   is the chosen scheme only if the user asked for activation.

---

## Accessibility

| layer | measured |
|---|---|
| body text on background | 9.57 – 19.53:1 |
| lowest palette token on its background | 5.56:1 |

No blanket AAA claim is made for the saturated hues — sRGB runs out before they get lighter.

## License

MIT © [Yorumi Colors](https://github.com/yorumicolors)
