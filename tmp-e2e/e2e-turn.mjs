import WebSocket from 'ws';

const URL = process.env.RACP_URL || 'ws://127.0.0.1:19445/v1/racp/ws';
const PAIR_TOKEN = process.env.PAIR_TOKEN;
const API_KEY = process.env.DEEPSEEK_KEY;
const BASE_URL = process.env.DEEPSEEK_BASE || 'https://api.deepseek.com';
const MODEL_ID = process.env.DEEPSEEK_MODEL || 'deepseek-chat';

function connect(token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL, { headers: { Authorization: `Bearer ${token}` } });
    ws.once('open', () => resolve(ws));
    ws.once('error', reject);
  });
}

function makeRpc(ws) {
  let id = 1;
  const pending = new Map();
  ws.on('message', (raw) => {
    let f;
    try { f = JSON.parse(raw.toString()); } catch { return; }
    if (f.id != null && pending.has(f.id)) {
      const { resolve, reject, timer } = pending.get(f.id);
      pending.delete(f.id);
      clearTimeout(timer);
      if (f.error) reject(new Error('RPC_ERROR ' + JSON.stringify(f.error)));
      else resolve(f.result);
    }
  });
  return (method, params = {}, timeoutMs = 60000) =>
    new Promise((resolve, reject) => {
      const i = id++;
      const timer = setTimeout(() => { if (pending.has(i)) { pending.delete(i); reject(new Error('TIMEOUT ' + method)); } }, timeoutMs);
      pending.set(i, { resolve, reject, timer });
      ws.send(JSON.stringify({ jsonrpc: '2.0', id: i, method, params }));
    });
}

const log = (...a) => console.log(...a);

(async () => {
  let ws;
  let rpc;
  let deviceId;
  let createdProvider = null;
  let createdSession = null;
  let exitCode = 0;
  try {
    const ws0 = await connect(PAIR_TOKEN);
    const rpc0 = makeRpc(ws0);
    await rpc0('connection/initialize', { client: { name: 'e2e-cli', version: '1', capabilities: {} }, protocolVersion: '2.0.0' });
    const paired = await rpc0('connection/pair', { deviceLabel: 'e2e-cli' });
    deviceId = paired.deviceId;
    log('PAIRED', paired.deviceId.slice(0, 8), paired.hostId);
    ws0.close();

    ws = await connect(paired.deviceToken);
    rpc = makeRpc(ws);
    await rpc('connection/ping', {});

    let providers = (await rpc('provider/list', {})).providers;
    let provider = providers.find((p) => (p.baseUrl || '').includes('deepseek.com'));
    if (!provider) {
      provider = (await rpc('provider/create', {
        provider: {
          name: 'DeepSeek',
          vendorKey: 'deepseek-e2e',
          type: 'openai_compatible',
          protocol: 'openai_completions',
          baseUrl: BASE_URL,
          authKind: 'api_key',
          apiKey: API_KEY,
          models: [{
            id: MODEL_ID,
            displayName: MODEL_ID,
            contextWindow: 128000,
            maxTokens: 8192,
            thinkingLevels: [],
            defaultThinkingLevel: null,
            supportsImages: false
          }]
        },
        context: { requestId: 'req_provider' }
      })).provider;
      createdProvider = provider;
    }
    log('PROVIDER', provider.id.slice(0, 8), provider.name, JSON.stringify(provider.models?.map((m) => m.id)));

    const projects = (await rpc('project/list', {})).projects;
    log('PROJECTS', JSON.stringify(projects.map((p) => ({ id: p.id, label: p.label }))));
    const project = projects[0];
    if (!project) throw new Error('no project');

    const session = (await rpc('session/create', {
      projectId: project.id,
      title: 'DeepSeek E2E ' + new Date().toISOString(),
      providerId: provider.id,
      modelId: MODEL_ID,
      permissionMode: 'auto',
      context: { requestId: 'req_session' }
    })).session;
    createdSession = session;
    log('SESSION', session.id.slice(0, 8), 'provider=' + String(session.providerId).slice(0, 8), 'model=' + session.modelId, 'mode=' + session.permissionMode);

    const events = [];
    ws.on('message', (raw) => {
      let f;
      try { f = JSON.parse(raw.toString()); } catch { return; }
      if (f.method === 'events/event') events.push(f.params.event);
    });
    await rpc('events/subscribe', { scope: 'session', sessionId: session.id });

    const turn = await rpc('turn/start', {
      sessionId: session.id,
      input: { text: '用一句话介绍你自己，然后说你看到的模型名。', attachments: [] },
      context: { requestId: 'req_turn' }
    });
    log('TURN_START', turn.turn ? turn.turn.id.slice(0, 8) : 'unknown');

    const deadline = Date.now() + 120000;
    let terminal = null;
    while (Date.now() < deadline) {
      terminal = events.find((e) => e.kind === 'turn.completed' || e.kind === 'turn.failed') || null;
      if (terminal) break;
      await new Promise((r) => setTimeout(r, 500));
    }
    if (!terminal) throw new Error('TIMEOUT waiting for turn terminal event');
    if (terminal.kind !== 'turn.completed') throw new Error('turn failed: ' + terminal.kind);
    const attach = await rpc('session/attach', { sessionId: session.id });
    // Only counts: never print message bodies, tool output or credentials.
    log('ITEMS', (attach.snapshot.items || []).length);
    log('FINAL_KINDS', events.map((e) => e.kind).join(','));
  } catch (error) {
    console.error('E2E_FAILED', error && error.message ? error.message : String(error));
    exitCode = 1;
  } finally {
    // Best-effort cleanup of everything this probe created. Failures are
    // reported so operators can clean up manually; they do not mask the result.
    if (rpc) {
      if (createdSession) {
        try {
          await rpc('session/delete', {
            sessionId: createdSession.id,
            confirmSessionId: createdSession.id,
            context: { requestId: 'cleanup_session' }
          });
        } catch (error) { console.error('CLEANUP_SESSION_FAILED', error.message); }
      }
      if (createdProvider) {
        try {
          await rpc('provider/delete', {
            providerId: createdProvider.id,
            confirmProviderId: createdProvider.id,
            context: { requestId: 'cleanup_provider' }
          });
        } catch (error) { console.error('CLEANUP_PROVIDER_FAILED', error.message); }
      }
      if (deviceId) {
        try { await rpc('connection/revoke', { deviceId }); }
        catch (error) { console.error('CLEANUP_DEVICE_FAILED', error.message); }
      }
    }
    if (ws) ws.close();
  }
  process.exit(exitCode);
})().catch((e) => { console.error('FATAL', e && e.stack || e); process.exit(1); });
