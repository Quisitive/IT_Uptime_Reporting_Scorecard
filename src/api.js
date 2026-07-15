import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { join, extname, normalize } from 'node:path';
import { randomUUID } from 'node:crypto';
import { buildScorecard, listPeriods } from './aggregate.js';
import { getDb, addNotice, deleteNotice, upsertEventMetric, recordDisk } from './db.js';
import { syslogStats } from './ingest/syslog.js';
import { proberStatus } from './ingest/prober.js';
import { currentPeriod } from './util/time.js';
import { authenticate, login, logout, changePassword } from './auth.js';
import { setSecrets, getSecret } from './secrets.js';
import { fleetSummary, listMachines, machineDetail, distinctGroups } from './machines.js';
import { problems, insights, recentSystemEvents } from './selfmonitor.js';
import { listDashboards, getDashboard, saveDashboard, deleteDashboard, WIDGET_CATALOG } from './dashboards.js';
import { testDefender } from './connectors/graph.js';
import { testAzureMonitor } from './connectors/azuremonitor.js';
import { sendMail } from './smtp.js';

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.webp': 'image/webp', '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon' };

function send(res, code, body, type = 'application/json') {
  const data = type === 'application/json' ? JSON.stringify(body) : body;
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store' });
  res.end(data);
}
async function readBody(req) {
  const chunks = []; for await (const c of req) chunks.push(c);
  if (!chunks.length) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { return {}; }
}

