[English](/README.md) | [Русский](/README.ru_RU.md)

# AdobeAudition-RU

[![Adobe Audition 2026+](https://img.shields.io/badge/Adobe%20Audition-2026%2B-9999FF.svg)](#requirements)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE.svg)](#requirements)

**AdobeAudition-RU** adds a Russian user interface to an installed Adobe Audition 2026 or later. It is a real `ru_RU` language, not Russian text placed in the Spanish or another language slot. A single PowerShell script installs it, switches the language and fully restores the original state.

## Quick start

Open PowerShell and run:

```powershell
irm https://github.com/coinman-dev/AdobeAudition-RU/releases/latest/download/Install-AuditionRU.ps1 | iex
```

Or download [`Install-AuditionRU.ps1`](https://github.com/coinman-dev/AdobeAudition-RU/releases/latest/download/Install-AuditionRU.ps1) from the latest release and choose *Run with PowerShell*. The script asks for administrator rights and opens a menu:

```text
  Adobe Audition 2026 26.5.0.82
  Interface language: English (en_US)
  Russian language:   not installed
  DLL patch:          not applied (original DLL)

   * 1. Install / update Russian
     2. Switch the interface language
     3. Remove the Russian language (restore original)
      0. Exit
```

Close Adobe Audition before installing or switching the language.

Installation puts the Russian language menu into the Audition folder: `AdobeAudition-RU\AdobeAudition-RU.cmd` (usually `C:\Program Files\Adobe\Adobe Audition 2026\AdobeAudition-RU\AdobeAudition-RU.cmd`). Double-click it to switch the language, update the translation or remove the Russian language. There is no need to download the script again.

If your antivirus blocks `powershell.exe`, see [Antivirus](#antivirus).

## How it works

Audition has no `.langpack` file and no language menu. Three things decide the language:

| What | Where | What the script does |
|---|---|---|
| Interface strings (~15,000) | `dict\ru_RU\zdictionary_AUDT_ru_RU.dat` | builds it for the installed version |
| Shared Adobe module strings (~7,700) | `dict\ru_RU\dva_ru_RU.dict` | builds it for the installed version |
| F1 help | `HelpCfg\ru_RU\Audition_*.helpcfg` | creates it from this version's English file |
| Selected language | `AMT\application.xml` → `installedLanguages` | changes the value |
| Allowed interface languages | `AuApplication.dll` | changes 2 bytes (see below) |

**Why the DLL is touched.** `app::SetLocalePref` in `AuApplication.dll` checks the language against a built-in list: de, en, es, fr, it, ja, ko, pt_BR, zh_CN. Any other language, including `ru_RU`, is silently replaced with `en_US`. The script finds this check through the function export and a characteristic byte sequence (`jne` + `lea rdx, "en_US"`), not a fixed address. It then replaces the `lea` with a short `jmp`, so the selected language is kept. On any version where the sequence is found exactly once, exactly 2 bytes change. If it is not found, the script changes nothing and says so.

**Any 2026+ version.** Dictionaries are built from the keys of the installed version's English dictionary. Strings the translation does not have (new features) stay in English, so raw `$$$/...` keys never appear. The script reports how much of the interface is translated.

## What changes and how to undo it

Nothing is deleted. Previous files and settings are kept in `<Audition folder>\AdobeAudition-RU\`:

- `backup\AuApplication.dll` — the original DLL;
- `backup\dict\...`, `backup\HelpCfg\...` — files that were in place of the Russian ones (for example from an installer with a Russian substitute);
- `state.json` — the original language, the installed files and their SHA256;
- `AdobeAudition-RU.cmd` and `Install-AuditionRU.ps1` — the Russian language menu: a copy of the script that did the installation. The copy configures the Audition in whose folder it is.

**Remove the Russian language** (`-Action Restore`) puts back the original DLL, the previous language and the previous files, then deletes the `AdobeAudition-RU` folder together with the menu. Files changed after installation are left alone.

After an Audition update the new `AuApplication.dll` is unpatched. The menu shows this on the *DLL patch* line; run the installation again.

## Download and verification

Files come from [GitHub Releases](https://github.com/coinman-dev/AdobeAudition-RU/releases). Each release has its own tag and a `manifest.json` with the size and SHA256 of every file and of the package.

1. The script downloads `manifest.json` of the latest release (or the one given with `-Release`).
2. If `%TEMP%\AdobeAudition-RU\<version>` already holds verified files of that version, it installs right away without downloading.
3. Otherwise it downloads the package with `curl` into a `.part` file and checks the size and SHA256 of the package and of every file inside.
4. If GitHub is unreachable, the newest verified cache is used.

When the script sits in a repository clone (with `manifest.json` and `ru_RU` next to it), it uses the clone's files, also verified by SHA256.

## Antivirus

The script does things that antivirus behaviour heuristics watch for: it downloads files from the internet, changes files in Program Files (including 2 bytes of a DLL) and restarts PowerShell with administrator rights. An antivirus may therefore take it for malware.

Before 0.1.2-beta the script restarted itself with `powershell.exe -EncodedCommand …`, and Avast blocked that as the threat `IDP.HELU.PSE91` (*detected in the command line*). The restart is now a plain `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script path> <parameters>` command, which did not trigger Avast in testing.

If your antivirus still blocks it:

- Open PowerShell as administrator (Win+X → *Terminal (Admin)* or *Windows PowerShell (Admin)*) and run the [quick start](#quick-start) command there. The script then does not need to restart.
- Do not turn off the antivirus and do not add `powershell.exe` to its exclusions.
- Report the false positive to the antivirus vendor and in [Issues](https://github.com/coinman-dev/AdobeAudition-RU/issues).

The script's code is open, the translation files are verified by SHA256, and *Remove the Russian language* reverts everything the script changed.

## Parameters

| Parameter | Purpose |
|---|---|
| `-Action Menu` | menu (default) |
| `-Action Install` | install or update Russian |
| `-Action Switch -Language en_US` | switch the language: `ru_RU`, `en_US` or another installed one |
| `-Action Restore` | remove the Russian language and restore everything |
| `-Action Status` | show the state (no administrator rights needed) |
| `-AuditionPath <folder>` | Audition folder, when there are several or the path is non-standard (the copy in an Audition folder uses that one) |
| `-Release v1.0.0` | a specific release instead of the latest |
| `-Source <folder>` | take files from a local folder with `manifest.json` |
| `-LearnPanel` | also install the Learn panel translation (enables `PlayerDebugMode`, see below) |
| `-Yes` | no questions |
| `-UILang ru\|en` | script message language (default: Windows language) |
| `-NoPause` | do not wait for a key before exiting |

Examples:

```powershell
.\Install-AuditionRU.ps1 -Action Install -Yes
.\Install-AuditionRU.ps1 -Action Switch -Language en_US
.\Install-AuditionRU.ps1 -Action Restore
```

`AdobeAudition-RU.cmd` in the Audition folder takes the same parameters.

## Learn panel

The *Audition Learn* panel is a separate signed Adobe CEP extension. Tested on Audition 26.5: once translation files are added to it, CEP refuses to load it with an *invalid signature* error. That is why the panel translation is installed only on request (`-LearnPanel` or the question during installation). Together with it the script sets `HKCU\Software\Adobe\CSXS.<N>\PlayerDebugMode = 1`, and the panel then opens in Russian. In this mode CEP loads modified and unsigned panels of all Adobe applications for this user. Removing the Russian language restores the previous value.

## Translation

- About 5,000 new Audition 2026 strings were translated from scratch. Format, standard, brand, error-code, key and MIDI controller names stay in Latin script.
- The 2023 community translation was fully reviewed, and about 3,750 strings were corrected. Strings from Adobe's official translation (`dva_ru_RU`) were kept.
- Menu, panel and command names are consistent across the interface, including the keyboard shortcut editor.

Translation errors and unsupported versions: [Issues](https://github.com/coinman-dev/AdobeAudition-RU/issues).

## Requirements

- Adobe Audition 2026 (26.0) or later, Windows x64.
- Windows PowerShell 5.1 or PowerShell 7.
- Administrator rights: the Audition folder is in Program Files.

## Development

```powershell
.\tests\Test-AuditionRU.ps1              # checks; the full cycle runs on a copy of Audition in a temp folder
.\tools\New-Release.ps1 -Version 1.0.0   # manifest.json + out\release\v1.0.0\
gh release create v1.0.0 "out\release\v1.0.0\*" --title v1.0.0 --notes-file CHANGELOG.md
```

Dictionary files are stored in Git as binary (`.gitattributes`) so their SHA256 matches `manifest.json`.

`Install-AuditionRU.ps1` in the repository is UTF-8 with a BOM. `New-Release.ps1` puts an ASCII-only copy of it into the release: Russian text in strings is written as character codes, and Russian comments are left out. Otherwise `irm | iex` fails: Windows PowerShell 5.1 reads files from GitHub Releases as Latin-1, and neither 5.1 nor 7 skips the BOM.

---
Adobe and Adobe Audition are trademarks of Adobe. This project is not affiliated with Adobe.
