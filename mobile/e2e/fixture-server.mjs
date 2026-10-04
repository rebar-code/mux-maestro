// A stand-in for the Mac app, for tests and screenshots: it serves the built
// bundle and the same JSON API, from demo data only.
//
//   PORT=5199 node e2e/fixture-server.mjs
//
// Test hooks (POST): /__fixture/reset, /__fixture/wait?id=, /__fixture/say?id=&text=,
// /__fixture/grouping?value=, /__fixture/deny?on=1, /__fixture/rotate?value=, /__fixture/drop,
// /__fixture/capability?name=&on=, /__fixture/manager-status?value=,
// /__fixture/mac-turn?text=&reply=&spinner=&ms= (ms: the pause between words),
// /__fixture/voice?mode=&speaker=&heard=&delay=, /__fixture/voice-takes,
// /__fixture/replies, /__fixture/prompt?id=&pid=&kind=,
// /__fixture/upload-max?value=, /__fixture/status?id=&value=,
// /__fixture/prompt also takes truncated=1, bare=1 (an id with no choices), quiet=1,
// scrolled=<last row> (a menu scrolled to rows 4…last, with more above and below),
// /__fixture/not-sent?cleared=&reason=, /__fixture/no-input?id=&on=, /__fixture/pasted?on=,
// /__fixture/prompt-delay?ms=, /__fixture/upload-slow?chunk=&answer=,
// /__fixture/upload-fail?status=&error=&message=,
// /__fixture/append?count= (adds lines to pane buildbox:8),
// /__fixture/screen?default=&max= (the screen endpoint's default and cap)
//
// Every /api/ request needs the header `X-MuxMaestro-Token: demo-token`.
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

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
let started, threads, chats, grouping, deny, token, log, screenDefault, screenMax;
let capabilities, manager, voice;
// Per thread id: the prompt on the pane. And everything the phone wrote.
let prompts, replies, uploadMax, promptSeq, notSent, noInput, pasted, keyLocks, promptDelay;
// Uploads: the paths taken, the threads with one in flight, how slow they are, a refusal for the next.
let saved, uploadLocks, uploadSlow, uploadFail;
const streams = new Set();

function reset() {
	started = Math.floor(Date.now() / 1000);
	grouping = 'recent';
	deny = false;
	token = DEMO_TOKEN;
	capabilities = { manager: true, voice: false, replies: false, keyBar: false, upload: false };
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
	promptSeq = 0;
	uploadMax = 10485760;
	replies = { texts: [], keys: [], answers: [], uploads: [], left: [], commandFetches: 0 };
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
		sessionActions: false,
		kill: false,
		artifacts: false,
		localServers: false,
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
		// Nobody could read what Enter or a digit would pick.
		// The keys that submit, and the digits, which pick a row.
		const picks = /^(Enter|C-[mjdo]|BTab|[1-9])$/.test(json.key);
		if (asked?.bare && picks)
			return send(res, 409, { error: 'unseen', message: 'Open the terminal to answer' });
		// No prompt and no input box in sight: the key would land nobody knows where.
		if (!asked && picks && noInput.has(thread.id))
			return send(res, 409, { error: 'no_input', message: 'Thread shows no input box' });
		if (asked && /^[1-9]$/.test(json.key) && !asked.options.some((o) => o.n === Number(json.key)))
			return send(res, 409, { error: 'no_option', message: 'Not a choice on the card' });
		keyLocks.add(thread.id);
		const locks = keyLocks;
		return void setTimeout(() => {
			locks.delete(thread.id);
			// An arrow moves the pane's cursor, and the prompt's id names the row it is on.
			const step = { Up: -1, Down: 1 }[json.key];
			if (asked && !asked.bare && step) {
				asked.base ??= asked.id;
				const rows = asked.options.map((o) => o.n);
				asked.selected = Math.min(rows.at(-1), Math.max(rows[0], asked.selected + step));
				asked.first ??= rows[0];
				asked.id =
					asked.selected === asked.first ? asked.base : `${asked.base}-row${asked.selected}`;
			}
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
		// The pane has a key for 1 to 9 only.
		if (json.option > 9 || !prompt.options.some((option) => option.n === json.option))
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

function api(req, res, url, body) {
	if (req.headers['x-muxmaestro-token'] !== token) return send(res, 401, { error: 'unpaired' });
	if (deny) return send(res, 403, { error: 'forbidden' });
	if (req.method !== 'GET' && !sameOriginWrite(req)) return send(res, 403, { error: 'forbidden' });
	const path = url.pathname;
	if (path === '/api/threads') return send(res, 200, threadsBody());
	if (path === '/api/hosts') return send(res, 200, hostsBody());
	if (path === '/api/config') return send(res, 200, configBody());
	if (path.startsWith('/api/manager')) return managerApi(req, res, url, String(body));
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
	const match =
		/^\/api\/threads\/([^/]+)\/(chat|screen|text|key|prompt|answer|commands|upload)$/.exec(path);
	const thread = match && threads.find((t) => t.id === decodeURIComponent(match[1]));
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
				role: 'assistant',
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

createServer((req, res) => {
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
	if (url.pathname.startsWith('/__fixture/'))
		return req.method === 'POST' ? hook(res, url) : send(res, 405, { error: 'method' });
	return asset(res, url);
}).listen(PORT, '127.0.0.1', () => console.log(`fixture server on http://127.0.0.1:${PORT}`));

setInterval(() => {
	for (const res of streams) res.write(': ping\n\n');
}, 15000).unref();
