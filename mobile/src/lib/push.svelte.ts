import { goto } from '$app/navigation';
import { ApiError, fetchPushKey, focusPush, subscribePush, unsubscribePush } from './api';
import { can, live } from './live.svelte';
import { isIOS, keyBytes, pushStatus, sameKey, type PushStatus } from './push';

/** How often an open thread tells the Mac it is on screen. The Mac forgets after 60 s. */
const FOCUS_MS = 20_000;

function standalone(): boolean {
	return (
		(navigator as { standalone?: boolean }).standalone === true ||
		matchMedia('(display-mode: standalone)').matches
	);
}

function supported(): boolean {
	return 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
}

async function subscription(): Promise<PushSubscription | null> {
	if (!supported()) return null;
	return (await navigator.serviceWorker.ready).pushManager.getSubscription();
}

/** This phone's notifications: whether they are on, and the switch. */
class Push {
	status = $state<PushStatus>('off');
	busy = $state(false);
	failed = $state(false);

	/** The subscription the Mac holds for this phone. */
	private endpoint: string | null = null;
	/** The thread on screen. */
	private thread: string | null = null;

	/** Read the phone's state. A subscription it holds is sent to the Mac again. */
	refresh = async (): Promise<void> => {
		const ok = supported();
		let held: PushSubscription | null = null;
		try {
			held = await subscription();
		} catch {
			// No service worker yet: not subscribed.
		}
		this.endpoint = null;
		if (held && can('notifications') && Notification.permission === 'granted') {
			try {
				const { key } = await fetchPushKey();
				if (sameKey(held.options.applicationServerKey, key)) {
					await subscribePush(held.toJSON());
					this.endpoint = held.endpoint;
				}
			} catch (error) {
				live.fail(error);
			}
		}
		this.status = pushStatus({
			ios: isIOS(navigator.userAgent, navigator.platform, navigator.maxTouchPoints),
			standalone: standalone(),
			supported: ok,
			permission: ok ? Notification.permission : null,
			subscribed: this.endpoint !== null
		});
		if (this.endpoint) this.tell();
	};

	/** The switch. It must run from a tap: the browser asks for permission here. */
	toggle = async (): Promise<void> => {
		if (this.busy) return;
		this.busy = true;
		this.failed = false;
		try {
			if (this.status === 'on') await this.disable();
			else await this.enable();
		} catch (error) {
			this.failed = true;
			live.fail(error);
		} finally {
			await this.refresh();
			this.busy = false;
		}
	};

	private async enable(): Promise<void> {
		// First, with nothing awaited before it: iOS asks only inside the tap.
		if ((await Notification.requestPermission()) !== 'granted') return;
		const { key } = await fetchPushKey();
		const { pushManager } = await navigator.serviceWorker.ready;
		let held = await pushManager.getSubscription();
		// Made for an older key of the Mac: the push service would refuse the Mac.
		if (held && !sameKey(held.options.applicationServerKey, key)) {
			await held.unsubscribe();
			held = null;
		}
		held ??= await pushManager.subscribe({
			userVisibleOnly: true,
			applicationServerKey: keyBytes(key)
		});
		try {
			await subscribePush(held.toJSON());
		} catch (error) {
			// The Mac did not take it: a subscription only the phone knows is no use.
			await held.unsubscribe();
			throw error;
		}
	}

	private async disable(): Promise<void> {
		const held = await subscription();
		if (!held) return;
		try {
			await unsubscribePush(held.endpoint);
		} catch (error) {
			// The Mac is told when it next sends: the push service answers "gone".
			if (!(error instanceof ApiError)) throw error;
		}
		await held.unsubscribe();
	}

	/** Tell the Mac which thread is on screen, so that thread sends nothing here. */
	private tell(): void {
		if (!this.endpoint || !can('notifications')) return;
		const shown = document.visibilityState === 'visible' ? this.thread : null;
		focusPush(this.endpoint, shown).catch(() => {
			// The Mac forgets on its own.
		});
	}

	/** Attachment for an open thread: it is on screen while mounted and visible. */
	watching(id: string): () => () => void {
		return () => {
			this.thread = id;
			this.tell();
			const timer = setInterval(() => {
				if (document.visibilityState === 'visible') this.tell();
			}, FOCUS_MS);
			const onVisibility = (): void => this.tell();
			document.addEventListener('visibilitychange', onVisibility);
			return () => {
				clearInterval(timer);
				document.removeEventListener('visibilitychange', onVisibility);
				if (this.thread === id) {
					this.thread = null;
					this.tell();
				}
			};
		};
	}
}

export const push = new Push();

/**
 * Attachment for the app root: read the state once, and open the thread of a
 * notification that was tapped while the app was open.
 */
export function notifications(): () => void {
	void push.refresh();
	if (!('serviceWorker' in navigator)) return () => {};
	const onMessage = (event: MessageEvent): void => {
		const data = event.data as { type?: string; url?: string } | null;
		// Only an address of this app: a path, never another origin.
		if (data?.type !== 'open' || typeof data.url !== 'string') return;
		if (!data.url.startsWith('/') || data.url.startsWith('//')) return;
		// eslint-disable-next-line svelte/no-navigation-without-resolve
		void goto(data.url);
	};
	navigator.serviceWorker.addEventListener('message', onMessage);
	return () => navigator.serviceWorker.removeEventListener('message', onMessage);
}
