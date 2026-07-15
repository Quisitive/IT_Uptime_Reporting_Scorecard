import { getDb } from './db.js';
import { periodRange, businessHoursInRange } from './util/time.js';
import { healthIndex } from './scoring.js';
import { computeAllSlas } from './sla.js';
import { fleetSummary } from './machines.js';
import { evalAll as evalCustomMetrics } from './customMetrics.js';

const EVENT_SOURCES = ['endpoint', 'ids', 'defender'];

export function buildScorecard(cfg, period) {
  const db = getDb();
  const bh = cfg.businessHours;
  const { startMs, endMs } = periodRange(period, bh.timezoneOffsetMinutes);
  const intervalHrs = cfg.probe.intervalSec / 3600;
  const availHrs = bh.standardMonthlyHours;

  // ---- headline uptime from __system__ (all critical up) ----
  const sysRow = db.prepare(
    `SELECT SUM(CASE WHEN up=0 THEN 1 ELSE 0 END) AS down_n, COUNT(*) AS n
     FROM avail_samples WHERE target='__system__' AND in_hours=1 AND ts>=? AND ts<?`
  ).get(startMs, endMs);
  const measuredDownHrs = (sysRow?.down_n || 0) * intervalHrs;
  const uptimePct = availHrs > 0 ? Math.max(0, Math.min(100, (availHrs - measuredDownHrs) / availHrs * 100)) : 0;
  const referenceBusinessHrs = Math.round(businessHoursInRange(startMs, Math.min(endMs, Date.now()), bh));

  const partialRow = db.prepare(
    `SELECT COUNT(DISTINCT ts) AS n FROM avail_samples
     WHERE target NOT IN ('__system__') AND up=0 AND in_hours=1 AND ts>=? AND ts<?`
  ).get(startMs, endMs);
  const degradedHrs = Math.max(0, (partialRow?.n || 0) * intervalHrs - measuredDownHrs);

  // ---- SLAs ----
  const slas = computeAllSlas(cfg, startMs, endMs);
  const tier1 = slas.filter((s) => s.tier === 1 && s.target != null);
  const uptimeTargetPct = tier1.length ? Math.max(...tier1.map((s) => s.target)) : 99.5;

  // ---- notices ----
  const notices = db.prepare(`SELECT id, ts, tier, description FROM notices WHERE ts>=? AND ts<? ORDER BY ts`).all(startMs, endMs);
  const tierCounts = { 1: 0, 2: 0, 3: 0 };
  notices.forEach((n) => { tierCounts[n.tier] = (tierCounts[n.tier] || 0) + 1; });

  // ---- event metrics ----
  const metricRows = db.prepare(`SELECT source, data_points, escalations, interventions, origin FROM event_metrics WHERE period=?`).all(period);
  const events = {};
  for (const s of EVENT_SOURCES) {
    const row = metricRows.find((m) => m.source === s);
    events[s] = row ? { dp: row.data_points, esc: row.escalations, int: row.interventions, origin: row.origin }
      : { dp: 0, esc: 0, int: 0, origin: 'none' };
  }
  const evTotals = EVENT_SOURCES.reduce((a, s) => ({ dp: a.dp + events[s].dp, esc: a.esc + events[s].esc, int: a.int + events[s].int }), { dp: 0, esc: 0, int: 0 });
  const secObserved = db.prepare(`SELECT COUNT(*) AS n FROM events WHERE category='security' AND ts>=? AND ts<?`).get(startMs, endMs).n;

  // ---- disks ----
  const sans = cfg.sans.map((s) => {
    const row = db.prepare(`SELECT used_bytes, total_bytes, ts, origin FROM disk_samples WHERE array=? AND ts<? ORDER BY ts DESC LIMIT 1`).get(s.name, endMs);
    const used = row?.used_bytes ?? null, total = row?.total_bytes ?? null;
    const pct = used != null && total > 0 ? +(used / total * 100).toFixed(2) : null;
    return { name: s.name, type: s.type, usedTB: used != null ? +(used / 1e12).toFixed(2) : null,
      totalTB: total != null ? +(total / 1e12).toFixed(2) : null, usedPct: pct, asOf: row?.ts || null, origin: row?.origin || null };
  });
  const worstDisk = sans.reduce((w, s) => (s.usedPct != null && s.usedPct > w.pct) ? { pct: s.usedPct, name: s.name } : w, { pct: null, name: '—' });

  // ---- health index (new scoring engine) ----
  const health = healthIndex(cfg.scoring, {
    uptimePct, uptimeTargetPct, worstDiskPct: worstDisk.pct, eventTotals: evTotals
  });

  return {
    period, generatedAt: Date.now(), org: cfg.org || '',
    uptime: { hrsAvailability: availHrs, hrsDown: +measuredDownHrs.toFixed(2), hrsDegraded: +degradedHrs.toFixed(2),
      uptimePct: +uptimePct.toFixed(2), uptimeTargetPct, referenceBusinessHrs, samples: sysRow?.n || 0 },
    incidents: { total: notices.length, tiers: tierCounts, notices },
    events: { sources: events, totals: evTotals, securityObserved: secObserved },
    disks: { sans, worst: worstDisk },
    slas,
    fleet: fleetSummary(),
    customMetrics: evalCustomMetrics(cfg, startMs, endMs),
    health
  };
}

export function listPeriods(cfg) {
  const db = getDb();
  const set = new Set();
  const off = cfg.businessHours.timezoneOffsetMinutes;
  const fmt = (ts) => { const d = new Date(ts + off * 60000); return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`; };
  // Enumerate every month between the earliest and latest sample (cheap: two indexed lookups).
  const range = db.prepare(`SELECT MIN(ts) a, MAX(ts) b FROM avail_samples`).get();
  if (range?.a) {
    const start = new Date(range.a + off * 60000); const end = new Date(range.b + off * 60000);
    const d = new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth(), 1));
    const last = Date.UTC(end.getUTCFullYear(), end.getUTCMonth(), 1);
    while (d.getTime() <= last) { set.add(`${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`); d.setUTCMonth(d.getUTCMonth() + 1); }
  }
  db.prepare(`SELECT DISTINCT period FROM event_metrics`).all().forEach((r) => set.add(r.period));
  db.prepare(`SELECT DISTINCT ts FROM notices`).all().forEach((r) => set.add(fmt(r.ts)));
  return [...set].filter(Boolean).sort().reverse();
}