export function startApi(cfg, connectorState) {
  const webDir = join(cfg.root, 'web');

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const path = url.pathname;
    const method = req.method;

    try {
      // ---- unauthenticated: liveness + login ----
      if (path === '/healthz') return send(res, 200, { ok: true });
      if (path === '/api/login' && method === 'POST') {
        const b = await readBody(req);
        const sid = login(b.username, b.password);
        if (!sid) return send(res, 401, { error: 'invalid credentials' });
        res.writeHead(200, { 'Content-Type': 'application/json',
          'Set-Cookie': `sid=${sid}; HttpOnly; SameSite=Strict; Path=/; Max-Age=${cfg.auth.sessionTtlHours * 3600}` });
        return res.end(JSON.stringify({ ok: true }));
      }

      // ---- auth gate ----
      // Assets the login page needs must be reachable before sign-in.
      const PUBLIC = new Set(['/login.html', '/icon.svg', '/favicon.ico']);
      const who = authenticate(req);
      if (!who) {
        if (path.startsWith('/api/')) return send(res, 401, { error: 'authentication required' });
        if (!PUBLIC.has(path)) { res.writeHead(302, { Location: '/login.html' }); return res.end(); }
        // public asset → fall through to static serving
      }

      // ---- authenticated API ----
      if (path === '/api/logout' && method === 'POST') { if (who?.sid) logout(who.sid);
        res.writeHead(200, { 'Set-Cookie': 'sid=; Path=/; Max-Age=0' }); return res.end('{}'); }
      if (path === '/api/change-password' && method === 'POST') {
        const b = await readBody(req); if (!b.password || b.password.length < 8) return send(res, 400, { error: 'min 8 chars' });
        changePassword(who.user, b.password); return send(res, 200, { ok: true }); }

      if (path === '/api/health') return send(res, 200, {
        ok: true, now: Date.now(), user: who?.user,
        syslog: syslogStats(), prober: proberStatus(), connectors: connectorState,
        fleet: fleetSummary(), problems: problems() });

      if (path === '/api/periods') {
        const periods = listPeriods(cfg); const cur = currentPeriod(cfg.businessHours.timezoneOffsetMinutes);
        if (!periods.includes(cur)) periods.unshift(cur); return send(res, 200, { periods }); }

      if (path === '/api/scorecard')
        return send(res, 200, buildScorecard(cfg, url.searchParams.get('period') || currentPeriod(cfg.businessHours.timezoneOffsetMinutes)));

      // ---- machines drill-down ----
      if (path === '/api/machines' && method === 'GET') return send(res, 200, listMachines({
        status: url.searchParams.get('status'), group: url.searchParams.get('group'),
        search: url.searchParams.get('search'), sort: url.searchParams.get('sort'),
        limit: parseInt(url.searchParams.get('limit') || '50', 10), offset: parseInt(url.searchParams.get('offset') || '0', 10) }));
      if (path.startsWith('/api/machines/') && method === 'GET') {
        const d = machineDetail(decodeURIComponent(path.split('/').pop())); return d ? send(res, 200, d) : send(res, 404, { error: 'not found' }); }
      if (path === '/api/groups') return send(res, 200, { groups: distinctGroups() });

      // ---- notices ----
      if (path === '/api/notices' && method === 'POST') { const b = await readBody(req);
        const id = addNotice(b.date ? Date.parse(b.date) : Date.now(), parseInt(b.tier, 10) || 2, String(b.description || '')); return send(res, 200, { ok: true, id }); }
      if (path.startsWith('/api/notices/') && method === 'DELETE') { deleteNotice(parseInt(path.split('/').pop(), 10)); return send(res, 200, { ok: true }); }

      if (path === '/api/event-metrics' && method === 'POST') { const b = await readBody(req);
        upsertEventMetric(b.period, b.source, b.dp, b.esc, b.int, 'manual'); return send(res, 200, { ok: true }); }
      if (path === '/api/disk' && method === 'POST') { const b = await readBody(req);
        recordDisk(Date.now(), b.array, (b.usedTB || 0) * 1e12, (b.totalTB || 0) * 1e12, 'manual'); return send(res, 200, { ok: true }); }

      // ---- diagnostics ----
      if (path === '/api/diagnostics') return send(res, 200, { problems: problems(), insights: insights(), recent: recentSystemEvents(150) });

      // ---- onboarding wizard / connectors ----
      if (path === '/api/connectors' && method === 'GET') return send(res, 200, {
        defender: { enabled: cfg.connectors.defender.enabled, tenantId: mask(getSecret('defender.tenantId') || process.env.GRAPH_TENANT_ID), configured: !!cfg.connectors.defender.creds.clientSecret },
        perch: { enabled: cfg.connectors.perch.enabled, configured: !!cfg.connectors.perch.creds.token },
        snmp: { enabled: cfg.connectors.snmp.enabled },
        azureMonitor: { enabled: cfg.connectors.azureMonitor.enabled, workspaceId: cfg.connectors.azureMonitor.workspaceId || '', tenantId: mask(getSecret('azureMonitor.tenantId') || process.env.AZURE_TENANT_ID), configured: !!cfg.connectors.azureMonitor.creds.clientSecret },
        smtp: { host: cfg.reporting.smtp.host, port: cfg.reporting.smtp.port, secure: cfg.reporting.smtp.secure, emailEnabled: cfg.reporting.destinations.email.enabled },
        apiToken: mask(getSecret('api.token')) });

      if (path === '/api/connectors/defender/test' && method === 'POST') { const b = await readBody(req);
        return send(res, 200, await testDefender({ tenantId: b.tenantId, clientId: b.clientId, clientSecret: b.clientSecret || cfg.connectors.defender.creds.clientSecret })); }
      if (path === '/api/connectors/defender/save' && method === 'POST') { const b = await readBody(req);
        const patch = { 'defender.tenantId': b.tenantId, 'defender.clientId': b.clientId, 'defender.enabled': !!b.enabled };
        if (b.clientSecret) patch['defender.clientSecret'] = b.clientSecret;
        setSecrets(patch);
        cfg.connectors.defender.enabled = !!b.enabled;
        cfg.connectors.defender.creds = { tenantId: b.tenantId, clientId: b.clientId, clientSecret: b.clientSecret || cfg.connectors.defender.creds.clientSecret };
        return send(res, 200, { ok: true }); }

      if (path === '/api/connectors/azuremonitor/test' && method === 'POST') { const b = await readBody(req);
        return send(res, 200, await testAzureMonitor(
          { tenantId: b.tenantId, clientId: b.clientId, clientSecret: b.clientSecret || cfg.connectors.azureMonitor.creds.clientSecret },
          b.workspaceId || cfg.connectors.azureMonitor.workspaceId)); }
      if (path === '/api/connectors/azuremonitor/save' && method === 'POST') { const b = await readBody(req);
        const patch = { 'azureMonitor.tenantId': b.tenantId, 'azureMonitor.clientId': b.clientId, 'azureMonitor.workspaceId': b.workspaceId, 'azureMonitor.enabled': !!b.enabled };
        if (b.clientSecret) patch['azureMonitor.clientSecret'] = b.clientSecret;
        setSecrets(patch);
        cfg.connectors.azureMonitor.enabled = !!b.enabled;
        cfg.connectors.azureMonitor.workspaceId = b.workspaceId;
        cfg.connectors.azureMonitor.creds = { tenantId: b.tenantId, clientId: b.clientId, clientSecret: b.clientSecret || cfg.connectors.azureMonitor.creds.clientSecret };
        return send(res, 200, { ok: true }); }

      if (path === '/api/connectors/perch/save' && method === 'POST') { const b = await readBody(req);
        setSecrets({ 'perch.base': b.base, 'perch.token': b.token });
        cfg.connectors.perch.enabled = !!b.enabled; cfg.connectors.perch.creds = { base: b.base, token: b.token };
        return send(res, 200, { ok: true }); }

      if (path === '/api/smtp/save' && method === 'POST') { const b = await readBody(req);
        if (b.password) setSecrets({ 'smtp.password': b.password });
        Object.assign(cfg.reporting.smtp, { host: b.host, port: +b.port || 25, secure: b.secure || 'none', authUser: b.authUser || '', password: b.password || cfg.reporting.smtp.password });
        Object.assign(cfg.reporting.destinations.email, { enabled: !!b.enabled, from: b.from || cfg.reporting.destinations.email.from, to: Array.isArray(b.to) ? b.to : String(b.to || '').split(',').map((s) => s.trim()).filter(Boolean) });
        return send(res, 200, { ok: true }); }
      if (path === '/api/smtp/test' && method === 'POST') { const b = await readBody(req);
        try { await sendMail({ ...cfg.reporting.smtp }, { from: cfg.reporting.destinations.email.from, to: b.to || cfg.reporting.destinations.email.to,
          subject: 'IT Scorecard SMTP test', text: 'This is a test message from the Nonin Scorecard Collector.' });
          return send(res, 200, { ok: true }); } catch (e) { return send(res, 200, { ok: false, error: e.message }); } }

      // ---- dashboards ----
      if (path === '/api/widget-catalog') return send(res, 200, { catalog: WIDGET_CATALOG });
      if (path === '/api/dashboards' && method === 'GET') return send(res, 200, { dashboards: listDashboards() });
      if (path === '/api/dashboards' && method === 'POST') { const b = await readBody(req); return send(res, 200, saveDashboard(b)); }
      if (path.startsWith('/api/dashboards/') && method === 'GET') { const d = getDashboard(path.split('/').pop()); return d ? send(res, 200, d) : send(res, 404, { error: 'not found' }); }
      if (path.startsWith('/api/dashboards/') && method === 'DELETE') { deleteDashboard(path.split('/').pop()); return send(res, 200, { ok: true }); }

      // ---- custom metric definitions ----
      if (path === '/api/custom-metrics' && method === 'GET')
        return send(res, 200, { metrics: cfg.customMetrics });
      if (path === '/api/custom-metrics' && method === 'POST') { const b = await readBody(req);
        const id = b.id || ('cm-' + randomUUID().slice(0, 8));
        const def = { id, name: b.name || id, match: b.match || {}, unit: b.unit || 'events' };
        getDb().prepare(`INSERT INTO custom_metrics(id,name,match_json,unit,created) VALUES(?,?,?,?,?)
          ON CONFLICT(id) DO UPDATE SET name=excluded.name, match_json=excluded.match_json, unit=excluded.unit`)
          .run(id, def.name, JSON.stringify(def.match), def.unit, Date.now());
        const i = cfg.customMetrics.findIndex((m) => m.id === id);
        if (i >= 0) cfg.customMetrics[i] = def; else cfg.customMetrics.push(def);
        return send(res, 200, def); }
      if (path.startsWith('/api/custom-metrics/') && method === 'DELETE') { const id = path.split('/').pop();
        getDb().prepare('DELETE FROM custom_metrics WHERE id=?').run(id);
        cfg.customMetrics = cfg.customMetrics.filter((m) => m.id !== id); return send(res, 200, { ok: true }); }

      // ---- static ----
      let file = path === '/' ? '/index.html' : path;
      const full = normalize(join(webDir, file));
      if (!full.startsWith(webDir)) return send(res, 403, 'forbidden', 'text/plain');
      try { const data = await readFile(full); return send(res, 200, data, MIME[extname(full)] || 'application/octet-stream'); }
      catch { return send(res, 404, { error: 'not found' }); }
    } catch (e) {
      console.error('[api]', e); return send(res, 500, { error: e.message });
    }
  });

  server.listen(cfg.http.port, () => console.log(`[api] UI + REST on http://0.0.0.0:${cfg.http.port}`));
  return server;
}

function mask(s) { if (!s) return null; return s.length <= 6 ? '••••' : s.slice(0, 3) + '••••' + s.slice(-2); }
