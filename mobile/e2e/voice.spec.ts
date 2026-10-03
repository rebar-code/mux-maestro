import { expect, test, type Locator, type Page } from '@playwright/test';
import { fakeMic, forget, pairingLink, reset } from './helpers';

interface Take {
	riff: boolean;
	rate: number;
	channels: number;
	bits: number;
	seconds: number;
	rms: number;
	target: string;
	speaker: boolean;
}

const status = (page: Page): Locator => page.locator('[data-voice-status]');
const primary = (page: Page): Locator => page.locator('[data-primary]');
const orb = (page: Page): Locator => page.locator('[data-orb]');
const said = (page: Page): Locator => page.locator('[data-said]');
const box = (page: Page): Locator => page.getByRole('textbox', { name: 'Ask the manager' });
const bar = (page: Page, name: string): Locator =>
	page.locator('[data-voicebar]').getByRole('button', { name, exact: true });

const REPLY = '2 threads need you: acme-app · checkout-fix, billing · proration.';

async function takes(page: Page): Promise<Take[]> {
	return ((await (await page.request.post('/__fixture/voice-takes')).json()) as { takes: Take[] })
		.takes;
}

const speak = (page: Page, on: boolean): Promise<void> =>
	page.evaluate((value) => window.__mic.speak(value), on);

/** Say something for `ms`, then go quiet. */
async function say(page: Page, ms: number): Promise<void> {
	await speak(page, true);
	await page.waitForTimeout(ms);
	await speak(page, false);
}

/**
 * Open the home with voice on and a microphone the test controls: a tone that
 * is "speech" while `speak(true)` and silence otherwise. No real device.
 */
async function open(page: Page, hooks: string[] = []): Promise<void> {
	await fakeMic(page);
	await reset(page);
	await page.request.post('/__fixture/capability?name=voice&on=1');
	for (const hook of hooks) await page.request.post(hook);
	await forget(page);
	await page.goto(pairingLink());
	await expect(primary(page)).toHaveText('🎙 Talk');
}

test('Manual: tap to start, tap to send, and a pause never cuts the take', async ({ page }) => {
	await open(page);
	await expect(status(page)).toHaveText('Start talking');
	await expect(bar(page, 'Manual')).toHaveAttribute('aria-pressed', 'true');

	await primary(page).click();
	await expect(status(page)).toHaveText('Recording — tap to send');
	await expect(primary(page)).toHaveText('↑ Submit');
	// Red while the take is open.
	await expect(primary(page)).toHaveCSS('background-color', 'rgb(255, 69, 58)');
	await expect(orb(page)).toHaveClass(/recording/);

	await say(page, 700);
	// Longer than the silence that ends a take in Auto.
	await page.waitForTimeout(3600);
	await expect(status(page)).toHaveText('Recording — tap to send');
	await say(page, 400);

	const sent = page.waitForRequest((request) => request.url().includes('/api/voice?'));
	await primary(page).click();
	const request = await sent;
	expect(request.method()).toBe('POST');
	expect(request.headers()['content-type']).toBe('audio/wav');
	expect(request.headers()['x-muxmaestro']).toBe('1');
	expect(request.headers()['x-muxmaestro-token']).toBe('demo-token');
	expect(new URL(request.url()).search).toBe('?target=manager&speaker=1');

	await expect(primary(page)).toHaveText('■ Stop');
	await expect(status(page)).toHaveText('Thinking…');
	await expect(said(page).locator('.u')).toHaveText('What needs me?');
	await expect(status(page)).toHaveText('Speaking…');
	await expect(primary(page)).toHaveText('❚❚ Pause');
	await expect(said(page).locator('.m').last()).toHaveText(REPLY);
	// The reply has two sentences: two clips, played in order, then it rests.
	await expect(status(page)).toHaveText('Start talking', { timeout: 8000 });
	await expect(primary(page)).toHaveText('🎙 Talk');
	expect(await page.evaluate(() => window.__clips)).toBe(2);

	// What the Mac got: raw PCM as a 16 kHz mono 16-bit WAV, the whole take.
	const [take, ...more] = await takes(page);
	expect(more).toEqual([]);
	expect(take).toMatchObject({ riff: true, rate: 16000, channels: 1, bits: 16, speaker: true });
	expect(take.seconds).toBeGreaterThan(4.5);
	expect(take.rms).toBeGreaterThan(0.01);
});

