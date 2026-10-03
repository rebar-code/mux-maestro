// A stand-in for the Mac app, for tests and screenshots: it serves the built
// bundle and the same JSON API, from demo data only.
//
//   PORT=5199 node e2e/fixture-server.mjs
//
// Test hooks (POST): /__fixture/reset, /__fixture/wait?id=, /__fixture/say?id=&text=,
// /__fixture/grouping?value=, /__fixture/deny?on=1, /__fixture/rotate?value=, /__fixture/drop,
// /__fixture/capability?name=&on=, /__fixture/manager-status?value=,
// /__fixture/mac-turn?text=&reply=, /__fixture/voice?mode=&speaker=&heard=&delay=,
// /__fixture/voice-takes, /__fixture/replies, /__fixture/prompt?id=&pid=&kind=,
// /__fixture/upload-max?value=, /__fixture/status?id=&value=, /__fixture/panes?id=&value=,
// /__fixture/prompt also takes truncated=1, bare=1 (an id with no choices), quiet=1,
// /__fixture/not-sent?cleared=&reason=, /__fixture/no-input?id=&on=, /__fixture/pasted?on=,
// /__fixture/serve-fails?code=, /__fixture/mappings (what the phone asked to publish),
// /__fixture/tailnet?name= (publish under that name, for screenshots)
//
// Every /api/ request needs the header `X-MuxMaestro-Token: demo-token`.
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { crc32, deflateSync } from 'node:zlib';

const ROOT = resolve(
	fileURLToPath(new URL('.', import.meta.url)),
	'../../app/MuxMaestro/Resources/mobile'
);
const PORT = Number(process.env.PORT);
if (!PORT) throw new Error('Set PORT (claim a free one first).');

const TYPES = {
	'.html': 'text/html; charset=utf-8',
	'.js': 'text/javascript; charset=utf-8',
	'.css': 'text/css; charset=utf-8',
	'.json': 'application/json',
	'.webmanifest': 'application/manifest+json',
	'.png': 'image/png',
	'.svg': 'image/svg+xml'
};

const HOSTS = [
	{
		name: 'localhost',
		color: '#3291ff',
		local: true,
		cpu: 38,
		load1: 3.1,
		cores: 10,
		mem: [21, 32],
		disk: 212
	},
	{
		name: 'devbox',
		color: '#f5a623',
		local: false,
		cpu: 12,
		load1: 0.64,
		cores: 8,
		mem: [9, 64],
		disk: 1434
	},
	{
		name: 'buildbox',
		color: '#a371f7',
		local: false,
		cpu: 71,
		load1: 7.36,
		cores: 8,
		mem: [27, 32],
		disk: 88
	}
];

// [session, window, host, status, prompt, age in seconds, extra]
const AWAKE = [
	[
		'acme-app',
		'checkout-fix',
		'localhost',
		'waiting',
		'fix the failing checkout test and open a PR',
		120
	],
	['billing', 'proration', 'devbox', 'waiting', 'add proration to plan changes', 360],
	['docs-site', 'search', 'localhost', 'busy', 'wire the search box to the new index', 40],
	[
		'acme-app',
		'onboarding-copy',
		'localhost',
		'busy',
		'shorten every step label to two words',
		180
	],
	['infra', 'deploy-fix', 'devbox', 'busy', 'find why the staging deploy times out', 300],
	['mobile', 'push-tokens', 'localhost', 'busy', 'rotate expired push tokens nightly', 540],
	['acme-app', 'dark-mode', 'localhost', 'idle', 'audit contrast on the settings page', 840],
	['reports', 'csv-export', 'buildbox', 'idle', 'export should stream, not buffer', 1860],
	['billing', 'invoices-pdf', 'localhost', 'idle', 'PR is open, waiting on review', 3120, 'yawning']
];
const ASLEEP = [
	'acme-app · flaky-e2e',
	'docs-site · redirects',
	'infra · log-retention',
	'reports · charts',
	'mobile · deep-links',
	'billing · tax-ids',
	'acme-app · a11y-pass',
	'infra · backups',
	'docs-site · changelog',
	'reports · filters',
	'mobile · offline',
	'acme-app · search-rank',
	'billing · coupons',
	'infra · alerts'
];

const CHATS = {
	'localhost:1': [
		['user', 'fix the failing checkout test and open a PR'],
		[
			'assistant',
			'The test fails because the tax line renders after the total is read. I will wait for the tax row before the assertion.'
		],
		['tool', 'tests/checkout.spec.ts', 'Read'],
		['tool', 'tests/checkout.spec.ts', 'Edit'],
		['assistant', 'Edited. The page is up on the dev server.'],
		['assistant', 'I need to run the spec to confirm it passes.']
	]
};

// The thread with artifacts and servers.
const MAKER = 'localhost:6';
CHATS[MAKER] = [
	['user', 'rotate expired push tokens nightly, and show the last run on the settings page'],
	[
		'assistant',
		'The job is in place. I will add the last run to the settings page and write the plan down.'
	],
	['tool', 'PLAN.md', 'Write'],
	['tool', 'src/jobs/rotate-tokens.ts', 'Edit'],
	['assistant', 'Edited. The page is up on the dev server at localhost:5173.'],
	['tool', 'pnpm exec playwright screenshot localhost:5173/settings', 'Bash'],
	['assistant', 'Here is the page after the change: settings-after.png'],
	['tool', 'pnpm exec vitest run --coverage', 'Bash'],
	['assistant', 'Coverage is in coverage/index.html. Docs: https://example.com/docs/push-tokens'],
	// Enough rows after the files that the chat scrolls.
	...Array.from({ length: 14 }, (_, i) => [
		i % 2 ? 'assistant' : 'tool',
		i % 2 ? `Run ${(i + 1) / 2} of 7 passed.` : 'pnpm exec vitest run src/jobs',
		...(i % 2 ? [] : ['Bash'])
	])
];

/** A PNG of `width` × `height`: a white page with a few grey rows, like a settings screen. */
function png(width, height) {
	const row = 1 + width * 3;
	const raw = Buffer.alloc(row * height, 0xff);
	const fill = (x0, y0, w, h, [r, g, b]) => {
		for (let y = y0; y < y0 + h; y += 1) {
			raw[y * row] = 0;
			for (let x = x0; x < x0 + w; x += 1) raw.set([r, g, b], y * row + 1 + x * 3);
		}
	};
	for (let y = 0; y < height; y += 1) raw[y * row] = 0;
	fill(0, 0, width, 56, [17, 17, 17]);
	fill(24, 20, 140, 16, [237, 237, 237]);
	for (let i = 0; i < 4; i += 1) {
		fill(24, 92 + i * 64, width - 200, 14, [40, 40, 40]);
		fill(width - 120, 88 + i * 64, 96, 22, i === 1 ? [50, 145, 255] : [220, 220, 220]);
		fill(24, 132 + i * 64, width - 48, 1, [232, 232, 232]);
	}
	const chunk = (type, data) => {
		const body = Buffer.concat([Buffer.from(type), data]);
		const out = Buffer.alloc(body.length + 8);
		out.writeUInt32BE(data.length, 0);
		body.copy(out, 4);
		out.writeUInt32BE(crc32(body), out.length - 4);
		return out;
	};
	const head = Buffer.alloc(13);
	head.writeUInt32BE(width, 0);
	head.writeUInt32BE(height, 4);
	head.set([8, 2, 0, 0, 0], 8);
	return Buffer.concat([
		Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
		chunk('IHDR', head),
		chunk('IDAT', deflateSync(raw)),
		chunk('IEND', Buffer.alloc(0))
	]);
}

