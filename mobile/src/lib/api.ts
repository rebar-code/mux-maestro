import { takeEvents } from './manager';
import type { ChatPage, Config, Host, ManagerHome, Thread, TurnEnd } from './types';

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

async function get<T>(path: string): Promise<T> {
	const response = await fetch(path, {
		cache: 'no-store',
		headers: { accept: 'application/json' }
	});
	if (!response.ok) throw await failure(response);
	return (await response.json()) as T;
}

/**
 * Every write goes through here. The server refuses a write without this
 * header, and a page on another origin cannot send it.
 */
async function post(path: string, body: unknown): Promise<Response> {
	const response = await fetch(path, {
		method: 'POST',
		cache: 'no-store',
		headers: { 'content-type': 'application/json', 'x-muxmaestro': '1' },
		body: JSON.stringify(body)
	});
	if (!response.ok) throw await failure(response);
	return response;
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

export function fetchConfig(): Promise<Config> {
	return get<Config>('/api/config');
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
	const response = await post('/api/manager/text', { text });
	const reader = response.body?.getReader();
	const decoder = new TextDecoder();
	let buffer = '';
	while (reader) {
		const { done, value } = await reader.read();
		if (done) break;
		const taken = takeEvents(buffer + decoder.decode(value, { stream: true }));
		buffer = taken.rest;
		for (const { event, data } of taken.events) {
			if (event === 'delta') onDelta((JSON.parse(data) as { text: string }).text);
			else if (event === 'end') return JSON.parse(data) as TurnEnd;
		}
	}
	// The stream closed with no end: the turn may still be running on the Mac.
	return { outcome: 'timeout', reply: '', message: 'Connection lost' };
}
