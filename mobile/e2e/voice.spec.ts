import { expect, test, type Locator, type Page } from '@playwright/test';
import { fakeMic, forget, pairingLink, reset, threadPath } from './helpers';

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
/** The manager's thread: its chat rows. */
const said = (page: Page): Locator => page.locator('[data-view="chat"]');
const box = (page: Page): Locator => page.getByRole('textbox', { name: 'Ask the Maestro' });
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
	await expect(primary(page)).toHaveText('Talk');
}

/** Talk mode on, in Manual, with no take open: the controls are drawn. */
async function talkMode(page: Page): Promise<void> {
	await primary(page).click();
	await bar(page, 'Auto').click();
	await expect(status(page)).toHaveText('Listening…');
	await bar(page, 'Manual').click();
	await expect(primary(page)).toHaveText('Talk');
	await expect(status(page)).toHaveCount(0);
}

test('the voice controls are drawn only in talk mode', async ({ page }) => {
	await open(page);
	const controls = page.locator('[data-voicebar]').getByRole('button');
	await expect(status(page)).toHaveCount(0);
	await expect(controls).toHaveCount(0);

	// A take starts talk mode. It lasts past the take: the controls do not come and go.
	await talkMode(page);
	await expect(primary(page)).toHaveText('Talk');
	for (const name of [
		'Auto',
		'Manual',
		'Skip back',
		'Back 15 seconds',
		'Forward 15 seconds',
		'Skip'
	]) {
		await expect(bar(page, name)).toBeVisible();
	}
	// Pause on the primary button is the way to silence a reply: there is no mute.
	await expect(bar(page, 'Speaker')).toHaveCount(0);

	// A typed turn ends it.
	await box(page).fill('what needs me?');
	await page.locator('[data-send]').click();
	await expect(said(page).locator('.a').last()).toHaveText(REPLY);
	await expect(controls).toHaveCount(0);
});

test('Manual: tap to start, tap to send, and a pause never cuts the take', async ({ page }) => {
	await open(page);
	await expect(status(page)).toHaveCount(0);

	await primary(page).click();
	await expect(bar(page, 'Manual')).toHaveAttribute('aria-pressed', 'true');
	await expect(status(page)).toHaveText('Recording — tap to send');
	await expect(primary(page)).toHaveText('↑ Submit');
	// Red while the take is open.
	await expect(primary(page)).toHaveCSS('background-color', 'rgb(255, 69, 58)');

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
	// The take has a name of its own: the Mac knows it when it comes again.
	expect(new URL(request.url()).search).toMatch(/^\?target=manager&speaker=1&take=[0-9a-f-]{36}$/);

	await expect(primary(page)).toHaveText('■ Stop');
	await expect(status(page)).toHaveText('Thinking…');
	await expect(said(page).locator('.u')).toHaveText('What needs me?');
	await expect(status(page)).toHaveText('Speaking…');
	await expect(primary(page)).toHaveText('❚❚ Pause');
	await expect(said(page).locator('.a').last()).toHaveText(REPLY);
	// The reply has two sentences: two clips, played in order, then it rests.
	await expect(status(page)).toHaveCount(0, { timeout: 8000 });
	await expect(primary(page)).toHaveText('Talk');
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
	// The take that starts talk mode is dropped when Auto takes over.
	await primary(page).click();
	await bar(page, 'Auto').click();
	await expect(bar(page, 'Auto')).toHaveAttribute('aria-pressed', 'true');
	await expect(status(page)).toHaveText('Listening…');
	await expect(primary(page)).toHaveText('Talk');
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
	// The mic is closed while the reply plays: the phone plays it at full
	// volume, and Auto cannot hear its own reply.
	expect(await page.evaluate(() => window.__mic.live())).toBe(0);

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
	// Opened for the first take, and once more after the reply.
	expect(await page.evaluate(() => window.__mic.opened)).toBe(2);
});

test('input only: the speech becomes text and nothing is read back', async ({ page }) => {
	// The Mac's setting: the phone has no switch for it.
	await open(page, ['/__fixture/voice?speaker=0']);
	// A choice an older build stored on this phone no longer counts.
	await page.evaluate(() => localStorage.setItem('mm.voice', '{"speaker":true}'));
	await page.reload();
	await primary(page).click();

	await say(page, 700);
	const sent = page.waitForRequest((request) => request.url().includes('/api/voice?'));
	await primary(page).click();
	expect(new URL((await sent).url()).search).toMatch(
		/^\?target=manager&speaker=0&take=[0-9a-f-]{36}$/
	);

	await expect(said(page).locator('.u')).toHaveText('What needs me?');
	await expect(said(page).locator('.a').last()).toHaveText(REPLY);
	await expect(status(page)).toHaveCount(0);
	await expect(primary(page)).toHaveText('Talk');
	expect(await page.evaluate(() => window.__clips)).toBe(0);
	expect((await takes(page))[0].speaker).toBe(false);
	// The turn is in the chat: a reload shows it.
	await page.reload();
	await expect(said(page).locator('.a').last()).toHaveText(REPLY);
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
	await expect(status(page)).toHaveCount(0);
	await expect(primary(page)).toHaveText('Talk');
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
	await expect(status(page)).toHaveCount(0);
	await expect(bar(page, 'Skip')).toBeDisabled();
	// The reply stays as text.
	await expect(said(page).locator('.a').last()).toHaveText(REPLY);
});

