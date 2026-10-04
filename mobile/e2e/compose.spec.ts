import { mkdirSync } from 'node:fs';
import { expect, test, type Locator, type Page } from '@playwright/test';
import { forget, pairingLink, reset, threadPath } from './helpers';

/** Idle, local, with a chat. */
const IDLE = 'localhost:7';
/** Another idle thread, to switch to. */
const OTHER = 'localhost:9';

interface Received {
	texts: { thread: string; text: string }[];
	keys: { thread: string; key: string }[];
}

const box = (page: Page): Locator => page.getByRole('textbox', { name: 'Reply' });
const ask = (page: Page): Locator => page.getByRole('textbox', { name: 'Ask the manager' });
const sendButton = (page: Page): Locator => page.getByRole('button', { name: '↑ Send' });
const note = (page: Page): Locator => page.locator('[data-note]');
const keybar = (page: Page): Locator => page.locator('[data-keybar]');
const dock = (page: Page): Locator => page.locator('[data-dock]');

async function received(page: Page): Promise<Received> {
	return (await (await page.request.post('/__fixture/replies')).json()) as Received;
}

async function open(page: Page, path: string, on: string[]): Promise<void> {
	await reset(page);
	for (const name of on) await page.request.post(`/__fixture/capability?name=${name}&on=1`);
	await forget(page);
	await page.goto(pairingLink(path));
}

/** The on-screen keyboard comes up: the page keeps its size, the visible part shrinks. */
async function keyboard(page: Page, visible: number): Promise<void> {
	await page.evaluate((height) => {
		const viewport = window.visualViewport as VisualViewport;
		Object.defineProperty(viewport, 'height', { configurable: true, get: () => height });
		viewport.dispatchEvent(new Event('resize'));
	}, visible);
}

async function shot(page: Page, name: string): Promise<void> {
	const dir = process.env.SHOTS;
	if (!dir) return;
	mkdirSync(dir, { recursive: true });
	await page.waitForTimeout(250);
	await page.screenshot({ path: `${dir}/${name}.png` });
}

const lines = (count: number): string =>
	Array.from({ length: count }, (_, n) => `line ${n + 1} of the reply`).join('\n');

/** The boxes of the dock's rows, top to bottom. */
async function rows(page: Page): Promise<{ top: number; bottom: number; name: string }[]> {
	return dock(page).evaluate((node) =>
		[...node.children]
			.map((child) => {
				const rect = child.getBoundingClientRect();
				return { top: rect.top, bottom: rect.bottom, name: child.className };
			})
			.filter((row) => row.bottom > row.top)
	);
}

/**
 * Everything the input area has to hold at one size, with so much of the
 * screen visible: `visible` is the screen's height with the keyboard closed.
 */
async function checkLayout(page: Page, visible: number): Promise<void> {
	// The dock ends where the visible screen ends: no band under it, nothing below it.
	const area = await dock(page).boundingBox();
	expect(Math.abs((area?.y ?? 0) + (area?.height ?? 0) - visible)).toBeLessThanOrEqual(1);
	// Its rows follow one another: none covers another.
	const stack = await rows(page);
	for (let n = 1; n < stack.length; n += 1)
		expect(stack[n].top, JSON.stringify(stack)).toBeGreaterThanOrEqual(stack[n - 1].bottom - 0.5);
	// The text box, the key bar and its hide-keyboard button are all on the visible screen.
	for (const part of [
		box(page),
		keybar(page),
		page.getByRole('button', { name: 'Hide keyboard' }),
		page.getByRole('button', { name: 'Attach' }),
		page.locator('.tbar'),
		page.locator('.tabs')
	]) {
		const at = await part.boundingBox();
		expect(at?.y).toBeGreaterThanOrEqual(0);
		expect((at?.y ?? 0) + (at?.height ?? 0)).toBeLessThanOrEqual(visible + 0.5);
		expect((at?.x ?? 0) + (at?.width ?? 0)).toBeLessThanOrEqual(page.viewportSize()?.width ?? 0);
	}
	// The key bar is right above the text box's row.
	const bar = await keybar(page).boundingBox();
	const form = await page.locator('[data-compose]').boundingBox();
	expect((bar?.y ?? 0) + (bar?.height ?? 0)).toBeLessThanOrEqual((form?.y ?? 0) + 0.5);
	// The last message ends on screen, above the dock, with at least a line of it showing.
	const last = await page.locator('[data-view="chat"] .a').last().boundingBox();
	const header = await page.locator('.tabs').boundingBox();
	const top = Math.max(last?.y ?? 0, (header?.y ?? 0) + (header?.height ?? 0));
	const bottom = (last?.y ?? 0) + (last?.height ?? 0);
	expect(bottom).toBeLessThanOrEqual((area?.y ?? 0) + 0.5);
	expect(bottom - top).toBeGreaterThanOrEqual(18);
}