const PLAN = `---
owner: me
---

# Plan

Rotate push tokens that expired, every night.

- Add \`rotateExpired()\` to the nightly job
- Show the last run on the settings page
- Run the spec 20 times

\`\`\`ts
export async function rotateExpired(now: Date): Promise<number> {
	const expired = await tokens.where('expiresAt', '<', now);
	return (await Promise.all(expired.map(rotate))).length;
}
\`\`\`

<script>document.title = 'markdown script ran'</script>

[Docs](https://example.com/docs/push-tokens)
`;

// The script must not run on the phone: the frame is sandboxed.
const COVERAGE = `<!doctype html><html><head><title>Coverage</title><style>
body{font:15px -apple-system,system-ui,sans-serif;margin:0;padding:26px 20px;color:#111;background:#fff}
h2{margin:0 0 18px;font-size:24px}.ln{display:flex;justify-content:space-between;padding:12px 0;border-bottom:1px solid #e8e8e8}
</style></head><body><h2>Coverage</h2>
<div class="ln"><span>src/jobs</span><span>94%</span></div>
<div class="ln"><span>src/settings</span><span>88%</span></div>
<div class="ln"><span>src/push</span><span>71%</span></div>
<p id="probe">Generated nightly</p>
<script>
document.getElementById('probe').textContent = 'script ran';
parent.postMessage('artifact-script-ran', '*');
fetch('/api/config').then(() => parent.postMessage('artifact-fetched', '*'));
</script>
<img src="/icon-192.png" alt="">
</body></html>`;

const JOB = `import { tokens } from '../push/store';

/** Rotate every push token that expired before \`now\`. */
export async function rotateExpired(now: Date): Promise<number> {
	const expired = await tokens.where('expiresAt', '<', now);
	const rotated = await Promise.all(expired.map((token) => tokens.rotate(token.id, { reason: 'expired', at: now })));
	return rotated.length;
}
`;

const ROOT_DIR = '/Users/me/code/mobile';
const artifactId = (path) => createHash('sha256').update(path).digest('hex').slice(0, 32);
// [name, dir, kind, mime, age in seconds, bytes]
const FILES = [
	['settings-after.png', '/tmp', 'image', 'image/png', 180, png(780, 520)],
	[
		'index.html',
		`${ROOT_DIR}/coverage`,
		'html',
		'text/html; charset=utf-8',
		120,
		Buffer.from(COVERAGE)
	],
	['PLAN.md', ROOT_DIR, 'markdown', 'text/plain; charset=utf-8', 720, Buffer.from(PLAN)],
	[
		'rotate-tokens.ts',
		`${ROOT_DIR}/src/jobs`,
		'code',
		'text/plain; charset=utf-8',
		660,
		Buffer.from(JOB)
	],
	['old-notes.txt', ROOT_DIR, 'text', 'text/plain; charset=utf-8', 4000, null]
].map(([name, dir, kind, mime, age, bytes]) => ({
	id: artifactId(`${dir}/${name}`),
	name,
	dir,
	kind,
	mime,
	age,
	bytes
}));

const artifactsBody = (thread) =>
	thread.id !== MAKER
		? { files: [], links: [], remote: !thread.local }
		: {
				files: [...FILES]
					.sort((a, b) => a.age - b.age)
					.map(({ bytes, age, ...file }) => ({
						...file,
						size: bytes ? bytes.length : null,
						at: started - age,
						exists: bytes !== null
					})),
				links: [
					{
						url: 'https://example.com/docs/push-tokens',
						host: 'example.com',
						path: '/docs/push-tokens',
						at: started - 60
					}
				],
				remote: false
			};

// What the thread runs: [port, mappable].
const link = (label, port, open = true) => ({ label, port, open, mappable: open });
const runningBody = (thread) =>
	thread.id !== MAKER
		? { known: true, unknowns: [], servers: [], stacks: [], containers: [] }
		: {
				known: false,
				unknowns: ['Docker unavailable on devbox'],
				servers: [
					{
						key: 'localhost|server|5173',
						label: 'mobile',
						host: 'localhost',
						local: true,
						port: 5173,
						https: true,
						mappable: true
					},
					{
						key: 'localhost|server|6006',
						label: 'storybook',
						host: 'localhost',
						local: true,
						port: 6006,
						https: false,
						mappable: true
					}
				],
				stacks: [
					{
						key: 'localhost|container|mobile',
						label: 'mobile',
						host: 'localhost',
						local: true,
						count: 10,
						links: [
							link('Studio', 54323),
							link('API', 54321),
							link('DB', 54322, false),
							link('Mail', 54324)
						]
					}
				],
				containers: [
					{
						key: 'localhost|container|acme-redis',
						label: 'acme-redis',
						host: 'localhost',
						local: true,
						count: 1,
						links: [link('', 6379)]
					},
					{
						key: 'devbox|container|mailpit',
						label: 'mailpit',
						host: 'devbox',
						local: false,
						count: 1,
						links: [{ label: '', port: 8025, open: true, mappable: false }]
					}
				]
			};
const MAX_MAPPINGS = 5;
const runningPorts = (thread) => {
	const running = runningBody(thread);
	return new Map(
		[
			...running.servers.map((s) => [s.port, s.mappable && s.label]),
			...[...running.stacks, ...running.containers].flatMap((c) =>
				c.links.map((l) => [l.port, l.mappable && (l.label ? `${c.label} ${l.label}` : c.label)])
			)
		].filter(([, label]) => label)
	);
};

function serversApi(req, res, path, body) {
	if (!capabilities.localServers) return send(res, 403, { error: 'disabled' });
	const list = () => ({
		mappings: [...mappings].sort((a, b) => a.port - b.port),
		max: MAX_MAPPINGS
	});
	if (path === '/api/servers')
		return req.method === 'GET'
			? send(res, 200, list())
			: send(res, 405, { error: 'method_not_allowed' });
	if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' });
	let ask;
	try {
		ask = JSON.parse(body);
	} catch {
		return send(res, 400, { error: 'bad_request' });
	}
	if (!Number.isInteger(ask?.port) || ask.port < 0 || ask.port > 65535)
		return send(res, 400, { error: 'bad_request' });
	if (path === '/api/servers/close') {
		const before = mappings.length;
		mappings = mappings.filter((m) => m.port !== ask.port);
		return mappings.length < before
			? send(res, 200, { ok: true })
			: send(res, 404, { error: 'not_found' });
	}
	if (path !== '/api/servers/open') return send(res, 404, { error: 'not_found' });
	const thread = threads.find((t) => t.id === ask.thread);
	if (!thread) return send(res, 404, { error: 'not_found' });
	const label = runningPorts(thread).get(ask.port);
	if (!label) return send(res, 404, { error: 'not_running' });
	if (ask.port === PORT || ask.port < 1024) return send(res, 403, { error: 'refused' });
	if (serveFails) {
		const code = serveFails;
		serveFails = null;
		tailnet = null;
		return send(res, code === 'unavailable' ? 503 : 409, {
			error: code,
			message:
				code === 'taken' ? `Tailscale already serves port ${ask.port}` : 'tailscale serve failed'
		});
	}
	// Without a name, the address is a page of the fixture, so a test can open it.
	const url = tailnet
		? `https://${tailnet}:${ask.port}/`
		: `http://127.0.0.1:${PORT}/__mapped/${ask.port}/`;
	if (!mappings.some((m) => m.port === ask.port)) {
		if (mappings.length >= MAX_MAPPINGS)
			return send(res, 409, { error: 'limit', message: `${MAX_MAPPINGS} ports are open already` });
		mappings.push({ port: ask.port, url, thread: thread.id, label });
	}
	return send(res, 200, { port: ask.port, url });
}