test('Skip back reads the last reply again, and the 15s buttons go through its audio', async ({
	page
}) => {
	await open(page);
	await talkMode(page);
	let asked = 0;
	page.on('request', (request) => {
		if (request.url().includes('/api/voice/replay')) asked += 1;
	});
	// Nothing was read yet: there is no audio to go through.
	await expect(bar(page, 'Back 15 seconds')).toBeDisabled();
	await expect(bar(page, 'Forward 15 seconds')).toBeDisabled();
	// With no audio on the phone the Mac reads the reply.
	await bar(page, 'Skip back').click();
	await expect(status(page)).toHaveText('Speaking…');
	await expect(bar(page, 'Back 15 seconds')).toBeEnabled();
	await expect(bar(page, 'Forward 15 seconds')).toBeEnabled();
	await expect(status(page)).toHaveCount(0, { timeout: 8000 });
	expect(asked).toBe(1);

	// The reply has ended. Its audio is kept: back 15 plays it from the phone.
	const before = await page.evaluate(() => window.__clips);
	await expect(bar(page, 'Forward 15 seconds')).toBeDisabled();
	await bar(page, 'Back 15 seconds').click();
	await expect(status(page)).toHaveText('Speaking…');
	await expect(primary(page)).toHaveText('❚❚ Pause');
	expect(await page.evaluate(() => window.__clips)).toBeGreaterThan(before);
	// The clips are shorter than 15 seconds together: forward goes past the end.
	await bar(page, 'Forward 15 seconds').click();
	await expect(status(page)).toHaveCount(0);
	await expect(primary(page)).toHaveText('Talk');

	// Skip back starts it again, from the phone too.
	await bar(page, 'Skip back').click();
	await expect(status(page)).toHaveText('Speaking…');
	// Paused, a jump plays on.
	await primary(page).click();
	await expect(status(page)).toHaveText('Paused');
	await bar(page, 'Back 15 seconds').click();
	await expect(status(page)).toHaveText('Speaking…');
	expect(asked).toBe(1);

	// Skip drops the audio: there is nothing to go back through.
	await bar(page, 'Skip').click();
	await expect(primary(page)).toHaveText('Talk');
	await expect(bar(page, 'Back 15 seconds')).toBeDisabled();
});

test('Cancel, left of Submit while a take is open, drops the take', async ({ page }) => {
	await open(page);
	const cancel = page.locator('[data-cancel]');
	await expect(cancel).toHaveCount(0);
	await primary(page).click();
	await expect(primary(page)).toHaveText('↑ Submit');
	await expect(cancel).toHaveText('Cancel');
	// Immediately left of the submit button, on its line.
	const left = (await cancel.boundingBox())!;
	const right = (await primary(page).boundingBox())!;
	expect(right.x - (left.x + left.width)).toBe(8);
	expect(Math.abs(left.y - right.y)).toBeLessThanOrEqual(1);
	expect(left.height).toBeGreaterThanOrEqual(40);
	expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(390);

	await say(page, 600);
	await cancel.click();
	await expect(primary(page)).toHaveText('Talk');
	await expect(cancel).toHaveCount(0);
	await expect(status(page)).toHaveCount(0);
	// Nothing was sent, and Manual gave the mic back.
	await page.waitForTimeout(500);
	expect(await takes(page)).toEqual([]);
	expect(await page.evaluate(() => window.__mic.live())).toBe(0);
	// Talk mode stays, and the next take works.
	await expect(bar(page, 'Manual')).toBeVisible();
	await primary(page).click();
	await say(page, 600);
	await primary(page).click();
	await expect(said(page).locator('.u')).toHaveText('What needs me?');
	expect(await takes(page)).toHaveLength(1);

	// Auto: Cancel drops the take and goes on listening.
	await expect(primary(page)).toHaveText('Talk', { timeout: 8000 });
	await bar(page, 'Auto').click();
	await expect(status(page)).toHaveText('Listening…');
	await primary(page).click();
	await expect(cancel).toBeVisible();
	await cancel.click();
	await expect(status(page)).toHaveText('Listening…');
	expect(await takes(page)).toHaveLength(1);
});

test('a thread has the same box: Cancel, the playback buttons, no mute', async ({ page }) => {
	await fakeMic(page);
	await reset(page);
	for (const name of ['voice', 'replies']) {
		await page.request.post(`/__fixture/capability?name=${name}&on=1`);
	}
	await forget(page);
	await page.goto(pairingLink(threadPath('localhost:7')));
	await expect(primary(page)).toHaveText('Talk');
	await primary(page).click();
	const cancel = page.locator('[data-cancel]');
	const left = (await cancel.boundingBox())!;
	const right = (await primary(page).boundingBox())!;
	expect(right.x - (left.x + left.width)).toBe(8);
	for (const name of ['Skip back', 'Back 15 seconds', 'Forward 15 seconds', 'Skip'])
		await expect(bar(page, name)).toBeVisible();
	await expect(bar(page, 'Speaker')).toHaveCount(0);
	await cancel.click();
	await expect(primary(page)).toHaveText('Talk');
	await expect(cancel).toHaveCount(0);
});

