/**
 * The phone's own log: what went wrong here, sent to the Mac in batches and
 * kept there in a file that `mux phone-log` reads. Errors and metadata only:
 * a line never holds message text or anything a person typed.
 *
 * This module is the part with no DOM: the line, the batcher and the rules
 * for what a line may say. `observe.ts` listens to the page and feeds it.
 */

export type Severity = 'info' | 'warn' | 'error';
export type Fields = Record<string, string | number | boolean | string[] | null | undefined>;

export interface Line {
	/** When it happened: `Date.now()`. */
	at: number;
	sev: Severity;
	/** What it is about: `error`, `fetch`, `sw`, `life`, … */
	kind: string;
	msg: string;
	/** How many times it happened while it waited to be sent. */
	n: number;
	fields: Fields;
}

/** A line as the Mac gets it. `age` is how long ago it happened, in ms. */
export type WireLine = Record<string, string | number | boolean | string[]>;

/** `ok`: the Mac has them. `retry`: it was not reached; keep them. `drop`: it refused them. */
export type Sent = 'ok' | 'retry' | 'drop';

const MSG_LIMIT = 300;
const STACK_LIMIT = 1500;

/** Lines are sent this long after the last one came in… */
export const QUIET_MS = 2000;
/** …and never later than this after the first one. */
export const MAX_WAIT_MS = 10_000;
/** Lines held in memory. One more pushes out the oldest. */
export const BUFFER_CAP = 200;
/**
 * Lines in one request. The Mac reads no body past `BODY_LIMIT`, and the
 * longest line (a full stack) is about 3 kB, so a full batch always fits.
 */
export const BATCH = 16;
/** The largest body the Mac's log route reads (`MobileLog.maxBodyBytes`). */
export const BODY_LIMIT = 65_536;
export const RETRY_MS = 5000;
export const RETRY_MAX_MS = 60_000;

export interface BatcherOptions {
	/** `last`: the page is going away, so the request must outlive it. */
	send: (lines: WireLine[], last: boolean) => Promise<Sent>;
	now?: () => number;
	setTimer?: (run: () => void, ms: number) => unknown;
	clearTimer?: (timer: unknown) => void;
	quietMs?: number;
	maxWaitMs?: number;
	cap?: number;
	batch?: number;
	retryMs?: number;
	retryMaxMs?: number;
}

/**
 * Holds lines in memory and sends them in batches. A page that fails in a
 * loop does not flood the Mac: the same line again is counted, not added, and
 * the buffer has a cap. A network that comes and goes loses nothing that
 * fits the buffer: a batch the Mac did not get is kept and sent again later.
 */
export class Batcher {
	private lines: Line[] = [];
	/** Lines in a request that has not been answered. */
	private flying = new Set<Line>();
	/** Lines the cap pushed out since the Mac was last told. */
	private dropped = 0;
	private timer: unknown = null;
	/** When the oldest line that waits for the quiet timer came in. */
	private waitingSince: number | null = null;
	/** The wait before the next try, while the Mac is not reached. */
	private backoff = 0;

	private readonly send: BatcherOptions['send'];
	private readonly now: () => number;
	private readonly setTimer: (run: () => void, ms: number) => unknown;
	private readonly clearTimer: (timer: unknown) => void;
	private readonly quietMs: number;
	private readonly maxWaitMs: number;
	private readonly cap: number;
	private readonly batch: number;
	private readonly retryMs: number;
	private readonly retryMaxMs: number;

	constructor(options: BatcherOptions) {
		this.send = options.send;
		this.now = options.now ?? Date.now;
		this.setTimer = options.setTimer ?? ((run, ms) => setTimeout(run, ms));
		this.clearTimer =
			options.clearTimer ?? ((timer) => clearTimeout(timer as ReturnType<typeof setTimeout>));
		this.quietMs = options.quietMs ?? QUIET_MS;
		this.maxWaitMs = options.maxWaitMs ?? MAX_WAIT_MS;
		this.cap = options.cap ?? BUFFER_CAP;
		this.batch = options.batch ?? BATCH;
		this.retryMs = options.retryMs ?? RETRY_MS;
		this.retryMaxMs = options.retryMaxMs ?? RETRY_MAX_MS;
	}

	/** Lines held, sent or not. */
	get size(): number {
		return this.lines.length;
	}

	push(line: Line): void {
		const same = this.waiting().find(
			(held) => held.sev === line.sev && held.kind === line.kind && held.msg === line.msg
		);
		if (same) {
			same.n += line.n;
			return;
		}
		this.lines.push(line);
		while (this.lines.length > this.cap) {
			const oldest = this.lines.findIndex((held) => !this.flying.has(held));
			if (oldest < 0) break;
			this.lines.splice(oldest, 1);
			this.dropped += 1;
		}
		// While the Mac is out of reach the next try is already set.
		if (this.backoff > 0) return;
		const now = this.now();
		this.waitingSince ??= now;
		this.schedule(Math.max(0, Math.min(this.quietMs, this.waitingSince + this.maxWaitMs - now)));
	}