function fileApi(res, url, thread) {
	const file = thread.id === MAKER && FILES.find((f) => f.id === url.searchParams.get('id'));
	if (!file || !file.bytes) return send(res, 404, { error: 'not_found' });
	res.writeHead(200, {
		'content-type': file.mime,
		'cache-control': 'no-store',
		'x-content-type-options': 'nosniff',
		'content-security-policy':
			"sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:",
		'content-disposition': 'attachment',
		'cross-origin-resource-policy': 'same-origin'
	});
	res.end(file.bytes);
}

// Why each waiting thread waits, as the manager's "Needs you" list says it.
const REASONS = { 'localhost:1': 'Permission · Bash', 'devbox:2': 'Question' };

// What each waiting pane asks. A thread made to wait later asks the first one.
const PERMISSION = {
	kind: 'permission',
	title: 'Bash command',
	detail: 'pnpm exec playwright test tests/checkout.spec.ts',
	question: 'Do you want to proceed?',
	options: [
		{ n: 1, label: 'Yes' },
		{ n: 2, label: 'Yes, and don’t ask again for pnpm exec' },
		{ n: 3, label: 'No, and tell Claude what to do differently' }
	]
};
const QUESTION = {
	kind: 'question',
	title: '',
	detail: '',
	question: 'Which rule should a plan downgrade use?',
	options: [
		{ n: 1, label: 'Credit the unused days' },
		{ n: 2, label: 'No credit until renewal' },
		{ n: 3, label: 'Type something else' }
	]
};
const LONG_COMMAND =
	'kubectl rollout restart deploy/web -n staging && kubectl rollout status deploy/web -n staging --timeout=120s && kubectl get pods -n staging -l app=web -o wide';
const PROMPTS = { 'localhost:1': PERMISSION, 'devbox:2': QUESTION };

const COMMANDS = [
	{ name: 'clear', description: 'Start a new conversation', source: 'builtin' },
	{ name: 'compact', description: 'Summarize the conversation so far', source: 'builtin' },
	{ name: 'commit', description: 'Create a git commit', source: 'skill' },
	{ name: 'code-review', description: 'Review the current diff', source: 'skill' },
	{ name: 'deploy-staging', description: 'Deploy this branch to staging', source: 'command' },
	{ name: 'review', description: 'Review a pull request', source: 'builtin' },
	{ name: 'security-review', description: 'Check the pending changes', source: 'builtin' }
];

const KEY_NAMES = /^(Enter|Escape|Up|Down|Left|Right|Tab|BTab|C-[a-z]|[1-9])$/;
// The Mac pastes text into a terminal: no control characters but newline and tab.
// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/;
const TEXT_MAX = 8192;

const DEMO_TOKEN = 'demo-token';
let started, threads, chats, grouping, deny, token, capabilities, manager, voice;
// Per thread id: the prompt on the pane. And everything the phone wrote.
let prompts, replies, uploadMax, promptSeq, notSent, noInput, pasted, keyLocks;
// Makes one thread row; set by `reset`, used again for a new window or session.
let makeThread;
// The ports published on the tailnet, and how the next publish is refused.
let mappings, serveFails, tailnet;
const streams = new Set();

function reset() {
	started = Math.floor(Date.now() / 1000);
	grouping = 'recent';
	deny = false;
	token = DEMO_TOKEN;
	capabilities = {
		manager: true,
		voice: false,
		replies: false,
		keyBar: false,
		upload: false,
		sessionActions: false,
		kill: false,
		find: false,
		artifacts: false,
		localServers: false
	};
	mappings = [];
	serveFails = null;
	prompts = {};
	// How the next text is refused after its paste, the panes with no input
	// box, whether an upload's path reaches the pane, and the keys in flight.
	notSent = null;
	noInput = new Set();
	pasted = true;
	keyLocks = new Set();
	promptSeq = 0;
	uploadMax = 10485760;
	replies = {
		texts: [],
		keys: [],
		answers: [],
		uploads: [],
		left: [],
		actions: [],
		commandFetches: 0
	};
	// The Mac's voice defaults, what the next take is heard as, how long the
	// Mac "thinks" before it has the transcript, and every take it was sent.
	voice = { mode: 'manual', speaker: true, heard: 'What needs me?', delay: 300, takes: [] };
	manager = {
		status: 'idle',
		turn: null,
		chat: [
			{
				n: 0,
				role: 'assistant',
				text: 'Two threads need you. Four are running. Nothing has failed in the last hour.'
			}
		],
		updates: [
			{
				kind: 'done',
				text: 'Search box wired to the new index',
				at: started - 240,
				host: 'localhost',
				session: 'docs-site',
				thread: 'localhost:3'
			},
			{
				kind: 'notification',
				text: 'Nightly build is green',
				at: started - 1500,
				host: '',
				session: '',
				thread: null
			}
		],
		review: [
			{
				key: 'billing:invoices-pdf',
				title: 'billing',
				detail: 'PR open 52m, CI green, no review yet',
				severity: 'warn',
				at: started - 3120,
				thread: 'localhost:9'
			}
		]
	};
	const color = (host) => HOSTS.find((h) => h.name === host).color;
	const make = (n, session, name, host, status, prompt, ageSeconds, idleStage) => {
		const local = host === 'localhost';
		return {
			id: `${host}:${n}`,
			host,
			hostColor: color(host),
			local,
			session,
			window: n,
			name,
			pane: `%${n}`,
			panes: 1,
			command: local ? 'claude' : 'zsh',
			cwd: `${local ? '/Users/me' : '/home/me'}/code/${session}`,
			status,
			since: started - ageSeconds,
			idleStage,
			lastPrompt: prompt ? { text: prompt, at: started - ageSeconds } : null,
			lastActivityAt: local ? started - ageSeconds : null,
			sessionActivity: started - ageSeconds,
			chat: local
		};
	};
	makeThread = make;
	threads = [
		...AWAKE.map(([s, w, h, st, p, a, stage], i) =>
			make(i + 1, s, w, h, st, p, a, stage ?? 'awake')
		),
		...ASLEEP.map((name, i) => {
			const [s, w] = name.split(' · ');
			return make(
				100 + i,
				s,
				w,
				i % 4 === 1 ? 'devbox' : 'localhost',
				'idle',
				'',
				(2 + i) * 3600,
				'dozing'
			);
		})
	];
	chats = {};
	for (const t of threads.filter((t) => t.chat)) {
		const lines = CHATS[t.id] ?? [
			['user', t.lastPrompt?.text ?? 'continue'],
			['tool', `"${t.name}"`, 'Grep'],
			['tool', 'src/index.ts', 'Read'],
			[
				'assistant',
				t.status === 'busy'
					? 'Working on it. 3 files changed so far.'
					: 'Done. 4 files changed, tests pass. Nothing else is needed from you.'
			]
		];
		chats[t.id] = lines.map(([role, text, tool], n) => ({
			n,
			role,
			text,
			...(tool ? { tool } : {})
		}));
	}
}
reset();