test('Auto: speech starts a take, silence sends it, and the mic reopens', async ({ page }) => {
	await open(page);
	await bar(page, 'Auto').click();
	await expect(bar(page, 'Auto')).toHaveAttribute('aria-pressed', 'true');
	await expect(status(page)).toHaveText('Listening…');
	await expect(primary(page)).toHaveText('🎙 Talk');
	expect(await page.evaluate(() => window.__mic.opened)).toBe(1);

	// No tap: the take opens when the speech starts.
	await speak(page, true);
	await expect(primary(page)).toHaveText('↑ Submit');
	await page.waitForTimeout(900);
	await speak(page, false);
	// About 3 s of silence sends it: not yet at 1.5 s, sent by 4.5 s.
	await page.waitForTimeout(1500);
	await expect(primary(page)).toHaveText('↑ Submit');
	await expect(primary(page)).toHaveText('■ Stop', { timeout: 3000 });
	await expect(said(page).locator('.u')).toHaveText('What needs me?');
	await expect(status(page)).toHaveText('Speaking…');

	// After the reply the mic is open again, with no tap.
	await expect(status(page)).toHaveText('Listening…', { timeout: 8000 });
	await page.waitForTimeout(600);
	await speak(page, true);
	await expect(primary(page)).toHaveText('↑ Submit');
	// A tap sends an Auto take too.
	await page.waitForTimeout(500);
	await primary(page).click();
	await speak(page, false);
	await expect(primary(page)).toHaveText('■ Stop');

	const all = await takes(page);
	expect(all).toHaveLength(2);
	// The silence Auto waited through is not sent.
	expect(all[0].seconds).toBeGreaterThan(0.8);
	expect(all[0].seconds).toBeLessThan(2.5);
	// The mic was opened once and kept.
	expect(await page.evaluate(() => window.__mic.opened)).toBe(1);
});

test('input only: the speech becomes text and nothing is read back', async ({ page }) => {
	await open(page);
	await bar(page, 'Speaker').click();
	await expect(bar(page, 'Speaker')).toHaveAttribute('aria-pressed', 'false');
	await expect(bar(page, 'Speaker')).toHaveText('🔇');

	await primary(page).click();
	await say(page, 700);
	const sent = page.waitForRequest((request) => request.url().includes('/api/voice?'));
	await primary(page).click();
	expect(new URL((await sent).url()).search).toBe('?target=manager&speaker=0');

	await expect(said(page).locator('.u')).toHaveText('What needs me?');
	await expect(said(page).locator('.m').last()).toHaveText(REPLY);
	await expect(status(page)).toHaveText('Start talking');
	await expect(primary(page)).toHaveText('🎙 Talk');
	expect(await page.evaluate(() => window.__clips)).toBe(0);
	expect((await takes(page))[0].speaker).toBe(false);
	// The turn is in the chat: a reload shows it.
	await page.reload();
	await expect(said(page).locator('.m').last()).toHaveText(REPLY);
});

test('interrupt: Stop while it thinks, Pause, Resume and Skip while it speaks', async ({
	page
}) => {
	await open(page, ['/__fixture/voice?delay=2500']);
	await primary(page).click();
	await say(page, 600);
	await primary(page).click();
	await expect(primary(page)).toHaveText('■ Stop');
	await primary(page).click();
	// Stopped before the Mac had the words: nothing was sent to the manager.
	await expect(status(page)).toHaveText('Start talking');
	await expect(primary(page)).toHaveText('🎙 Talk');
	await page.waitForTimeout(2800);
	await expect(said(page).locator('.u')).toHaveCount(0);

	await page.request.post('/__fixture/voice?delay=100');
	await primary(page).click();
	await say(page, 600);
	await primary(page).click();
	await expect(status(page)).toHaveText('Speaking…');
	await primary(page).click();
	await expect(status(page)).toHaveText('Paused');
	await expect(primary(page)).toHaveText('▶ Resume');
	// Paused is held, not ended.
	await page.waitForTimeout(2500);
	await expect(status(page)).toHaveText('Paused');
	await primary(page).click();
	await expect(status(page)).toHaveText('Speaking…');
	await expect(primary(page)).toHaveText('❚❚ Pause');

	await expect(bar(page, 'Skip')).toBeEnabled();
	await bar(page, 'Skip').click();
	await expect(status(page)).toHaveText('Start talking');
	await expect(bar(page, 'Skip')).toBeDisabled();
	// The reply stays as text.
	await expect(said(page).locator('.m').last()).toHaveText(REPLY);
});

