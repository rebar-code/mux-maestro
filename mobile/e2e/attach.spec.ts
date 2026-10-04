import { mkdirSync } from 'node:fs';
import { expect, test, type APIResponse, type Locator, type Page } from '@playwright/test';
import { forget, pairingLink, reset, threadPath, TOKEN_HEADER, touchDrag } from './helpers';

/** Idle, local, with a chat. Its directory is `/Users/me/code/acme-app`. */
const IDLE = 'localhost:7';
const BUSY = 'localhost:3';
const DIR = '/Users/me/code/acme-app';

interface Upload {
	thread: string;
	name: string;
	path: string;
	bytes: number;
	type: string | null;
	paste: boolean;
}

interface Received {
	texts: { thread: string; text: string }[];
	uploads: Upload[];
}

/** A one-pixel PNG: a real image, so its thumbnail draws. */
const PNG = Buffer.from(
	'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
	'base64'
);

const png = (name: string): { name: string; mimeType: string; buffer: Buffer } => ({
	name,
	mimeType: 'image/png',
	buffer: PNG
});
const txt = (name: string, text = 'notes'): { name: string; mimeType: string; buffer: Buffer } => ({
	name,
	mimeType: 'text/plain',
	buffer: Buffer.from(text)
});

const box = (page: Page): Locator => page.getByRole('textbox', { name: 'Reply' });
const sendButton = (page: Page): Locator => page.getByRole('button', { name: '↑ Send' });
/** Submit the composer's form, as Enter on real keys does. On a phone, Return is a new line. */
const submit = (page: Page): Promise<void> =>
	page.locator('form.compose').evaluate((form: HTMLFormElement) => form.requestSubmit());
const note = (page: Page): Locator => page.locator('[data-note]');
const attach = (page: Page): Locator => page.getByRole('button', { name: 'Attach' });
const picker = (page: Page): Locator => page.locator('[data-attach-input]');
const tiles = (page: Page): Locator => page.locator('[data-tile]');
const tile = (page: Page, name: string): Locator => page.locator(`[data-tile="${name}"]`);
const label = (page: Page, name: string): Locator => tile(page, name).locator('[data-tile-label]');

async function received(page: Page): Promise<Received> {
	return (await (await page.request.post('/__fixture/replies')).json()) as Received;
}

async function open(page: Page, id: string, on: string[], hooks: string[] = []): Promise<void> {
	await reset(page);
	for (const name of on) await page.request.post(`/__fixture/capability?name=${name}&on=1`);
	for (const hook of hooks) await page.request.post(hook);
	await forget(page);
	await page.goto(pairingLink(threadPath(id)));
	await expect(page.locator('.tbar .title b')).toBeVisible();
	await expect(attach(page)).toBeVisible();
}

/** Screenshots are taken only when SHOTS names a directory outside the repo. */
async function shot(page: Page, name: string): Promise<void> {
	const dir = process.env.SHOTS;
	if (!dir) return;
	mkdirSync(dir, { recursive: true });
	await page.waitForTimeout(250);
	await page.screenshot({ path: `${dir}/${name}.png` });
}

/** Every `/text` and `/upload` request the page makes, as it starts. */
function watch(page: Page): { texts: string[]; uploads: string[] } {
	const seen = { texts: [] as string[], uploads: [] as string[] };
	page.on('request', (request) => {
		const url = new URL(request.url());
		if (url.pathname.endsWith('/text')) seen.texts.push(request.postData() ?? '');
		if (url.pathname.endsWith('/upload')) seen.uploads.push(url.searchParams.get('name') ?? '');
	});
	return seen;
}

