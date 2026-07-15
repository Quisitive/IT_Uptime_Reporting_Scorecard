import { loadConfig } from './config.js';
import { initDb, getDb } from './db.js';
import { initAuth } from './auth.js';
import { startSyslog } from './ingest/syslog.js';
import { startProber } from './ingest/prober.js';
import { startApi } from './api.js';
import { pollDefender } from './connectors/graph.js';
import { pollPerch } from './connectors/perch.js';
import { pollSans } from './connectors/san.js';
import { pollAzureMonitor } from './connectors/azuremonitor.js';
import { initSelfMonitor, fail, ok, backoffSec } from './selfmonitor.js';
import { initReporting, startScheduler, alert } from './reporting.js';
import { buildScorecard } from './aggregate.js';
import { currentPeriod } from './util/time.js';

const cfg = loadConfig();
console.log('=== Quisitive Scorecard Collector v0.2 ===');
initDb(cfg.database.path);
console.log(`[db] ${cfg.database.path}`);

// Merge runtime-defined custom metrics from the DB into the config.
try {
  for (const r of getDb().prepare('SELECT id,name,match_json,unit FROM custom_metrics').all()) {
    if (!cfg.customMetrics.some((m) => m.id === r.id))
      cfg.customMetrics.push({ id: r.id, name: r.name, match: JSON.parse(r.match_json || '{}'), unit: r.unit });
  }
} catch (e) { console.error('[init] custom metrics load:', e.message); }

initAuth(cfg);
initSelfMonitor(cfg, (subject, body, key) => alert(subject, body, key));
initReporting(cfg);

// ---- ingest ----
try {
  startSyslog(cfg);
} catch (e) { fail('syslog', 'start', e.message, { critical: true }); }

startProber(cfg, {
  onStateChange: (t, up) => {
    if (!up && cfg.alerts.onMachineDown)
      alert(`Machine DOWN: ${t.name}`, `${t.name} (${t.host}:${t.port}, group ${t.group || '—'}) is not responding.`, `down:${t.name}`);
  },
  onError: (e) => fail('prober', 'cycle', e.message)
});

// ---- connectors with adaptive backoff + fail-out-loud ----
const connectorState = { defender: {}, perch: {}, san: {}, azuremonitor: {} };
function scheduleConnector(name, fn, baseIntervalMin) {
  const component = `connector:${name}`;
  const run = async () => {
    let delayMs = baseIntervalMin * 60000;
    try {
      const r = await fn(cfg);
      connectorState[name] = { lastRun: Date.now(), lastResult: r };
      if (r?.skipped) console.log(`[${component}] skipped — ${r.skipped}`);
      else { ok(component); console.log(`[${component}] ok`); }
    } catch (e) {
      connectorState[name] = { lastRun: Date.now(), lastResult: { error: e.message } };
      const back = fail(component, 'poll', e.message, { critical: cfg.alerts.onCollectorFailure }) * 1000;
      delayMs = Math.max(delayMs, back); // slow down while failing
      console.log(`[${component}] backing off ${Math.round(delayMs / 1000)}s`);
    }
    setTimeout(run, delayMs);
  };
  run();
}
scheduleConnector('defender', pollDefender, cfg.connectors.defender.pollIntervalMin);
scheduleConnector('perch', pollPerch, cfg.connectors.perch.pollIntervalMin);
scheduleConnector('san', pollSans, cfg.connectors.snmp.pollIntervalMin);
scheduleConnector('azuremonitor', pollAzureMonitor, cfg.connectors.azureMonitor.pollIntervalMin);

// ---- periodic SLA-breach / critical-down alerting ----
setInterval(() => {
  try {
    const sc = buildScorecard(cfg, currentPeriod(cfg.businessHours.timezoneOffsetMinutes));
    if (cfg.alerts.onSlaBreach) for (const s of sc.slas) if (s.breached)
      alert(`SLA BREACH: ${s.name}`, `${s.name} (tier ${s.tier}) at ${s.uptimePct}% vs target ${s.target}%.`, `sla:${s.name}`);
    if (sc.fleet.criticalDown > 0)
      alert(`${sc.fleet.criticalDown} critical machine(s) down`, `Investigate in the Machines view.`, 'fleet:critical');
  } catch (e) { fail('alerting', 'check', e.message); }
}, 15 * 60000);

startScheduler();
startApi(cfg, connectorState);

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
process.on('uncaughtException', (e) => { try { fail('process', 'uncaught', e.stack || e.message, { critical: true }); } catch {} });
process.on('unhandledRejection', (e) => { try { fail('process', 'unhandledRejection', String(e)); } catch {} });