const GB = 1024 ** 3;
const hostsBody = () => ({
	hosts: HOSTS.map((h) => ({
		name: h.name,
		color: h.color,
		local: h.local,
		reachability: 'reachable',
		threads: threads.filter((t) => t.host === h.name).length,
		stats: {
			cpuPercent: h.cpu,
			load1: h.load1,
			cores: h.cores,
			memUsedBytes: h.mem[0] * GB,
			memTotalBytes: h.mem[1] * GB,
			diskFreeBytes: h.disk * GB,
			diskTotalBytes: 2000 * GB,
			uptimeSeconds: 432000
		}
	}))
});
const threadsBody = () => ({ threads });
const configBody = () => ({
	capabilities: {
		access: true,
		manager: capabilities.manager,
		voice: capabilities.voice,
		replies: capabilities.replies,
		keyBar: capabilities.keyBar,
		upload: capabilities.upload,
		sessionActions: capabilities.sessionActions,
		kill: capabilities.kill,
		find: capabilities.find,
		artifacts: capabilities.artifacts,
		localServers: capabilities.localServers,
		stopServers: false,
		notifications: false,
		liveTerminal: false
	},
	grouping,
	voice: { mode: voice.mode, speaker: voice.speaker, maxSeconds: 120 },
	upload: { maxBytes: uploadMax }
});

const nowSeconds = () => Math.floor(Date.now() / 1000);

/** The prompt on a waiting thread's pane, made the first time it is asked for. */
function promptOf(thread) {
	// A pane can show a prompt while its status says nothing of it.
	if (prompts[thread.id] === undefined) {
		if (thread.status !== 'waiting') return null;
		promptSeq += 1;
		prompts[thread.id] = {
			id: `p${promptSeq}-${thread.window}`,
			...(PROMPTS[thread.id] ?? PERMISSION),
			truncated: false
		};
	}
	return prompts[thread.id];
}

/** The body of `GET /prompt`: an id alone when the pane shows no readable choices. */
function promptBody(thread) {
	const asked = promptOf(thread);
	if (!asked) return { prompt: null, id: null };
	// `bare` and `full` are the fixture's own notes.
	const prompt = { ...asked };
	delete prompt.bare;
	delete prompt.full;
	return { prompt: asked.bare ? null : prompt, id: asked.id };
}

function setStatus(thread, status) {
	Object.assign(thread, { status, since: nowSeconds(), idleStage: 'awake' });
	if (status !== 'waiting') delete prompts[thread.id];
	push('threads', threadsBody());
	if (capabilities.manager) push('manager', managerLive());
}

const chatRow = (thread, role, text) => {
	const rows = chats[thread.id];
	if (rows) rows.push({ n: rows.length, role, text });
};

/** The pane's 409 while it cannot take free text, or `null`. */
function refusedBy(thread) {
	if (thread.status === 'busy')
		return { error: 'busy', message: `${thread.name} is running a turn` };
	if (thread.status === 'waiting' || promptOf(thread))
		return { error: 'waiting', message: `${thread.name} is waiting on a prompt` };
	if (noInput.has(thread.id)) return { error: 'no_input', message: 'Thread shows no input box' };
	return null;
}

const threadReply = (text) => `Done: ${text}. 2 files changed, tests pass.`;

/** One turn of a demo thread: busy, the reply word by word, then idle. */
function runThreadTurn(thread, text, onDelta = () => {}, onEnd = () => {}) {
	chatRow(thread, 'user', text);
	thread.lastPrompt = { text, at: nowSeconds() };
	setStatus(thread, 'busy');
	const reply = threadReply(text);
	const words = reply.split(/(?<= )/);
	const mine = threads;
	const step = () => {
		// A reset between two words: the turn belongs to the test before.
		if (threads !== mine) return onEnd(reply);
		const word = words.shift();
		if (word === undefined) {
			chatRow(thread, 'assistant', reply);
			setStatus(thread, 'idle');
			return onEnd(reply);
		}
		onDelta(word);
		setTimeout(step, 40);
	};
	setTimeout(step, 250);
}

function replyApi(req, res, url, thread, route, body) {
	const needs = route === 'key' ? 'keyBar' : route === 'upload' ? 'upload' : 'replies';
	// The key bar names the prompt in its keys, so it may read the prompt too.
	const allowed =
		route === 'prompt' ? capabilities.replies || capabilities.keyBar : capabilities[needs];
	if (!allowed) return send(res, 403, { error: 'disabled' });
	const reads = route === 'prompt' || route === 'commands';
	if (req.method !== (reads ? 'GET' : 'POST'))
		return send(res, 405, { error: 'method_not_allowed' });
	if (!thread) return send(res, 404, { error: 'not_found' });
	if (route === 'prompt') return send(res, 200, promptBody(thread));
	if (route === 'commands') {
		replies.commandFetches += 1;
		return send(res, 200, { commands: COMMANDS });
	}
	if (route === 'upload') {
		const name = url.searchParams.get('name');
		if (!name || name.includes('/') || body.length === 0)
			return send(res, 400, { error: 'bad_request' });
		if (body.length > uploadMax) return send(res, 413, { error: 'too_large' });
		const refused = refusedBy(thread);
		if (refused) return send(res, 409, refused);
		replies.uploads.push({
			thread: thread.id,
			name,
			bytes: body.length,
			type: req.headers['content-type'] ?? null,
			text: body.length <= 256 ? body.toString('utf8') : null
		});
		return send(res, 200, { ok: true, path: `${thread.cwd}/${name}`, pasted });
	}
	let json = {};
	try {
		json = JSON.parse(String(body));
	} catch {
		// Not JSON: the checks below answer 400.
	}
	if (route === 'key') {
		if (typeof json.key !== 'string' || !KEY_NAMES.test(json.key))
			return send(res, 400, { error: 'bad_key' });
		if (json.prompt !== undefined && typeof json.prompt !== 'string')
			return send(res, 400, { error: 'bad_request' });
		// One write to a thread at a time: a second key while one is in flight is refused.
		if (keyLocks.has(thread.id))
			return send(res, 409, { error: 'busy', message: `${thread.name} is taking a key` });
		// The pane waits on a prompt the phone did not name: the key could answer the wrong one.
		const asked = promptOf(thread);
		if (asked && asked.id !== json.prompt) return send(res, 409, { error: 'stale' });
		keyLocks.add(thread.id);
		const locks = keyLocks;
		return void setTimeout(() => {
			locks.delete(thread.id);
			replies.keys.push({
				thread: thread.id,
				key: json.key,
				...(json.prompt === undefined ? {} : { prompt: json.prompt })
			});
			send(res, 200, { ok: true });
		}, 30);
	}
	if (route === 'answer') {
		if (typeof json.prompt !== 'string' || !Number.isInteger(json.option))
			return send(res, 400, { error: 'bad_request' });
		const prompt = promptOf(thread);
		if (!prompt || prompt.id !== json.prompt) return send(res, 409, { error: 'stale' });
		if (!prompt.options.some((option) => option.n === json.option))
			return send(res, 400, { error: 'bad_request' });
		replies.answers.push({ thread: thread.id, prompt: json.prompt, option: json.option });
		setStatus(thread, 'busy');
		return send(res, 200, { ok: true });
	}
	// text
	const text = typeof json.text === 'string' ? json.text.trim() : '';
	if (!text || CONTROL.test(text)) return send(res, 400, { error: 'bad_request' });
	if (Buffer.byteLength(text) > TEXT_MAX) return send(res, 413, { error: 'too_large' });
	const refused = refusedBy(thread);
	if (refused) return send(res, 409, refused);
	if (notSent) {
		// Pasted, not submitted. The Mac tried to take it out of the input box again.
		const { cleared, reason } = notSent;
		notSent = null;
		if (!cleared) replies.left.push({ thread: thread.id, text });
		return send(res, 409, {
			error: 'not_sent',
			reason,
			message: `${thread.name} did not take the reply`,
			cleared
		});
	}
	replies.texts.push({ thread: thread.id, text });
	runThreadTurn(thread, text);
	return send(res, 200, { ok: true });
}