test('one file: its tile shows done, its path is in the box, and nothing is sent', async ({
	page
}) => {
	await open(page, IDLE, ['replies', 'upload']);
	const seen = watch(page);
	// One picker, for the library, the camera and files alike; many at a time.
	await expect(picker(page)).toHaveAttribute('multiple', '');
	expect(await picker(page).getAttribute('accept')).toBeNull();
	expect(await picker(page).getAttribute('capture')).toBeNull();
	expect(await page.locator('input[type="file"]').count()).toBe(1);
	await expect(attach(page)).not.toHaveAttribute('aria-disabled');
	const hit = await attach(page).evaluate((button) => {
		const rect = button.getBoundingClientRect();
		const x = rect.left + rect.width / 2;
		const y = rect.top + rect.height / 2;
		return (
			document.elementFromPoint(x, y - 21) === button &&
			document.elementFromPoint(x - 21, y) === button
		);
	});
	expect(hit).toBe(true);

	const sent = page.waitForRequest((request) => request.url().includes('/upload?'));
	await picker(page).setInputFiles(png('shot.png'));
	const request = await sent;
	expect(request.method()).toBe('POST');
	expect(new URL(request.url()).pathname).toBe('/api/threads/localhost%3A7/upload');
	// The file is saved; the phone types the path itself.
	expect(new URL(request.url()).search).toBe('?name=shot.png&paste=0');
	expect(request.headers()['content-type']).toBe('application/octet-stream');
	expect(request.headers()['x-muxmaestro']).toBe('1');
	expect(request.headers()['x-muxmaestro-token']).toBe('demo-token');

	await expect(tile(page, 'shot.png')).toHaveAttribute('data-state', 'done');
	await expect(label(page, 'shot.png')).toHaveText('Attached');
	// An image shows itself.
	await expect(tile(page, 'shot.png').locator('img')).toHaveAttribute('src', /^blob:/);
	await expect(box(page)).toHaveValue(`${DIR}/shot.png `);
	// The words come next: the box has the path and waits.
	await expect(sendButton(page)).toBeEnabled();
	await page.waitForTimeout(300);
	expect(seen.texts).toEqual([]);
	const got = await received(page);
	expect(got.texts).toEqual([]);
	expect(got.uploads).toEqual([
		{
			thread: IDLE,
			name: 'shot.png',
			path: `${DIR}/shot.png`,
			bytes: PNG.length,
			type: 'application/octet-stream',
			paste: false
		}
	]);

	// The same file again: the picker was emptied, and the Mac gives the copy a number.
	await picker(page).setInputFiles(png('shot.png'));
	await expect(tiles(page)).toHaveCount(2);
	await expect(tiles(page).nth(1)).toHaveAttribute('data-state', 'done');
	await expect(box(page)).toHaveValue(`${DIR}/shot.png ${DIR}/shot-2.png `);
});

test('three files go one by one, in pick order', async ({ page }) => {
	await open(page, IDLE, ['replies', 'upload'], ['/__fixture/upload-slow?answer=150']);
	// The Mac refuses a second write to a thread while one is in flight: none was.
	const order: string[] = [];
	const answers: number[] = [];
	page.on('request', (request) => {
		const url = new URL(request.url());
		if (url.pathname.endsWith('/upload')) order.push(url.searchParams.get('name') ?? '');
	});
	page.on('response', (response) => {
		if (new URL(response.url()).pathname.endsWith('/upload')) answers.push(response.status());
	});
	await box(page).fill('compare these');
	await picker(page).setInputFiles([png('before.png'), txt('release notes.txt'), png('after.png')]);
	await expect(tiles(page)).toHaveCount(3);
	// While the first is on its way the others wait, and Send waits with them.
	await expect(tile(page, 'before.png')).toHaveAttribute('data-state', 'uploading');
	await expect(label(page, 'after.png')).toHaveText('Waiting');
	await expect(sendButton(page)).toBeDisabled();

	for (const name of ['before.png', 'release notes.txt', 'after.png'])
		await expect(tile(page, name)).toHaveAttribute('data-state', 'done');
	expect(order).toEqual(['before.png', 'release notes.txt', 'after.png']);
	expect(answers).toEqual([200, 200, 200]);
	// A name with a space comes back quoted, as it has to be typed.
	await expect(box(page)).toHaveValue(
		`compare these ${DIR}/before.png '${DIR}/release notes.txt' ${DIR}/after.png `
	);
	await expect(sendButton(page)).toBeEnabled();
	expect((await received(page)).uploads.map((upload) => upload.name)).toEqual(order);
	// A file has a glyph and its name; an image has its picture.
	await expect(tile(page, 'release notes.txt').locator('img')).toHaveCount(0);
	await expect(tile(page, 'release notes.txt').locator('b')).toHaveText('release notes.txt');

	// Three fit side by side, whole.
	const row = page.locator('[data-tiles]');
	expect(await row.evaluate((el) => el.scrollWidth <= el.clientWidth)).toBe(true);
	// More tiles than fit: the row scrolls sideways, and the page stays put.
	await picker(page).setInputFiles([txt('d.txt'), txt('e.txt')]);
	await expect(tile(page, 'e.txt')).toHaveAttribute('data-state', 'done');
	const at = await row.boundingBox();
	const y = (at?.y ?? 0) + (at?.height ?? 0) / 2;
	await touchDrag(page, [300, y], [60, y]);
	expect(await row.evaluate((el) => el.scrollLeft)).toBeGreaterThan(50);
	await expect(page.locator('[data-drawer]')).toBeHidden();
});