test('Replay reads the last reply again, and Talk during it starts a take', async ({ page }) => {
	await open(page);
	await bar(page, 'Replay').click();
	await expect(status(page)).toHaveText('Speaking…');
	expect(await page.evaluate(() => window.__clips)).toBeGreaterThan(0);
	await bar(page, 'Skip').click();
	await expect(primary(page)).toHaveText('🎙 Talk');

	// Speaker off does not stop a Replay: the tap asks for it.
	await bar(page, 'Speaker').click();
	const before = await page.evaluate(() => window.__clips);
	await bar(page, 'Replay').click();
	await expect(status(page)).toHaveText('Speaking…');
	expect(await page.evaluate(() => window.__clips)).toBeGreaterThan(before);
	await expect(status(page)).toHaveText('Start talking', { timeout: 12000 });
});

test('the button is Send while the box has text, and Talk when it is empty', async ({ page }) => {
	await open(page);
	await box(page).fill('status?');
	await expect(primary(page)).toHaveCount(0);
	const send = page.getByRole('button', { name: '↑ Send' });
	await expect(send).toBeEnabled();
	await box(page).fill('');
	await expect(send).toHaveCount(0);
	await expect(primary(page)).toHaveText('🎙 Talk');

	// Typing works while voice is on, and a typed turn is not a take.
	await box(page).fill('what needs me?');
	await send.click();
	await expect(said(page).locator('.m').last()).toHaveText(REPLY);
	await expect(primary(page)).toHaveText('🎙 Talk');
	expect(await takes(page)).toEqual([]);
});

test('the large button is the same control', async ({ page }) => {
	await open(page);
	await expect(orb(page)).toHaveAccessibleName('Talk to the manager');
	await orb(page).click();
	await expect(primary(page)).toHaveText('↑ Submit');
	await expect(orb(page)).toHaveAccessibleName('Submit to the manager');
	await say(page, 600);
	// The button breathes while a take is open, so it never holds still.
	await orb(page).click({ force: true });
	await expect(orb(page)).toHaveClass(/thinking/);
	await expect(orb(page)).toHaveClass(/speaking/);
	await expect(orb(page)).toHaveAccessibleName('Pause to the manager');
	await expect(status(page)).toHaveText('Start talking', { timeout: 8000 });
	expect(await takes(page)).toHaveLength(1);
});

test('mode and speaker are remembered on this phone; the Mac sets the start', async ({ page }) => {
	// A phone that has picked nothing starts with the Mac's defaults.
	await open(page, ['/__fixture/voice?mode=auto&speaker=0']);
	await expect(bar(page, 'Auto')).toHaveAttribute('aria-pressed', 'true');
	await expect(bar(page, 'Speaker')).toHaveAttribute('aria-pressed', 'false');
	// No tap yet, so no mic: Auto says so by not claiming to listen.
	await expect(status(page)).toHaveText('Start talking');
	expect(await page.evaluate(() => window.__mic.opened)).toBe(0);

	await bar(page, 'Manual').click();
	await bar(page, 'Speaker').click();
	await page.reload();
	await expect(bar(page, 'Manual')).toHaveAttribute('aria-pressed', 'true');
	await expect(bar(page, 'Speaker')).toHaveAttribute('aria-pressed', 'true');
	// The phone's own choice outlives a change on the Mac.
	await page.request.post('/__fixture/voice?mode=auto&speaker=0');
	await expect(bar(page, 'Manual')).toHaveAttribute('aria-pressed', 'true');
	await expect(bar(page, 'Speaker')).toHaveAttribute('aria-pressed', 'true');
});