const managerLive = () => ({
	needsYou: threads
		.filter((t) => t.status === 'waiting')
		.map((t) => ({
			key: null,
			title: `${t.session} · ${t.name}`,
			detail: REASONS[t.id] ?? 'Needs you',
			severity: null,
			at: t.since,
			thread: t.id
		})),
	review: manager.review,
	updates: manager.updates,
	turn: manager.turn
});
const managerBody = () => ({
	...managerLive(),
	status: manager.turn ? 'busy' : manager.status,
	chat: { messages: manager.chat, next: manager.chat.length, reset: false }
});
const say = (role, text) => manager.chat.push({ n: manager.chat.length, role, text });

/** What the demo manager answers: the threads that wait. */
function managerReply() {
	const waiting = threads.filter((t) => t.status === 'waiting');
	if (!waiting.length) {
		const busy = threads.filter((t) => t.status === 'busy').length;
		return `Nothing needs you. ${busy} threads are running.`;
	}
	return `${waiting.length} threads need you: ${waiting.map((t) => `${t.session} · ${t.name}`).join(', ')}.`;
}

/** Run one turn word by word. `onDelta` and `onEnd` are for the caller's own stream. */
function runTurn(prompt, reply, onDelta = () => {}, onEnd = () => {}) {
	manager.turn = { prompt, reply: '' };
	push('manager', managerLive());
	const words = reply.split(/(?<= )/);
	const mine = manager;
	const step = () => {
		// A reset between two words: the turn belongs to the test before.
		if (manager !== mine) return onEnd();
		const word = words.shift();
		if (word === undefined) {
			say('user', prompt);
			say('assistant', reply);
			manager.turn = null;
			onEnd();
			push('manager', managerLive());
			return;
		}
		manager.turn = { prompt, reply: manager.turn.reply + word };
		onDelta(word);
		// The reply grows by a small event; the board is not sent again.
		push('manager-delta', { text: word });
		setTimeout(step, 40);
	};
	setTimeout(step, 150);
}

/** The Mac refuses a write without its header or from another origin. */
function sameOriginWrite(req) {
	const origin = req.headers.origin;
	return (
		req.headers['x-muxmaestro'] !== undefined &&
		origin !== undefined &&
		new URL(origin).host === req.headers.host
	);
}

function managerApi(req, res, path, body) {
	if (!capabilities.manager) return send(res, 403, { error: 'disabled' });
	if (path === '/api/manager') {
		if (req.method !== 'GET') return send(res, 405, { error: 'method_not_allowed' });
		return send(res, 200, managerBody());
	}
	if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' });
	let json = {};
	try {
		json = JSON.parse(body);
	} catch {
		// Not JSON: the checks below answer 400.
	}
	if (path === '/api/manager/dismiss') {
		if (typeof json.key !== 'string') return send(res, 400, { error: 'bad_request' });
		if (!manager.review.some((item) => item.key === json.key))
			return send(res, 404, { error: 'not_found' });
		manager.review = manager.review.filter((item) => item.key !== json.key);
		push('manager', managerLive());
		return send(res, 200, { ok: true });
	}
	if (path !== '/api/manager/text') return send(res, 404, { error: 'not_found' });
	const text = typeof json.text === 'string' ? json.text.trim() : '';
	if (!text || CONTROL.test(text)) return send(res, 400, { error: 'bad_request' });
	if (Buffer.byteLength(text) > TEXT_MAX) return send(res, 413, { error: 'too_large' });
	if (manager.turn) return send(res, 409, { error: 'busy', message: 'A turn is running' });
	if (manager.status === 'waiting')
		return send(res, 409, { error: 'waiting', message: 'Manager is waiting on a prompt' });
	if (manager.status === 'unknown')
		return send(res, 503, { error: 'not_ready', message: 'Manager is not ready' });
	if (manager.status === 'busy')
		return send(res, 409, { error: 'busy', message: 'Manager is busy' });
	res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store' });
	const event = (name, data) => res.write(`event: ${name}\ndata: ${JSON.stringify(data)}\n\n`);
	const reply = managerReply();
	runTurn(
		text,
		reply,
		(word) => event('delta', { text: word }),
		() => {
			event('end', { outcome: 'done', reply, message: null });
			res.end();
		}
	);
}

/** One spoken sentence: a quiet tone as a 24 kHz WAV, like the Mac's clips. */
function clip(seconds) {
	const rate = 24000;
	const count = Math.floor(rate * seconds);
	const wav = Buffer.alloc(44 + count * 2);
	wav.write('RIFF', 0);
	wav.writeUInt32LE(36 + count * 2, 4);
	wav.write('WAVEfmt ', 8);
	wav.writeUInt32LE(16, 16);
	wav.writeUInt16LE(1, 20);
	wav.writeUInt16LE(1, 22);
	wav.writeUInt32LE(rate, 24);
	wav.writeUInt32LE(rate * 2, 28);
	wav.writeUInt16LE(2, 32);
	wav.writeUInt16LE(16, 34);
	wav.write('data', 36);
	wav.writeUInt32LE(count * 2, 40);
	for (let i = 0; i < count; i += 1) {
		wav.writeInt16LE(Math.round(Math.sin((2 * Math.PI * 220 * i) / rate) * 1200), 44 + i * 2);
	}
	return wav.toString('base64');
}

/** What a posted take is: its WAV header, as the Mac would read it. */
function describeTake(body, url) {
	const riff = body.length >= 44 && body.toString('latin1', 0, 4) === 'RIFF';
	const rate = riff ? body.readUInt32LE(24) : 0;
	const samples = riff ? (body.length - 44) / 2 : 0;
	let sum = 0;
	for (let i = 0; i < samples; i += 1) sum += (body.readInt16LE(44 + i * 2) / 32768) ** 2;
	return {
		riff,
		rate,
		channels: riff ? body.readUInt16LE(22) : 0,
		bits: riff ? body.readUInt16LE(34) : 0,
		seconds: rate ? samples / rate : 0,
		// Loudness: a take of silence would be near 0.
		rms: samples ? Math.sqrt(sum / samples) : 0,
		target: url.searchParams.get('target'),
		speaker: url.searchParams.get('speaker') === '1'
	};
}