test('a file over the limit is not sent; the others are', async ({ page }) => {
	await open(page, IDLE, ['replies', 'upload'], ['/__fixture/upload-max?value=8']);
	const seen = watch(page);
	await picker(page).setInputFiles([
		txt('a.txt', 'abc'),
		txt('big.txt', 'far more than eight bytes'),
		txt('c.txt', 'xyz')
	]);
	await expect(tile(page, 'big.txt')).toHaveAttribute('data-state', 'failed');
	await expect(label(page, 'big.txt')).toHaveText('Too large');
	// Sending it again cannot help.
	await expect(page.getByRole('button', { name: 'Retry big.txt' })).toHaveCount(0);
	await expect(tile(page, 'a.txt')).toHaveAttribute('data-state', 'done');
	await expect(tile(page, 'c.txt')).toHaveAttribute('data-state', 'done');
	await expect(box(page)).toHaveValue(`${DIR}/a.txt ${DIR}/c.txt `);
	expect(seen.uploads).toEqual(['a.txt', 'c.txt']);
	expect((await received(page)).uploads.map((upload) => upload.name)).toEqual(['a.txt', 'c.txt']);
	// It does not hold Send up.
	await expect(sendButton(page)).toBeEnabled();
});

test('remove: a waiting file is dropped, one on its way is stopped, a done one takes its path', async ({
	page
}) => {
	await open(page, IDLE, ['replies', 'upload'], ['/__fixture/upload-slow?answer=4000']);
	const seen = watch(page);
	await picker(page).setInputFiles([txt('a.txt'), txt('b.txt'), txt('c.txt')]);
	await expect(tile(page, 'a.txt')).toHaveAttribute('data-state', 'uploading');
	await expect(tile(page, 'c.txt')).toHaveAttribute('data-state', 'waiting');

	// Every tile has its remove button, as large as a finger.
	for (const name of ['a.txt', 'b.txt', 'c.txt']) {
		const size = await page.getByRole('button', { name: `Remove ${name}` }).boundingBox();
		expect(size?.width).toBeGreaterThanOrEqual(44);
		expect(size?.height).toBeGreaterThanOrEqual(44);
	}

	// Waiting: it never leaves the phone.
	await page
		.getByRole('button', { name: 'Remove c.txt' })
		.evaluate((el: HTMLElement) => el.click());
	await expect(tile(page, 'c.txt')).toHaveCount(0);

	// On its way: stopped. The next one starts.
	await page.request.post('/__fixture/upload-slow?answer=0');
	const stopped = page.waitForEvent('requestfailed', (request) =>
		request.url().includes('name=a.txt')
	);
	await page.getByRole('button', { name: 'Remove a.txt' }).tap();
	await stopped;
	await expect(tile(page, 'a.txt')).toHaveCount(0);
	await expect(tile(page, 'b.txt')).toHaveAttribute('data-state', 'done');
	await expect(box(page)).toHaveValue(`${DIR}/b.txt `);
	// The Mac may still be letting go of the stopped one: then b goes again by itself.
	expect(seen.uploads.slice(0, 2)).toEqual(['a.txt', 'b.txt']);
	expect(new Set(seen.uploads)).toEqual(new Set(['a.txt', 'b.txt']));
	expect((await received(page)).uploads.map((upload) => upload.name)).toEqual(['b.txt']);

	// Done: the tile goes, and its path with it; the words around it stay.
	await box(page).fill(`see ${DIR}/b.txt and tell me`);
	await page.getByRole('button', { name: 'Remove b.txt' }).tap();
	await expect(tiles(page)).toHaveCount(0);
	await expect(page.locator('[data-tiles]')).toHaveCount(0);
	await expect(box(page)).toHaveValue('see and tell me');

	// A path the human changed is theirs: it stays.
	await box(page).fill('');
	await picker(page).setInputFiles(txt('d.txt'));
	await expect(tile(page, 'd.txt')).toHaveAttribute('data-state', 'done');
	await box(page).fill(`${DIR}/d.txt.bak `);
	await page.getByRole('button', { name: 'Remove d.txt' }).tap();
	await expect(tiles(page)).toHaveCount(0);
	await expect(box(page)).toHaveValue(`${DIR}/d.txt.bak `);
});

