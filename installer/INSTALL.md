# Installing the Quisitive IT Scorecard Collector (Windows Service)

This installs the collector as an always-on **Windows Service** with a **bundled Node.js
runtime** — the target server needs nothing pre-installed. No Docker required.

## For the operator (installing on a server)

1. Copy the installer bundle to the server and unzip it.
2. Open **PowerShell as Administrator** in the unzipped folder.
3. Run the wizard:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```
4. Answer the prompts (install directory, web port, syslog ports, firewall, admin password).
5. When it finishes it prints the URL (`http://<server>:8080`) and the **first-run admin
   password** (auto-generated unless you set one). Open the UI, sign in as `admin`, and change
   the password under **Setup**.

### Unattended / scripted install
```powershell
.\install.ps1 -Silent -InstallDir "C:\Program Files\QuisitiveScorecard" `
  -HttpPort 8080 -SyslogUdpPort 514 -SyslogTcpPort 514 `
  -OpenFirewall Yes -StartService -AdminPassword 'ChangeMe!23'
```

### Preview without changing anything
```powershell
.\install.ps1 -DryRun
```
Prints every action it *would* take (no files copied, no service/firewall changes).

## What it does
- Copies the app to the install directory (default `C:\Program Files\QuisitiveScorecard`).
- Places the bundled `runtime\node.exe` (or downloads Node 22 if not bundled).
- Registers a Windows Service **"Quisitive IT Scorecard Collector"** via the WinSW wrapper
  (auto-start, auto-restart on failure, rolling logs under `service\logs`).
- Opens inbound firewall rules for the web and syslog ports (if you chose Yes).
- Starts the service and opens the browser.

## Managing the service
| Action | Command |
|---|---|
| Start / stop / restart | `services.msc` → "Quisitive IT Scorecard Collector", or `service\QuisitiveScorecard.exe restart` |
| View logs | `<InstallDir>\service\logs\QuisitiveScorecard.out.log` (and `.err.log`) |
| Edit settings | `<InstallDir>\config\collector.json`, then restart the service |
| Data / DB / reports | `<InstallDir>\data\` |

## Upgrading
Re-run `install.ps1` with the same install directory. It stops the service, replaces
`src/`, `web/`, `scripts/`, updates the runtime, and restarts — **your `config\collector.json`
and `data\` are preserved**.

## Uninstalling
```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1            # keeps data
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -RemoveData -Silent
```

## Security notes
- Expose the web port only behind a **TLS reverse proxy** (IIS ARR, nginx) if it leaves the LAN.
- Connector secrets (Defender, Perch, SMTP) are entered in the web **Setup** wizard and stored in
  `<InstallDir>\data\secrets.json` (ACL it to the service account / admins).
- The service runs as **LocalSystem** by default. To run under a dedicated service account, set it
  in `services.msc` after install and grant it read/write to `<InstallDir>\data`.

---

## For the packager (building the shippable bundle)

From a build machine with internet:
```powershell
cd quisitive-scorecard-collector\installer
.\package-installer.ps1                 # downloads Node + WinSW, produces a fully offline bundle
.\package-installer.ps1 -SkipDownloads  # smaller; target fetches Node + WinSW at install time
```
Output: `dist\QuisitiveScorecard-Installer-<version>.zip`. Ship that zip to operators.