function voiceApi(req, res, url, body) {
	const path = url.pathname;
	if (!capabilities.voice) return send(res, 403, { error: 'disabled' });
	if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' });
	if (path === '/api/voice/warm') return send(res, 200, { ok: true });
	if (path !== '/api/voice' && path !== '/api/voice/replay')
		return send(res, 404, { error: 'not_found' });
	const target = url.searchParams.get('target');
	const thread = threads.find((t) => t.id === target);
	if (target !== 'manager' && !thread) return send(res, 404, { error: 'not_found' });
	if (!capabilities[thread ? 'replies' : 'manager']) return send(res, 403, { error: 'disabled' });
	const stream = () =>
		res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store' });
	const event = (name, data) => res.write(`event: ${name}\ndata: ${JSON.stringify(data)}\n\n`);
	const speak = (reply) =>
		reply
			.split(/(?<=[.!?:])\s+/)
			.forEach((text, seq) => event('audio', { seq, text, wav: clip(0.9) }));

	if (path === '/api/voice/replay') {
		const said = thread ? (chats[thread.id] ?? []) : manager.chat;
		const reply = said.findLast((message) => message.role === 'assistant')?.text;
		if (!reply) return send(res, 404, { error: 'nothing', message: 'Nothing to replay' });
		stream();
		speak(reply);
		event('end', { outcome: 'done', reply, message: null });
		return res.end();
	}

	const take = describeTake(body, url);
	if (body.length > 4194304) return send(res, 413, { error: 'too_long' });
	if (!take.riff) return send(res, 400, { error: 'bad_audio', message: 'Not a WAV recording' });
	const refused = thread && refusedBy(thread);
	if (refused) return send(res, 409, refused);
	if (!thread) {
		if (manager.turn) return send(res, 409, { error: 'busy', message: 'A turn is running' });
		if (manager.status === 'waiting')
			return send(res, 409, { error: 'waiting', message: 'Manager is waiting on a prompt' });
	}
	voice.takes.push(take);
	stream();
	const { heard, delay } = voice;
	const mine = manager;
	setTimeout(() => {
		if (manager !== mine || res.destroyed) return res.end();
		if (!heard) {
			event('end', { outcome: 'empty', reply: '', message: 'Heard nothing' });
			return res.end();
		}
		event('transcript', { text: heard });
		if (thread) {
			replies.texts.push({ thread: thread.id, text: heard, spoken: true });
			return runThreadTurn(
				thread,
				heard,
				(word) => event('delta', { text: word }),
				(reply) => {
					if (take.speaker) speak(reply);
					event('end', { outcome: 'done', reply, message: null });
					res.end();
				}
			);
		}
		const reply = managerReply();
		runTurn(
			heard,
			reply,
			(word) => event('delta', { text: word }),
			() => {
				if (take.speaker) speak(reply);
				event('end', { outcome: 'done', reply, message: null });
				res.end();
			}
		);
	}, delay);
}

function screen(t) {
	const last =
		(chats[t.id] ?? []).filter((m) => m.role === 'assistant').at(-1)?.text ?? `${t.session} $ `;
	const box = '─'.repeat(52);
	const asked = promptOf(t);
	const tail = asked
		? [
				`╭${box}╮`,
				`│ ${asked.title || 'Question'}`,
				'│',
				`│   ${asked.full ?? (asked.detail || asked.question)}`,
				'│',
				...asked.options.map((o, i) => `│ ${i === 0 ? '❯' : ' '} ${o.n}. ${o.label}`),
				`╰${box}╯`
			]
		: [
				`╭${box}╮`,
				`│ >${' '.repeat(50)}│`,
				`╰${box}╯`,
				t.status === 'busy' ? '  ✻ Working… (esc to interrupt)' : '  ? for shortcuts'
			];
	// One line wider than a phone: the terminal view has to scroll sideways.
	const wide = `  ⎿  Read ${t.cwd}/tests/checkout.spec.ts (212 lines) · Edit tests/checkout.spec.ts (+3 −1) · 2 files changed`;
	return [`⏺ ${last.slice(0, 50)}`, wide, '', ...tail, ''].join('\n');
}

const ACTIONS = [
	'new-session',
	'new-window',
	'rename-session',
	'rename-window',
	'kill-session',
	'kill-window',
	'kill-pane',
	'zoom-pane'
];
const NAME_ASCII = /^[A-Za-z0-9 \-_/,]$/;
const NAME_HIDDEN = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Co}\p{Cn}]/u;

/** The Mac's rule for a session or window name. */
function nameOf(raw) {
	if (typeof raw !== 'string') return null;
	const name = raw.trim();
	if (!name || name.startsWith('-') || [...name].length > 64) return null;
	for (const char of name) {
		const code = char.codePointAt(0);
		if (code < 0x80 ? !NAME_ASCII.test(char) : code !== 0x200d && NAME_HIDDEN.test(char))
			return null;
	}
	return name;
}

const dirsOf = (host) =>
	[...new Set(threads.filter((t) => t.host === host).map((t) => t.cwd))].sort();

/** One session action, checked the way the Mac checks it. */
function tmuxApi(req, res, path, body) {
	if (!capabilities.sessionActions) return send(res, 403, { error: 'disabled' });
	const action = decodeURIComponent(path.slice('/api/tmux/'.length));
	if (action.startsWith('kill') && !capabilities.kill) return send(res, 403, { error: 'disabled' });
	if (!ACTIONS.includes(action)) return send(res, 400, { error: 'bad_action' });
	if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' });
	let fields;
	try {
		fields = JSON.parse(body);
	} catch {
		fields = null;
	}
	if (fields === null || typeof fields !== 'object' || Array.isArray(fields))
		return send(res, 400, { error: 'bad_request' });

	const byThread = ['rename-window', 'kill-window', 'kill-pane', 'zoom-pane'].includes(action);
	let thread = null;
	let host = null;
	let session = null;
	if (byThread || (action !== 'new-session' && fields.thread !== undefined)) {
		if (typeof fields.thread !== 'string') return send(res, 400, { error: 'bad_request' });
		thread = threads.find((t) => t.id === fields.thread);
		if (!thread) return send(res, 404, { error: 'not_found' });
		({ host, session } = thread);
	} else {
		if (typeof fields.host !== 'string') return send(res, 400, { error: 'bad_request' });
		if (!HOSTS.some((h) => h.name === fields.host)) return send(res, 404, { error: 'not_found' });
		host = fields.host;
		if (action !== 'new-session') {
			if (typeof fields.session !== 'string') return send(res, 400, { error: 'bad_request' });
			session = fields.session;
			thread = threads.find((t) => t.host === host && t.session === session);
			if (!thread) return send(res, 404, { error: 'not_found' });
		}
	}
	const inSession = (t) => t.host === host && t.session === session;
	const taken = (name) => threads.some((t) => t.host === host && t.session === name);
	const next = Math.max(...threads.map((t) => t.window)) + 1;
	const result = { ok: true };

	if (action === 'new-session') {
		let dir = null;
		if (fields.dir !== undefined && fields.dir !== null) {
			if (!dirsOf(host).includes(fields.dir)) return send(res, 400, { error: 'bad_dir' });
			dir = fields.dir;
		}
		let name = dir ? nameOf(dir.split('/').at(-1).replace(/[.:]/g, '_')) : null;
		if (fields.name !== undefined && fields.name !== null) {
			name = nameOf(fields.name);
			if (!name) return send(res, 400, { error: 'bad_name' });
		}
		name ??= 'session';
		const base = name;
		for (let n = 2; taken(name); n += 1) name = `${base}-${n}`;
		const made = makeThread(next, name, 'zsh', host, 'idle', '', 0, 'awake');
		Object.assign(made, { command: 'zsh', chat: false, ...(dir ? { cwd: dir } : {}) });
		threads.push(made);
		result.session = name;
	} else if (action === 'new-window') {
		const made = makeThread(next, session, 'zsh', host, 'idle', '', 0, 'awake');
		Object.assign(made, { command: 'zsh', chat: false, cwd: thread.cwd });
		threads.push(made);
		result.thread = made.id;
	} else if (action === 'rename-session' || action === 'rename-window') {
		const name = nameOf(fields.name);
		if (!name) return send(res, 400, { error: 'bad_name' });
		if (action === 'rename-session') {
			if (name !== session && taken(name)) return send(res, 409, { error: 'exists' });
			for (const t of threads.filter(inSession)) t.session = name;
		} else {
			for (const t of threads.filter((t) => inSession(t) && t.window === thread.window))
				t.name = name;
		}
	} else if (action !== 'zoom-pane') {
		if (fields.confirm !== true) return send(res, 400, { error: 'confirm_required' });
		const { id, window } = thread;
		threads = threads.filter((t) =>
			action === 'kill-pane'
				? t.id !== id
				: action === 'kill-window'
					? !(inSession(t) && t.window === window)
					: !inSession(t)
		);
	}
	replies.actions.push({ action, ...fields });
	push('threads', threadsBody());
	push('hosts', hostsBody());
	return send(res, 200, result);
}