test('a failed file says why, and goes again on a retry', async ({ page }) => {
	await open(page, IDLE, ['replies', 'upload']);
	// The Mac had a bad moment.
	await page.request.post('/__fixture/upload-fail?status=503&error=unavailable');
	await picker(page).setInputFiles(txt('a.txt'));
	await expect(tile(page, 'a.txt')).toHaveAttribute('data-state', 'failed');
	await expect(label(page, 'a.txt')).toHaveText('Refused');
	await expect(box(page)).toHaveValue('');
	const retry = page.getByRole('button', { name: 'Retry a.txt' });
	expect((await retry.boundingBox())?.width).toBeGreaterThanOrEqual(44);
	await retry.tap();
	await expect(tile(page, 'a.txt')).toHaveAttribute('data-state', 'done');
	await expect(box(page)).toHaveValue(`${DIR}/a.txt `);

	// A refusal with a sentence shows the sentence; one that will not change has no retry.
	await page.request.post(
		'/__fixture/upload-fail?status=403&error=disabled&message=Uploads%20are%20off'
	);
	await picker(page).setInputFiles(txt('b.txt'));
	await expect(label(page, 'b.txt')).toHaveText('Uploads are off');
	await expect(page.getByRole('button', { name: 'Retry b.txt' })).toHaveCount(0);

	// No network: nothing is sent, and the tile waits for a retry.
	await page.context().setOffline(true);
	await picker(page).setInputFiles(txt('c.txt'));
	await expect(label(page, 'c.txt')).toHaveText('Offline');
	await page.context().setOffline(false);
	await page.getByRole('button', { name: 'Retry c.txt' }).tap();
	await expect(tile(page, 'c.txt')).toHaveAttribute('data-state', 'done');
	expect((await received(page)).uploads.map((upload) => upload.name)).toEqual(['a.txt', 'c.txt']);
});

test('the bar on a tile follows the bytes as they go', async ({ page }) => {
	// The Mac reads slowly, so the phone sees the body leave in steps.
	await open(page, IDLE, ['replies', 'upload'], ['/__fixture/upload-slow?chunk=25']);
	await picker(page).setInputFiles({
		name: 'trace.bin',
		mimeType: 'application/octet-stream',
		buffer: Buffer.alloc(6 * 1024 * 1024, 7)
	});
	const bar = tile(page, 'trace.bin').getByRole('progressbar');
	const steps = new Set<number>();
	await expect
		.poll(
			async () => {
				const now = Number(await bar.getAttribute('aria-valuenow').catch(() => '100'));
				steps.add(now);
				return [...steps].filter((value) => value > 0 && value < 100).length;
			},
			{ intervals: [20], timeout: 20_000 }
		)
		.toBeGreaterThanOrEqual(2);
	// The label says the same number.
	await expect(label(page, 'trace.bin')).toHaveText(/^\d+%$|^Attached$/);
	await expect(tile(page, 'trace.bin')).toHaveAttribute('data-state', 'done', { timeout: 30_000 });
	const sorted = [...steps].sort((a, b) => a - b);
	expect([...steps]).toEqual(sorted);
});

test('uploads off: the button is dimmed, and a tap says so', async ({ page }) => {
	await open(page, IDLE, ['replies']);
	let choosers = 0;
	page.on('filechooser', () => (choosers += 1));
	const seen = watch(page);
	await expect(attach(page)).toHaveAttribute('aria-disabled', 'true');
	expect(
		Number(await attach(page).evaluate((button) => getComputedStyle(button).opacity))
	).toBeLessThan(0.5);
	await expect(note(page)).toHaveCount(0);
	const before = await box(page).boundingBox();

	// Playwright will not tap what says it is disabled; a finger will.
	await attach(page).tap({ force: true });
	await expect(note(page)).toHaveText('Off in MuxMaestro Settings');
	await page.waitForTimeout(300);
	expect(choosers).toBe(0);
	expect(seen.uploads).toEqual([]);
	await expect(tiles(page)).toHaveCount(0);
	// The button did not move the box sideways.
	expect((await box(page).boundingBox())?.x).toBe(before?.x);
	await shot(page, 'attach-off');

	// A pasted image has nowhere to go either.
	await box(page).evaluate(
		(input, bytes) => {
			const data = new DataTransfer();
			data.items.add(new File([new Uint8Array(bytes)], 'image.png', { type: 'image/png' }));
			input.dispatchEvent(
				new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true })
			);
		},
		[...PNG]
	);
	await expect(tiles(page)).toHaveCount(0);
	expect(seen.uploads).toEqual([]);

	// The Mac switches uploads on: the same button, live, with no reload.
	await page.request.post('/__fixture/capability?name=upload&on=1');
	await expect(attach(page)).not.toHaveAttribute('aria-disabled');
	const chooser = page.waitForEvent('filechooser');
	await attach(page).tap();
	expect((await chooser).isMultiple()).toBe(true);
	expect((await box(page).boundingBox())?.x).toBe(before?.x);
});

