import { tokenFrom, withoutPair } from './pairing';
import { frameParser, readOrStall, STALLED, type Frame } from './sse';
import type {
	ActionTarget,
	ArtifactList,
	ChatPage,
	Command,
	Config,
	FindResult,
	Host,
	ManagerHome,
	Mapping,
	MappingList,
	PromptState,
	RunningList,
	Thread,
	TmuxAction,
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
		readonly detail: string | null = null,
		/** Why a `not_sent` text was not submitted. */
		readonly reason: string | null = null,
		/** A `not_sent` text was taken out of the pane's input box again. */
		readonly cleared: boolean | null = null
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
		const body = (await response.json()) as Record<string, unknown>;
		return new ApiError(
			response.status,
			typeof body.error === 'string' ? body.error : null,
			typeof body.message === 'string' ? body.message : null,
			typeof body.reason === 'string' ? body.reason : null,
			typeof body.cleared === 'boolean' ? body.cleared : null
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
	extra: Record<string, string> = {},
	write?: Write
): Promise<Response> {
	const sent = as ?? token;
	const type = write && ('json' in write ? 'application/json' : write.type);
	const response = await fetch(path, {
		cache: 'no-store',
		headers: {
			accept,
			...extra,
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
	// "Not modified": the answer to a request that named what it already has.
	if (response.status === 304) return response;
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
	return request(
		path,
		'text/event-stream',
		undefined,
		signal,
		{},
		{
			bytes: audio,
			...(audio ? { type: 'audio/wav' } : {})
		}
	);
}

function post(path: string, body: unknown, accept = 'application/json'): Promise<Response> {
	return request(path, accept, undefined, undefined, {}, { json: body });
}

async function get<T>(path: string, as?: string, signal?: AbortSignal): Promise<T> {
	return (await (await request(path, 'application/json', as, signal)).json()) as T;
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

/** Where a thread's chat and screen are read from. */
export const threadPath = (id: string): string => `/api/threads/${encodeURIComponent(id)}`;
/** The manager pane is read the same way, from its own routes. */
export const MANAGER_PATH = '/api/manager';

export async function fetchThreads(): Promise<Thread[]> {
	return (await get<{ threads: Thread[] }>('/api/threads')).threads;
}

export async function fetchHosts(): Promise<Host[]> {
	return (await get<{ hosts: Host[] }>('/api/hosts')).hosts;
}

/** `base`: `threadPath(id)` or `MANAGER_PATH`. */
export function fetchChat(base: string, after?: number): Promise<ChatPage> {
	return get<ChatPage>(`${base}/chat${after === undefined ? '' : `?after=${after}`}`);
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
	base: string,
	lines?: number,
	etag?: string | null
): Promise<ScreenPage | null> {
	const response = await request(
		`${base}/screen${lines === undefined ? '' : `?lines=${lines}`}`,
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

/** Type `text` into the thread's pane and submit it. */
export async function sendText(id: string, text: string): Promise<void> {
	await post(`${threadPath(id)}/text`, { text });
}

/**
 * Press one key in a pane. `base`: `threadPath(id)` or `MANAGER_PATH`. `key`
 * is a name from `reply.ts`. `prompt` names the prompt the phone shows: a
 * pane that waits on another one answers 409 `stale` and takes no key.
 * `terminal`: the pane's own text was on screen at the tap, so the human could
 * read a prompt the card cannot hold.
 */
export async function sendKey(
	base: string,
	key: string,
	prompt: string | null,
	terminal: boolean
): Promise<void> {
	await post(`${base}/key`, {
		key,
		...(prompt ? { prompt } : {}),
		...(terminal ? { terminal } : {})
	});
}

/** What a pane asks now. `base`: `threadPath(id)` or `MANAGER_PATH`. */
export async function fetchPrompt(base: string): Promise<PromptState> {
	const body = await get<Partial<PromptState>>(`${base}/prompt`);
	const prompt = body.prompt ?? null;
	return { prompt, id: body.id ?? prompt?.id ?? null };
}

/**
 * Answer the prompt `prompt` with one of its options, or cancel it. A prompt
 * that changed answers 409 `stale`. `base`: `threadPath(id)` or `MANAGER_PATH`.
 */
export async function answerPrompt(
	base: string,
	prompt: string,
	choice: { option: number } | { cancel: true }
): Promise<void> {
	await post(`${base}/answer`, { prompt, ...choice });
}

export async function fetchCommands(id: string): Promise<Command[]> {
	return (await get<{ commands: Command[] }>(`${threadPath(id)}/commands`)).commands;
}

/** What the Mac says of a file it saved. */
export interface Uploaded {
	/** Where the file is on the Mac. A name that was taken got a number. */
	path: string;
	/** The path as it is typed into a pane: quoted when it has to be. */
	text: string;
}

function refusalOf(xhr: XMLHttpRequest): ApiError {
	try {
		const body = JSON.parse(xhr.responseText) as Record<string, unknown>;
		return new ApiError(
			xhr.status,
			typeof body.error === 'string' ? body.error : null,
			typeof body.message === 'string' ? body.message : null,
			typeof body.reason === 'string' ? body.reason : null,
			typeof body.cleared === 'boolean' ? body.cleared : null
		);
	} catch {
		return new ApiError(xhr.status, null);
	}
}

/**
 * Put `file` in the thread's directory under `name`. Nothing is typed into
 * the pane: the caller gets the path, to put it in the reply.
 *
 * The one request that is not a `fetch`: `fetch` cannot say how much of a
 * body has gone out, and a photo over a phone link needs a progress bar. It
 * carries the token and the write header like every other write, and a
 * refusal is the same `ApiError`. No answer at all (offline, or the Mac out
 * of reach) rejects with a plain `Error`; `signal` aborts it.
 */
export function uploadFile(
	id: string,
	file: Blob,
	name: string,
	onProgress: (sent: number, total: number) => void,
	signal: AbortSignal
): Promise<Uploaded> {
	return new Promise((resolve, reject) => {
		if (signal.aborted) return reject(new DOMException('Aborted', 'AbortError'));
		const xhr = new XMLHttpRequest();
		xhr.open('POST', `${threadPath(id)}/upload?name=${encodeURIComponent(name)}&paste=0`);
		xhr.setRequestHeader('accept', 'application/json');
		xhr.setRequestHeader('content-type', 'application/octet-stream');
		xhr.setRequestHeader('x-muxmaestro', '1');
		if (token) xhr.setRequestHeader(TOKEN_HEADER, token);
		const abort = (): void => xhr.abort();
		signal.addEventListener('abort', abort, { once: true });
		const settle = (): void => signal.removeEventListener('abort', abort);
		xhr.upload.onprogress = (event) => {
			if (event.lengthComputable) onProgress(event.loaded, event.total);
		};
		xhr.onload = () => {
			settle();
			if (xhr.status < 200 || xhr.status >= 300) return reject(refusalOf(xhr));
			try {
				const body = JSON.parse(xhr.responseText) as Partial<Uploaded>;
				const path = body.path ?? '';
				resolve({ path, text: body.text ?? path });
			} catch {
				reject(new ApiError(xhr.status, null));
			}
		};
		xhr.onerror = () => {
			settle();
			reject(new Error('No answer'));
		};
		xhr.onabort = () => {
			settle();
			reject(new DOMException('Aborted', 'AbortError'));
		};
		xhr.send(file);
	});
}

/** What a session action answers: the new window's thread, or the new session's name. */
export interface ActionResult {
	thread?: string;
	session?: string;
}

/**
 * Run one session action on the Mac. A kill must carry `confirm: true`; the
 * Mac refuses it otherwise.
 */
export async function tmuxAction(
	action: TmuxAction,
	body: (ActionTarget | { host: string }) & { name?: string; dir?: string; confirm?: true }
): Promise<ActionResult> {
	return (await (await post(`/api/tmux/${action}`, body)).json()) as ActionResult;
}

/** The directories a host offers for a new session. */
export async function fetchDirs(host: string): Promise<string[]> {
	return (await get<{ dirs: string[] }>(`/api/hosts/${encodeURIComponent(host)}/dirs`)).dirs;
}

/** Find `query` in the thread's scrollback. */
export function fetchFind(id: string, query: string, signal?: AbortSignal): Promise<FindResult> {
	return get<FindResult>(
		`${threadPath(id)}/find?q=${encodeURIComponent(query)}`,
		undefined,
		signal
	);
}

export function fetchArtifacts(id: string): Promise<ArtifactList> {
	return get<ArtifactList>(`${threadPath(id)}/artifacts`);
}

/**
 * One artifact's bytes. The file is named by the id the Mac gave it, never by
 * a path. It is fetched (the token rides in a header) and never linked to.
 */
export async function fetchFile(id: string, file: string, signal?: AbortSignal): Promise<Blob> {
	const path = `${threadPath(id)}/file?id=${encodeURIComponent(file)}`;
	return (await request(path, '*/*', undefined, signal)).blob();
}

export function fetchRunning(id: string): Promise<RunningList> {
	return get<RunningList>(`${threadPath(id)}/running`);
}

export function fetchMappings(): Promise<MappingList> {
	return get<MappingList>('/api/servers');
}

/** Ask the Mac to publish one of the thread's local ports on the tailnet. */
export async function openServer(id: string, port: number): Promise<Mapping> {
	return (await (await post('/api/servers/open', { thread: id, port })).json()) as Mapping;
}

export async function closeServer(port: number): Promise<void> {
	await post('/api/servers/close', { port });
}

/** The Mac's push key: what this phone subscribes with. */
export function fetchPushKey(): Promise<{ key: string }> {
	return get<{ key: string }>('/api/push/key');
}

/** Hand the Mac this phone's push subscription, as the browser wrote it. */
export async function subscribePush(subscription: PushSubscriptionJSON): Promise<void> {
	await post('/api/push/subscribe', subscription);
}

export async function unsubscribePush(endpoint: string): Promise<void> {
	await post('/api/push/unsubscribe', { endpoint });
}

/** Say which thread this phone shows (`null`: none), so it sends no push here. */
export async function focusPush(endpoint: string, thread: string | null): Promise<void> {
	await post('/api/push/focus', { endpoint, thread });
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
