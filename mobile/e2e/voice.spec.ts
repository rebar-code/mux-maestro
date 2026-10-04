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

test('Manual: tap to start, tap to send, and a pause never cuts the take', async ({ page }) => {
	await open(page);
	await expect(status(page)).toHaveText('Start talking');
	await expect(bar(page, 'Manual')).toHaveAttribute('aria-pressed', 'true');

	await primary(page).click();
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
	expect(new URL(request.url()).search).toBe('?target=manager&speaker=1');

	await expect(primary(page)).toHaveText('■ Stop');
	await expect(status(page)).toHaveText('Thinking…');
	await expect(said(page).locator('.u')).toHaveText('What needs me?');
	await expect(status(page)).toHaveText('Speaking…');
	await expect(primary(page)).toHaveText('❚❚ Pause');
	await expect(said(page).locator('.a').last()).toHaveText(REPLY);
	// The reply has two sentences: two clips, played in order, then it rests.
	await expect(status(page)).toHaveText('Start talking', { timeout: 8000 });
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
	await open(page);
	await bar(page, 'Speaker').click();
	await expect(bar(page, 'Speaker')).toHaveAttribute('aria-pressed', 'false');
	await expect(bar(page, 'Speaker').locator('[data-icon="speakerOff"]')).toBeVisible();

	await primary(page).click();
	await say(page, 700);
	const sent = page.waitForRequest((request) => request.url().includes('/api/voice?'));
	await primary(page).click();
	expect(new URL((await sent).url()).search).toBe('?target=manager&speaker=0');

	await expect(said(page).locator('.u')).toHaveText('What needs me?');
	await expect(said(page).locator('.a').last()).toHaveText(REPLY);
	await expect(status(page)).toHaveText('Start talking');
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
	await expect(status(page)).toHaveText('Start talking');
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
	await expect(status(page)).toHaveText('Start talking');
	await expect(bar(page, 'Skip')).toBeDisabled();
	// The reply stays as text.
	await expect(said(page).locator('.a').last()).toHaveText(REPLY);
});

test('Replay reads the last reply again, and Talk during it starts a take', async ({ page }) => {
	await open(page);
	await bar(page, 'Replay').click();
	await expect(status(page)).toHaveText('Speaking…');
	expect(await page.evaluate(() => window.__clips)).toBeGreaterThan(0);
	await bar(page, 'Skip').click();
	await expect(primary(page)).toHaveText('Talk');

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
	await expect(primary(page)).toHaveText('Talk');

	// Typing works while voice is on, and a typed turn is not a take.
	await box(page).fill('what needs me?');
	await send.click();
	await expect(said(page).locator('.a').last()).toHaveText(REPLY);
	await expect(primary(page)).toHaveText('Talk');
	expect(await takes(page)).toEqual([]);
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
	// Manual opens the mic only on a tap: it has no mute control.
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
	await expect(status(page)).toHaveText('Start talking');

	await page.request.post('/__fixture/manager-status?value=waiting');
	await primary(page).click();
	await say(page, 600);
	await primary(page).click();
	await expect(status(page)).toHaveText('Manager is waiting on a prompt');
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
	await expect(status(page)).toHaveText('Start talking', { timeout: 10000 });
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
	await expect(status(page)).toHaveText('Start talking');
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
	await expect(status(page)).toHaveText('Start talking', { timeout: 8000 });
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
	await expect(status(page)).toHaveText('Start talking', { timeout: 8000 });
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
	await expect(status(page)).toHaveText('Start talking', { timeout: 8000 });
});

