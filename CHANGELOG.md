# Changelog

## 0.1.1-beta — 2026-09-23

- Fixed: `irm … | iex` failed in Windows PowerShell 5.1 with *Unexpected token* and *Unexpected attribute 'CmdletBinding'*. PowerShell reads a file downloaded from GitHub Releases as Latin-1 (5.1) or UTF-8 (7.4) and does not skip the UTF-8 BOM, so the script header was no longer a comment. The release now ships a plain ASCII copy of `Install-AuditionRU.ps1`: text in other alphabets is written as character codes. The copy works with `irm | iex` and as a downloaded file in Windows PowerShell 5.1 and PowerShell 7.
- `tools\New-Release.ps1` builds this copy and checks that its code and strings match the source. The tests run the copy the way `irm | iex` does and check the Russian messages.
- The translation is unchanged.

## 0.1.0-beta — 2026-09-23

First public beta. Translation made for Adobe Audition 26.5.0.82, works with 2026 (26.0) and later. Install, language switch and full restore were verified on a real Audition 26.5 installation; 1.0.0 follows after a clean-install check.

- `Install-AuditionRU.ps1`: install, switch the interface language, restore, status; RU/EN messages; self-elevation; works via `irm | iex`.
- Real `ru_RU` language: dictionaries `dict\ru_RU`, help `HelpCfg\ru_RU`, `installedLanguages` in `AMT\application.xml`.
- `AuApplication.dll`: 2-byte patch of the built-in language list in `app::SetLocalePref`, found by export and byte pattern; original kept in `AdobeAudition-RU\backup`.
- Dictionaries are built for the installed version: missing strings fall back to English, coverage is reported; strings that exist only in the code (*Sign In…*, *Manage My Account…*) are translated too.
- Downloads from GitHub Releases with SHA256 verification of the package and every file; verified cache in `%TEMP%\AdobeAudition-RU`; offline fallback.
- Nothing is deleted: replaced files go to `AdobeAudition-RU\backup` and are restored on removal. Files that are still in use (for example a DLL held by a hung Audition process) are replaced by renaming and cleaned up on the next run.
- Translation: about 5,000 new strings; the 2023 community translation fully reviewed (about 3,750 corrections); consistent menu, panel and command names; unique menu mnemonics.
- Optional Learn panel translation (`-LearnPanel`); enables CEP `PlayerDebugMode`, without which Adobe rejects the modified signed panel.
