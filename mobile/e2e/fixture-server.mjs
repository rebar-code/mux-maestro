// A stand-in for the Mac app, for tests and screenshots: it serves the built
// bundle and the same JSON API, from demo data only.
//
//   PORT=5199 node e2e/fixture-server.mjs
//
// Test hooks (POST): /__fixture/reset, /__fixture/wait?id=, /__fixture/say?id=&text=&role=,
// /__fixture/grouping?value=, /__fixture/deny?on=1, /__fixture/rotate?value=, /__fixture/drop,
// /__fixture/capability?name=&on=, /__fixture/manager-status?value=,
// /__fixture/mac-turn?text=&reply=&spinner=&ms= (ms: the pause between words),
// /__fixture/voice?mode=&speaker=&heard=&delay=, /__fixture/voice-takes,
// /__fixture/replies, /__fixture/prompt?id=&pid=&kind=,
// /__fixture/upload-max?value=, /__fixture/status?id=&value=,
// /__fixture/panes?id=&value=, /__fixture/find-busy?value=,
// /__fixture/prompt also takes truncated=1, bare=1 (an id with no choices), quiet=1,
// scrolled=<last row> (a menu scrolled to rows 4…last, with more above and below),
// /__fixture/not-sent?cleared=&reason=, /__fixture/no-input?id=&on=, /__fixture/pasted?on=,
// /__fixture/serve-fails?code=, /__fixture/mappings (what the phone asked to publish),
// /__fixture/tailnet?name= (publish under that name, for screenshots),
// /__fixture/push (the subscriptions and the thread each phone says it shows),
// /__fixture/push-limit?on=1 (refuse the next subscription: the Mac holds its most),
// /__fixture/push-forget (the Mac drops every subscription, as a new pairing code does),
// /__fixture/prompt-delay?ms=,
// /__fixture/manager-prompt?kind=&bare=&scrolled=&pid=&quiet=, /__fixture/prompt-delay?ms=, /__fixture/upload-slow?chunk=&answer=,
// /__fixture/upload-fail?status=&error=&message=, /__fixture/build?tag=, /__fixture/text-slow?ms=,
// /__fixture/append?count= (adds lines to pane buildbox:8),
// /__fixture/screen?default=&max= (the screen endpoint's default and cap)
// /__fixture/point?key=&thread=&title=&reason= (the Maestro points at a session; no thread: one that is gone),
// /__fixture/terminal (what the live terminal's sockets were sent, and how they were opened),
// /__fixture/terminal-drop (cut every live socket), /__fixture/terminal-say?text=,
// /__fixture/terminal-refuse?code= (close the next sockets with that code; 0 to stop)
// /__fixture/requests (GET too: the request list as the Mac holds it),
// /__fixture/requests-mode?value=ok|corrupt (the list file does not parse: reads and writes answer 500),
// /__fixture/requests-fail?status=&error= (the next state write fails that way),
// /__fixture/requests-set?id=&state= (the agent changed a row behind the phone's back)
//
// Every /api/ request needs the header `X-MuxMaestro-Token: demo-token`.
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { crc32, deflateSync } from 'node:zlib';
import { WebSocketServer } from 'ws';

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
	[
		'assistant',
		'Coverage is in coverage/index.html, the trend in coverage/chart.svg. Docs: https://example.com/docs/push-tokens'
	],
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
<a id="out" href="/__mapped/1/">Full report</a>
<a id="self" target="_self" href="/__mapped/2/">Summary</a>
<a id="top" target="_top" href="/__mapped/3/">Index</a>
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