for (const size of [
	{ width: 375, height: 667, keys: 260 },
	{ width: 430, height: 932, keys: 346 }
]) {
	test.describe(`${size.width}x${size.height}`, () => {
		test.use({ viewport: { width: size.width, height: size.height } });

		for (const up of [false, true]) {
			const visible = up ? size.height - size.keys : size.height;

			test(`the input area fits, grows to its cap and shrinks, keyboard ${up ? 'open' : 'closed'}`, async ({
				page
			}) => {
				await open(page, threadPath(IDLE), ['replies', 'keyBar', 'upload']);
				await expect(page.locator('[data-view="chat"] .a').last()).toBeVisible();
				await box(page).tap();
				if (up) await keyboard(page, visible);
				await checkLayout(page, visible);

				// One line: a touch target, and text large enough that iOS does not zoom.
				const one = await box(page).boundingBox();
				expect(one?.height).toBeGreaterThanOrEqual(44);
				expect(one?.height).toBeLessThan(50);
				expect(
					await box(page).evaluate((el) => parseFloat(getComputedStyle(el).fontSize))
				).toBeGreaterThanOrEqual(16);
				if (!up) await shot(page, `input-1-line-${size.width}`);

				// It grows with each line.
				await box(page).fill(lines(3));
				const three = await box(page).boundingBox();
				expect(three?.height).toBeCloseTo((one?.height ?? 0) + 2 * 22, 0);
				await checkLayout(page, visible);

				// Up to eight lines or 40% of what is visible, whichever is less; then it scrolls inside.
				await box(page).fill(lines(30));
				const cap = Math.min(8 * 22 + 22, Math.floor(visible * 0.4));
				const grown = await box(page).boundingBox();
				expect(Math.abs((grown?.height ?? 0) - cap)).toBeLessThanOrEqual(1);
				expect(await box(page).evaluate((el) => el.scrollHeight > el.clientHeight + 20)).toBe(true);
				// The page did not grow with it, and nothing went under the keyboard.
				expect(await page.evaluate(() => document.documentElement.scrollHeight)).toBe(size.height);
				await checkLayout(page, visible);
				// Send is on screen, within reach.
				const pill = await sendButton(page).boundingBox();
				expect((pill?.y ?? 0) + (pill?.height ?? 0)).toBeLessThanOrEqual(visible);
				expect(pill?.height).toBeGreaterThanOrEqual(40);
				if (up) await shot(page, `input-grown-${size.width}`);

				// Lines taken out: it shrinks again.
				await box(page).fill(lines(2));
				expect((await box(page).boundingBox())?.height).toBeCloseTo((one?.height ?? 0) + 22, 0);

				// Sent: one line again, and the keyboard stays where it is.
				await box(page).fill(lines(5));
				await sendButton(page).tap();
				await expect(box(page)).toHaveValue('');
				expect((await box(page).boundingBox())?.height).toBeCloseTo(one?.height ?? 0, 0);
				await expect(box(page)).toBeFocused();
				expect((await received(page)).texts).toEqual([{ thread: IDLE, text: lines(5) }]);
				await checkLayout(page, visible);
			});
		}

		test('the cap follows the visible screen as the keyboard comes and goes', async ({ page }) => {
			await open(page, threadPath(IDLE), ['replies', 'keyBar']);
			await box(page).fill(lines(30));
			const closed = (await box(page).boundingBox())?.height ?? 0;
			expect(Math.abs(closed - Math.min(198, Math.floor(size.height * 0.4)))).toBeLessThanOrEqual(
				1
			);
			await keyboard(page, size.height - size.keys);
			const raised = (await box(page).boundingBox())?.height ?? 0;
			expect(
				Math.abs(raised - Math.min(198, Math.floor((size.height - size.keys) * 0.4)))
			).toBeLessThanOrEqual(1);
			await keyboard(page, size.height);
			expect((await box(page).boundingBox())?.height).toBe(closed);
		});
	});
}

