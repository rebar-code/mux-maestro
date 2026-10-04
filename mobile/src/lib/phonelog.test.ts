import { describe, expect, it } from 'vitest';
import {
	BATCH,
	Batcher,
	BODY_LIMIT,
	describeError,
	iosVersion,
	pathOf,
	statusSeverity,
	threadIn,
	unquoted,
	type Line,
	type Sent,
	type WireLine
} from './phonelog';

/** A clock and timers the test moves by hand. */
function world(answer: () => Sent | Promise<Sent> = () => 'ok') {
	let now = 1000;
	let nextId = 1;
	const timers = new Map<number, { at: number; run: () => void }>();
	const sent: { lines: WireLine[]; last: boolean }[] = [];
	const batcher = new Batcher({
		send: async (lines, last) => {
			sent.push({ lines, last });
			return answer();
		},
		now: () => now,
		setTimer: (run, ms) => {
			timers.set(nextId, { at: now + ms, run });
			return nextId++;
		},
		clearTimer: (timer) => void timers.delete(timer as number),
		quietMs: 2000,
		maxWaitMs: 10_000,
		cap: 5,
		batch: 3,
		retryMs: 5000,
		retryMaxMs: 20_000
	});
	/** Move the clock, run what came due, and let the sends settle. */
	const advance = async (ms: number): Promise<void> => {
		const until = now + ms;
		for (;;) {
			const due = [...timers.entries()]
				.filter(([, timer]) => timer.at <= until)
				.sort((a, b) => a[1].at - b[1].at)[0];
			if (!due) break;
			timers.delete(due[0]);
			now = due[1].at;
			due[1].run();
			await settle();
		}
		now = until;
	};
	const line = (msg: string, kind = 'error'): Line => ({
		at: now,
		sev: 'error',
		kind,
		msg,
		n: 1,
		fields: {}
	});
	return { batcher, sent, advance, line, timers };
}

const settle = async (): Promise<void> => {
	for (let i = 0; i < 10; i++) await Promise.resolve();
};

const messages = (batch: { lines: WireLine[] }): unknown[] => batch.lines.map((l) => l.msg);