// An image that carries a script. Shown as a picture it runs nothing; as a
// page of the app's own origin it would read the pairing token.
const CHART = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 160" width="300" height="160">
<rect width="300" height="160" fill="#101418"/>
<polyline points="20,130 80,96 140,104 200,58 280,30" fill="none" stroke="#45d483" stroke-width="4"/>
<script>
window.__svgRan = localStorage.getItem('mm.token');
document.title = 'svg script ran';
fetch('/api/config', { headers: { 'X-MuxMaestro-Token': localStorage.getItem('mm.token') } });
</script>
</svg>`;

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
	['chart.svg', `${ROOT_DIR}/coverage`, 'image', 'image/svg+xml', 130, Buffer.from(CHART)],
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
	selected: 1,
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
	selected: 1,
	options: [
		{ n: 1, label: 'Credit the unused days' },
		{ n: 2, label: 'No credit until renewal' },
		{ n: 3, label: 'Type something else' }
	]
};
const LONG_COMMAND =
	'kubectl rollout restart deploy/web -n staging && kubectl rollout status deploy/web -n staging --timeout=120s && kubectl get pods -n staging -l app=web -o wide';
// A menu scrolled to its middle: rows 1 to 3 are above what the pane shows.
const REGIONS = [
	'us-east',
	'us-west',
	'eu-west',
	'eu-central',
	'eu-north',
	'ap-south',
	'ap-southeast',
	'ap-northeast',
	'sa-east',
	'ca-central',
	'me-south',
	'af-south'
];
const scrolledMenu = (last) => ({
	kind: 'question',
	title: '',
	detail: '',
	question: 'Which region should staging run in?',
	selected: 4,
	moreAbove: true,
	moreBelow: true,
	options: REGIONS.map((label, i) => ({ n: i + 1, label })).slice(3, last)
});
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
const LONG_ID = 'devbox:5';
// A pane with 500 numbered, coloured lines of scrollback.
const LOG_ID = 'buildbox:8';
const E = '\x1b';
// The things the human asked agents for, as the Mac's request list holds them.
// `history` is how each got to its state, oldest first; entries are only appended.
const ask = (at, verbatim) => ({ at, by: 'me', verbatim });
const agent = (at, note) => ({ at, by: 'maestro', note });
const REQUEST_HISTORY = {
	'req-012': [
		ask('2026-10-03', 'The checkout test fails about one run in five. Find out why and fix it.'),
		agent(
			'2026-10-03',
			'The tax row renders after the total is read. The test now waits for it. PR is open.'
		)
	],
	'req-013': [
		ask('2026-10-03', 'Rotate the staging deploy keys before they expire.'),
		agent('2026-10-03', 'Blocked: the new keys are not issued yet.')
	],
	'req-016': [
		ask(
			'2026-10-03',
			'The CSV export runs out of memory on big accounts. Make it stream the rows instead of building the whole file first.'
		),
		agent('2026-10-03', 'Split the export into pages of 1,000 rows, one file per page.'),
		ask('2026-10-04', 'No, one file, streamed. Ten files do not help the people who download it.'),
		agent(
			'2026-10-04',
			'I misread the ask as paging. Removed the pages; the export now streams one file row by row.'
		)
	],
	'req-018': [
		ask('2026-09-28', 'Check the contrast on the settings page.'),
		ask('2026-10-04', 'Still wanted, but after the release. Park it until then.'),
		agent('2026-10-04', 'Parked until after the release.')
	]
};
const REQUESTS = {
	schema: 2,
	updated: '2026-10-04T16:20:00Z',
	requests: [
		['req-011', 'Add proration to plan changes', 'acme-app', '2026-10-03', 'done'],
		['req-012', 'Fix the flaky checkout test', 'acme-app', '2026-10-03', 'review'],
		['req-013', 'Rotate the staging deploy keys', 'devbox', '2026-10-03', 'blocked'],
		[
			'req-014',
			'Shorten every onboarding step label to two words',
			'acme-app',
			'2026-10-03',
			'todo'
		],
		['req-015', 'Move the nightly backups to the new bucket', 'devbox', '2026-10-03', 'done'],
		[
			'req-016',
			'Stream the CSV export instead of buffering it',
			'acme-app',
			'2026-10-04',
			'in_progress'
		],
		['req-017', 'Find why the build cache misses on every run', 'devbox', '2026-10-04', 'todo'],
		[
			'req-018',
			'Audit contrast on the settings page',
			'acme-app',
			'earlier, restated 2026-10-04',
			'parked'
		],
		['req-019', 'Turn on log retention for the worker', 'devbox', '2026-10-04', 'in_progress']
	].map(([id, title, project, asked, state]) => ({
		id,
		title,
		project,
		asked,
		state,
		detail: `Notes for ${id} that the phone does not show.`,
		blocked_by: state === 'blocked' ? 'Waiting on new keys from the host provider' : null,
		history: REQUEST_HISTORY[id] ?? [ask(asked, `${title}, please.`)]
	})),
	blockers: [{ id: 'blk-1', text: 'Staging keys expire on Friday' }],
	open_questions: [{ id: 'q-1', text: 'Keep the old export format as an option?' }]
};
const REQUEST_STATES = ['todo', 'in_progress', 'blocked', 'review', 'done'];

let started, threads, chats, grouping, deny, token, log, screenDefault, screenMax;
let capabilities, manager, voice;
// Per thread id: the prompt on the pane. And everything the phone wrote.
let prompts, replies, uploadMax, promptSeq, notSent, noInput, pasted, keyLocks, promptDelay;
// Makes one thread row; set by `reset`, used again for a new window or session.
let makeThread;
// The ports published on the tailnet, and how the next publish is refused.
let mappings, serveFails, tailnet;
// The request tracker's list, whether its file reads as corrupt, and how the next state write fails.
let requests, requestsCorrupt, requestsFail;
// The phones subscribed to push, the thread each shows, and a full list.
let pushSubs, pushFocus, pushLimit;
// How many finds the Mac refuses as busy before it answers one.
let findBusy;
// Uploads: the paths taken, the threads with one in flight, how slow they are, a refusal for the next.
let saved, uploadLocks, uploadSlow, uploadFail;
// Set: the server holds a newer build than the one a phone may have cached.
let buildTag = null;
// How long a reply's answer takes to come back.
let textSlow = 0;
const streams = new Set();
// The live terminal: its open sockets, what they typed (as text), how each
// was opened, and the close code the next ones get.
const terminals = new Set();
let terminalTyped, terminalOpens, terminalRefuse;

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
		localServers: false,
		notifications: false,
		liveTerminal: false
	};
	for (const socket of terminals) socket.terminate();
	terminals.clear();
	terminalTyped = '';
	terminalOpens = [];
	terminalRefuse = 0;
	pushSubs = [];
	pushFocus = {};
	pushLimit = false;
	mappings = [];
	requests = structuredClone(REQUESTS);
	requestsCorrupt = false;
	requestsFail = null;
	serveFails = null;
	prompts = {};
	// How the next text is refused after its paste, the panes with no input
	// box, whether an upload's path reaches the pane, and the keys in flight.
	notSent = null;
	noInput = new Set();
	pasted = true;
	keyLocks = new Set();
	// How long `GET /prompt` takes, so a test can tap before the card catches up.
	promptDelay = 0;
	saved = new Set();
	uploadLocks = new Set();
	uploadSlow = { chunk: 0, answer: 0 };
	uploadFail = null;
	buildTag = null;
	textSlow = 0;
	promptSeq = 0;
	findBusy = 0;
	uploadMax = 10485760;
	replies = {
		texts: [],
		keys: [],
		answers: [],
		cancels: [],
		uploads: [],
		left: [],
		actions: [],
		commandFetches: 0,
		// What the phone wrote to the manager pane's prompt, and how often it asked for it.
		manager: { keys: [], answers: [], cancels: [], promptFetches: 0 }
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
		// Sessions the Maestro points at, as `mux point` records them.
		points: [],
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
	screenDefault = 2000;
	screenMax = 10000;
	log = [];
	appendLog(500);
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
		notifications: capabilities.notifications,
		liveTerminal: capabilities.liveTerminal
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
	delete prompt.base;
	delete prompt.first;
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

/** A path as it is typed into a pane: quoted when a shell would split it. */
const typed = (path) => (/^[\w@%+=:,./-]+$/.test(path) ? path : `'${path.replace(/'/g, `'\\''`)}'`);

