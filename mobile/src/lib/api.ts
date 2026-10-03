import { tokenFrom, withoutPair } from './pairing';
import { frameParser, readOrStall, STALLED, type Frame } from './sse';
import type { ChatPage, Config, Host, ManagerHome, Thread, TurnEnd } from './types';

const TOKEN_KEY = 'mm.token';
const TOKEN_HEADER = 'X-MuxMaestro-Token';

let token: string | null = null;
try {
	token = localStorage.getItem(TOKEN_KEY);
} catch {
	// Storage is blocked: pairing lasts for this visit only.
}

export function hasToken(): boolean {
	return token !== null;
}

export function setToken(value: string | null): void {
	token = value;
	try {
		if (value === null) localStorage.removeItem(TOKEN_KEY);
		else localStorage.setItem(TOKEN_KEY, value);
	} catch {
		// See above.
	}
}

/**
 * Take the token from a pairing link's fragment, keep it, and clear it from
 * the address bar. True when the address held one.
 */
export function adoptPairingLink(): boolean {
	if (!location.hash.includes('pair=')) return false;
	const found = tokenFrom(location.hash);
	history.replaceState(
		history.state,
		'',
		location.pathname + location.search + withoutPair(location.hash)
	);
	if (found) setToken(found);
	return found !== null;
}

// Before the first request, so that request already carries the token.
adoptPairingLink();

export class ApiError extends Error {
	constructor(
		readonly status: number,
		/** The `error` word in the response body, if it had one. */
		readonly code: string | null,
		/** The sentence the server sent for the human, if it sent one. */
		readonly detail: string | null = null
	) {
		super(detail ?? `HTTP ${status}${code ? ` ${code}` : ''}`);
	}

	/**
	 * The server refused this device. A 403 for a feature that is switched off
	 * says "disabled" and is not this.
	 */
	get forbidden(): boolean {
		return this.status === 403 && this.code === 'forbidden';
	}

	/** This phone has no pairing token, or the Mac no longer accepts it. */
	get unpaired(): boolean {
		return this.status === 401;
	}
}

async function failure(response: Response): Promise<ApiError> {
	try {
		const body = (await response.json()) as { error?: unknown; message?: unknown };
		return new ApiError(
			response.status,
			typeof body.error === 'string' ? body.error : null,
			typeof body.message === 'string' ? body.message : null
		);
	} catch {
		return new ApiError(response.status, null);
	}
}

/** Every API call goes through here, so every one carries the pairing token. */
async function request(
	path: string,
	accept: string,
	as?: string,
	signal?: AbortSignal,
	extra: Record<string, string> = {},
	write?: unknown
): Promise<Response> {
	const sent = as ?? token;
	const response = await fetch(path, {
		cache: 'no-store',
		headers: {
			accept,
			...extra,
			...(sent ? { [TOKEN_HEADER]: sent } : {}),
			// The server refuses a write without this header, and a page on
			// another origin cannot send it.
			...(write === undefined ? {} : { 'content-type': 'application/json', 'x-muxmaestro': '1' })
		},
		...(write === undefined ? {} : { method: 'POST', body: JSON.stringify(write) }),
		signal
	});
	// "Not modified": the answer to a request that named what it already has.
	if (response.status === 304) return response;
	if (!response.ok) throw await failure(response);
	return response;
}

function post(path: string, body: unknown, accept = 'application/json'): Promise<Response> {
	return request(path, accept, undefined, undefined, {}, body);
}

async function get<T>(path: string, as?: string): Promise<T> {
	return (await (await request(path, 'application/json', as)).json()) as T;
}

/**
 * Read the live event stream until it ends, calling `onFrame` for each event.
 * `EventSource` cannot send the token header, so this reads the stream itself.
 * Resolves when the server closes the stream; throws `ApiError` if it refuses.
 */
export async function readEvents(
	signal: AbortSignal,
	onFrame: (frame: Frame) => void
): Promise<void> {
	const response = await request('/api/events', 'text/event-stream', undefined, signal);
	if (!response.body) return;
	const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
	const parse = frameParser();
	for (;;) {
		const { done, value } = await reader.read();
		if (done) return;
		for (const frame of parse(value)) onFrame(frame);
	}
}

const threadPath = (id: string): string => `/api/threads/${encodeURIComponent(id)}`;

export async function fetchThreads(): Promise<Thread[]> {
	return (await get<{ threads: Thread[] }>('/api/threads')).threads;
}

export async function fetchHosts(): Promise<Host[]> {
	return (await get<{ hosts: Host[] }>('/api/hosts')).hosts;
}

export function fetchChat(id: string, after?: number): Promise<ChatPage> {
	return get<ChatPage>(`${threadPath(id)}/chat${after === undefined ? '' : `?after=${after}`}`);
}

export interface ScreenPage {
	/** Scrollback and screen, with the terminal's colour codes. */
	text: string;
	/** How many lines the server was asked for, after its own limits. */
	lines: number;
	/** The most lines it will ever send. */
	max: number;
	etag: string | null;
}

/**
 * The pane's text. `lines`: how many to ask for (left out, the server picks).
 * `etag`: the tag of the text already held; null comes back when it has not changed.
 */
export async function fetchScreen(
	id: string,
	lines?: number,
	etag?: string | null
): Promise<ScreenPage | null> {
	const response = await request(
		`${threadPath(id)}/screen${lines === undefined ? '' : `?lines=${lines}`}`,
		'application/json',
		undefined,
		undefined,
		etag ? { 'If-None-Match': etag } : {}
	);
	if (response.status === 304) return null;
	const body = (await response.json()) as { text: string; lines?: number; max?: number };
	return {
		text: body.text,
		lines: body.lines ?? 0,
		max: body.max ?? 0,
		etag: response.headers.get('ETag')
	};
}

/** `as`: ask with this token, not the stored one (to test a token before keeping it). */
export function fetchConfig(as?: string): Promise<Config> {
	return get<Config>('/api/config', as);
}

export function fetchManager(): Promise<ManagerHome> {
	return get<ManagerHome>('/api/manager');
}

export async function dismissReview(key: string): Promise<void> {
	await post('/api/manager/dismiss', { key });
}

/** The Mac pings a quiet turn stream every 15 s; three missed pings is a dead stream. */
const TURN_STALL_MS = 45_000;

/**
 * Run one manager turn. `onDelta` gets the reply as it is written. A turn the
 * Mac refuses to start throws an `ApiError` whose `detail` says why.
 */
export async function sendManagerText(
	text: string,
	onDelta: (text: string) => void
): Promise<TurnEnd> {
	const response = await post('/api/manager/text', { text }, 'text/event-stream');
	const reader = response.body?.pipeThrough(new TextDecoderStream()).getReader();
	const parse = frameParser();
	while (reader) {
		const chunk = await readOrStall(() => reader.read(), TURN_STALL_MS);
		if (chunk === STALLED) {
			void reader.cancel();
			break;
		}
		const { done, value } = chunk;
		if (done) break;
		for (const frame of parse(value)) {
			if (frame.event === 'delta') onDelta((JSON.parse(frame.data) as { text: string }).text);
			else if (frame.event === 'end') return JSON.parse(frame.data) as TurnEnd;
		}
	}
	// The stream closed with no end: the turn may still be running on the Mac.
	return { outcome: 'timeout', reply: '', message: 'Connection lost' };
}