describe('Batcher', () => {
	it('sends nothing until the lines have been quiet for a while', async () => {
		const { batcher, sent, advance, line } = world();
		batcher.push(line('a'));
		await advance(1999);
		expect(sent).toHaveLength(0);
		await advance(1);
		expect(sent).toHaveLength(1);
		expect(messages(sent[0])).toEqual(['a']);
		expect(sent[0].last).toBe(false);
		expect(batcher.size).toBe(0);
	});

	it('starts the quiet wait again with each new line', async () => {
		const { batcher, sent, advance, line } = world();
		batcher.push(line('a'));
		await advance(1500);
		batcher.push(line('b'));
		await advance(1500);
		expect(sent).toHaveLength(0);
		await advance(500);
		expect(messages(sent[0])).toEqual(['a', 'b']);
	});

	it('never waits longer than the longest wait, however busy the page is', async () => {
		const { batcher, sent, advance, line } = world();
		// A new line every second: never two quiet seconds.
		for (let i = 0; i < 10; i++) {
			batcher.push(line(`a${i % 2}`, `k${i}`));
			if (i < 9) await advance(1000);
		}
		expect(sent).toHaveLength(0);
		await advance(1000);
		expect(sent.length).toBeGreaterThan(0);
	});

	it('stamps each line with how long ago it happened, not with the phone clock', async () => {
		const { batcher, sent, advance, line } = world();
		batcher.push(line('a'));
		await advance(2000);
		expect(sent[0].lines[0].age).toBe(2000);
	});

	it('sends at once when the page is hidden, as a request that outlives it', async () => {
		const { batcher, sent, line } = world();
		batcher.push(line('a'));
		await batcher.flush(true);
		expect(sent).toHaveLength(1);
		expect(sent[0].last).toBe(true);
		expect(batcher.size).toBe(0);
	});

	it('counts a line that repeats instead of adding it', async () => {
		const { batcher, sent, advance, line } = world();
		for (let i = 0; i < 100; i++) batcher.push(line('loop'));
		expect(batcher.size).toBe(1);
		await advance(2000);
		expect(sent).toHaveLength(1);
		expect(sent[0].lines).toHaveLength(1);
		expect(sent[0].lines[0].n).toBe(100);
	});

	it('holds no more than its cap: the oldest lines go, and the Mac is told how many', async () => {
		const { batcher, sent, advance, line } = world();
		for (let i = 0; i < 12; i++) batcher.push(line(`m${i}`));
		expect(batcher.size).toBe(5);
		await advance(2000);
		const all = sent.flatMap((batch) => batch.lines);
		const note = all.find((l) => l.kind === 'dropped');
		expect(note?.n).toBe(7);
		expect(all.filter((l) => l.kind !== 'dropped').map((l) => l.msg)).toEqual([
			'm7',
			'm8',
			'm9',
			'm10',
			'm11'
		]);
	});

	it('sends a long buffer in batches', async () => {
		const { batcher, sent, advance, line } = world();
		for (let i = 0; i < 5; i++) batcher.push(line(`m${i}`));
		await advance(2000);
		expect(sent.map((batch) => batch.lines.length)).toEqual([3, 2]);
	});

	it('keeps the lines when the Mac is not reached, and tries again later and later', async () => {
		let reach: Sent = 'retry';
		const { batcher, sent, advance, line } = world(() => reach);
		batcher.push(line('a'));
		await advance(2000);
		expect(sent).toHaveLength(1);
		expect(batcher.size).toBe(1);
		await advance(4999);
		expect(sent).toHaveLength(1);
		await advance(1);
		expect(sent).toHaveLength(2);
		// The second wait is twice the first.
		await advance(9999);
		expect(sent).toHaveLength(2);
		// A line that comes in meanwhile does not bring the next try forward.
		batcher.push(line('b'));
		reach = 'ok';
		await advance(1);
		expect(sent).toHaveLength(3);
		expect(messages(sent[2])).toEqual(['a', 'b']);
		expect(batcher.size).toBe(0);
	});

	it('keeps the lines when the send throws', async () => {
		const { batcher, sent, advance, line } = world(() => {
			throw new Error('offline');
		});
		batcher.push(line('a'));
		await advance(2000);
		expect(sent).toHaveLength(1);
		expect(batcher.size).toBe(1);
	});

	it('does not forget what the cap pushed out when the send that said so failed', async () => {
		let reach: Sent = 'retry';
		const { batcher, sent, advance, line } = world(() => reach);
		for (let i = 0; i < 7; i++) batcher.push(line(`m${i}`));
		await advance(2000);
		reach = 'ok';
		await advance(5000);
		const note = sent[sent.length - 2].lines.find((l) => l.kind === 'dropped');
		expect(note?.n).toBe(2);
	});

	it('drops lines the Mac refuses: the same lines again would be refused again', async () => {
		const { batcher, sent, advance, line, timers } = world(() => 'drop');
		batcher.push(line('a'));
		await advance(2000);
		expect(sent).toHaveLength(1);
		expect(batcher.size).toBe(0);
		expect(timers.size).toBe(0);
	});

	it('does not send a line twice when the page hides during a send', async () => {
		let release: (sent: Sent) => void = () => {};
		const { batcher, sent, advance, line } = world(
			() => new Promise<Sent>((done) => (release = done))
		);
		batcher.push(line('a'));
		await advance(2000);
		expect(sent).toHaveLength(1);
		batcher.push(line('b'));
		const hidden = batcher.flush(true);
		await settle();
		expect(sent).toHaveLength(2);
		expect(messages(sent[1])).toEqual(['b']);
		release('ok');
		await hidden;
	});

	it('sends no batch the Mac would refuse for its size, however long the lines are', async () => {
		const sent: WireLine[][] = [];
		const batcher = new Batcher({
			send: async (lines) => {
				sent.push(lines);
				return 'ok';
			}
		});
		for (let i = 0; i < BATCH * 2; i++) {
			// The longest line there is: a full message, a full stack, the device.
			const error = new Error(`${i} ${'m'.repeat(400)}`);
			error.stack = 'at f (/_app/immutable/chunks/a.js:1:2)\n'.repeat(100);
			const { msg, ...rest } = describeError(error, '');
			batcher.push({
				at: 0,
				sev: 'error',
				kind: 'error',
				msg,
				n: 1,
				fields: { ...rest, ua: 'u'.repeat(300), project: 'p'.repeat(64), src: 's'.repeat(300) }
			});
		}
		await batcher.flush();
		expect(sent[0]).toHaveLength(BATCH);
		const body = JSON.stringify({ sid: 'abcdefgh', build: 'a5c3b32afc8b', lines: sent[0] });
		expect(new TextEncoder().encode(body).length).toBeLessThan(BODY_LIMIT);
	});

	it('leaves out fields with no value', async () => {
		const { batcher, sent, advance, line } = world();
		batcher.push({ ...line('a'), fields: { status: 500, src: undefined, ios: null } });
		await advance(2000);
		expect(sent[0].lines[0]).toEqual({
			age: 2000,
			sev: 'error',
			kind: 'error',
			msg: 'a',
			status: 500
		});
	});
});