test('an image pasted from the clipboard becomes a tile; pasted text stays text', async ({
	page
}) => {
	await open(page, IDLE, ['replies', 'upload']);
	const pasteImage = (): Promise<boolean> =>
		box(page).evaluate(
			(input, bytes) => {
				const data = new DataTransfer();
				data.items.add(new File([new Uint8Array(bytes)], 'image.png', { type: 'image/png' }));
				data.setData('text/plain', 'image.png');
				const event = new ClipboardEvent('paste', {
					clipboardData: data,
					bubbles: true,
					cancelable: true
				});
				input.dispatchEvent(event);
				return event.defaultPrevented;
			},
			[...PNG]
		);
	// The picture is taken, and its name is not also pasted as text.
	expect(await pasteImage()).toBe(true);
	await expect(tile(page, 'pasted-1.png')).toHaveAttribute('data-state', 'done');
	await expect(tile(page, 'pasted-1.png').locator('img')).toHaveAttribute('src', /^blob:/);
	await expect(box(page)).toHaveValue(`${DIR}/pasted-1.png `);
	expect(await pasteImage()).toBe(true);
	await expect(tile(page, 'pasted-2.png')).toHaveAttribute('data-state', 'done');
	expect((await received(page)).uploads.map((upload) => upload.name)).toEqual([
		'pasted-1.png',
		'pasted-2.png'
	]);

	// Text is left to the box.
	const prevented = await box(page).evaluate((input) => {
		const data = new DataTransfer();
		data.setData('text/plain', 'hello');
		const event = new ClipboardEvent('paste', {
			clipboardData: data,
			bubbles: true,
			cancelable: true
		});
		input.dispatchEvent(event);
		return event.defaultPrevented;
	});
	expect(prevented).toBe(false);
	await expect(tiles(page)).toHaveCount(2);
});

test('Send waits for the upload, posts the text with the paths, and clears the tiles', async ({
	page
}) => {
	await open(page, IDLE, ['replies', 'upload'], ['/__fixture/upload-slow?answer=700']);
	const seen = watch(page);
	await box(page).fill('look at this');
	await picker(page).setInputFiles(png('shot.png'));
	await expect(tile(page, 'shot.png')).toHaveAttribute('data-state', 'uploading');
	// Not while a file is on its way: by the pill or by Enter.
	await expect(sendButton(page)).toBeDisabled();
	await submit(page);
	await page.waitForTimeout(200);
	expect(seen.texts).toEqual([]);

	await expect(tile(page, 'shot.png')).toHaveAttribute('data-state', 'done');
	await expect(box(page)).toHaveValue(`look at this ${DIR}/shot.png `);
	await box(page).pressSequentially('and fix it');
	await sendButton(page).click();

	await expect(box(page)).toHaveValue('');
	await expect(tiles(page)).toHaveCount(0);
	const text = `look at this ${DIR}/shot.png and fix it`;
	expect(seen.texts.map((body) => JSON.parse(body) as unknown)).toEqual([{ text }]);
	expect((await received(page)).texts).toEqual([{ thread: IDLE, text }]);
	await expect(page.locator('.u').last()).toHaveText(text);
});

test('a busy pane still takes a file: nothing is typed into it', async ({ page }) => {
	await open(page, BUSY, ['replies', 'upload']);
	await expect(attach(page)).not.toHaveAttribute('aria-disabled');
	await picker(page).setInputFiles(txt('a.txt'));
	await expect(tile(page, 'a.txt')).toHaveAttribute('data-state', 'done');
	await expect(box(page)).toHaveValue('/Users/me/code/docs-site/a.txt ');
	// The reply itself waits for the pane.
	await expect(sendButton(page)).toBeDisabled();
});

