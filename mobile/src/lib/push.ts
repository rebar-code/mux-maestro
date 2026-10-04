/** What the Notifications control shows. */
export type PushStatus = 'unsupported' | 'install' | 'denied' | 'off' | 'on';

export interface PushEnv {
	ios: boolean;
	/** The app runs from the Home Screen, not in a browser tab. */
	standalone: boolean;
	/** The browser has service workers, push and notifications. */
	supported: boolean;
	permission: NotificationPermission | null;
	subscribed: boolean;
}

/**
 * iOS gives a web app push only once it is on the Home Screen, so that comes
 * first: in a Safari tab the push API is not there at all.
 */
export function pushStatus(env: PushEnv): PushStatus {
	if (env.ios && !env.standalone) return 'install';
	if (!env.supported) return 'unsupported';
	if (env.permission === 'denied') return 'denied';
	return env.subscribed && env.permission === 'granted' ? 'on' : 'off';
}

/** An iPad says it is a Mac; a Mac has no touch screen. */
export function isIOS(userAgent: string, platform: string, touchPoints: number): boolean {
	return /iPad|iPhone|iPod/.test(userAgent) || (platform === 'MacIntel' && touchPoints > 1);
}

/** The Mac's key (base64url) as the bytes `pushManager.subscribe` takes. */
export function keyBytes(key: string): Uint8Array<ArrayBuffer> {
	const text = atob(key.replace(/-/g, '+').replace(/_/g, '/'));
	const bytes = new Uint8Array(text.length);
	for (let i = 0; i < text.length; i += 1) bytes[i] = text.charCodeAt(i);
	return bytes;
}

/** Whether a subscription was made with the Mac's current key. */
export function sameKey(held: ArrayBuffer | null | undefined, key: string): boolean {
	if (!held) return false;
	const a = new Uint8Array(held);
	const b = keyBytes(key);
	return a.length === b.length && a.every((byte, i) => byte === b[i]);
}

export interface PushMessage {
	title: string;
	body: string;
	/** Notifications with one tag replace each other. */
	tag: string;
	/** The thread a tap opens. Empty: the app's first screen. */
	thread: string;
}

const GENERIC: PushMessage = { title: 'MuxMaestro', body: '', tag: 'muxmaestro', thread: '' };

/**
 * What the Mac sent, as a notification. A message that cannot be read still
 * gives one: iOS takes push away from an app that gets a push and shows nothing.
 */
export function parsePush(text: string | null): PushMessage {
	try {
		const data = JSON.parse(text ?? '') as Record<string, unknown>;
		const word = (key: keyof PushMessage): string => {
			const value = data[key];
			return typeof value === 'string' && value ? value.slice(0, 300) : GENERIC[key];
		};
		return { title: word('title'), body: word('body'), tag: word('tag'), thread: word('thread') };
	} catch {
		return GENERIC;
	}
}

/** The app address of a thread. */
export function threadUrl(thread: string): string {
	return thread ? `/t/${encodeURIComponent(thread)}` : '/';
}