/** A pane's scrollback: a test run that scrolled off, then what the pane shows. */
function scrollback(t) {
	const run = ['$ pnpm exec playwright test tests/checkout.spec.ts', ''];
	for (let n = 1; n <= 60; n += 1) {
		run.push(
			n % 9 === 0
				? `  ✓ ${n} the Tax line renders before the total (${40 + n} ms)`
				: `  ✓ ${n} checkout step ${n} keeps the cart (${10 + n} ms)`
		);
	}
	return [...run, '', '  60 passed (4.1s)', '', ...screen(t).trimEnd().split('\n')];
}

const FIND_MAX_QUERY = 200;
const FIND_MAX_MATCHES = 200;

/** Find in a pane's scrollback: plain text, no case until the query has an uppercase letter. */
function findApi(res, url, thread) {
	if (!capabilities.find) return send(res, 403, { error: 'disabled' });
	if (!thread) return send(res, 404, { error: 'not_found' });
	const query = (url.searchParams.get('q') ?? '').trim();
	if (!query || [...query].length > FIND_MAX_QUERY || CONTROL.test(query) || /[\n\t]/.test(query))
		return send(res, 400, { error: 'bad_query' });
	const exact = query !== query.toLowerCase();
	const needle = exact ? query : query.toLowerCase();
	const lines = scrollback(thread);
	const matches = [];
	let truncated = false;
	lines.forEach((line, index) => {
		const hay = exact ? line : line.toLowerCase();
		const ranges = [];
		for (let at = hay.indexOf(needle); at >= 0; at = hay.indexOf(needle, at + needle.length))
			ranges.push([at, at + needle.length]);
		if (!ranges.length) return;
		if (matches.length >= FIND_MAX_MATCHES) truncated = true;
		else matches.push({ line: index, ranges });
	});
	return send(res, 200, { text: lines.join('\n'), matches, truncated });
}

const send = (res, status, body, type = 'application/json') => {
	res.writeHead(status, { 'content-type': type, 'cache-control': 'no-store' });
	res.end(typeof body === 'string' ? body : JSON.stringify(body));
};
const push = (event, body) => {
	for (const res of streams) res.write(`event: ${event}\ndata: ${JSON.stringify(body)}\n\n`);
};

function api(req, res, url, body) {
	if (req.headers['x-muxmaestro-token'] !== token) return send(res, 401, { error: 'unpaired' });
	if (deny) return send(res, 403, { error: 'forbidden' });
	if (req.method !== 'GET' && !sameOriginWrite(req)) return send(res, 403, { error: 'forbidden' });
	const path = url.pathname;
	if (path === '/api/threads') return send(res, 200, threadsBody());
	if (path === '/api/hosts') return send(res, 200, hostsBody());
	if (path === '/api/config') return send(res, 200, configBody());
	if (path.startsWith('/api/manager')) return managerApi(req, res, path, String(body));
	if (path.startsWith('/api/voice')) return voiceApi(req, res, url, body);
	if (path === '/api/events') {
		res.writeHead(200, {
			'content-type': 'text/event-stream',
			'cache-control': 'no-store',
			connection: 'keep-alive'
		});
		streams.add(res);
		res.on('close', () => streams.delete(res));
		res.write(`event: config\ndata: ${JSON.stringify(configBody())}\n\n`);
		res.write(`event: threads\ndata: ${JSON.stringify(threadsBody())}\n\n`);
		res.write(`event: hosts\ndata: ${JSON.stringify(hostsBody())}\n\n`);
		if (capabilities.manager)
			res.write(`event: manager\ndata: ${JSON.stringify(managerLive())}\n\n`);
		return;
	}
	if (path.startsWith('/api/tmux/')) return tmuxApi(req, res, path, String(body));
	if (path === '/api/servers' || path.startsWith('/api/servers/'))
		return serversApi(req, res, path, String(body));
	const made = /^\/api\/threads\/([^/]+)\/(artifacts|file|running)$/.exec(path);
	if (made) {
		if (!capabilities[made[2] === 'running' ? 'localServers' : 'artifacts'])
			return send(res, 403, { error: 'disabled' });
		if (req.method !== 'GET') return send(res, 405, { error: 'method_not_allowed' });
		const thread = threads.find((t) => t.id === decodeURIComponent(made[1]));
		if (!thread) return send(res, 404, { error: 'not_found' });
		if (made[2] === 'file') return fileApi(res, url, thread);
		return send(res, 200, made[2] === 'running' ? runningBody(thread) : artifactsBody(thread));
	}
	const dirs = /^\/api\/hosts\/([^/]+)\/dirs$/.exec(path);
	if (dirs) {
		if (!capabilities.sessionActions) return send(res, 403, { error: 'disabled' });
		const host = decodeURIComponent(dirs[1]);
		if (!HOSTS.some((h) => h.name === host)) return send(res, 404, { error: 'not_found' });
		return send(res, 200, { dirs: dirsOf(host) });
	}
	const match =
		/^\/api\/threads\/([^/]+)\/(chat|screen|text|key|prompt|answer|commands|upload|find)$/.exec(
			path
		);
	const thread = match && threads.find((t) => t.id === decodeURIComponent(match[1]));
	if (match && match[2] === 'find') return findApi(res, url, thread);
	if (match && match[2] !== 'chat' && match[2] !== 'screen')
		return replyApi(req, res, url, thread, match[2], body);
	if (!thread) return send(res, 404, { error: 'not_found' });
	if (match[2] === 'screen') return send(res, 200, { text: screen(thread) });
	const all = chats[thread.id];
	if (!all) return send(res, 404, { error: 'not_found' });
	const after = url.searchParams.get('after');
	return send(res, 200, {
		messages: after === null ? all : all.slice(Number(after)),
		next: all.length,
		reset: false
	});
}