test('on the footer a tap never drags the board and a drag never starts a take', async ({
	page
}) => {
	await open(page);
	const board = page.locator('[data-board]');
	const foot = page.locator('[data-foot]');
	const opened = (): Promise<number> => page.evaluate(() => window.__mic.opened);
	const centre = async (target: Locator): Promise<[number, number]> => {
		const box = (await target.boundingBox())!;
		return [box.x + box.width / 2, box.y + box.height / 2];
	};
	const lower = async (): Promise<void> => {
		while ((await board.getAttribute('data-stop')) !== '0') {
			await page.locator('[data-grab]').click();
			await page.waitForTimeout(350);
		}
	};

	// A drag up that starts on Talk raises the board. It is not a take.
	let [x, y] = await centre(primary(page));
	await page.mouse.move(x, y);
	await page.mouse.down();
	await page.mouse.move(x, y - 160, { steps: 12 });
	await page.waitForTimeout(120);
	await page.mouse.up();
	await expect(board).not.toHaveAttribute('data-stop', '0');
	await expect(primary(page)).toHaveText('Talk');
	expect(await opened()).toBe(0);
	await lower();

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
	await lower();

	// The same on the other voice controls: a drag from Auto does not switch the mode.
	[x, y] = await centre(bar(page, 'Auto'));
	await page.mouse.move(x, y);
	await page.mouse.down();
	await page.mouse.move(x, y - 160, { steps: 12 });
	await page.waitForTimeout(120);
	await page.mouse.up();
	await expect(bar(page, 'Manual')).toHaveAttribute('aria-pressed', 'true');
	expect(await opened()).toBe(0);
	await lower();

	// A drag to the side that starts on the button is not a take either.
	[x, y] = await centre(primary(page));
	await page.mouse.move(x, y);
	await page.mouse.down();
	await page.mouse.move(x - 160, y, { steps: 10 });
	await page.mouse.move(x - 20, y, { steps: 10 });
	await page.mouse.up();
	await page.waitForTimeout(300);
	expect(await opened()).toBe(0);
	if (await page.locator('[data-drawer]').isVisible()) {
		await page.getByRole('button', { name: 'Close sidebar' }).click();
	}
	await lower();
	await expect(primary(page)).toHaveText('Talk');

	// A tap, with the small slip a finger makes, starts the take and the
	// footer stays where it is.
	const rest = (await foot.boundingBox())!.y;
	[x, y] = await centre(primary(page));
	await page.mouse.move(x, y);
	await page.mouse.down();
	await page.mouse.move(x + 3, y - 3);
	await page.mouse.up();
	await expect(primary(page)).toHaveText('↑ Submit');
	expect(await opened()).toBe(1);
	await expect(board).toHaveAttribute('data-stop', '0');
	expect((await foot.boundingBox())!.y).toBe(rest);
	// And the tap to send does not move it either.
	await say(page, 500);
	await primary(page).click();
	await expect(primary(page)).toHaveText('■ Stop');
	await expect(board).toHaveAttribute('data-stop', '0');
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
	const controls = [
		...['Auto', 'Manual', 'Speaker', 'Replay', 'Skip'].map((name) => bar(page, name)),
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
	// 8pt between the icon buttons.
	const speaker = (await bar(page, 'Speaker').boundingBox())!;
	const replay = (await bar(page, 'Replay').boundingBox())!;
	expect(replay.x - (speaker.x + speaker.width)).toBeGreaterThanOrEqual(8);
	// Nothing sits under the home indicator or runs off the side.
	const form = (await page.locator('form.compose').boundingBox())!;
	expect(form.y + form.height).toBeLessThanOrEqual(844);
	expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(390);
});

test('the voice controls rise with the footer and work at every stop of the board', async ({
	page
}) => {
	await open(page);
	const board = page.locator('[data-board]');
	const foot = page.locator('[data-foot]');
	for (const stop of [1, 2]) {
		await page.locator('[data-grab]').click();
		await expect(board).toHaveAttribute('data-stop', String(stop));
		await expect
			.poll(async () => {
				const first = (await foot.boundingBox())?.y;
				await page.waitForTimeout(80);
				return (await foot.boundingBox())?.y === first;
			})
			.toBe(true);
		// The bar is on the footer, above the board, and a tap reaches each control.
		const voicebar = (await page.locator('[data-voicebar]').boundingBox())!;
		const list = (await board.boundingBox())!;
		expect(voicebar.y + voicebar.height).toBeLessThanOrEqual(list.y + 60);
		for (const control of [bar(page, 'Auto'), bar(page, 'Speaker'), primary(page)]) {
			const reached = await control.evaluate((element) => {
				const box = element.getBoundingClientRect();
				const hit = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2);
				return hit === element || element.contains(hit);
			});
			expect(reached, `stop ${stop}`).toBe(true);
		}
	}
	// A take works with the board up.
	await primary(page).click();
	await expect(status(page)).toHaveText('Recording — tap to send');
	await say(page, 600);
	await primary(page).click();
	await expect(primary(page)).toHaveText('■ Stop');
	expect(await takes(page)).toHaveLength(1);
	await expect(board).toHaveAttribute('data-stop', '2');
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