test('a muted mic takes nothing, and a refused take says why', async ({ page }) => {
	await open(page);
	await primary(page).click();
	await expect(primary(page)).toHaveText('↑ Submit');
	await bar(page, 'Microphone').click();
	await expect(status(page)).toHaveText('Mic muted');
	await expect(primary(page)).toBeDisabled();
	await expect(orb(page)).toBeDisabled();
	expect(await takes(page)).toEqual([]);
	await bar(page, 'Microphone').click();
	await expect(primary(page)).toBeEnabled();

	await page.request.post('/__fixture/manager-status?value=waiting');
	await primary(page).click();
	await say(page, 600);
	await primary(page).click();
	await expect(status(page)).toHaveText('Manager is waiting on a prompt');
	await expect(primary(page)).toHaveText('🎙 Talk');

	// A take with no words in it.
	await page.request.post('/__fixture/manager-status?value=idle');
	await page.request.post('/__fixture/voice?heard=');
	await primary(page).click();
	await say(page, 600);
	await primary(page).click();
	await expect(status(page)).toHaveText('Heard nothing');
});

test('the first tap creates the audio the reply needs', async ({ page }) => {
	await page.addInitScript(() => {
		const made: string[] = [];
		(window as unknown as { __contexts: string[] }).__contexts = made;
		const Real = window.AudioContext;
		window.AudioContext = class extends Real {
			constructor(options?: AudioContextOptions) {
				super(options);
				made.push(navigator.userActivation.isActive ? 'in a tap' : 'outside a tap');
			}
		};
	});
	await open(page);
	const contexts = (): Promise<string[]> =>
		page.evaluate(() => (window as unknown as { __contexts: string[] }).__contexts);
	expect(await contexts()).toEqual([]);
	// Any tap does it, not only Talk.
	await page.locator('.chip').first().click();
	expect((await contexts())[0]).toBe('in a tap');
});

test('every voice control has a 44pt touch area, clear of its neighbours', async ({ page }) => {
	await open(page);
	const controls = [
		...['Auto', 'Manual', 'Speaker', 'Replay', 'Microphone'].map((name) => bar(page, name)),
		primary(page)
	];
	// The large button is a 148pt circle.
	expect((await orb(page).boundingBox())!.width).toBeGreaterThanOrEqual(44);
	for (const control of controls) {
		// The touch area: the control, or the larger box drawn around it.
		const area = await control.evaluate((element) => {
			const box = element.getBoundingClientRect();
			const around = getComputedStyle(element, '::after');
			const grown = around.content !== 'none' && around.position === 'absolute';
			const size = {
				width: Math.max(box.width, grown ? parseFloat(around.width) : 0),
				height: Math.max(box.height, grown ? parseFloat(around.height) : 0)
			};
			// A tap near each corner of that area reaches the control.
			const x = box.x + box.width / 2;
			const y = box.y + box.height / 2;
			const reached = [-1, 1].flatMap((dx) =>
				[-1, 1].map((dy) => {
					const hit = document.elementFromPoint(
						x + dx * (size.width / 2 - 2),
						y + dy * (size.height / 2 - 2)
					);
					return hit === element || element.contains(hit);
				})
			);
			return { ...size, reached };
		});
		const name = (await control.getAttribute('aria-label')) ?? (await control.textContent());
		expect(area.width, `${name} width`).toBeGreaterThanOrEqual(44);
		expect(area.height, `${name} height`).toBeGreaterThanOrEqual(44);
		expect(area.reached, `${name} taps`).toEqual([true, true, true, true]);
	}
	// 8pt between the icon buttons.
	const speaker = (await bar(page, 'Speaker').boundingBox())!;
	const replay = (await bar(page, 'Replay').boundingBox())!;
	expect(replay.x - (speaker.x + speaker.width)).toBeGreaterThanOrEqual(8);
	// Nothing sits under the home indicator or runs off the side.
	const form = (await page.locator('form.compose').boundingBox())!;
	expect(form.y + form.height).toBeLessThanOrEqual(844);
	expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(390);
});

test('with reduced motion nothing in the bar animates', async ({ page }) => {
	await page.emulateMedia({ reducedMotion: 'reduce' });
	await open(page);
	await primary(page).click();
	await expect(status(page)).toHaveText('Recording — tap to send');
	const animated = await page.evaluate(
		() =>
			[...document.querySelectorAll('[data-voicebar] .wave i, [data-orb]')].filter(
				(element) => getComputedStyle(element).animationName !== 'none'
			).length
	);
	expect(animated).toBe(0);
});