	/**
	 * Send what waits, now. With `last` (the page is hidden or closed) it does
	 * not wait for a request that is still out.
	 */
	async flush(last = false): Promise<void> {
		if (!last && this.flying.size > 0) return;
		const batch = this.waiting().slice(0, this.batch);
		if (batch.length === 0) return;
		this.unschedule();
		this.waitingSince = null;
		for (const line of batch) this.flying.add(line);
		const now = this.now();
		const wire = batch.map((line) => wireLine(line, now));
		const dropped = this.dropped;
		this.dropped = 0;
		if (dropped > 0) {
			wire.unshift({
				age: 0,
				sev: 'warn',
				kind: 'dropped',
				msg: `${dropped} lines did not fit the phone's buffer`,
				n: dropped
			});
		}
		let sent: Sent;
		try {
			sent = await this.send(wire, last);
		} catch {
			sent = 'retry';
		}
		for (const line of batch) this.flying.delete(line);
		if (sent === 'retry') {
			this.dropped += dropped;
			this.backoff = this.backoff ? Math.min(this.backoff * 2, this.retryMaxMs) : this.retryMs;
			this.schedule(this.backoff);
			return;
		}
		this.backoff = 0;
		this.lines = this.lines.filter((line) => !batch.includes(line));
		if (this.waiting().length > 0) this.schedule(0);
	}

	private waiting(): Line[] {
		return this.lines.filter((line) => !this.flying.has(line));
	}

	private schedule(ms: number): void {
		this.unschedule();
		this.timer = this.setTimer(() => {
			this.timer = null;
			void this.flush();
		}, ms);
	}

	private unschedule(): void {
		if (this.timer === null) return;
		this.clearTimer(this.timer);
		this.timer = null;
	}
}

function wireLine(line: Line, now: number): WireLine {
	const wire: WireLine = {};
	for (const [key, value] of Object.entries(line.fields)) {
		if (value !== undefined && value !== null) wire[key] = value;
	}
	wire.age = Math.max(0, now - line.at);
	wire.sev = line.sev;
	wire.kind = line.kind;
	wire.msg = line.msg;
	if (line.n > 1) wire.n = line.n;
	return wire;
}

// Lines recorded before `observe.ts` has started wait here.
const EARLY_CAP = 50;
const early: Line[] = [];
let sink: ((line: Line) => void) | null = null;

/**
 * Add a line to the phone log. `fields` are numbers, flags and short names:
 * a path, a status, a duration. Never text a person typed. A `thread` field
 * (a thread id) names the project the line belongs to. It never throws.
 */
export function record(sev: Severity, kind: string, msg: string, fields: Fields = {}): void {
	const line: Line = { at: Date.now(), sev, kind, msg: clip(msg, MSG_LIMIT), n: 1, fields };
	try {
		if (sink) sink(line);
		else if (early.length < EARLY_CAP) early.push(line);
	} catch {
		// The log must never be the thing that breaks the app.
	}
}

/** Where recorded lines go from now on. The ones that waited go there first. */
export function attach(to: (line: Line) => void): void {
	sink = to;
	for (const line of early.splice(0)) to(line);
}

function clip(text: string, limit: number): string {
	return text.length <= limit ? text : `${text.slice(0, limit)}…`;
}

/**
 * An address as the log keeps it: the path alone. The query is left out: it
 * can hold what was typed (a search) or a file's name.
 */
export function pathOf(url: string, base: string): string {
	try {
		const parsed = new URL(url, base);
		return parsed.origin === new URL(base).origin
			? parsed.pathname
			: parsed.origin + parsed.pathname;
	} catch {
		return '(not an address)';
	}
}

/** The thread a path is about: `/t/<id>`, `/api/threads/<id>/…`, `/api/terminal/<id>`. */
export function threadIn(path: string): string | null {
	const found = /^\/(?:t|api\/threads|api\/terminal)\/([^/]+)/.exec(path);
	if (!found) return null;
	try {
		return decodeURIComponent(found[1]);
	} catch {
		return found[1];
	}
}

/**
 * Text between double quotes, taken out. A parse error quotes the text it
 * could not read, and that text can be a message.
 */
export function unquoted(text: string): string {
	return text.replace(/"[^"]*"/g, '"…"');
}

export interface ErrorNote {
	msg: string;
	name?: string;
	stack?: string;
}

/** What the log keeps of a thrown value: its name, its message, its stack. */
export function describeError(error: unknown, origin: string): ErrorNote {
	if (error instanceof Error) {
		const stack =
			typeof error.stack === 'string' && error.stack !== ''
				? clip(unquoted(error.stack.split(origin).join('')), STACK_LIMIT)
				: undefined;
		return {
			msg: clip(unquoted(error.message) || error.name, MSG_LIMIT),
			name: error.name,
			...(stack ? { stack } : {})
		};
	}
	// A value that is not an error is named by its type alone: what it holds
	// could be anything.
	const text = typeof error === 'string' ? error : Object.prototype.toString.call(error);
	return { msg: clip(unquoted(text), MSG_LIMIT) };
}

/** `18.5` from an iPhone's or iPad's user agent; null on anything else. */
export function iosVersion(agent: string): string | null {
	const found = /(?:iPhone|iPad|iPod).*? OS (\d+)_(\d+)(?:_(\d+))?/.exec(agent);
	if (!found) return null;
	return found.slice(1).filter(Boolean).join('.');
}

/** A request the Mac refused is a warning; one it failed at is an error. */
export function statusSeverity(status: number): Severity {
	return status >= 500 ? 'error' : 'warn';
}