test('Return is a new line on a phone; the button sends', async ({ page }) => {
	await open(page, threadPath(IDLE), ['replies']);
	await expect(box(page)).toHaveAttribute('enterkeyhint', 'enter');
	// Prose: the keyboard capitalises and corrects it.
	await expect(box(page)).toHaveAttribute('autocapitalize', 'sentences');
	await expect(box(page)).toHaveAttribute('autocorrect', 'on');
	await expect(box(page)).toHaveAttribute('spellcheck', 'true');
	expect(await box(page).evaluate((el) => el.tagName)).toBe('TEXTAREA');

	await box(page).tap();
	await page.keyboard.type('first');
	await page.keyboard.press('Enter');
	await page.keyboard.type('second');
	await expect(box(page)).toHaveValue('first\nsecond');
	await page.waitForTimeout(200);
	expect((await received(page)).texts).toEqual([]);

	await sendButton(page).tap();
	await expect(box(page)).toHaveValue('');
	expect((await received(page)).texts).toEqual([{ thread: IDLE, text: 'first\nsecond' }]);
	// The chat shows the line break.
	await expect(page.locator('.u').last()).toHaveText('first\nsecond');
});

test('with real keys Enter sends, Shift+Enter is a new line, and a composition never sends', async ({
	browser,
	baseURL
}) => {
	// A laptop: a pointer that is fine and hovers, no touch.
	const context = await browser.newContext({
		baseURL,
		viewport: { width: 430, height: 932 },
		hasTouch: false,
		isMobile: false
	});
	const page = await context.newPage();
	await open(page, threadPath(IDLE), ['replies']);
	expect(await page.evaluate(() => matchMedia('(pointer: fine) and (hover: hover)').matches)).toBe(
		true
	);
	await box(page).click();
	await page.keyboard.type('one');
	await page.keyboard.press('Shift+Enter');
	await page.keyboard.type('two');
	await expect(box(page)).toHaveValue('one\ntwo');

	// An input method is choosing a word: its Enter is not a send.
	const prevented = await box(page).evaluate((el) => {
		const event = new KeyboardEvent('keydown', {
			key: 'Enter',
			isComposing: true,
			bubbles: true,
			cancelable: true
		});
		el.dispatchEvent(event);
		return event.defaultPrevented;
	});
	expect(prevented).toBe(false);
	await page.waitForTimeout(200);
	expect((await received(page)).texts).toEqual([]);

	await page.keyboard.press('Enter');
	await expect(box(page)).toHaveValue('');
	expect((await received(page)).texts).toEqual([{ thread: IDLE, text: 'one\ntwo' }]);
	await expect(box(page)).toBeFocused();
	await context.close();
});

test('a pasted block keeps its line breaks, and they are posted', async ({ page }) => {
	await open(page, threadPath(IDLE), ['replies']);
	await box(page).tap();
	// As a paste from another system: carriage returns and all.
	await page.evaluate(() =>
		document.execCommand('insertText', false, 'steps:\r\n\t1. build\r\n\t2. test\rdone')
	);
	await expect(box(page)).toHaveValue('steps:\n\t1. build\n\t2. test\ndone');
	expect((await box(page).boundingBox())?.height).toBeGreaterThan(44 + 2 * 22);
	const sent = page.waitForRequest((request) => request.url().endsWith('/text'));
	await sendButton(page).tap();
	expect((await sent).postDataJSON()).toEqual({ text: 'steps:\n\t1. build\n\t2. test\ndone' });
	await expect(box(page)).toHaveValue('');
	expect((await received(page)).texts).toEqual([
		{ thread: IDLE, text: 'steps:\n\t1. build\n\t2. test\ndone' }
	]);
});

