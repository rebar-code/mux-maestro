import { tokenFrom, withoutPair } from './pairing';
import { frameParser, type Frame } from './sse';
import type {
	ChatPage,
	Command,
	Config,
	Host,
	ManagerHome,
	Prompt,
	Thread,
	TurnEnd
} from './types';

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

/** What a write sends: JSON, or bytes of a named type (or nothing). */
type Write = { json: unknown } | { bytes: BodyInit | null; type?: string };

/** Every API call goes through here, so every one carries the pairing token. */
async function request(
	path: string,
	accept: string,
	as?: string,
	signal?: AbortSignal,
	write?: Write
): Promise<Response> {
	const sent = as ?? token;
	const type = write && ('json' in write ? 'application/json' : write.type);
	const response = await fetch(path, {
		cache: 'no-store',
		headers: {
			accept,
			...(sent ? { [TOKEN_HEADER]: sent } : {}),
			// The server refuses a write without this header, and a page on
			// another origin cannot send it.
			...(write ? { 'x-muxmaestro': '1' } : {}),
			...(type ? { 'content-type': type } : {})
		},
		...(write
			? { method: 'POST', body: 'json' in write ? JSON.stringify(write.json) : write.bytes }
			: {}),
		signal
	});
	if (!response.ok) throw await failure(response);
	return response;
}

/**
 * A write whose body is a recording, or nothing. It carries the token and the
 * write header like every other write; the answer is an event stream.
 */
export function postAudio(
	path: string,
	audio: ArrayBuffer | null,
	signal?: AbortSignal
): Promise<Response> {
	return request(path, 'text/event-stream', undefined, signal, {
		bytes: audio,
		...(audio ? { type: 'audio/wav' } : {})
	});
}

function post(path: string, body: unknown, accept = 'application/json'): Promise<Response> {
	return request(path, accept, undefined, undefined, { json: body });
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

export async function fetchScreen(id: string): Promise<string> {
	return (await get<{ text: string }>(`${threadPath(id)}/screen`)).text;
}

/** `as`: ask with this token, not the stored one (to test a token before keeping it). */
export function fetchConfig(as?: string): Promise<Config> {
	return get<Config>('/api/config', as);
}

/** Type `text` into the thread's pane and submit it. */
export async function sendText(id: string, text: string): Promise<void> {
	await post(`${threadPath(id)}/text`, { text });
}

/** Press one key in the thread's pane. `key` is a name from `reply.ts`. */
export async function sendKey(id: string, key: string): Promise<void> {
	await post(`${threadPath(id)}/key`, { key });
}

/** What the thread's pane asks now, or `null`. */
export async function fetchPrompt(id: string): Promise<Prompt | null> {
	return (await get<{ prompt: Prompt | null }>(`${threadPath(id)}/prompt`)).prompt;
}

/** Pick option `option` of the prompt `prompt`. A prompt that changed answers 409 `stale`. */
export async function answerPrompt(id: string, prompt: string, option: number): Promise<void> {
	await post(`${threadPath(id)}/answer`, { prompt, option });
}

export async function fetchCommands(id: string): Promise<Command[]> {
	return (await get<{ commands: Command[] }>(`${threadPath(id)}/commands`)).commands;
}

/** Put `file` in the thread's directory. Resolves to the path it got on the Mac. */
export async function uploadFile(id: string, file: File): Promise<string> {
	const response = await request(
		`${threadPath(id)}/upload?name=${encodeURIComponent(file.name)}`,
		'application/json',
		undefined,
		undefined,
		{ bytes: file, type: 'application/octet-stream' }
	);
	return ((await response.json()) as { path: string }).path;
}

export function fetchManager(): Promise<ManagerHome> {
	return get<ManagerHome>('/api/manager');
}

export async function dismissReview(key: string): Promise<void> {
	await post('/api/manager/dismiss', { key });
}

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
		const { done, value } = await reader.read();
		if (done) break;
		for (const frame of parse(value)) {
			if (frame.event === 'delta') onDelta((JSON.parse(frame.data) as { text: string }).text);
			else if (frame.event === 'end') return JSON.parse(frame.data) as TurnEnd;
		}
	}
	// The stream closed with no end: the turn may still be running on the Mac.
	return { outcome: 'timeout', reply: '', message: 'Connection lost' };
}