test('the button is Send while the box has text, and Talk when it is empty', async ({ page }) => {
	await open(page);
	await box(page).fill('status?');
	await expect(primary(page)).toHaveCount(0);
	const send = page.getByRole('button', { name: /^Send(ing)?$/ });
	await expect(send).toBeEnabled();
	await box(page).fill('');
	await expect(send).toHaveCount(0);
	await expect(primary(page)).toHaveText('Talk');

	// Typing works while voice is on, and a typed turn is not a take.
	await box(page).fill('what needs me?');
	await send.click();
	await expect(said(page).locator('.a').last()).toHaveText(REPLY);
	await expect(primary(page)).toHaveText('Talk');
	expect(await takes(page)).toEqual([]);
});

test('the mode is remembered on this phone; the Mac sets the start', async ({ page }) => {
	// A phone that has picked nothing starts with the Mac's defaults.
	await open(page, ['/__fixture/voice?mode=auto&speaker=0']);
	// No tap yet, so no mic: Auto says so by not claiming to listen.
	await expect(status(page)).toHaveCount(0);
	expect(await page.evaluate(() => window.__mic.opened)).toBe(0);
	await primary(page).click();
	await expect(bar(page, 'Auto')).toHaveAttribute('aria-pressed', 'true');

	await bar(page, 'Manual').click();
	await page.reload();
	await primary(page).click();
	await expect(bar(page, 'Manual')).toHaveAttribute('aria-pressed', 'true');
	// The phone's own choice outlives a change on the Mac.
	await page.request.post('/__fixture/voice?mode=auto&speaker=0');
	await expect(bar(page, 'Manual')).toHaveAttribute('aria-pressed', 'true');
});

test('a muted mic takes nothing, and a refused take says why', async ({ page }) => {
	await open(page);
	// Manual opens the mic only on a tap: it has no mute control.
	await primary(page).click();
	await expect(bar(page, 'Microphone')).toHaveCount(0);
	await bar(page, 'Auto').click();
	await expect(status(page)).toHaveText('Listening…');
	await expect(bar(page, 'Microphone').locator('[data-icon="mic"]')).toBeVisible();
	await bar(page, 'Microphone').click();
	await expect(status(page)).toHaveText('Mic muted');
	await expect(bar(page, 'Microphone').locator('[data-icon="micOff"]')).toBeVisible();
	await expect(primary(page)).toBeDisabled();
	expect(await takes(page)).toEqual([]);
	// Back in Manual the mute is gone with its control: Talk works.
	await bar(page, 'Manual').click();
	await expect(bar(page, 'Microphone')).toHaveCount(0);
	await expect(primary(page)).toBeEnabled();
	await expect(status(page)).toHaveCount(0);

	await page.request.post('/__fixture/manager-status?value=waiting');
	await primary(page).click();
	await say(page, 600);
	await primary(page).click();
	await expect(status(page)).toHaveText('Maestro is waiting on a prompt');
	await expect(primary(page)).toHaveText('Talk');

	// A take with no words in it.
	await page.request.post('/__fixture/manager-status?value=idle');
	await page.request.post('/__fixture/voice?heard=');
	await primary(page).click();
	await say(page, 600);
	await primary(page).click();
	await expect(status(page)).toHaveText('No speech heard');
});

test('the mic is given back when it is not needed', async ({ page }) => {
	const live = (): Promise<number> => page.evaluate(() => window.__mic.live());
	await open(page, ['/__fixture/voice?delay=1500']);
	expect(await live()).toBe(0);

	// Manual: held for the take only.
	await primary(page).click();
	await expect(primary(page)).toHaveText('↑ Submit');
	expect(await live()).toBe(1);
	await say(page, 600);
	await primary(page).click();
	await expect(primary(page)).toHaveText('■ Stop');
	expect(await live()).toBe(0);
	await expect(status(page)).toHaveCount(0, { timeout: 10000 });
	expect(await live()).toBe(0);

	// A take that is stopped, not sent, gives it back too.
	await primary(page).click();
	await expect(primary(page)).toHaveText('↑ Submit');

	// Auto drops the open take and holds the mic while it listens; mute and
	// Manual give it back.
	await bar(page, 'Auto').click();
	await expect(status(page)).toHaveText('Listening…');
	expect(await live()).toBe(1);
	await bar(page, 'Microphone').click();
	expect(await live()).toBe(0);
	await bar(page, 'Microphone').click();
	await expect(status(page)).toHaveText('Listening…');
	expect(await live()).toBe(1);
	await bar(page, 'Manual').click();
	expect(await live()).toBe(0);

	// Leaving the page gives it back, whatever the mode.
	await bar(page, 'Auto').click();
	await expect(status(page)).toHaveText('Listening…');
	expect(await live()).toBe(1);
	await page.evaluate(() => window.dispatchEvent(new Event('pagehide')));
	expect(await live()).toBe(0);
	await expect(status(page)).toHaveCount(0);
	// One tap brings it back.
	await primary(page).click();
	await expect(primary(page)).toHaveText('↑ Submit');
	expect(await live()).toBe(1);
});

test('a mic that does not open says why', async ({ page }) => {
	await open(page);
	for (const [error, label] of [
		['NotAllowedError', 'Mic blocked'],
		['NotFoundError', 'No microphone'],
		['NotReadableError', 'Mic in use']
	]) {
		await page.evaluate((name) => (window.__mic.fail = name), error);
		await primary(page).click();
		await expect(status(page)).toHaveText(label);
		await expect(primary(page)).toHaveText('Talk');
	}
	// Allowed again: the next tap records, and the label goes.
	await page.evaluate(() => (window.__mic.fail = null));
	await primary(page).click();
	await expect(status(page)).toHaveText('Recording — tap to send');
});

