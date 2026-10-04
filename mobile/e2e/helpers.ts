import { expect, type Locator, type Page } from '@playwright/test';

export const WIDTH = 390;

declare global {
	interface Window {
		__mic: {
			opened: number;
			speak: (on: boolean) => void;
			live: () => number;
			/** The next `getUserMedia` fails with this error name. */
			fail: string | null;
			/** As iOS does: the mic prompt leaves the page's audio suspended. */
			suspendOnOpen: boolean;
		};
		/** The app's own audio context: the one the first tap made. */
		__app: AudioContext | null;
		/** The audio session type the app asked for (iOS 17). */
		__session: () => string;
		/** Screen wake locks the app holds. */
		__awake: () => number;
		/** Reply clips that started to play. */
		__clips: number;
	}
}

/**
 * Give the page a microphone the test controls: a tone that is "speech" while
 * `window.__mic.speak(true)` and silence otherwise. No real device.
 */
export async function fakeMic(page: Page): Promise<void> {
	await page.addInitScript(() => {
		let gain: GainNode | null = null;
		const streams: MediaStream[] = [];
		// The app's context is the first one made outside the fake microphone.
		let making = false;
		window.__app = null;
		const Real = window.AudioContext;
		window.AudioContext = class extends Real {
			constructor(options?: AudioContextOptions) {
				super(options);
				if (!making && (window.__app === null || window.__app.state === 'closed')) {
					window.__app = this;
				}
			}
		};
		const audioSession = { type: 'auto' };
		Object.defineProperty(navigator, 'audioSession', { value: audioSession });
		window.__session = () => audioSession.type;
		let held = 0;
		Object.defineProperty(navigator, 'wakeLock', {
			value: {
				request: async () => {
					held += 1;
					return { release: async () => void (held -= 1) };
				}
			}
		});
		window.__awake = () => held;
		window.__mic = {
			opened: 0,
			fail: null,
			suspendOnOpen: false,
			speak: (on) => {
				if (gain) gain.gain.value = on ? 0.5 : 0;
			},
			// Streams the page still holds open: what lights the phone's mic indicator.
			live: () =>
				streams.filter((stream) => stream.getTracks().some((track) => track.readyState === 'live'))
					.length
		};
		navigator.mediaDevices.getUserMedia = async () => {
			if (window.__mic.fail) throw new DOMException('refused', window.__mic.fail);
			if (window.__mic.suspendOnOpen) await window.__app?.suspend();
			window.__mic.opened += 1;
			making = true;
			const context = new AudioContext();
			making = false;
			await context.resume();
			const tone = context.createOscillator();
			tone.frequency.value = 220;
			gain = context.createGain();
			gain.gain.value = 0;
			const out = context.createMediaStreamDestination();
			tone.connect(gain).connect(out);
			tone.start();
			streams.push(out.stream);
			return out.stream;
		};
		// A reply clip is longer than the cue that follows a take.
		window.__clips = 0;
		const start = AudioBufferSourceNode.prototype.start;
		AudioBufferSourceNode.prototype.start = function (...args) {
			if ((this.buffer?.duration ?? 0) > 0.5) window.__clips += 1;
			return start.apply(this, args);
		};
	});
}

export async function reset(page: Page): Promise<void> {
	await page.request.post('/__fixture/reset');
}

export const TOKEN = 'demo-token';
export const TOKEN_HEADER = { 'X-MuxMaestro-Token': TOKEN };

/** The link the Mac shows as a QR code. */
export const pairingLink = (path = '/'): string => `${path}#pair=${TOKEN}`;

/** Empty this origin's storage, from a page that does not start the app. */
export async function forget(page: Page): Promise<void> {
	await page.goto('/manifest.webmanifest');
	await page.evaluate(() => localStorage.clear());
}

/**
 * Open a page with nothing left over from the test before. The app is opened
 * through the pairing link, as a phone that scanned the QR code would.
 */
export async function fresh(page: Page, path = '/'): Promise<void> {
	await reset(page);
	await forget(page);
	await page.goto(pairingLink(path));
}

export const threadPath = (id: string): string => `/t/${encodeURIComponent(id)}`;

export const drawer = (page: Page): Locator => page.locator('[data-drawer]');

/** How far the drawer is from fully open, in pixels (0 = open). */
export async function drawerOffset(page: Page): Promise<number> {
	return drawer(page).evaluate((el) => Math.abs(el.getBoundingClientRect().left));
}

export async function expectDrawerOpen(page: Page): Promise<void> {
	await expect.poll(() => drawerOffset(page)).toBe(0);
}

export async function expectDrawerClosed(page: Page): Promise<void> {
	await expect(drawer(page)).toBeHidden();
}

/** Press, move in steps, and stay down, so a test can look mid-drag. */
export async function dragStart(
	page: Page,
	from: [number, number],
	to: [number, number]
): Promise<void> {
	await page.mouse.move(from[0], from[1]);
	await page.mouse.down();
	await page.mouse.move(to[0], to[1], { steps: 12 });
}

export async function drag(
	page: Page,
	from: [number, number],
	to: [number, number]
): Promise<void> {
	await dragStart(page, from, to);
	// Rest before lifting, so the release is a slow drag and not a flick.
	await page.waitForTimeout(120);
	await page.mouse.up();
}

/** A real touch drag (not a mouse), so the browser applies `touch-action`. */
export async function touchDrag(
	page: Page,
	from: [number, number],
	to: [number, number]
): Promise<void> {
	const cdp = await page.context().newCDPSession(page);
	const send = (
		type: 'touchStart' | 'touchMove' | 'touchEnd',
		point?: [number, number]
	): Promise<unknown> =>
		cdp.send('Input.dispatchTouchEvent', {
			type,
			touchPoints: point ? [{ x: point[0], y: point[1] }] : []
		});
	await send('touchStart', from);
	const steps = 12;
	for (let i = 1; i <= steps; i += 1) {
		await send('touchMove', [
			from[0] + ((to[0] - from[0]) * i) / steps,
			from[1] + ((to[1] - from[1]) * i) / steps
		]);
	}
	await page.waitForTimeout(120);
	await send('touchEnd');
	await cdp.detach();
}

type Point = [number, number];

/**
 * A real two-finger gesture: both fingers land, move in steps to their end
 * points, and (unless `hold`) lift. With `hold`, call the returned function to lift.
 */
export async function twoFingers(
	page: Page,
	from: [Point, Point],
	to: [Point, Point],
	hold = false
): Promise<() => Promise<void>> {
	const cdp = await page.context().newCDPSession(page);
	const send = (type: 'touchStart' | 'touchMove' | 'touchEnd', points: Point[]): Promise<unknown> =>
		cdp.send('Input.dispatchTouchEvent', {
			type,
			touchPoints: points.map(([x, y], id) => ({ x, y, id }))
		});
	await send('touchStart', [from[0]]);
	await send('touchStart', from);
	const steps = 10;
	const at = (i: number, k: 0 | 1): Point => [
		from[k][0] + ((to[k][0] - from[k][0]) * i) / steps,
		from[k][1] + ((to[k][1] - from[k][1]) * i) / steps
	];
	for (let i = 1; i <= steps; i += 1) await send('touchMove', [at(i, 0), at(i, 1)]);
	const lift = async (): Promise<void> => {
		await send('touchEnd', []);
		await cdp.detach();
	};
	if (!hold) await lift();
	return lift;
}