test('three tiles: done, failed, on its way; the box under them does not move', async ({
	page
}) => {
	await open(page, IDLE, ['replies', 'upload', 'keyBar']);
	await picker(page).setInputFiles(png('checkout.png'));
	await expect(tile(page, 'checkout.png')).toHaveAttribute('data-state', 'done');
	const place = async (): Promise<unknown> => [
		await box(page).boundingBox(),
		await page.locator('[data-tiles]').boundingBox()
	];
	const first = await place();

	await page.request.post('/__fixture/upload-fail?status=503&error=unavailable');
	await picker(page).setInputFiles(txt('trace.log'));
	await expect(tile(page, 'trace.log')).toHaveAttribute('data-state', 'failed');
	await page.request.post('/__fixture/upload-slow?answer=4000');
	await picker(page).setInputFiles(txt('notes.md'));
	await expect(tile(page, 'notes.md')).toHaveAttribute('data-state', 'uploading');
	// Three tiles in three states, one height: the box is where it was.
	expect(await place()).toEqual(first);
	// The tiles are whole: none is cut off top or bottom by the bar.
	const row = await page.locator('[data-tiles]').boundingBox();
	for (const one of await tiles(page).all()) {
		const at = await one.boundingBox();
		expect(at?.y).toBeGreaterThanOrEqual(row?.y ?? 0);
		expect((at?.y ?? 0) + (at?.height ?? 0)).toBeLessThanOrEqual(
			(row?.y ?? 0) + (row?.height ?? 0)
		);
	}
	// Above the box, below the key bar.
	const keys = await page.locator('[data-keybar]').boundingBox();
	expect((keys?.y ?? 0) + (keys?.height ?? 0)).toBeLessThanOrEqual(row?.y ?? 0);
	expect((row?.y ?? 0) + (row?.height ?? 0)).toBeLessThanOrEqual(
		(await box(page).boundingBox())?.y ?? 0
	);
	await shot(page, 'attach-tiles');
});

test('the fixture saves without typing, as the Mac does', async ({ page }) => {
	await reset(page);
	const origin = new URL(test.info().project.use.baseURL ?? '').origin;
	const post = (query: string, data: string, id = BUSY): Promise<APIResponse> =>
		page.request.post(`/api/threads/${encodeURIComponent(id)}/upload?${query}`, {
			data,
			headers: { ...TOKEN_HEADER, 'X-MuxMaestro': '1', origin }
		});
	expect((await post('name=a.txt&paste=0', 'x')).status()).toBe(403);
	await page.request.post('/__fixture/capability?name=upload&on=1');

	// A busy pane: with the paste it is refused, without it the file is saved.
	expect((await post('name=a.txt', 'x')).status()).toBe(409);
	const first = await post('name=a.txt&paste=0', 'x');
	expect([first.status(), await first.json()]).toEqual([
		200,
		{
			ok: true,
			pasted: false,
			path: '/Users/me/code/docs-site/a.txt',
			text: '/Users/me/code/docs-site/a.txt'
		}
	]);
	// A name that is taken gets a number; one with a space is quoted for the pane.
	expect(((await (await post('name=a.txt&paste=0', 'x')).json()) as { path: string }).path).toBe(
		'/Users/me/code/docs-site/a-2.txt'
	);
	expect(
		((await (await post('name=my%20file.txt&paste=0', 'x')).json()) as { text: string }).text
	).toBe("'/Users/me/code/docs-site/my file.txt'");

	expect((await post('name=a.txt&paste=0', '')).status()).toBe(400);
	expect((await post('paste=0', 'x')).status()).toBe(400);
	expect((await post('name=a.txt&paste=0', 'x', 'none:1')).status()).toBe(404);
	await page.request.post('/__fixture/upload-max?value=4');
	const big = await post('name=a.txt&paste=0', 'too many bytes');
	expect([big.status(), await big.json()]).toEqual([413, { error: 'too_large' }]);
	await page.request.post('/__fixture/upload-max?value=10485760');

	// One write to a thread at a time.
	await page.request.post('/__fixture/upload-slow?answer=400');
	const slow = post('name=b.txt&paste=0', 'x');
	await page.waitForTimeout(100);
	const second = await post('name=c.txt&paste=0', 'x');
	expect([second.status(), await second.json()]).toEqual([
		409,
		{ error: 'busy', message: 'A reply is being sent' }
	]);
	expect((await slow).status()).toBe(200);
});