test('text over the size limit says how far over, and is not sent', async ({ page }) => {
	await open(page, threadPath(IDLE), ['replies']);
	let posts = 0;
	page.on('request', (request) => {
		if (request.url().endsWith('/text')) posts += 1;
	});
	// 8192 bytes go; one more does not. A two-byte letter counts as two.
	await box(page).fill('x'.repeat(8190) + 'é');
	await expect(note(page)).toHaveCount(0);
	await expect(sendButton(page)).toBeEnabled();
	await box(page).fill('x'.repeat(8190) + 'éé');
	await expect(note(page)).toHaveText('Too long by 2 bytes');
	await expect(sendButton(page)).toBeDisabled();
	await page.locator('form.compose').evaluate((form: HTMLFormElement) => form.requestSubmit());
	await page.waitForTimeout(300);
	expect(posts).toBe(0);
	await expect(box(page)).toHaveValue('x'.repeat(8190) + 'éé');

	// Cut back: the label goes and it sends.
	await box(page).fill('x'.repeat(8190) + 'é');
	await expect(note(page)).toHaveCount(0);
	await sendButton(page).tap();
	await expect(box(page)).toHaveValue('');
	expect(posts).toBe(1);
});

test('a draft is kept per thread, across a switch and a reload, until it is sent', async ({
	page
}) => {
	await open(page, threadPath(IDLE), ['replies', 'keyBar']);
	await box(page).fill('half a thought\nwith a second line');
	// Another thread has its own box.
	await page.getByRole('button', { name: 'Menu' }).click();
	await page.locator(`[data-drawer] [data-thread="${OTHER}"]`).click();
	await expect(page.locator('.tbar .title b')).toHaveText('billing · invoices-pdf');
	await expect(box(page)).toHaveValue('');
	await box(page).fill('for the other one');

	// Back: the first draft is there, line break and all.
	await page.goBack();
	await expect(page.locator('.tbar .title b')).toHaveText('acme-app · dark-mode');
	await expect(box(page)).toHaveValue('half a thought\nwith a second line');
	expect((await box(page).boundingBox())?.height).toBeGreaterThan(60);

	// The app is closed and opened again.
	await page.reload();
	await expect(box(page)).toHaveValue('half a thought\nwith a second line');
	await page.goto(threadPath(OTHER));
	await expect(box(page)).toHaveValue('for the other one');

	// Emptied: nothing is kept for it.
	await box(page).fill('');
	await page.reload();
	await expect(box(page)).toHaveValue('');

	// Sent: the draft is gone for good.
	await page.goto(threadPath(IDLE));
	await expect(box(page)).toHaveValue('half a thought\nwith a second line');
	await sendButton(page).tap();
	await expect(box(page)).toHaveValue('');
	await page.reload();
	await expect(box(page)).toHaveValue('');
	const kept = await page.evaluate(() => localStorage.getItem('mm.drafts'));
	expect(JSON.parse(kept ?? '{}')).toEqual({});
});

test('a tap on Send, a key, attach or a slash row leaves the focus and the caret in the box', async ({
	page
}) => {
	await open(page, threadPath(IDLE), ['replies', 'keyBar', 'upload']);
	await box(page).tap();
	await page.keyboard.type('hello world');
	const caret = (): Promise<[number | null, number | null]> =>
		box(page).evaluate((el: HTMLTextAreaElement) => [el.selectionStart, el.selectionEnd]);
	await box(page).evaluate((el: HTMLTextAreaElement) => el.setSelectionRange(5, 5));

	await keybar(page).getByRole('button', { name: 'Escape', exact: true }).tap();
	await expect(box(page)).toBeFocused();
	expect(await caret()).toEqual([5, 5]);

	const chooser = page.waitForEvent('filechooser');
	await page.getByRole('button', { name: 'Attach' }).tap();
	await chooser;
	await expect(box(page)).toBeFocused();
	expect(await caret()).toEqual([5, 5]);

	// A text key types where the caret is.
	await keybar(page)
		.locator('.keys')
		.evaluate((keys) => (keys.scrollLeft = keys.scrollWidth));
	await keybar(page).getByRole('button', { name: 'Tilde', exact: true }).tap();
	await expect(box(page)).toHaveValue('hello~ world');
	await expect(box(page)).toBeFocused();
	expect(await caret()).toEqual([6, 6]);

	// A slash row fills the box with the command as it is spelled, and the box keeps the focus.
	await box(page).fill('/Co');
	await page.locator('[data-slash]').getByRole('option', { name: '/commit' }).tap();
	await expect(box(page)).toHaveValue('/commit ');
	await expect(box(page)).toBeFocused();

	await box(page).fill('ship it');
	await sendButton(page).tap();
	await expect(box(page)).toHaveValue('');
	await expect(box(page)).toBeFocused();
});

