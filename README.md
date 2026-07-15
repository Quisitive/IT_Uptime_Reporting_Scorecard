# IT Uptime &amp; Security Scorecard — Collector

A self-contained, **agentless** monitoring appliance that installs on one network server and
produces a live IT Uptime &amp; Security Scorecard. It probes machines for availability, ingests
syslog, pulls Microsoft Defender / Perch metrics via API, tracks per-SLA uptime, scales to
thousands of hosts, alerts by email, and reports its own failures. Zero external npm
dependencies (Node 22 built-ins only); ships as one small Docker container.

---

## Contents
1. [Quick start](#1-quick-start)
2. [First-run onboarding](#2-first-run-onboarding)
3. [What each screen does](#3-what-each-screen-does)
4. [Adding &amp; removing machines](#4-adding--removing-machines)
5. [Getting Defender logs (onboarding wizard)](#5-getting-defender-logs)
6. [Forwarding syslog &amp; Windows events](#6-forwarding-syslog--windows-events)
7. [SLAs](#7-slas) · [SANs &amp; SAN name mapping](#8-sans--san-name-mapping)
8. [Health Index calibration](#9-health-index-calibration)
9. [Automated reporting &amp; alerts](#10-automated-reporting--alerts)
10. [Custom metrics &amp; dashboards](#11-custom-metrics--dashboards)
11. [Fail-out-loud &amp; self-diagnostics](#12-fail-out-loud--self-diagnostics)
12. [Security](#13-security) · [REST API](#14-rest-api) · [Architecture](#15-architecture)

---

## 1. Quick start

```bash
cd scorecard-collector
docker compose up -d --build
```
- UI: `http://<server>:8080` → you'll be redirected to a login page.
- The first-run **admin password** is printed once in the logs (`docker compose logs collector`)
  unless you set `ADMIN_PASSWORD` in `docker-compose.yml`.
- Change it immediately under **Setup → Change password**.

Run without Docker (dev): `npm start` (Node ≥ 22.5). Bind syslog to a high port with
`SYSLOG_UDP_PORT=5514 SYSLOG_TCP_PORT=5514` if you can't use 514. Load a month of demo data
with `npm run seed`.

Everything persists under `./data` (SQLite DB, `secrets.json`, generated reports). Back that up.

> **No infrastructure?** [`standalone/index.html`](standalone/) is a single-file, offline version
> of the same scorecard with manual data entry — just open it in a browser. See
> [standalone/README.md](standalone/README.md).

---

## 2. First-run onboarding

1. **Log in** and change the admin password (Setup).
2. **Edit `config/collector.json`** — set your `org`, business hours, probe `targets`, `groups`,
   `slas`, and `sans`. Restart the container to apply (`docker compose restart collector`).
3. **Connect Defender** (Setup → wizard) if you want automatic security-event numbers — see §5.
4. **Configure SMTP** (Setup) if you want emailed reports/alerts — see §10.
5. Point **syslog** and **Windows Event Forwarding** at the collector — see §6.

The collector works immediately with just probe targets; connectors are optional and self-skip
until configured.

---

## 3. What each screen does

| Screen | Purpose |
|---|---|
| **Overview** | Health Index, headline KPIs, fleet up/down, SLA-breach count, custom metrics. Problem tiles link straight to the drill-down. |
| **Machines** | Filterable, paginated list of every host (built for thousands). Filter by status / group / search; click a row for per-machine detail (24h availability, recent events). |
| **SLAs** | Per-application/group uptime vs. target, with breach flags. |
| **Events &amp; Incidents** | The three event sources (Endpoint / IDS / Defender) — LIVE (connector) or MANUAL (editable) — plus tiered outage notices. |
| **Disk** | SAN capacity bars; manual capacity entry when no live poll exists. |
| **Dashboards** | Build custom dashboards from built-in KPIs + your custom metrics. |
| **Setup** | Onboarding wizards (Defender, Perch, SMTP), API token, change password. |
| **Diagnostics** | The collector's own failures, insights from recurring issues, recent system events. |

---

## 4. Adding &amp; removing machines

Machines are the `probe.targets` array in `config/collector.json`:

```json
{ "name": "SERVER01", "host": "10.0.0.10", "port": 3389, "critical": true, "os": "windows", "group": "Domain Controllers" }
```

| Field | Meaning |
|---|---|
| `name` | Unique display name (also the key used to match forwarded syslog by host). |
| `host` / `port` | What to TCP-probe. Use a port that's always open when the box is healthy (445/3389 Windows, 22 Linux, 443 web). |
| `critical` | `true` counts toward system uptime, SLA "any-member-down", and critical-down alerts. |
| `group` | Free-text group; used by SLAs and the Machines filter. |

- **Add**: append an entry, then `docker compose restart collector`. It appears after the first probe cycle.
- **Remove**: delete the entry and restart. It stops being probed; its history remains in the DB
  (and it drops out of the fleet count once `machine_status` is pruned — delete its row from
  `machine_status` if you want it gone immediately).
- **Bulk / thousands of hosts**: keep one JSON entry per host. The prober is
  concurrency-limited (`probe.concurrency`, default 100) and debounced (`probe.downAfterFails`,
  default 2) so large fleets stay light. The Overview never lists individual machines — it shows
  aggregates and links into the paginated **Machines** view for investigation.
- **Groups**: list them under `groups` (for description) and reference them from `slas[].scope.groups`.

> Tip: generate `targets` from your CMDB/AD export with a script and drop it into the config —
> it's plain JSON.

---

## 5. Getting Defender logs

**Option A — Graph Security API (recommended).** In **Setup → Microsoft Defender wizard**:
1. Register an app in Entra ID → App registrations.
2. Add **application** permission `SecurityIncident.Read.All` (Microsoft Graph) and **Grant admin consent**.
3. Create a client secret.
4. Paste tenant ID, client ID, secret → **Test connection** → **Enable polling** → **Save**.

Credentials are stored in `data/secrets.json` (mode 600), never in the config file. You can also
supply them as env vars (`GRAPH_TENANT_ID/CLIENT_ID/CLIENT_SECRET`), which take precedence.
The connector maps: Data Points = incidents (New/InProgress/Resolved), Escalations = Medium/High,
Interventions = classification `truePositive`.

**Option B — log connector (no API).** Forward Defender/Sentinel alerts to this collector's
syslog (udp/tcp 514) via a Sentinel export / Logic App / your SIEM, and enter the Endpoint
"OverWatch-analyzed events" figure manually under **Events** (it comes from the MDR report, which
has no API). Perch/IDS is the same idea via **Setup → Perch**.

---

## 6. Forwarding syslog &amp; Windows events

Point log sources at **udp/tcp 514** (RFC 3164 and 5424 both parsed).

- **Windows hosts don't emit syslog natively.** Use **Windows Event Forwarding (WEF/WEC)** or a
  forwarder (NXLog / Winlogbeat) to relay Event Log → syslog. Forward these System-log IDs:
  `6005` boot · `6006` clean shutdown · `6008` unexpected shutdown · `6013` uptime · `1074`
  planned restart · `Kernel-Power 41` hard reboot · `2013` disk near capacity. Security IDs
  `4625/4740/4688` feed the "security events observed" metric and custom metrics.
- **Linux / network / SANs / firewalls / ESXi**: native syslog — send directly.
- Make the forwarded **hostname match the target `name`** (or the SAN `syslogHost`) so events
  attach to the right machine/array.

Test:
```bash
printf '<11>1 2026-06-15T09:00:00Z SERVER01 EventLog - - - EventID=6008 previous shutdown unexpected' | nc -u -w1 <server> 514
```

### Azure Monitor Agent (AMA) — pull instead of forward
For Azure VMs, Arc-enabled servers, or anything already onboarded to a **Log Analytics
workspace**, the collector can *pull* the agent's data instead of receiving forwarded syslog —
handy for cloud hosts the collector can't TCP-probe. Configure it in **Setup → Azure Monitor**
(or `config.connectors.azureMonitor` + `AZURE_*` env):

1. Give an Entra app (the Defender app is fine) the **Log Analytics Reader** role on the workspace.
2. Enter tenant/client/secret + **Workspace ID**, test, enable.

It polls every `pollIntervalMin` (default 10) and ingests:
- **`Heartbeat`** → each `Computer` becomes a machine in the fleet (group "Azure Monitor"),
  up/down by last-heartbeat age (`heartbeatDownAfterMin`, default 15).
- **`Event`** (Windows) → the events table, classified by `EventID` (same map as syslog).
- **`Syslog`** (Linux) → the events table, classified by message.

Ingested events flow into per-machine detail, custom metrics, and the security-events count.
> Note: if a host is *both* TCP-probed and Azure-monitored, keep the probe `name` and the AMA
> `Computer` name identical to avoid it appearing twice in the fleet.

---

## 7. SLAs

Define tiered SLAs in `config/collector.json`:
```json
{ "name": "Core Identity", "tier": 1, "uptimeTarget": 99.9, "scope": { "groups": ["Domain Controllers"] } }
```
`scope` can list `groups` and/or explicit `targets`. A service is counted **down** for a sample
interval if **any in-scope member** is down (during business hours). The **SLAs** screen shows
actual vs. target and flags breaches; tier-1 targets drive the Health Index uptime sub-score, and
breaches raise alerts (§10).

---

## 8. SANs &amp; SAN name mapping

SANs are listed under `sans`. Capacity can arrive four ways: **SNMP poll**, **REST poll**,
**syslog capacity alerts**, or **manual entry** (Disk screen / `POST /api/disk`).

```json
{ "name": "SAN-PROD-01", "type": "nimble",
  "syslogHost": "san-prod-01",
  "snmpHost": "10.0.5.10",
  "oids": { "used": "1.3.6.1.4.1.12740...", "total": "1.3.6.1.4.1.12740..." } }
```

**SAN name mapping — important.** The array's display name (`name`) is what the whole app keys
on. But other sources report different identifiers:
- **Syslog**: matched by the message's hostname. Set `syslogHost` to the hostname the array
  actually sends (e.g. `san-prod-01`) so capacity alerts and disk figures attach to the
  right array. Without it, a capacity alert would be stored under the raw syslog hostname and
  wouldn't show on the Disk screen.
- **SNMP/REST**: keyed by `snmpHost` / env creds → written back under `name`.
- Enable SNMP globally with `connectors.snmp.enabled: true` and set `community`. Provide either
  `{used,total}` OIDs (bytes) or hrStorage-style `{size,used,units}` OIDs.
- **MSA name**: `MSA` is a placeholder — rename it to the real array name in both `name` and
  `syslogHost`.

---

## 9. Health Index calibration

The Health Index (0–100) is a **transparent weighted average** of three bounded sub-scores.
Tune everything under `scoring` in `config/collector.json`:

```json
"scoring": {
  "weights": { "uptime": 50, "disk": 25, "security": 25 },
  "uptime":   { "floorBelowTargetPct": 2.0 },
  "disk":     { "warnPct": 70, "critPct": 85 },
  "security": { "pointsPerIntervention": 8, "maxInterventionPenalty": 60,
                "escalationRatePer1000": 5, "maxEscalationPenalty": 40 }
}
```

- **Uptime sub-score** is measured *relative to the tier-1 SLA target*, not an absolute 100%.
  At/above target → 100; at `target − floorBelowTargetPct` → 0; linear between. Widen the floor
  to be more forgiving.
- **Disk sub-score** is piecewise on the worst array: 100 at 0% used → ~60 at `warnPct` → ~20 at
  `critPct` → 0 at 100%.
- **Security sub-score** is driven by **interventions** (confirmed incidents), capped at
  `maxInterventionPenalty`, plus a small **escalation-rate** term (per 1,000 data points), capped
  at `maxEscalationPenalty`. This is deliberately **rate-based** so high IDS log/escalation
  volumes (hundreds of thousands of events) don't zero out the score — only real interventions
  move it materially.

Example: raise `weights.uptime` if availability matters most to the business; raise
`pointsPerIntervention` to punish confirmed incidents harder. Changes apply on restart.

---

## 10. Automated reporting &amp; alerts

**Scheduled reports** (`reporting.schedules`) run on a 5-field cron and generate an HTML + JSON
scorecard, delivered to any of:
- **local** — written to `reporting.destinations.local.dir` (mount it to a network share for
  "remote host storage").
- **http** — PUT/POST the JSON to `reporting.destinations.http.url` (bearer via `REPORT_HTTP_TOKEN`).
- **email** — via the SMTP relay (Setup → SMTP; supports none/STARTTLS/TLS + AUTH LOGIN).

```json
{ "name": "Monthly executive report", "cron": "0 8 1 * *", "period": "previous", "deliver": ["local","email"] }
```

**Event-driven alerts** (`alerts`): SLA breach, machine down, and collector-failure alerts are
emailed (deduped by `minMinutesBetweenSame`). If email isn't configured, alerts are still
recorded and shown in Diagnostics (never silently dropped).

---

## 11. Custom metrics &amp; dashboards

- **Custom metrics** count already-ingested log events by any of
  `{source, category, eventId, severityMax, hostLike, messageLike}`. Define them in
  `config.customMetrics` or at runtime via `POST /api/custom-metrics`. They appear on the
  Overview and in the dashboard widget catalog — new metrics from existing logging, no new
  collection required.
- **Custom dashboards** (Dashboards screen) compose widgets from built-in KPIs
  (health, uptime, disk, fleet, SLA table…) and custom metrics. Saved in the DB.

---

## 12. Fail-out-loud &amp; self-diagnostics

- Every subsystem failure (connector error, SMTP failure, probe error, uncaught exception) is
  written to `system_events`, logged, and shown as a **red banner** across the top of the UI.
- The **Diagnostics** screen lists active problems, and **insights** learned from recurring
  failures over 24h with a suggested fix per component.
- Failing connectors get **adaptive exponential backoff** (`selfMonitor.backoffBase/MaxSec`) so a
  broken integration slows its retries instead of hammering.
- Critical failures also raise an email alert when configured.

---

## 13. Security
- All UI/API routes require login (session cookie) or the `X-Api-Token` header (token in
  `data/secrets.json`).
- Credentials come from env vars or the mode-600 secrets file — never the committed config.
- Expose `:8080` only behind a **TLS-terminating reverse proxy** with access controls. The
  container needs inbound 514 from managed subnets and outbound 443 to Graph/Perch/SANs.
- Defender needs an Entra app with `SecurityIncident.Read.All` (application) + admin consent.

## 14. REST API
`Authorization` = session cookie or `X-Api-Token`.

| Method | Path | Purpose |
|---|---|---|
| POST | `/api/login` / `/api/logout` | Session auth |
| GET | `/api/scorecard?period=YYYY-MM` | Full computed scorecard |
| GET | `/api/health` | Status, ingest counts, connectors, fleet, problems |
| GET | `/api/machines?status&group&search&limit&offset` | Paginated fleet |
| GET | `/api/machines/:name` | Per-machine detail |
| GET | `/api/diagnostics` | Problems + insights + system events |
| POST | `/api/notices` · `/api/event-metrics` · `/api/disk` | Manual data entry |
| POST | `/api/connectors/defender/test` · `/save` | Wizard |
| POST | `/api/smtp/test` · `/save` | SMTP wizard |
| GET/POST/DELETE | `/api/dashboards` · `/api/custom-metrics` | Dashboards & metrics |

## 15. Architecture

```
Windows ─WEF/NXLog─┐
Linux/net/SAN ─────┼─► syslog 514 ─► parser ─┐
critical targets ◄─┤   TCP probe (business hrs, concurrency-limited, debounced)
MS Graph/Perch ────┼─► API pollers (adaptive backoff) ─┼─► SQLite (/data) ─► scoring+SLA+aggregation ─► REST/UI :8080
SAN SNMP/REST ─────┘                                    └─► scheduler ─► reports (local/http/email) + alerts
                                                        self-monitor ─► system_events ─► banner + Diagnostics
```

Modules: `ingest/` (syslog, prober, snmp) · `connectors/` (graph, perch, san) · `scoring.js`
`sla.js` `machines.js` `customMetrics.js` `dashboards.js` `reporting.js` `smtp.js` `selfmonitor.js`
`auth.js` `secrets.js` `aggregate.js` `api.js`.

## Roadmap (not yet implemented)
Native TLS syslog (6514) · full SNMP hrStorageTable walk · Defender for Endpoint streaming API
for the OverWatch figure · month-over-month trend charts · multi-user RBAC.
