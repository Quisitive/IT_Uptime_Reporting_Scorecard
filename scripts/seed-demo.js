// Populates the database with a month of realistic sample data so the dashboard
// can be demonstrated without live infrastructure.  Run:  npm run seed
import { loadConfig } from '../src/config.js';
import { initDb, getDb, recordAvail, recordDisk, upsertEventMetric, addNotice } from '../src/db.js';
import { periodRange } from '../src/util/time.js';

const cfg = loadConfig();
initDb(cfg.database.path);
const _db = getDb();
const bh = cfg.businessHours;

// Seed the PREVIOUS full month (matches the reporting convention).
const d = new Date(Date.now() + bh.timezoneOffsetMinutes * 60000);
d.setUTCDate(1); d.setUTCMonth(d.getUTCMonth() - 1);
const period = `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
const { startMs, endMs } = periodRange(period, bh.timezoneOffsetMinutes);

const intervalMs = cfg.probe.intervalSec * 1000;
const targets = cfg.probe.targets;

// Inject two outages during business hours using the first two configured targets (if present).
const outages = [
  targets[0] ? { target: targets[0].name, startFrac: 0.35, hours: 2.0 }   : null,
  targets[1] ? { target: targets[1].name, startFrac: 0.62, hours: 0.75 }  : null
].filter(Boolean);
function isDown(name, ts) {
  return outages.some((o) => {
    if (o.target !== name) return false;
    const s = startMs + (endMs - startMs) * o.startFrac;
    return ts >= s && ts < s + o.hours * 3600000;
  });
}
function inHours(ts) {
  const t = new Date(ts + bh.timezoneOffsetMinutes * 60000);
  const dow = t.getUTCDay(), h = t.getUTCHours();
  return bh.days.includes(dow) && h >= bh.startHour && h < bh.endHour;
}

let n = 0;
_db.exec('BEGIN');
for (let ts = startMs; ts < Math.min(endMs, Date.now()); ts += intervalMs) {
  const ih = inHours(ts) ? 1 : 0;
  let anyCriticalDown = false;
  for (const t of targets) {
    const down = isDown(t.name, ts);
    recordAvail(ts, t.name, down ? 0 : 1, down ? null : 5 + Math.round((ts % 7)), ih);
    if (t.critical && down) anyCriticalDown = true;
  }
  recordAvail(ts, '__system__', anyCriticalDown ? 0 : 1, null, ih);
  n++;
}
_db.exec('COMMIT');

// Disk snapshots — one per configured SAN (latest wins); fill in realistic used/total values.
for (const s of cfg.sans) {
  recordDisk(endMs - 1, s.name, 0, 0);
}

// Event metrics (as if pulled from Defender / Perch / OverWatch report).
upsertEventMetric(period, 'endpoint', 128934, 6, 2, 'manual');   // Defender OverWatch report
upsertEventMetric(period, 'ids', 41250000, 214, 3, 'perch-api'); // Perch Hero
upsertEventMetric(period, 'defender', 47, 12, 4, 'defender-api'); // MS Defender incidents

// Incident-response notices (tied to the first two outages if targets were available).
if (outages[0]) addNotice(startMs + (endMs - startMs) * outages[0].startFrac, 2, `${outages[0].target} outage — ~${outages[0].hours}h`);
if (outages[1]) addNotice(startMs + (endMs - startMs) * outages[1].startFrac, 3, `${outages[1].target} degraded — ~${outages[1].hours}h`);

console.log(`Seeded ${n} probe cycles for period ${period}.`);
console.log('Start the collector (npm start) and open http://localhost:8080');