describe('what a line may say', () => {
	it('keeps the path of an address and never its query', () => {
		const base = 'https://devmac.example.ts.net:7433/t/localhost%3A3';
		expect(pathOf('/api/threads/localhost%3A3/find?q=my+secret+words', base)).toBe(
			'/api/threads/localhost%3A3/find'
		);
		expect(pathOf('https://devmac.example.ts.net:7433/_app/immutable/a.js#x', base)).toBe(
			'/_app/immutable/a.js'
		);
		expect(pathOf('https://other.example.com/x?y=1', base)).toBe('https://other.example.com/x');
	});

	it('finds the thread a path is about', () => {
		expect(threadIn('/t/localhost%3A3')).toBe('localhost:3');
		expect(threadIn('/api/threads/devbox%3A12/chat')).toBe('devbox:12');
		expect(threadIn('/api/terminal/localhost%3A3')).toBe('localhost:3');
		expect(threadIn('/api/threads')).toBeNull();
		expect(threadIn('/')).toBeNull();
	});

	it('takes quoted text out of a message: a parse error quotes what it read', () => {
		expect(unquoted('Unexpected token \'h\', "hello wor"... is not valid JSON')).toBe(
			'Unexpected token \'h\', "…"... is not valid JSON'
		);
	});

	it('describes an error by name, message and stack, without the origin', () => {
		const error = new TypeError('x is not a function');
		error.stack = 'f@https://devmac.example.ts.net:7433/_app/immutable/a.js:1:20';
		expect(describeError(error, 'https://devmac.example.ts.net:7433')).toEqual({
			msg: 'x is not a function',
			name: 'TypeError',
			stack: 'f@/_app/immutable/a.js:1:20'
		});
	});

	it('names a thrown value that is not an error by its type alone', () => {
		expect(describeError({ text: 'a message someone wrote' }, '')).toEqual({
			msg: '[object Object]'
		});
		expect(describeError('plain', '')).toEqual({ msg: 'plain' });
	});

	it('cuts a long message', () => {
		expect(describeError(new Error('x'.repeat(1000)), '').msg).toHaveLength(301);
	});

	it('reads the iOS version from the user agent', () => {
		expect(
			iosVersion('Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15')
		).toBe('18.5');
		expect(iosVersion('Mozilla/5.0 (iPad; CPU OS 17_6_1 like Mac OS X)')).toBe('17.6.1');
		expect(iosVersion('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)')).toBeNull();
	});

	it('calls a refusal a warning and a failure of the Mac an error', () => {
		expect(statusSeverity(404)).toBe('warn');
		expect(statusSeverity(503)).toBe('error');
	});
});
