# Standalone Scorecard (single-file, manual entry)

`index.html` is a self-contained, offline version of the IT Uptime &amp; Security Scorecard —
no server, no install. Double-click it (or open in any browser) and it runs entirely
client-side, saving data in the browser's `localStorage`.

Use this when you want to produce a scorecard by **manually entering** the monthly numbers
(uptime hours, outage notices, Defender/Perch/OverWatch event counts, SAN capacity) rather
than collecting them automatically.

## Features
- Live-calculated System Uptime %, tiered outage notices, event funnels, SAN utilization bars.
- Configurable, transparent Health Index.
- Multiple saved reporting periods; JSON export/import; print / Save-as-PDF.
- Light/dark theme; Quisitive-branded (logo embedded as a data URI — fully self-contained).

## When to use which
| | Standalone (this) | Collector ([../](../README.md)) |
|---|---|---|
| Data entry | Manual | Automated (probing, syslog, APIs) |
| Install | None — open the file | Windows Service / Docker |
| Scale | A handful of systems | Hundreds–thousands of machines |
| Best for | Quick monthly report, no infrastructure | Continuous monitoring + alerting |

The collector can generate the same scorecard automatically; this file is the zero-infrastructure
fallback and a handy way to preview the report format.