test('the level meter moves with the voice while the mic is open', async ({ page }) => {
	await open(page);
	const meter = page.getByRole('meter', { name: 'Mic level' });
	await expect(meter).toHaveCount(0);
	await primary(page).click();
	await expect(meter).toBeVisible();
	const level = async (): Promise<number> => Number(await meter.getAttribute('aria-valuenow'));
	await expect.poll(level).toBeLessThan(10);
	await speak(page, true);
	await expect.poll(level).toBeGreaterThan(50);
	await speak(page, false);
	await expect.poll(level).toBeLessThan(10);
	await say(page, 500);
	await primary(page).click();
	// No mic, no meter.
	await expect(meter).toHaveCount(0);

	// Auto shows it while it waits for speech too.
	await expect(status(page)).toHaveCount(0, { timeout: 8000 });
	await bar(page, 'Auto').click();
	await expect(status(page)).toHaveText('Listening…');
	await expect(meter).toBeVisible();
});

test('a take that cannot be used says why: no speech, no Mac, no models', async ({ page }) => {
	await open(page);
	// Nothing said: nothing is sent.
	await primary(page).click();
	await page.waitForTimeout(700);
	await primary(page).click();
	await expect(status(page)).toHaveText('No speech heard');
	await expect(primary(page)).toHaveText('Talk');
	expect(await takes(page)).toEqual([]);

	// The Mac is asleep or off the tailnet.
	await page.route('**/api/voice?*', (route) => route.abort());
	await primary(page).click();
	await say(page, 600);
	await primary(page).click();
	await expect(status(page)).toHaveText('Mac not reachable');
	await page.unroute('**/api/voice?*');

	// The Mac has not fetched its voice models yet.
	await page.route('**/api/voice?*', (route) =>
		route.fulfill({
			status: 503,
			contentType: 'application/json',
			body: JSON.stringify({ error: 'models', message: 'Voice models not ready' })
		})
	);
	await primary(page).click();
	await say(page, 600);
	await primary(page).click();
	await expect(status(page)).toHaveText('Voice models loading');
	await page.unroute('**/api/voice?*');

	// A take longer than the Mac accepts.
	await page.route('**/api/voice?*', (route) =>
		route.fulfill({
			status: 413,
			contentType: 'application/json',
			body: JSON.stringify({ error: 'too_long' })
		})
	);
	await primary(page).click();
	await say(page, 600);
	await primary(page).click();
	await expect(status(page)).toHaveText('Take too long');
});

test('the phone is told what the audio is for, and the screen stays on for a turn', async ({
	page
}) => {
	await open(page, ['/__fixture/voice?delay=800']);
	const session = (): Promise<string> => page.evaluate(() => window.__session());
	const awake = (): Promise<number> => page.evaluate(() => window.__awake());
	expect(await session()).toBe('auto');
	expect(await awake()).toBe(0);

	await primary(page).click();
	await expect(status(page)).toHaveText('Recording — tap to send');
	// The mic is open: the session records, and the screen must not lock.
	expect(await session()).toBe('play-and-record');
	expect(await awake()).toBe(1);
	await say(page, 600);
	await primary(page).click();
	await expect(primary(page)).toHaveText('■ Stop');
	// The mic is closed before the reply: it plays as playback, which the
	// ringer switch does not mute and the earpiece does not get.
	expect(await session()).toBe('playback');
	expect(await page.evaluate(() => window.__mic.live())).toBe(0);
	expect(await awake()).toBe(1);
	await expect(status(page)).toHaveText('Speaking…');
	expect(await session()).toBe('playback');
	await expect(status(page)).toHaveCount(0, { timeout: 8000 });
	expect(await awake()).toBe(0);
});

test('the mic prompt suspends the audio; the take still records', async ({ page }) => {
	await open(page);
	await page.evaluate(() => (window.__mic.suspendOnOpen = true));
	await primary(page).click();
	await expect(status(page)).toHaveText('Recording — tap to send');
	expect(await page.evaluate(() => window.__app?.state)).toBe('running');
	await speak(page, true);
	await expect
		.poll(async () =>
			Number(await page.getByRole('meter', { name: 'Mic level' }).getAttribute('aria-valuenow'))
		)
		.toBeGreaterThan(50);
	await page.waitForTimeout(500);
	await speak(page, false);
	await primary(page).click();
	await expect(said(page).locator('.u')).toHaveText('What needs me?');
	expect((await takes(page))[0].rms).toBeGreaterThan(0.01);
});

test('an interruption ends a take with a label and holds a reply for Resume', async ({ page }) => {
	await open(page);
	// A call comes in while a take is open.
	await primary(page).click();
	await expect(status(page)).toHaveText('Recording — tap to send');
	await page.evaluate(() => window.__app?.suspend());
	await expect(status(page)).toHaveText('Mic interrupted');
	await expect(primary(page)).toHaveText('Talk');
	expect(await page.evaluate(() => window.__mic.live())).toBe(0);
	expect(await takes(page)).toEqual([]);

	// The next tap resumes the audio and records.
	await primary(page).click();
	await expect(status(page)).toHaveText('Recording — tap to send');
	expect(await page.evaluate(() => window.__app?.state)).toBe('running');
	await say(page, 600);
	await primary(page).click();

	// The same while the reply plays: it is held, not lost.
	await expect(status(page)).toHaveText('Speaking…');
	await page.evaluate(() => window.__app?.suspend());
	await expect(status(page)).toHaveText('Paused');
	await expect(primary(page)).toHaveText('▶ Resume');
	await primary(page).click();
	await expect(status(page)).toHaveText('Speaking…');
	await expect(status(page)).toHaveCount(0, { timeout: 8000 });
});

