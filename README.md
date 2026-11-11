# TAK Remote Access Setup

Connects a Windows PC to The Alt Key PLLC's office network for remote work. IT runs it with the employee during
onboarding, by pasting one line into PowerShell. There's nothing to download and nothing secret in this repository:
joining the network needs a one-time code that IT creates for each PC.

## Onboarding a PC (IT, on a call with the employee)

1. **Create a one-time code.** Tailscale admin console → **Settings → Keys → Generate auth key**:
   **Reusable** off, **Ephemeral** off, **Pre-approved** off, **Tags** `tag:client`, expiry 1 day.
   Send it to the employee (email or chat).
2. **The employee turns on BitLocker first**, if it isn't on yet (setup checks, and explains how if not).
3. **The employee opens PowerShell as administrator:** Start → type `PowerShell` → right-click
   **Windows PowerShell** → **Run as administrator** (an administrator password may be needed).
4. **They paste this and press Enter:**

   ```powershell
   irm https://raw.githubusercontent.com/OWNER/REPO/main/TAKSetup.ps1 | iex
   ```

5. **They type their name and paste the one-time code** when asked. You approve the device in the admin
   console when setup says it's waiting.

Setup shows four plain steps and finishes with "You're all set". The desktop then has **TAK Remote Desktop**
(working within a few minutes, once the IT dashboard has seen BitLocker on) and **Get IT Help** (a link to the
dashboard's help page). Running it again on the same PC is safe: it re-applies everything.

## What it does

All of it is in [TAKSetup.ps1](TAKSetup.ps1), readable top to bottom. In short:

- **BitLocker:** checks it (read-only). It must be protecting the drive, or encrypting it with a TPM.
  Setup never turns BitLocker on and never reads recovery keys.
- **Installers:** Tailscale, RustDesk and Microsoft's OpenSSH, downloaded from the vendors' own sites. Each must
  match the SHA-256 pinned in the script and carry a valid signature from that vendor, or setup stops.
- **Tailscale:** joins as `tag:client` (no Remote Desktop). The IT dashboard switches the PC to `tag:rdp-client`
  once BitLocker is on.
- **RustDesk:** direct connections from Tailscale addresses only, never RustDesk's public servers, and the
  employee clicks **Accept** for every session.
- **OpenSSH Server for IT:** key logins only (the public keys in the script), only from Tailscale addresses, only
  as the local administrator `tak-it`. Its password is random and never stored, and it can't sign in at the
  keyboard or over Remote Desktop.
- **Log:** `C:\ProgramData\TAKRemoteAccess\setup-script.log`. Device state: `device-state.txt` in the same folder.

## Updating

Edit `TAKSetup.ps1` directly. To move to a new Tailscale, RustDesk or OpenSSH version, change that installer's
`Version`, `Url` (a versioned URL, never a "latest" link) and `Sha256` in the `$Installers` table near the top.
To add or revoke an IT SSH key, edit `$SshAdminKeys`; PCs pick it up the next time setup runs on them.
