import { expect, type Locator, type Page } from '@playwright/test';

export const WIDTH = 390;

declare global {
	interface Window {
		__mic: { opened: number; speak: (on: boolean) => void; live: () => number };
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
		window.__mic = {
			opened: 0,
			speak: (on) => {
				if (gain) gain.gain.value = on ? 0.5 : 0;
			},
			// Streams the page still holds open: what lights the phone's mic indicator.
			live: () =>
				streams.filter((stream) => stream.getTracks().some((track) => track.readyState === 'live'))
					.length
		};
		navigator.mediaDevices.getUserMedia = async () => {
			window.__mic.opened += 1;
			const context = new AudioContext();
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
