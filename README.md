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
token is 5.6:1. Every value is generated from the shared palette — nothing is hand-tuned.

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

Or from a checkout: `./install.ps1 -Flavour abyss`.

The installer finds `settings.json` (Store, Preview, Canary and unpackaged locations), then:

1. **Merges the seven schemes** into the `"schemes"` array. It edits the file textually —
   your comments, trailing commas, key order and every other object survive byte for byte.
   A scheme it shipped before is replaced in place rather than duplicated, and the merged file
   is parsed back before anything is written. A backup lands next to it as
   `settings.json.yorumi-backup`.
2. **Offers to activate one**, by setting `"colorScheme"` in `profiles.defaults` — one key, all
   profiles. Declining leaves your current colours alone.
3. **Offers to theme PowerShell itself**, by running the
   [yorumi for PowerShell](https://github.com/yorumicolors/powershell) installer with the same
   flavour, so the prompt, syntax highlighting and directory colours match the window.

Nothing is applied without an answer: when there is nobody to ask (`-NonInteractive`, or input
piped from a file) the installer does only the file work and prints what is left to do.

| flag | effect |
|---|---|
| `-Flavour <name>` | which scheme to activate and hand to PowerShell. Default `ether` |
| `-SettingsPath <file>` | edit a specific `settings.json` instead of the discovered one |
| `-Activate` / `-NoActivate` | set `profiles.defaults.colorScheme` without asking / never |
| `-InstallPowerShell` / `-NoInstallPowerShell` | same, for the PowerShell theme |
| `-PowerShellInstaller <file>` | use a local `powershell/install.ps1` instead of downloading |
| `-NonInteractive` | ask nothing |

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
   or `./install.ps1 -Flavour <name>` in a checkout.
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
