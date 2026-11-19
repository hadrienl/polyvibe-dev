# 0046 — Vibe Manager becomes Polyvibe

- Status: proposed
- Date: 2026-11-19

## Why

"Vibe Manager" says what the application does, but it cannot be found: it is two common words,
and a search for it returns managers of every kind. "Vibe ADE", the first idea, was taken by a
product in the same niche. Polyvibe was chosen out of three names, after a poll of developer
personas and a comparison of icons: it is one word, nothing of the same name exists among
developer tools, and `polyvibe.dev` was free. The icon, "Ondes croisées", draws three agents as
three sources whose waves meet, in the session colors (coral, violet, green).

## What changes

Everything the user reads: the application's name (`PRODUCT_NAME`, `CFBundleDisplayName`, the
bundle's folder and executable), every string of the 17 languages, the privacy prompts, the
companion's names (`Polyvibe Companion` on the Mac and on the iPhone), the icon
(`Design/AppIcon.svg`, `AppIcon-small.svg` for 16 and 32 points, `AppIcon-iOS.svg` without
transparency), the site at `https://polyvibe.dev/`, the documentation and the release titles. The
former name is not mentioned on the site: few people know it.

## What is kept, and why

A rename must not cost a user their data, their permissions or their updates.

| Kept | Why |
| --- | --- |
| Bundle identifiers `eu.hadrien.VibeManager…`, app group, iCloud container | macOS keys privacy grants, preferences and the data folder to them; Sparkle refuses an update of another identifier |
| Designated requirement | Same reason: the TCC grants follow it |
| `hadrienl.github.io/vibe-manager/appcast.xml` served | Every copy built before the rename reads it; GitHub Pages redirects it to the custom domain. New builds read `https://polyvibe.dev/appcast.xml` |
| `~/Library/Logs/Vibe Manager` | Where the diagnostics of every copy already are, and what the troubleshooting pages tell users to send |
| Keychain item labels, `TERM_PROGRAM=VibeManager`, the `VIBE_*` variables, the MCP servers' names | Identifiers that items, agents and scripts already rely on |
| `VibeManager-<version>.*` release assets | `Scripts/publish-appcast.sh` reads every release, older ones included |
| Module and target names (`VibeManagerKit`…), the repository's name | Not read by users; renaming them only rewrites history |
| The `Vibe Manager Companion Developer ID` provisioning profile | Its name in the developer portal |

## Copies installed before the rename

Sparkle installs an update where the application already is, under its folder's name: an existing
copy stays `/Applications/Vibe Manager.app`, its executable and its menus becoming Polyvibe. So:

- the path redaction of diagnostics keeps `/Applications/Vibe Manager.app` beside
  `/Applications/Polyvibe.app`;
- the crash reports collected start with `Polyvibe` or `Vibe Manager`, the latter for a crash of
  the days before the update;
- the release removes the notification sound it had copied as `Vibe Manager – <sound>` in
  `~/Library/Sounds`; a test build does not, since the user may still run another copy.

A new download is `Polyvibe.app`.

## Order of the switch

1. Register `polyvibe.dev`.
2. In the repository, Settings › Pages › Custom domain: `polyvibe.dev`, then enforce HTTPS; the
   DNS records GitHub asks for (A/AAAA on the apex). From then on the former address redirects.
3. Merge this change: the site is rebuilt with its canonical addresses on the new domain.
4. Release: the first Polyvibe build reaches every user through the existing feed.
5. Do not rename the repository yet. GitHub redirects its pages, clones and API calls after a
   rename, but not `hadrienl.github.io/vibe-manager/`: the copies older than Polyvibe would stop
   finding their updates. Rename it once those copies have updated, months later, or never.