test('Send shows a send on its way, and takes no second tap', async ({ page }) => {
	await open(page, threadPath(IDLE), ['replies']);
	// The answer takes a while to come back.
	await page.request.post('/__fixture/text-slow?ms=1500');
	// Empty, and blank: nothing to send.
	await expect(sendButton(page)).toHaveCount(0);
	await box(page).fill('  \n ');
	await expect(sendButton(page)).toHaveCount(0);

	await box(page).fill('ship it');
	await sendButton(page).tap();
	await expect(sendButton(page)).toBeDisabled();
	await expect(sendButton(page)).toHaveAttribute('aria-busy', 'true');
	// A second try while the first is out goes nowhere.
	await page.locator('form.compose').evaluate((form: HTMLFormElement) => form.requestSubmit());
	await page.locator('form.compose').evaluate((form: HTMLFormElement) => form.requestSubmit());
	await expect(box(page)).toHaveValue('');
	await page.waitForTimeout(300);
	expect((await received(page)).texts).toEqual([{ thread: IDLE, text: 'ship it' }]);
});
test('the manager home has the same box: it grows, keeps its draft, and sends the lines', async ({
	page
}) => {
	await open(page, '/', []);
	await expect(ask(page)).toBeVisible();
	expect(await ask(page).evaluate((el) => el.tagName)).toBe('TEXTAREA');
	await expect(page.locator('[data-growing]')).toHaveCount(1);
	const one = (await ask(page).boundingBox())?.height ?? 0;
	expect(one).toBeGreaterThanOrEqual(44);

	await ask(page).tap();
	await page.keyboard.type('what needs me?');
	await page.keyboard.press('Enter');
	await page.keyboard.type('and what failed?');
	await expect(ask(page)).toHaveValue('what needs me?\nand what failed?');
	expect((await ask(page).boundingBox())?.height).toBeCloseTo(one + 22, 0);
	// The footer still ends where the screen ends.
	const foot = await page.locator('[data-foot]').boundingBox();
	expect(Math.round((foot?.y ?? 0) + (foot?.height ?? 0))).toBe(844);

	await ask(page).fill(lines(30));
	expect(Math.abs(((await ask(page).boundingBox())?.height ?? 0) - 198)).toBeLessThanOrEqual(1);
	await shot(page, 'input-grown-manager');
	// With the keyboard up the footer sits on it, with nothing under it.
	await keyboard(page, 500);
	const raised = await page.locator('[data-foot]').boundingBox();
	expect(Math.abs((raised?.y ?? 0) + (raised?.height ?? 0) - 500)).toBeLessThanOrEqual(1);
	expect(Math.abs(((await ask(page).boundingBox())?.height ?? 0) - 198)).toBeLessThanOrEqual(1);
	await keyboard(page, 844);

	// The draft is the manager's own, and survives a reload.
	await ask(page).fill('what needs me?\nand what failed?');
	await page.reload();
	await expect(ask(page)).toHaveValue('what needs me?\nand what failed?');

	const sent = page.waitForRequest((request) => request.url().endsWith('/api/manager/text'));
	await sendButton(page).tap();
	expect((await sent).postDataJSON()).toEqual({ text: 'what needs me?\nand what failed?' });
	await expect(ask(page)).toHaveValue('');
	// The turn runs to its end before the app is closed.
	await expect(page.locator('[data-view="chat"] .a').last()).toContainText('2 threads need you');
	await expect(page.locator('[data-thinking]')).toHaveCount(0);
	expect((await ask(page).boundingBox())?.height).toBeCloseTo(one, 0);
	await page.reload();
	await expect(ask(page)).toHaveValue('');
});
