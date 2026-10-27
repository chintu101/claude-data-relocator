# claude-data-relocator

Move Claude Desktop's data/cache folder off your `C:` drive (e.g. to `D:\Claude`)
without breaking the app — no reinstall, no settings loss.

## Why this exists

Claude Desktop has no setting or install-time option to choose where its data
lives, and a plain NTFS junction or symlink placed on `%APPDATA%\Claude`
**does not work**.

Claude Desktop ships as an MSIX-packaged ("Desktop Bridge") Windows app.
Windows transparently bind-redirects the app's view of `%APPDATA%\Claude` to
a real backing folder under:

```
%LOCALAPPDATA%\Packages\<PackageFamilyName>\LocalCache\Roaming\Claude
```

That redirection happens below the NTFS reparse-point layer, so a junction
or symlink placed directly on `%APPDATA%\Claude` gets silently shadowed and
has no effect — which is why attempts at this usually "don't work."

This script finds the **real** backing folder and junctions *that* instead,
so the redirection Windows already does for you ends up pointing at your
chosen drive. If Claude isn't installed as an MSIX package on your machine,
it falls back to junctioning `%APPDATA%\Claude` / `%LOCALAPPDATA%\Claude`
directly, which is correct for that case.

## Usage

```powershell
.\Move-ClaudeData.ps1
```

You'll be prompted for a destination folder (e.g. `D:\Claude`) and asked to
confirm before anything happens. To skip the prompts:

```powershell
.\Move-ClaudeData.ps1 -TargetRoot "D:\Claude" -Force
```

### Parameters

| Parameter         | Effect |
|-------------------|--------|
| `-TargetRoot`     | Destination folder. Prompted for interactively if omitted. |
| `-Force`          | Skip confirmation prompts (closing Claude, proceeding with the move). Never on its own permits overwriting an existing, non-empty destination — see `-AllowOverwrite`. |
| `-AllowOverwrite` | Required (in addition to confirming, or with `-Force`) if the destination folder already has content in it, since the copy step mirrors with `robocopy /MIR`, which deletes anything in the destination not present in the source. |
| `-DeleteBackup`   | Delete the `.bak-*` backup of the original folder immediately after a successful migration, instead of leaving it for you to remove by hand. |

## What it does

1. Locates Claude's real data folder (MSIX package backing store, or a plain
   `%APPDATA%\Claude` / `%LOCALAPPDATA%\Claude` install as a fallback).
2. Asks where you want the data instead.
3. Closes Claude if it's running (only the exact `Claude` process, and only
   after showing you the PIDs/paths and getting confirmation unless
   `-Force` is passed).
4. Mirrors the data to the destination with `robocopy /MIR`.
5. Renames the original folder to `<path>.bak-<timestamp>` — nothing is
   deleted.
6. Creates an NTFS junction at the original path pointing at the new
   location, and verifies it.

Safe to re-run: any folder already converted to a junction is skipped, so a
partial or interrupted run can simply be re-run to pick up where it left
off.

Requires Windows + PowerShell 5.1+. No admin rights needed — junctions,
unlike symlinks, don't require elevation or Developer Mode.

## Undoing a migration

```powershell
Remove-Item "<original path>"              # removes the junction only, not the data
Rename-Item "<original path>.bak-<timestamp>" "<original folder name>"
```

(`<original path>` is the MSIX backing folder path from the script's output,
not `%APPDATA%\Claude` itself.)

## Safety notes

- Nothing is deleted by default; originals become `.bak-*` folders for you
  to remove once you've confirmed Claude works correctly.
- `-Force` will stop processes named exactly `Claude` without asking, but it
  will never run `robocopy /MIR` over a non-empty destination folder unless
  you also pass `-AllowOverwrite`.
- If a run fails partway through (e.g. two of two mappings, one already
  junctioned), re-running is safe — completed mappings are detected and
  skipped.

## Disclaimer

This script moves application data by renaming folders and creating NTFS
junctions. Review the script before running it. Not affiliated with
Anthropic. Use at your own risk.

## License

MIT — see [LICENSE](LICENSE).