function dropStreams() {
	for (const res of streams) res.end();
	streams.clear();
}

function hook(res, url) {
	const id = url.searchParams.get('id');
	const thread = threads.find((t) => t.id === id);
	const now = Math.floor(Date.now() / 1000);
	switch (url.pathname) {
		case '/__fixture/reset':
			reset();
			push('config', configBody());
			break;
		case '/__fixture/wait':
			if (!thread) return send(res, 404, { error: 'not_found' });
			Object.assign(thread, { status: 'waiting', since: now, idleStage: 'awake' });
			break;
		case '/__fixture/status':
			// Put a thread in a state, as the pane's own work would.
			if (!thread) return send(res, 404, { error: 'not_found' });
			Object.assign(thread, {
				status: url.searchParams.get('value') ?? 'idle',
				since: now,
				idleStage: 'awake'
			});
			if (thread.status !== 'waiting') delete prompts[thread.id];
			break;
		case '/__fixture/panes':
			// The window was split: it holds this many threads now.
			if (!thread) return send(res, 404, { error: 'not_found' });
			thread.panes = Number(url.searchParams.get('value') ?? 2);
			break;
		case '/__fixture/prompt':
			// The pane moved on to another prompt while the phone showed the first.
			if (!thread) return send(res, 404, { error: 'not_found' });
			promptSeq += 1;
			prompts[thread.id] = {
				id: url.searchParams.get('pid') ?? `p${promptSeq}-${thread.window}`,
				...(url.searchParams.get('kind') === 'question' ? QUESTION : PERMISSION),
				truncated: url.searchParams.get('truncated') === '1',
				...(url.searchParams.get('bare') === '1' ? { bare: true } : {})
			};
			if (prompts[thread.id].truncated) {
				// The card gets the start of the command; the terminal has all of it.
				prompts[thread.id].full = LONG_COMMAND;
				prompts[thread.id].detail = LONG_COMMAND.slice(0, 88);
			}
			if (url.searchParams.get('quiet') === '1') return send(res, 200, { ok: true });
			Object.assign(thread, { status: 'waiting', since: now, idleStage: 'awake' });
			break;
		case '/__fixture/upload-max':
			uploadMax = Number(url.searchParams.get('value') ?? 10485760);
			push('config', configBody());
			break;
		case '/__fixture/not-sent':
			notSent = {
				cleared: url.searchParams.get('cleared') === '1',
				reason: url.searchParams.get('reason') ?? 'busy'
			};
			return send(res, 200, { ok: true });
		case '/__fixture/no-input':
			if (!thread) return send(res, 404, { error: 'not_found' });
			if (url.searchParams.get('on') === '0') noInput.delete(thread.id);
			else noInput.add(thread.id);
			return send(res, 200, { ok: true });
		case '/__fixture/pasted':
			pasted = url.searchParams.get('on') !== '0';
			return send(res, 200, { ok: true });
		case '/__fixture/replies':
			return send(res, 200, replies);
		case '/__fixture/say':
			if (!thread || !chats[thread.id]) return send(res, 404, { error: 'not_found' });
			chats[thread.id].push({
				n: chats[thread.id].length,
				role: 'assistant',
				text: url.searchParams.get('text') ?? ''
			});
			thread.lastActivityAt = now;
			break;
		case '/__fixture/grouping':
			grouping = url.searchParams.get('value') ?? 'recent';
			push('config', configBody());
			break;
		case '/__fixture/rotate':
			token = url.searchParams.get('value') ?? 'rotated-token';
			dropStreams();
			return send(res, 200, { ok: true });
		case '/__fixture/drop':
			dropStreams();
			return send(res, 200, { ok: true });
		case '/__fixture/deny':
			deny = url.searchParams.get('on') === '1';
			break;
		case '/__fixture/capability':
			capabilities[url.searchParams.get('name')] = url.searchParams.get('on') === '1';
			push('config', configBody());
			break;
		case '/__fixture/serve-fails':
			serveFails = url.searchParams.get('code');
			break;
		case '/__fixture/tailnet':
			tailnet = url.searchParams.get('name');
			break;
		case '/__fixture/mappings':
			return send(res, 200, { mappings });
		case '/__fixture/manager-status':
			manager.status = url.searchParams.get('value') ?? 'idle';
			break;
		case '/__fixture/voice':
			// The Mac's voice settings, and how the next take goes.
			for (const [key, value] of url.searchParams) {
				if (key === 'speaker') voice.speaker = value === '1';
				else if (key === 'delay') voice.delay = Number(value);
				else if (key === 'mode' || key === 'heard') voice[key] = value;
			}
			push('config', configBody());
			break;
		case '/__fixture/voice-takes':
			return send(res, 200, { takes: voice.takes });
		case '/__fixture/mac-turn':
			// A turn typed into the Mac rail: the phone must follow it.
			runTurn(url.searchParams.get('text') ?? '', url.searchParams.get('reply') ?? '');
			break;
		default:
			return send(res, 404, { error: 'not_found' });
	}
	push('threads', threadsBody());
	push('hosts', hostsBody());
	if (capabilities.manager) push('manager', managerLive());
	return send(res, 200, { ok: true });
}

async function asset(res, url) {
	const rel = normalize(decodeURIComponent(url.pathname)).replace(/^(\.\.[/\\])+/, '');
	const file = join(ROOT, rel);
	const wanted = file.startsWith(ROOT) && extname(file) ? file : join(ROOT, 'index.html');
	try {
		const body = await readFile(wanted);
		res.writeHead(200, {
			'content-type': TYPES[extname(wanted)] ?? 'application/octet-stream',
			'cache-control': url.pathname.startsWith('/_app/immutable/')
				? 'public, max-age=31536000, immutable'
				: 'no-cache'
		});
		res.end(body);
	} catch {
		if (extname(file)) return send(res, 404, 'Not found', 'text/plain');
		send(res, 503, 'Run `make mobile` first.', 'text/plain');
	}
}

createServer((req, res) => {
	const url = new URL(req.url, `http://${req.headers.host}`);
	if (url.pathname.startsWith('/api/')) {
		// A take is audio: the body stays bytes until a route wants text.
		const chunks = [];
		req.on('data', (chunk) => chunks.push(chunk));
		req.on('end', () => api(req, res, url, Buffer.concat(chunks)));
		return;
	}
	// What a published dev server answers: a page of its own, on another path.
	if (url.pathname.startsWith('/__mapped/'))
		return send(
			res,
			200,
			`<!doctype html><title>dev server</title><h1>Port ${url.pathname.split('/')[2]}</h1>`,
			'text/html'
		);
	if (url.pathname.startsWith('/__fixture/'))
		return req.method === 'POST' ? hook(res, url) : send(res, 405, { error: 'method' });
	return asset(res, url);
}).listen(PORT, '127.0.0.1', () => console.log(`fixture server on http://127.0.0.1:${PORT}`));

setInterval(() => {
	for (const res of streams) res.write(': ping\n\n');
}, 15000).unref();