/** `name` in `dir`, with `-2`, `-3`… before its extension while the name is taken. */
function freePath(dir, name) {
	const dot = name.lastIndexOf('.');
	const [stem, ext] = dot > 0 ? [name.slice(0, dot), name.slice(dot)] : [name, ''];
	let path = `${dir}/${name}`;
	for (let n = 2; saved.has(path); n += 1) path = `${dir}/${stem}-${n}${ext}`;
	return path;
}

/**
 * `POST /upload?paste=0`: the file is saved and nothing is typed, so what the
 * pane is doing does not matter. One write to a thread at a time.
 */
function saveOnly(req, res, thread, name, body) {
	if (uploadLocks.has(thread.id))
		return send(res, 409, { error: 'busy', message: 'A reply is being sent' });
	if (uploadFail) {
		const { status, body: refusal } = uploadFail;
		uploadFail = null;
		return send(res, status, refusal);
	}
	uploadLocks.add(thread.id);
	const locks = uploadLocks;
	const files = saved;
	// The phone gave up on it: nothing is kept, and the thread is free again.
	res.on('close', () => {
		if (res.writableEnded) return;
		clearTimeout(timer);
		locks.delete(thread.id);
	});
	const timer = setTimeout(() => {
		locks.delete(thread.id);
		const path = freePath(thread.cwd, name);
		files.add(path);
		replies.uploads.push({
			thread: thread.id,
			name,
			path,
			bytes: body.length,
			type: req.headers['content-type'] ?? null,
			paste: false
		});
		send(res, 200, { ok: true, pasted: false, path, text: typed(path) });
	}, uploadSlow.answer);
}

/**
 * `POST …/key` for a thread or the manager. `pane`: its lock, name, the prompt
 * on it, whether it shows no input box, and where to record the key.
 */
function pressKey(res, json, pane) {
	if (typeof json.key !== 'string' || !KEY_NAMES.test(json.key))
		return send(res, 400, { error: 'bad_key' });
	if (json.prompt !== undefined && typeof json.prompt !== 'string')
		return send(res, 400, { error: 'bad_request' });
	// One write to a pane at a time: a second key while one is in flight is refused.
	if (keyLocks.has(pane.lock))
		return send(res, 409, { error: 'busy', message: `${pane.name} is taking a key` });
	// The pane waits on a prompt the phone did not name: the key could answer the wrong one.
	const asked = pane.asked;
	if (asked && asked.id !== json.prompt) return send(res, 409, { error: 'stale' });
	// The keys that submit, and the digits, which pick a row.
	const picks = /^(Enter|C-[mjdo]|BTab|[1-9])$/.test(json.key);
	// Nobody could read what they would pick, unless the pane's own text was on screen.
	if (asked?.bare && picks && json.terminal !== true)
		return send(res, 409, { error: 'unseen', message: 'Open the terminal to answer' });
	// No prompt and no input box in sight: the key would land nobody knows where.
	if (!asked && picks && pane.noInput)
		return send(res, 409, { error: 'no_input', message: 'Thread shows no input box' });
	if (
		asked &&
		!asked.bare &&
		/^[1-9]$/.test(json.key) &&
		!asked.options.some((o) => o.n === Number(json.key))
	)
		return send(res, 409, { error: 'no_option', message: 'Not a choice on the card' });
	keyLocks.add(pane.lock);
	const locks = keyLocks;
	setTimeout(() => {
		locks.delete(pane.lock);
		// An arrow moves the pane's cursor, and the prompt's id names the row it is on.
		const step = { Up: -1, Down: 1 }[json.key];
		if (asked && !asked.bare && step) {
			asked.base ??= asked.id;
			const rows = asked.options.map((o) => o.n);
			asked.selected = Math.min(rows.at(-1), Math.max(rows[0], asked.selected + step));
			asked.first ??= rows[0];
			asked.id = asked.selected === asked.first ? asked.base : `${asked.base}-row${asked.selected}`;
		}
		pane.record({
			key: json.key,
			...(json.prompt === undefined ? {} : { prompt: json.prompt }),
			...(json.terminal === true ? { terminal: true } : {})
		});
		send(res, 200, { ok: true });
	}, 30);
}

/** `POST …/answer` for a thread or the manager: one option of the prompt, or its cancel. */
function answerRoute(res, json, prompt, on) {
	const cancel = json.cancel === true;
	if (typeof json.prompt !== 'string' || (!cancel && !Number.isInteger(json.option)))
		return send(res, 400, { error: 'bad_request' });
	if (!prompt || prompt.id !== json.prompt) return send(res, 409, { error: 'stale' });
	if (cancel) {
		on.cancel();
		on.done(true);
		return send(res, 200, { ok: true });
	}
	// The pane has a key for 1 to 9 only, and a prompt with no readable choices has none.
	if (prompt.bare || json.option > 9 || !prompt.options.some((option) => option.n === json.option))
		return send(res, 400, { error: 'bad_request' });
	on.option(json.option);
	on.done(false);
	return send(res, 200, { ok: true });
}

/** The prompt on the manager pane, when it waits on one. */
function managerPrompt() {
	return manager.status === 'waiting' ? (manager.prompt ?? null) : null;
}

