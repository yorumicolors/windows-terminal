<h1 align="center" valign="middle">
  <img height="40px" src="https://github.com/yorumicolors/.github/blob/main/res/seal_sots.gif?raw=true">
  <sup>yorumi for windows terminal - deep code, quiet sea</sup>
</h1>

<p align="center">
  A calming deep sea colorscheme for developers, crafted for <strong>Windows Terminal</strong>.
</p>

---

Yorumi keeps visual noise low with mellow, low-contrast UI component backgrounds while text and syntax stay sharp: body text measures 9.6-19.5:1 against its background (WCAG AAA), and the lowest-contrast syntax token is 5.6:1 (WCAG AA).

## Theme Showcase

> [!WARNING]  
> Yorumi Mist and Shade are replaced by `bifrost` and `ryujin` which offer similar color palette. \
> Other themes such as `cosmic`, `kabocha` and `ether` are not showcased yet. \
> The showcase images are currently outdated and will be replaced with new images.

<table>
  <tr>
    <td align="center" width="50%"><a href="images/yorumi-abyss.png"><img src="images/yorumi-abyss.png" width="420" alt="yorumi abyss"></a><br><code>Yorumi Abyss</code></td>
    <td align="center" width="50%"><a href="images/yorumi-kraken.png"><img src="images/yorumi-kraken.png" width="420" alt="yorumi kraken"></a><br><code>Yorumi Kraken</code></td>
  </tr>
  <tr>
    <td align="center" width="50%"><a href="images/yorumi-mist.png"><img src="images/yorumi-mist.png" width="420" alt="yorumi mist"></a><br><code>Yorumi Mist</code></td>
    <td align="center" width="50%"><a href="images/yorumi-shade.png"><img src="images/yorumi-shade.png" width="420" alt="yorumi shade"></a><br><code>Yorumi Shade</code></td>
  </tr>
</table>

## Manual Installation

Open Windows Terminal &rarr; **Settings** (`Ctrl + ,`) &rarr; **Open JSON file** (bottom left), then pick one:

> [!WARNING]  
> This section does not cover adding yorumi-<flavour>-theme.json, since it isn't supported for now

| Option       | Instructions                                                                                  |
| ------------ | --------------------------------------------------------------------------------------------- |
| One flavour  | Copy the contents of `yorumi-<flavour>.json` and paste them into the `"schemes"` array.       |
| All flavours | Copy the entries from the `"schemes"` array in `yorumi.json` into your own `"schemes"` array. |

Separate entries with commas. Save, then choose it under **Settings &rarr; Profiles &rarr; Defaults &rarr; Appearance &rarr; Color scheme**.

## Accessibility
Body text measures 9.6-19.5:1 against the background (WCAG 2.1 AAA); every palette token clears 5.6:1 (AA). No blanket AAA claim is made for syntax colours - sRGB runs out before the saturated hues get lighter.
