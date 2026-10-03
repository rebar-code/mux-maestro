import type { ChatPage, Config, Host, Thread } from './types';

export class ApiError extends Error {
	constructor(
		readonly status: number,
		/** The `error` word in the response body, if it had one. */
		readonly code: string | null
	) {
		super(`HTTP ${status}${code ? ` ${code}` : ''}`);
	}

	/**
	 * The server refused this device. A 403 for a feature that is switched off
	 * says "disabled" and is not this.
	 */
	get forbidden(): boolean {
		return this.status === 403 && this.code === 'forbidden';
	}
}

async function errorCode(response: Response): Promise<string | null> {
	try {
		const body = (await response.json()) as { error?: unknown };
		return typeof body.error === 'string' ? body.error : null;
	} catch {
		return null;
	}
}

async function get<T>(path: string): Promise<T> {
	const response = await fetch(path, {
		cache: 'no-store',
		headers: { accept: 'application/json' }
	});
	if (!response.ok) throw new ApiError(response.status, await errorCode(response));
	return (await response.json()) as T;
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