/** `/api/manager/prompt|answer|key`: the manager pane's prompt, as a thread's. */
function managerAsk(req, res, path, body) {
	const route = path.slice('/api/manager/'.length);
	const allowed =
		route === 'prompt'
			? capabilities.replies || capabilities.keyBar
			: capabilities[route === 'key' ? 'keyBar' : 'replies'];
	if (!allowed) return send(res, 403, { error: 'disabled' });
	if (req.method !== (route === 'prompt' ? 'GET' : 'POST'))
		return send(res, 405, { error: 'method_not_allowed' });
	if (manager.status === 'off') return send(res, 503, { error: 'unavailable' });
	const asked = managerPrompt();
	if (route === 'prompt') {
		replies.manager.promptFetches += 1;
		if (!asked) return send(res, 200, { prompt: null, id: null });
		const prompt = { ...asked };
		for (const note of ['bare', 'full', 'base', 'first']) delete prompt[note];
		return send(res, 200, { prompt: asked.bare ? null : prompt, id: asked.id });
	}
	let json = {};
	try {
		json = JSON.parse(String(body));
	} catch {
		// Not JSON: the checks below answer 400.
	}
	if (route === 'key')
		return pressKey(res, json, {
			lock: 'manager',
			name: 'Maestro',
			asked,
			noInput: false,
			record: (entry) => replies.manager.keys.push(entry)
		});
	return answerRoute(res, json, asked, {
		option: (option) => replies.manager.answers.push({ prompt: json.prompt, option }),
		cancel: () => replies.manager.cancels.push({ prompt: json.prompt }),
		done: () => {
			manager.prompt = null;
			manager.status = 'idle';
		}
	});
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
	if (route === 'prompt') {
		const answer = promptBody(thread);
		return void setTimeout(() => send(res, 200, answer), promptDelay);
	}
	if (route === 'commands') {
		replies.commandFetches += 1;
		return send(res, 200, { commands: COMMANDS });
	}
	if (route === 'upload') {
		const name = url.searchParams.get('name');
		if (!name || name.includes('/') || body.length === 0)
			return send(res, 400, { error: 'bad_request' });
		if (body.length > uploadMax) return send(res, 413, { error: 'too_large' });
		if (url.searchParams.get('paste') === '0') return saveOnly(req, res, thread, name, body);
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
	if (route === 'key')
		return pressKey(res, json, {
			lock: thread.id,
			name: thread.name,
			asked: promptOf(thread),
			noInput: noInput.has(thread.id),
			record: (entry) => replies.keys.push({ thread: thread.id, ...entry })
		});
	if (route === 'answer')
		return answerRoute(res, json, promptOf(thread), {
			option: (option) => replies.answers.push({ thread: thread.id, prompt: json.prompt, option }),
			cancel: () => replies.cancels.push({ thread: thread.id, prompt: json.prompt }),
			// Answered: the pane works on. Cancelled: it is back at its input box.
			done: (cancelled) => setStatus(thread, cancelled ? 'idle' : 'busy')
		});
	// text
	const text = typeof json.text === 'string' ? json.text.trim() : '';
	if (!text || CONTROL.test(text)) return send(res, 400, { error: 'bad_request' });
	if (Buffer.byteLength(text) > TEXT_MAX) return send(res, 413, { error: 'too_large' });
	const refused = refusedBy(thread);
	if (refused) return send(res, 409, refused);
	if (notSent) {
		// Pasted, not submitted. The Mac tried to take it out of the input box again.
		const { reason } = notSent;
		// A prompt came up after the paste: the Mac sends no keys at a prompt,
		// so the text stays in the pane.
		const cleared = reason === 'waiting' ? false : notSent.cleared;
		notSent = null;
		if (reason === 'waiting') {
			promptSeq += 1;
			prompts[thread.id] = {
				id: `p${promptSeq}-${thread.window}`,
				...PERMISSION,
				truncated: false
			};
		}
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
	// A slow link: the pane has the text, the phone waits for the answer.
	return void setTimeout(() => send(res, 200, { ok: true }), textSlow);
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
	points: manager.points,
	updates: manager.updates,
	turn: manager.turn
});
const managerBody = () => ({
	...managerLive(),
	status: manager.turn ? 'busy' : manager.status
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
function runTurn(prompt, reply, onDelta = () => {}, onEnd = () => {}, spinner = null, ms = 40) {
	manager.turn = { prompt, reply: '', spinner: null };
	push('manager', managerLive());
	const words = reply.split(/(?<= )/);
	const mine = manager;
	const step = () => {
		// A reset between two words: the turn belongs to the test before.
		if (manager !== mine) return onEnd();
		const word = words.shift();
		// The pane's transcript gets the prompt a moment after it is sent.
		if (manager.turn.reply === '') {
			say('user', prompt);
			if (spinner) {
				manager.turn.spinner = spinner;
				push('manager-spinner', { text: spinner });
			}
		}
		if (word === undefined) {
			say('assistant', reply);
			manager.turn = null;
			onEnd();
			push('manager', managerLive());
			return;
		}
		manager.turn = { ...manager.turn, reply: manager.turn.reply + word };
		onDelta(word);
		// The reply grows by a small event; the board is not sent again.
		push('manager-delta', { text: word });
		setTimeout(step, ms);
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

function requestsApi(req, res, path, body) {
	if (!capabilities.manager) return send(res, 403, { error: 'disabled' });
	const corrupt = () =>
		send(res, 500, { error: 'corrupt', message: 'requests.json is not valid JSON' });
	if (path === '/api/requests') {
		if (req.method !== 'GET') return send(res, 405, { error: 'method_not_allowed' });
		return requestsCorrupt ? corrupt() : send(res, 200, requests);
	}
	if (path !== '/api/requests/state') return send(res, 404, { error: 'not_found' });
	if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' });
	let json = {};
	try {
		json = JSON.parse(body);
	} catch {
		// Not JSON: the checks below answer 400.
	}
	if (typeof json.id !== 'string' || !REQUEST_STATES.includes(json.state))
		return send(res, 400, { error: 'bad_request' });
	if (requestsFail) {
		const { status, error } = requestsFail;
		requestsFail = null;
		return send(res, status, { error, message: 'The request list is being written' });
	}
	if (requestsCorrupt) return corrupt();
	const row = requests.requests.find((request) => request.id === json.id);
	if (!row) return send(res, 404, { error: 'not_found' });
	// As the Mac does: every change from the phone is appended to the row's history.
	row.history.push({
		at: new Date().toISOString().slice(0, 10),
		by: 'me',
		note: `State changed from ${row.state} to ${json.state} on the phone.`
	});
	row.state = json.state;
	requests.updated = new Date().toISOString();
	return send(res, 200, requests);
}

function managerApi(req, res, url, body) {
	const path = url.pathname;
	if (!capabilities.manager) return send(res, 403, { error: 'disabled' });
	if (path === '/api/manager') {
		if (req.method !== 'GET') return send(res, 405, { error: 'method_not_allowed' });
		return send(res, 200, managerBody());
	}
	// The manager pane is read like a thread: the same chat cursor and screen.
	if (path === '/api/manager/chat' || path === '/api/manager/screen') {
		if (req.method !== 'GET') return send(res, 405, { error: 'method_not_allowed' });
		if (path === '/api/manager/chat') return send(res, 200, chatPage(manager.chat, url));
		return sendScreen(req, res, url, managerScreen());
	}
	if (/^\/api\/manager\/(prompt|answer|key)$/.test(path)) return managerAsk(req, res, path, body);
	if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' });
	let json = {};
	try {
		json = JSON.parse(body);
	} catch {
		// Not JSON: the checks below answer 400.
	}
	if (path === '/api/manager/dismiss') {
		if (typeof json.key !== 'string') return send(res, 400, { error: 'bad_request' });
		if (![...manager.review, ...manager.points].some((item) => item.key === json.key))
			return send(res, 404, { error: 'not_found' });
		manager.review = manager.review.filter((item) => item.key !== json.key);
		manager.points = manager.points.filter((item) => item.key !== json.key);
		push('manager', managerLive());
		return send(res, 200, { ok: true });
	}
	if (path !== '/api/manager/text') return send(res, 404, { error: 'not_found' });
	const text = typeof json.text === 'string' ? json.text.trim() : '';
	if (!text || CONTROL.test(text)) return send(res, 400, { error: 'bad_request' });
	if (Buffer.byteLength(text) > TEXT_MAX) return send(res, 413, { error: 'too_large' });
	if (manager.turn) return send(res, 409, { error: 'busy', message: 'A turn is running' });
	if (manager.status === 'waiting')
		return send(res, 409, { error: 'waiting', message: 'Maestro is waiting on a prompt' });
	if (manager.status === 'unknown')
		return send(res, 503, { error: 'not_ready', message: 'Maestro is not ready' });
	if (manager.status === 'busy')
		return send(res, 409, { error: 'busy', message: 'Maestro is busy' });
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
			return send(res, 409, { error: 'waiting', message: 'Maestro is waiting on a prompt' });
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
	if (t.id === LOG_ID) return log;
	const last =
		(chats[t.id] ?? []).filter((m) => m.role === 'assistant').at(-1)?.text ?? `${t.session} $ `;
	const box = '─'.repeat(52);
	const asked = promptOf(t);
	const tail = asked
		? [
				`╭${box}╮`,
				`│ ${E}[1m${asked.title || 'Question'}${E}[0m`,
				'│',
				`│   ${asked.full ?? (asked.detail || asked.question)}`,
				'│',
				...asked.options.map((o) =>
					o.n === asked.selected
						? `│ ${E}[1;34m❯ ${o.n}. ${o.label}${E}[0m`
						: `│   ${o.n}. ${o.label}`
				),
				`╰${box}╯`
			]
		: [
				`╭${box}╮`,
				`│ >${' '.repeat(50)}│`,
				`╰${box}╯`,
				t.status === 'busy'
					? `  ${E}[33m✻ Working…${E}[0m ${E}[2m(esc to interrupt)${E}[0m`
					: `  ${E}[2m? for shortcuts${E}[0m`
			];
	// One line wider than a phone: the terminal view has to scroll sideways.
	const wide = `  ⎿  Read ${t.cwd}/tests/checkout.spec.ts (212 lines) · Edit tests/checkout.spec.ts (+3 −1) · 2 files changed`;
	// One pane with a long scrollback, so the terminal also scrolls down.
	const history =
		t.id === LONG_ID
			? Array.from(
					{ length: 90 },
					(_, n) =>
						`  12:${String(n % 60).padStart(2, '0')}:07 deploy web-${n % 7} step ${n + 1}/90 ok`
				)
			: [];
	return [
		...history,
		`${E}[32m⏺${E}[0m ${last.slice(0, 50)}`,
		`${E}[2m${wide}${E}[0m`,
		'',
		...tail,
		''
	];
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
	// A session is killed by one of its threads, never by its name.
	if (
		byThread ||
		action === 'kill-session' ||
		(action !== 'new-session' && fields.thread !== undefined)
	) {
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
		const home = host === 'localhost' ? '/Users/me' : '/home/me';
		Object.assign(made, { command: 'zsh', chat: false, cwd: dir ?? home });
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
	// The search captures plain text: no colours.
	// eslint-disable-next-line no-control-regex
	const shown = screen(t).map((line) => line.replace(/\u001b\[[0-9;]*m/g, ''));
	while (shown.length && !shown.at(-1).trim()) shown.pop();
	return [...run, '', '  60 passed (4.1s)', '', ...shown];
}

const FIND_MAX_QUERY = 200;
const FIND_MAX_MATCHES = 200;

/** Find in a pane's scrollback: plain text, no case until the query has an uppercase letter. */
function findApi(res, url, thread) {
	if (!capabilities.find) return send(res, 403, { error: 'disabled' });
	if (findBusy > 0) {
		findBusy -= 1;
		return send(res, 409, { error: 'busy', message: 'Another find is running' });
	}
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

/** A pane's lines as the screen routes answer them. */
function sendScreen(req, res, url, all) {
	// Same rules as the Mac: digits only, else the default; then 1 to the cap.
	const asked = url.searchParams.get('lines') ?? '';
	const lines = Math.min(
		Math.max(/^\d+$/.test(asked) ? Number(asked) : screenDefault, 1),
		screenMax
	);
	const text = all.slice(-lines).join('\n');
	const etag = `"${createHash('sha1').update(`${lines}\n${text}`).digest('hex').slice(0, 16)}"`;
	if (req.headers['if-none-match'] === etag) {
		res.writeHead(304, { etag, 'cache-control': 'no-store' });
		return res.end();
	}
	res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store', etag });
	return res.end(JSON.stringify({ text, lines, max: screenMax }));
}

const chatPage = (all, url) => {
	const after = url.searchParams.get('after');
	return {
		messages: after === null ? all : all.slice(Number(after)),
		next: all.length,
		reset: false
	};
};

/** The manager pane as a terminal shows it: its last reply, then its input box or its spinner. */
function managerScreen() {
	const box = '─'.repeat(52);
	const last = manager.chat.filter((m) => m.role === 'assistant').at(-1)?.text ?? '';
	return [
		`${E}[32m⏺${E}[0m ${last}`,
		'',
		...(manager.turn ? [`✻ ${manager.turn.spinner ?? 'Thinking…'}`, ''] : []),
		`╭${box}╮`,
		`│ >${' '.repeat(50)}│`,
		`╰${box}╯`,
		manager.status === 'waiting' ? '  Do you want to proceed? ❯ 1. Yes  2. No' : '  ? for shortcuts'
	];
}

// A P-256 public key (the sender key of the RFC 8291 example), as the Mac's.
const PUSH_KEY =
	'BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8';
const PUSH_HOSTS = [
	'web.push.apple.com',
	'fcm.googleapis.com',
	'updates.push.services.mozilla.com'
];

/** The Mac's push routes: the key, and what a phone subscribes and shows. */
function pushApi(req, res, path, body) {
	if (!capabilities.notifications) return send(res, 403, { error: 'disabled' });
	if (path === '/api/push/key')
		return req.method === 'GET'
			? send(res, 200, { key: PUSH_KEY })
			: send(res, 405, { error: 'method' });
	if (req.method !== 'POST') return send(res, 405, { error: 'method' });
	let sent;
	try {
		sent = JSON.parse(body);
	} catch {
		return send(res, 400, { error: 'bad_request' });
	}
	const endpoint = typeof sent.endpoint === 'string' ? sent.endpoint : '';
	const held = pushSubs.some((sub) => sub.endpoint === endpoint);
	if (path === '/api/push/subscribe') {
		let host = '';
		try {
			const url = new URL(endpoint);
			if (url.protocol === 'https:' && !url.username && !url.port) host = url.hostname;
		} catch {
			// Refused below.
		}
		if (!PUSH_HOSTS.includes(host) || !sent.keys?.p256dh || !sent.keys?.auth)
			return send(res, 400, { error: 'bad_subscription' });
		if (!held && pushLimit) return send(res, 409, { error: 'limit' });
		if (!held) pushSubs.push({ endpoint, keys: sent.keys });
		return send(res, 200, { ok: true });
	}
	if (path === '/api/push/unsubscribe') {
		pushSubs = pushSubs.filter((sub) => sub.endpoint !== endpoint);
		delete pushFocus[endpoint];
		return send(res, 200, { ok: true });
	}
	if (path === '/api/push/focus') {
		if (!held) return send(res, 404, { error: 'not_found' });
		pushFocus[endpoint] = sent.thread ?? null;
		return send(res, 200, { ok: true });
	}
	return send(res, 404, { error: 'not_found' });
}

function api(req, res, url, body) {
	if (req.headers['x-muxmaestro-token'] !== token) return send(res, 401, { error: 'unpaired' });
	if (deny) return send(res, 403, { error: 'forbidden' });
	if (req.method !== 'GET' && !sameOriginWrite(req)) return send(res, 403, { error: 'forbidden' });
	const path = url.pathname;
	if (path === '/api/threads') return send(res, 200, threadsBody());
	if (path === '/api/hosts') return send(res, 200, hostsBody());
	if (path === '/api/config') return send(res, 200, configBody());
	if (path.startsWith('/api/manager')) return managerApi(req, res, url, String(body));
	if (path === '/api/requests' || path.startsWith('/api/requests/'))
		return requestsApi(req, res, path, String(body));
	if (path.startsWith('/api/voice')) return voiceApi(req, res, url, body);
	if (path.startsWith('/api/push/')) return pushApi(req, res, path, String(body));
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
	if (match[2] === 'screen') return sendScreen(req, res, url, screen(thread));
	const all = chats[thread.id];
	if (!all) return send(res, 404, { error: 'not_found' });
	const after = url.searchParams.get('after');
	return send(res, 200, {
		messages: after === null ? all : all.slice(Number(after)),
		next: all.length,
		reset: false
	});
}

/** One numbered line of the log pane. A few carry things the parser must handle. */
function logLine(n) {
	const label = `line ${String(n).padStart(3, '0')}`;
	const rest = `  build step ${n} of the nightly run finished without warnings (${(n * 37) % 900}ms)`;
	if (n === 100) return `${E}[38;5;208m${label}${E}[0m${rest}`;
	if (n === 200) return `${E}[38;2;255;100;0m${label}${E}[0m${rest}`;
	if (n === 300) return `${label}  <script>alert(1)</script>`;
	if (n === 400) return `${E}]0;window title\x07${label}  after a title${E}[K`;
	if (n === 450) return `${E}[1;7m${label}${E}[0m${E}[2m${rest}${E}[0m`;
	if (n === 460) return `${E}[44m${label}${E}[49m ${E}[3;4mitalic underline${E}[0m`;
	return `${E}[${31 + (n % 6)}m${label}${E}[0m${rest}`;
}

function appendLog(count) {
	for (let i = 0; i < count; i += 1) log.push(logLine(log.length + 1));
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
		case '/__fixture/find-busy':
			findBusy = Number(url.searchParams.get('value') ?? 1);
			return send(res, 200, { ok: true });
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
				...(url.searchParams.get('scrolled')
					? scrolledMenu(Number(url.searchParams.get('scrolled')))
					: url.searchParams.get('kind') === 'question'
						? QUESTION
						: PERMISSION),
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
		case '/__fixture/prompt-delay':
			promptDelay = Number(url.searchParams.get('ms') ?? 0);
			return send(res, 200, { ok: true });
		case '/__fixture/text-slow':
			textSlow = Number(url.searchParams.get('ms') ?? 0);
			return send(res, 200, { ok: true });
		case '/__fixture/build':
			buildTag = url.searchParams.get('tag');
			return send(res, 200, { ok: true });
		case '/__fixture/upload-slow':
			// `chunk`: a wait after each piece of the body is read, so the phone's
			// progress has steps. `answer`: a wait before the answer.
			uploadSlow = {
				chunk: Number(url.searchParams.get('chunk') ?? 0),
				answer: Number(url.searchParams.get('answer') ?? 0)
			};
			return send(res, 200, { ok: true });
		case '/__fixture/upload-fail':
			// The next upload is refused, once.
			uploadFail = {
				status: Number(url.searchParams.get('status') ?? 503),
				body: {
					error: url.searchParams.get('error') ?? 'unavailable',
					...(url.searchParams.get('message') ? { message: url.searchParams.get('message') } : {})
				}
			};
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
				role: url.searchParams.get('role') ?? 'assistant',
				text: url.searchParams.get('text') ?? ''
			});
			thread.lastActivityAt = now;
			break;
		case '/__fixture/grouping':
			grouping = url.searchParams.get('value') ?? 'recent';
			push('config', configBody());
			break;
		case '/__fixture/append':
			appendLog(Number(url.searchParams.get('count') ?? 1));
			// The row changes too, so an open thread view fetches at once.
			threads.find((t) => t.id === LOG_ID).since = now + log.length;
			break;
		case '/__fixture/screen':
			screenDefault = Number(url.searchParams.get('default') ?? 2000);
			screenMax = Number(url.searchParams.get('max') ?? 10000);
			return send(res, 200, { ok: true });
		case '/__fixture/rotate':
			token = url.searchParams.get('value') ?? 'rotated-token';
			dropStreams();
			return send(res, 200, { ok: true });
		case '/__fixture/terminal':
			return send(res, 200, {
				typed: terminalTyped,
				opens: terminalOpens,
				sockets: terminals.size
			});
		case '/__fixture/terminal-drop':
			for (const socket of terminals) socket.terminate();
			terminals.clear();
			return send(res, 200, { ok: true });
		case '/__fixture/terminal-say':
			for (const socket of terminals) socket.send(Buffer.from(url.searchParams.get('text') ?? ''));
			return send(res, 200, { ok: true });
		case '/__fixture/terminal-refuse':
			terminalRefuse = Number(url.searchParams.get('code')) || 0;
			return send(res, 200, { ok: true });
		case '/__fixture/drop':
			dropStreams();
			return send(res, 200, { ok: true });
		case '/__fixture/deny':
			deny = url.searchParams.get('on') === '1';
			// A refused device gets no events: nothing is pushed.
			return send(res, 200, { ok: true });
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
		case '/__fixture/push':
			return send(res, 200, { subscriptions: pushSubs, focus: pushFocus });
		case '/__fixture/push-forget':
			pushSubs = [];
			pushFocus = {};
			break;
		case '/__fixture/push-limit':
			pushLimit = url.searchParams.get('on') === '1';
			break;
		case '/__fixture/mappings':
			return send(res, 200, { mappings });
		case '/__fixture/requests':
			return send(res, 200, requests);
		case '/__fixture/requests-mode':
			requestsCorrupt = url.searchParams.get('value') === 'corrupt';
			break;
		case '/__fixture/requests-fail':
			requestsFail = {
				status: Number(url.searchParams.get('status') ?? 409),
				error: url.searchParams.get('error') ?? 'busy'
			};
			break;
		case '/__fixture/requests-set': {
			// The agent changed a row on the Mac, behind the phone's back.
			const row = requests.requests.find((request) => request.id === id);
			if (!row) return send(res, 404, { error: 'not_found' });
			row.state = url.searchParams.get('state') ?? 'todo';
			break;
		}
		case '/__fixture/manager-prompt': {
			// The manager pane asks something: `kind`, `bare=1`, `scrolled=<last row>`, `pid=`.
			const shape = url.searchParams.get('scrolled')
				? scrolledMenu(Number(url.searchParams.get('scrolled')))
				: url.searchParams.get('kind') === 'permission'
					? PERMISSION
					: QUESTION;
			promptSeq += 1;
			manager.prompt = {
				id: url.searchParams.get('pid') ?? `m${promptSeq}`,
				...shape,
				truncated: false,
				...(url.searchParams.get('bare') === '1' ? { bare: true } : {})
			};
			if (url.searchParams.get('quiet') !== '1') manager.status = 'waiting';
			return send(res, 200, { ok: true });
		}
		case '/__fixture/point': {
			// As `mux point <session> --reason …` records it: the Mac resolves the thread.
			const key = url.searchParams.get('key') ?? 'point:localhost:acme-app';
			manager.points = [
				...manager.points.filter((item) => item.key !== key),
				{
					key,
					title: url.searchParams.get('title') ?? 'acme-app',
					detail: url.searchParams.get('reason') ?? 'needs your approval',
					severity: 'blocked',
					at: now,
					thread: url.searchParams.get('thread')
				}
			];
			break;
		}
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
			runTurn(
				url.searchParams.get('text') ?? '',
				url.searchParams.get('reply') ?? '',
				undefined,
				undefined,
				url.searchParams.get('spinner'),
				Number(url.searchParams.get('ms') ?? 40)
			);
			break;
		default:
			return send(res, 404, { error: 'not_found' });
	}
	push('threads', threadsBody());
	push('hosts', hostsBody());
	if (capabilities.manager) push('manager', managerLive());
	return send(res, 200, { ok: true });
}

// The policy the Mac sends with the app shell: only the app's own scripts
// run, and the one inline script of the shell is named by its hash.
let shellPolicy;
async function policy() {
	if (shellPolicy) return shellPolicy;
	const shell = await readFile(join(ROOT, 'index.html'), 'utf8');
	const hashes = [...shell.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi)].map(
		([, text]) => `'sha256-${createHash('sha256').update(text).digest('base64')}'`
	);
	shellPolicy = [
		"default-src 'self'",
		["script-src 'self'", ...hashes].join(' '),
		"style-src 'self' 'unsafe-inline'",
		"img-src 'self' data: blob:",
		"media-src 'self' data: blob:",
		"font-src 'self' data:",
		// As the Mac does: the app's own socket address, named.
		`connect-src 'self' ws://127.0.0.1:${PORT}`,
		"worker-src 'self'",
		"manifest-src 'self'",
		"frame-src 'none'",
		"object-src 'none'",
		"base-uri 'none'",
		"form-action 'none'",
		"frame-ancestors 'none'"
	].join('; ');
	return shellPolicy;
}

async function asset(res, url) {
	const rel = normalize(decodeURIComponent(url.pathname)).replace(/^(\.\.[/\\])+/, '');
	const file = join(ROOT, rel);
	const wanted = file.startsWith(ROOT) && extname(file) ? file : join(ROOT, 'index.html');
	try {
		let body = await readFile(wanted);
		// A later build of the app: the worker's bytes differ, and the page says which it is.
		if (buildTag && wanted.endsWith('service-worker.js')) {
			// A new build has a new version, so its worker keeps its own cache.
			const { version } = JSON.parse(await readFile(join(ROOT, '_app/version.json'), 'utf8'));
			body = Buffer.from(String(body).replaceAll(version, `${version}-${buildTag}`));
		}
		if (buildTag && wanted.endsWith('index.html'))
			body = Buffer.from(
				String(body).replace('</head>', `<meta name="mm-build" content="${buildTag}" /></head>`)
			);
		res.writeHead(200, {
			'content-security-policy': await policy(),
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

// A test run that loses its server should be able to say why.
process.on('uncaughtException', (error) => {
	console.error('fixture server crashed:', error);
	process.exit(1);
});
for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP'])
	process.on(signal, () => {
		console.error(`fixture server stopped by ${signal}`);
		process.exit(0);
	});

// The live terminal: a pane of 100 x 30 with some scrollback and a prompt.
// What is typed is echoed, and Enter "runs" the line.
const TERMINAL = { cols: 100, rows: 30 };
function terminalScreen() {
	const lines = [];
	for (let n = 1; n <= 80; n += 1) {
		lines.push(
			`${E}[${31 + (n % 6)}mbuild ${String(n).padStart(3, '0')}${E}[0m compiling acme-app`
		);
	}
	return `${lines.join('\r\n')}\r\nme@devbox acme-app % `;
}

const sockets = new WebSocketServer({ noServer: true, maxPayload: 4096 });

function terminal(socket) {
	let paired = false;
	let line = '';
	const timer = setTimeout(() => !paired && socket.close(4401), 2000);
	socket.on('close', () => {
		clearTimeout(timer);
		terminals.delete(socket);
	});
	socket.on('message', (data, binary) => {
		if (!paired) {
			// The first message is the pairing token, as text. Nothing else is.
			if (binary || String(data) !== token) return socket.close(4401);
			paired = true;
			if (terminalRefuse) return socket.close(terminalRefuse);
			if (!threads.some((t) => t.id === socket.thread)) return socket.close(4404);
			terminals.add(socket);
			socket.send(JSON.stringify({ type: 'ready', ...TERMINAL }));
			socket.send(Buffer.from(terminalScreen()));
			return;
		}
		if (!binary) return socket.close(1003);
		const text = String(data);
		terminalTyped += text;
		let skip = 0;
		for (const char of text) {
			// An arrow is three bytes: none of them is part of the line.
			if (char === '\x1b') skip = 3;
			if (skip > 0) skip -= 1;
			else if (char === '\r') {
				socket.send(Buffer.from(`\r\nran: ${line}\r\nme@devbox acme-app % `));
				line = '';
			} else if (char >= ' ') {
				line += char;
				socket.send(Buffer.from(char));
			}
		}
	});
}

function upgrade(req, socket, head) {
	const url = new URL(req.url, `http://${req.headers.host}`);
	const refuse = (status) => socket.end(`HTTP/1.1 ${status} Refused\r\nConnection: close\r\n\r\n`);
	const made = /^\/api\/terminal\/([^/]+)$/.exec(url.pathname);
	if (!made) return refuse(404);
	terminalOpens.push({
		url: req.url,
		token: req.headers['x-muxmaestro-token'] ?? null,
		protocol: req.headers['sec-websocket-protocol'] ?? null
	});
	if (!capabilities.liveTerminal) return refuse(403);
	// The one check that keeps another site's page out.
	if (req.headers.origin !== `http://${req.headers.host}`) return refuse(403);
	if (url.search) return refuse(400);
	sockets.handleUpgrade(req, socket, head, (ws) => {
		ws.thread = decodeURIComponent(made[1]);
		terminal(ws);
	});
}

const server = createServer((req, res) => {
	const url = new URL(req.url, `http://${req.headers.host}`);
	if (url.pathname.startsWith('/api/')) {
		// A take is audio: the body stays bytes until a route wants text.
		const chunks = [];
		const slow = url.pathname.endsWith('/upload') ? uploadSlow.chunk : 0;
		req.on('data', (chunk) => {
			chunks.push(chunk);
			if (!slow) return;
			// Read no faster than this, so the sender sees its bytes go out in steps.
			req.pause();
			setTimeout(() => req.resume(), slow);
		});
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
		return req.method === 'POST' || (req.method === 'GET' && url.pathname === '/__fixture/requests')
			? hook(res, url)
			: send(res, 405, { error: 'method' });
	return asset(res, url);
});
server.on('upgrade', upgrade);
server.listen(PORT, '127.0.0.1', () => console.log(`fixture server on http://127.0.0.1:${PORT}`));

setInterval(() => {
	for (const res of streams) res.write(': ping\n\n');
}, 15000).unref();