test('on the footer a drag never starts a take or presses a control; a tap does', async ({
	page
}) => {
	await open(page);
	const foot = page.locator('[data-foot]');
	const opened = (): Promise<number> => page.evaluate(() => window.__mic.opened);
	const centre = async (target: Locator): Promise<[number, number]> => {
		const box = (await target.boundingBox())!;
		return [box.x + box.width / 2, box.y + box.height / 2];
	};
	const bottom = async (): Promise<number> => {
		const box = (await foot.boundingBox())!;
		return box.y + box.height;
	};
	const rest = await bottom();

	// A drag up that starts on Talk is not a take.
	let [x, y] = await centre(primary(page));
	await page.mouse.move(x, y);
	await page.mouse.down();
	await page.mouse.move(x, y - 160, { steps: 12 });
	await page.waitForTimeout(120);
	await page.mouse.up();
	await page.waitForTimeout(350);
	await expect(primary(page)).toHaveText('Talk');
	expect(await opened()).toBe(0);
	expect(await bottom()).toBe(rest);

	// Up and back down onto the button, which a browser calls a click: still no take.
	[x, y] = await centre(primary(page));
	await page.mouse.move(x, y);
	await page.mouse.down();
	await page.mouse.move(x, y - 80, { steps: 8 });
	await page.mouse.move(x, y, { steps: 8 });
	await page.mouse.up();
	await page.waitForTimeout(350);
	await expect(primary(page)).toHaveText('Talk');
	expect(await opened()).toBe(0);

	// The same on the other voice controls: a drag from Auto does not switch the mode.
	await talkMode(page);
	const held = await opened();
	[x, y] = await centre(bar(page, 'Auto'));
	await page.mouse.move(x, y);
	await page.mouse.down();
	await page.mouse.move(x, y - 160, { steps: 12 });
	await page.waitForTimeout(120);
	await page.mouse.up();
	await expect(bar(page, 'Manual')).toHaveAttribute('aria-pressed', 'true');
	expect(await opened()).toBe(held);

	// A drag to the side that starts on the button is not a take either.
	[x, y] = await centre(primary(page));
	await page.mouse.move(x, y);
	await page.mouse.down();
	await page.mouse.move(x - 160, y, { steps: 10 });
	await page.mouse.move(x - 20, y, { steps: 10 });
	await page.mouse.up();
	await page.waitForTimeout(300);
	expect(await opened()).toBe(held);
	if (await page.locator('[data-drawer]').isVisible()) {
		await page.getByRole('button', { name: 'Close sidebar' }).click();
	}
	await expect(primary(page)).toHaveText('Talk');

	// A tap, with the small slip a finger makes, starts the take and the
	// footer stays where it is: its status line comes in above, its foot does not move.
	[x, y] = await centre(primary(page));
	await page.mouse.move(x, y);
	await page.mouse.down();
	await page.mouse.move(x + 3, y - 3);
	await page.mouse.up();
	await expect(primary(page)).toHaveText('↑ Submit');
	expect(await opened()).toBe(held + 1);
	expect(await bottom()).toBe(rest);
	// And the tap to send does not move it either.
	await say(page, 500);
	await primary(page).click();
	await expect(primary(page)).toHaveText('■ Stop');
	expect(await bottom()).toBe(rest);
});

test('the delays of a turn are measured', async ({ page }) => {
	await open(page);
	await primary(page).click();
	await say(page, 600);
	await primary(page).click();
	await expect(status(page)).toHaveText('Speaking…');
	const voicebar = page.locator('[data-voicebar]');
	const text = Number(await voicebar.getAttribute('data-first-text-ms'));
	const audio = Number(await voicebar.getAttribute('data-first-audio-ms'));
	// The fixture hears the take after 300 ms and speaks once the reply is written.
	expect(text).toBeGreaterThanOrEqual(250);
	expect(text).toBeLessThan(1500);
	expect(audio).toBeGreaterThan(text);
	expect(audio).toBeLessThan(5000);
	console.log(`fixture turn: first text ${text} ms, first audio ${audio} ms after Submit`);
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
	await talkMode(page);
	const controls = [
		...['Auto', 'Manual', 'Skip back', 'Back 15 seconds', 'Forward 15 seconds', 'Skip'].map(
			(name) => bar(page, name)
		),
		primary(page)
	];
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
	// 8pt between the mode switch and the playback buttons.
	const mode = (await bar(page, 'Manual').boundingBox())!;
	const back = (await bar(page, 'Skip back').boundingBox())!;
	expect(back.x - (mode.x + mode.width)).toBeGreaterThanOrEqual(8);
	// Nothing sits under the home indicator or runs off the side.
	const form = (await page.locator('form.compose').boundingBox())!;
	expect(form.y + form.height).toBeLessThanOrEqual(844);
	expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(390);
});

test('the voice controls work with the Board tab showing', async ({ page }) => {
	await open(page);
	await talkMode(page);
	await page.locator('[data-tab="board"]').click();
	await expect(page.locator('[data-page="board"]')).not.toHaveAttribute('inert', '');
	// The bar is on the footer, under the board, and a tap reaches each control.
	const voicebar = (await page.locator('[data-voicebar]').boundingBox())!;
	const list = (await page.locator('[data-board]').boundingBox())!;
	expect(voicebar.y).toBeGreaterThanOrEqual(list.y + list.height - 1);
	for (const control of [bar(page, 'Auto'), bar(page, 'Skip back'), primary(page)]) {
		const reached = await control.evaluate((element) => {
			const box = element.getBoundingClientRect();
			const hit = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2);
			return hit === element || element.contains(hit);
		});
		expect(reached).toBe(true);
	}
	// A take works from the board.
	await primary(page).click();
	await expect(status(page)).toHaveText('Recording — tap to send');
	await say(page, 600);
	await primary(page).click();
	await expect(primary(page)).toHaveText('■ Stop');
	expect(await takes(page)).toHaveLength(1);
});

test('with reduced motion nothing in the bar animates', async ({ page }) => {
	await page.emulateMedia({ reducedMotion: 'reduce' });
	await open(page);
	await primary(page).click();
	await expect(status(page)).toHaveText('Recording — tap to send');
	const animated = await page.evaluate(
		() =>
			[...document.querySelectorAll('[data-voicebar] .wave i')].filter(
				(element) => getComputedStyle(element).animationName !== 'none'
			).length
	);
	expect(animated).toBe(0);
});

/** Two quick taps of one finger on the text of a message. */
async function doubleTap(page: Page, row: Locator): Promise<void> {
	const box = await row.boundingBox();
	if (!box) throw new Error('the message is not on the screen');
	await page.touchscreen.tap(box.x + 24, box.y + 12);
	await page.touchscreen.tap(box.x + 24, box.y + 12);
}

async function openMessages(page: Page, thread: string): Promise<void> {
	await fakeMic(page);
	await reset(page);
	// Voice alone: reading aloud types nothing, so Replies stays off.
	await page.request.post('/__fixture/capability?name=voice&on=1');
	await page.request.post('/__fixture/voice?delay=700');
	await page.request.post(
		`/__fixture/say?id=${thread}&text=${encodeURIComponent('Pushed to the branch. CI is green.')}`
	);
	await forget(page);
	await page.goto(pairingLink(threadPath(thread)));
	await expect(page.locator('.a').nth(1)).toContainText('Pushed to the branch.');
}

test('a double tap on an agent message opens its menu under it, one menu at a time', async ({
	page,
	context
}) => {
	await context.grantPermissions(['clipboard-read', 'clipboard-write']);
	await openMessages(page, 'localhost:7');
	const menus = page.locator('[data-menu]');
	const first = page.locator('.a').nth(0);
	const second = page.locator('.a').nth(1);
	// No menu until it is asked for. Play is under each agent message, and only there.
	await expect(menus).toHaveCount(0);
	await expect(page.locator('[data-say]')).toHaveCount(await page.locator('.a').count());
	await expect(first.getByRole('button', { name: 'Play' })).toBeVisible();
	await expect(first.getByRole('button', { name: 'Copy' })).toHaveCount(0);
	await expect(page.locator('.u [data-say]')).toHaveCount(0);

	// One tap is not the gesture, and neither are two slow ones.
	await first.tap({ position: { x: 24, y: 12 } });
	await page.waitForTimeout(450);
	await first.tap({ position: { x: 24, y: 12 } });
	await page.waitForTimeout(450);
	await expect(menus).toHaveCount(0);
	// The human's messages have no menu.
	await doubleTap(page, page.locator('.u').first());
	await expect(menus).toHaveCount(0);

	await doubleTap(page, first);
	await expect(menus).toHaveCount(1);
	await expect(first.locator('[data-menu]')).toBeVisible();
	await expect(first.getByRole('button', { name: 'Play' })).toBeVisible();
	await expect(first.getByRole('button', { name: 'Copy' })).toBeVisible();
	// In the flow, between the message's text and the message after it.
	const text = await first.locator('.prose').boundingBox();
	const menu = await first.locator('[data-menu]').boundingBox();
	const after = await second.boundingBox();
	expect(menu!.y).toBeGreaterThanOrEqual(text!.y + text!.height);
	expect(after!.y).toBeGreaterThanOrEqual(menu!.y + menu!.height);
	// The double tap selected no word and did not zoom the page.
	expect(await page.evaluate(() => String(getSelection()))).toBe('');
	expect(await page.evaluate(() => window.visualViewport?.scale)).toBe(1);
	if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/menu-open.png` });

	// Each button is a full touch target.
	for (const name of ['Play', 'Copy']) {
		const target = await first
			.getByRole('button', { name })
			.evaluate((el) => getComputedStyle(el, '::after').height);
		expect(parseFloat(target)).toBeGreaterThanOrEqual(44);
	}
	await first.getByRole('button', { name: 'Copy' }).tap();
	await expect(first.getByRole('button', { name: 'Copy' })).toHaveAttribute('data-copied', '');
	expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(
		'Done. 4 files changed, tests pass. Nothing else is needed from you.'
	);
	await expect(menus).toHaveCount(1);

	// A double tap on another message moves the menu there.
	await doubleTap(page, second);
	await expect(menus).toHaveCount(1);
	await expect(second.locator('[data-menu]')).toBeVisible();
	// A second double tap on the message that has it closes it.
	await doubleTap(page, second);
	await expect(menus).toHaveCount(0);

	// A tap outside closes it: on another message, on the human's, on the bar.
	for (const outside of [first, page.locator('.u').first(), page.locator('header .title')]) {
		await doubleTap(page, second);
		await expect(menus).toHaveCount(1);
		await page.waitForTimeout(350);
		await outside.tap({ position: { x: 24, y: 12 } });
		await expect(menus).toHaveCount(0);
		await page.waitForTimeout(350);
	}

	// A mouse opens it the same way.
	const box = await first.boundingBox();
	await page.mouse.dblclick(box!.x + 24, box!.y + 12);
	await expect(first.locator('[data-menu]')).toBeVisible();
	expect(await page.evaluate(() => String(getSelection()))).toBe('');
});

test('Play under a message reads it aloud, one message at a time', async ({ page }) => {
	const THREAD = 'localhost:7';
	const playButton = (row: Locator): Locator => row.locator('[data-say]');
	const clips = (): Promise<number> => page.evaluate(() => window.__clips);
	const said = async (): Promise<{ target: string; n: number; cached: boolean }[]> =>
		((await (await page.request.post('/__fixture/voice-said')).json()) as { said: never[] }).said;

	await openMessages(page, THREAD);
	const first = page.locator('.a').nth(0);
	const second = page.locator('.a').nth(1);
	// No double tap: the button is there.
	await expect(playButton(first)).toHaveAccessibleName('Play');
	await expect(playButton(first).locator('[data-icon="play"]')).toBeVisible();

	// A tap asks the Mac for that row. Until audio comes the button shows progress, not Play.
	const asked = page.waitForRequest((request) => request.url().includes('/api/voice/say'));
	await playButton(first).tap();
	const request = await asked;
	expect(request.method()).toBe('POST');
	expect(new URL(request.url()).search).toMatch(/^\?target=localhost%3A7&n=\d+$/);
	expect(request.headers()['x-muxmaestro']).toBe('1');
	await expect(playButton(first)).toHaveAttribute('data-say', 'loading');
	await expect(playButton(first)).toHaveAttribute('aria-busy', 'true');
	await expect(playButton(first).locator('[data-icon]')).toHaveCount(0);
	if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/play-loading.png` });

	// Audio plays on this phone: the button is Stop.
	await expect(playButton(first)).toHaveAttribute('data-say', 'playing');
	await expect(playButton(first)).toHaveAccessibleName('Stop');
	await expect(playButton(first).locator('[data-icon="stop"]')).toBeVisible();
	expect(await clips()).toBeGreaterThan(0);
	if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/play-playing.png` });

	// A tap outside does not stop it.
	await page.locator('.u').first().tap();
	await expect(playButton(first)).toHaveAttribute('data-say', 'playing');
	// Neither does the menu of another message.
	await doubleTap(page, second);
	await expect(playButton(first)).toHaveAttribute('data-say', 'playing');
	await expect(playButton(second)).toHaveAttribute('data-say', 'idle');

	// Play on another message stops this one: they never talk over each other.
	await playButton(second).tap();
	await expect(playButton(first)).toHaveAttribute('data-say', 'idle');
	await expect(playButton(second)).toHaveAttribute('data-say', 'playing');
	// A tap on the message that is read is its Stop: nothing new is asked for.
	await playButton(second).tap();
	await expect(playButton(second)).toHaveAttribute('data-say', 'idle');
	expect((await said()).map((one) => one.cached)).toEqual([false, false]);

	// The same message again comes from the Mac's cache, and starts sooner.
	const again = Date.now();
	await playButton(first).tap();
	await expect(playButton(first)).toHaveAttribute('data-say', 'playing');
	expect(Date.now() - again).toBeLessThan(700);
	expect((await said()).at(-1)?.cached).toBe(true);
	// Read to its end: the button is Play again.
	await expect(playButton(first)).toHaveAttribute('data-say', 'idle', { timeout: 8000 });
	await expect(playButton(first)).toHaveAccessibleName('Play');
});

// MARK: a take is kept until the Mac has it

/** The takes this phone still holds for the bar on screen. */
const kept = (page: Page): Locator => page.locator('[data-kept-take]');
const resend = (page: Page): Locator => kept(page).getByRole('button', { name: 'Resend' });

interface Sent {
	target: string;
	text: string;
	from: 'audio' | 'words';
}

async function sent(page: Page): Promise<Sent[]> {
	return ((await (await page.request.post('/__fixture/voice-takes')).json()) as { sent: Sent[] })
		.sent;
}

/** One Manual take: tap, speak, tap. */
async function take(page: Page): Promise<void> {
	await primary(page).click();
	await expect(primary(page)).toHaveText('↑ Submit');
	await say(page, 600);
	await primary(page).click();
}

test('a take the Mac never got is kept, lasts through a reload, and is sent again', async ({
	page
}) => {
	await open(page);
	// The Mac is asleep or off the tailnet.
	await page.route('**/api/voice?*', (route) => route.abort());
	await take(page);
	await expect(status(page)).toHaveText('Mac not reachable');
	await expect(kept(page)).toHaveCount(1);
	await page.unroute('**/api/voice?*');

	// It is on the phone, not in the page: a reload does not lose it.
	await page.reload();
	await expect(primary(page)).toHaveText('Talk');
	await expect(kept(page)).toHaveCount(1);
	expect(await sent(page)).toEqual([]);

	await resend(page).click();
	await expect(said(page).locator('.u').last()).toHaveText('What needs me?');
	await expect(said(page).locator('.a').last()).toHaveText(REPLY);
	await expect(kept(page)).toHaveCount(0);
	// The audio went again: the Mac never had it.
	expect(await sent(page)).toEqual([{ target: 'manager', text: 'What needs me?', from: 'audio' }]);
	expect((await takes(page)).length).toBe(1);

	// The Mac has it: nothing is left on the phone.
	await page.reload();
	await expect(primary(page)).toHaveText('Talk');
	await expect(kept(page)).toHaveCount(0);
});

test('every way a send fails keeps the take', async ({ page }) => {
	await open(page);
	// The Mac answers, and does not take it.
	await page.route('**/api/voice?*', (route) =>
		route.fulfill({
			status: 503,
			contentType: 'application/json',
			body: JSON.stringify({ error: 'models', message: 'Voice models not ready' })
		})
	);
	await take(page);
	await expect(status(page)).toHaveText('Voice models loading');
	await expect(kept(page)).toHaveCount(1);
	await page.unroute('**/api/voice?*');

	// The stream dies before the Mac has the words.
	await page.request.post('/__fixture/voice?fail=cut');
	await take(page);
	await expect(kept(page)).toHaveCount(2);

	// The Mac could not transcribe it.
	await page.request.post('/__fixture/voice?fail=failed');
	await take(page);
	await expect(status(page)).toHaveText('Could not transcribe');
	await expect(kept(page)).toHaveCount(3);
	expect(await sent(page)).toEqual([]);

	// Each one goes again by itself.
	for (const left of [2, 1, 0]) {
		await resend(page).first().click();
		await expect(kept(page)).toHaveCount(left);
		await expect(primary(page)).toHaveText('Talk', { timeout: 15000 });
	}
	expect((await sent(page)).map((one) => one.text)).toEqual(Array(3).fill('What needs me?'));
});

test('a take the Mac heard and did not send goes again as words', async ({ page }) => {
	await open(page, ['/__fixture/voice?fail=refused']);
	await take(page);
	// The words are known: they are what the kept take shows.
	await expect(kept(page)).toHaveCount(1);
	await expect(kept(page)).toContainText('What needs me?');
	// In one place only: the words are not put in the text box as well.
	await expect(box(page)).toHaveValue('');
	expect(await sent(page)).toEqual([]);

	const again = page.waitForRequest((request) => request.url().includes('/api/voice?'));
	await resend(page).click();
	const request = await again;
	expect(request.url()).toContain('heard=1');
	expect(request.postDataJSON()).toEqual({ text: 'What needs me?' });
	await expect(said(page).locator('.a').last()).toHaveText(REPLY);
	await expect(kept(page)).toHaveCount(0);
	expect(await sent(page)).toEqual([{ target: 'manager', text: 'What needs me?', from: 'words' }]);
	// The audio was sent once only.
	expect((await takes(page)).length).toBe(1);
});

test('a take the Mac sent before the answer was lost is not typed twice', async ({ page }) => {
	await open(page, ['/__fixture/voice?fail=lost']);
	await take(page);
	// The phone was never told, so it keeps the take.
	await expect(kept(page)).toHaveCount(1);
	await expect(primary(page)).toHaveText('Talk', { timeout: 15000 });
	expect((await sent(page)).length).toBe(1);

	// The Mac knows the take: it answers that it has it, and types nothing.
	await resend(page).click();
	await expect(kept(page)).toHaveCount(0);
	await expect(primary(page)).toHaveText('Talk');
	expect((await sent(page)).length).toBe(1);
	expect((await takes(page)).length).toBe(1);
	await expect(said(page).locator('.u')).toHaveCount(1);
});

test('Discard drops a kept take for good', async ({ page }) => {
	await open(page);
	await page.route('**/api/voice?*', (route) => route.abort());
	await take(page);
	await expect(kept(page)).toHaveCount(1);
	await page.unroute('**/api/voice?*');

	await kept(page).getByRole('button', { name: 'Discard' }).click();
	await expect(kept(page)).toHaveCount(0);
	// The phone's storage is written a moment after the tap.
	await page.waitForTimeout(200);
	await page.reload();
	await expect(primary(page)).toHaveText('Talk');
	await expect(kept(page)).toHaveCount(0);
	expect(await sent(page)).toEqual([]);
});

test('a take that is open when the app goes to the background is kept', async ({ page }) => {
	await open(page);
	await primary(page).click();
	await expect(primary(page)).toHaveText('↑ Submit');
	await say(page, 600);
	await page.evaluate(() => window.dispatchEvent(new Event('pagehide')));
	await expect(primary(page)).toHaveText('Talk');
	await expect(kept(page)).toHaveCount(1);
	expect(await takes(page)).toEqual([]);

	await resend(page).click();
	await expect(said(page).locator('.a').last()).toHaveText(REPLY);
	await expect(kept(page)).toHaveCount(0);
	expect((await takes(page))[0].seconds).toBeGreaterThan(0.5);
});

test('a thread keeps its own takes', async ({ page }) => {
	await open(page);
	await page.route('**/api/voice?*', (route) => route.abort());
	await take(page);
	await expect(kept(page)).toHaveCount(1);
	await page.unroute('**/api/voice?*');

	// The manager's take is not offered in a thread.
	await page.request.post('/__fixture/capability?name=replies&on=1');
	await page.goto(threadPath('localhost:7'));
	await expect(primary(page)).toHaveText('Talk');
	await expect(kept(page)).toHaveCount(0);
});
