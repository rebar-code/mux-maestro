import { expect, test, type Locator, type Page } from '@playwright/test';
import {
	drag,
	dragStart,
	expectDrawerClosed,
	expectDrawerOpen,
	fresh,
	threadPath,
	twoFingers,
	WIDTH
} from './helpers';

const MAKER = 'localhost:6';
const OTHER = 'localhost:3';

async function open(page: Page, id = MAKER, on = ['artifacts', 'localServers']): Promise<void> {
	await fresh(page, threadPath(id));
	for (const name of on) await page.request.post(`/__fixture/capability?name=${name}&on=1`);
	// The switches reach the phone with the next config.
	await page.reload();
	await expect(page.locator('.u').first()).toBeVisible();
}

const tab = (page: Page, name: string): Locator => page.locator(`[data-tab="${name}"]`);
const pageOf = (page: Page, name: string): Locator => page.locator(`[data-page="${name}"]`);
const trackLeft = (page: Page): Promise<number> =>
	page.locator('.track').evaluate((el) => Math.round(el.getBoundingClientRect().left));

async function expectTab(page: Page, index: number): Promise<void> {
	await expect.poll(() => trackLeft(page)).toBe(index === 0 ? 0 : -index * WIDTH);
}

const LEFT: [[number, number], [number, number]] = [
	[320, 420],
	[90, 424]
];
const RIGHT: [[number, number], [number, number]] = [
	[70, 420],
	[300, 424]
];

test('the tabs are there only for the features that are on', async ({ page }) => {
	await open(page, MAKER, []);
	await expect(tab(page, 'main')).toBeVisible();
	await expect(tab(page, 'artifacts')).toHaveCount(0);
	await expect(tab(page, 'servers')).toHaveCount(0);
	await expect(page.locator('[data-artifact]')).toHaveCount(0);

	await open(page, MAKER, ['artifacts']);
	await expect(tab(page, 'artifacts')).toHaveText('Artifacts');
	await expect(tab(page, 'servers')).toHaveCount(0);

	await open(page);
	await expect(page.locator('.tabs [role="tab"]')).toHaveText([/Chat/, 'Artifacts', 'Servers']);
});

test('swipe chain: left goes Chat, Artifacts, Servers; right comes back and then opens the sidebar', async ({
	page
}) => {
	await open(page);
	await expectTab(page, 0);

	await drag(page, ...LEFT);
	await expectTab(page, 1);
	await expect(tab(page, 'artifacts')).toHaveAttribute('aria-selected', 'true');
	await expect(pageOf(page, 'artifacts').getByText('Files · 6')).toBeVisible();

	await drag(page, ...LEFT);
	await expectTab(page, 2);
	await expect(tab(page, 'servers')).toHaveAttribute('aria-selected', 'true');

	// The last page resists and stays.
	await drag(page, ...LEFT);
	await expectTab(page, 2);

	await drag(page, ...RIGHT);
	await expectTab(page, 1);
	await expectDrawerClosed(page);
	await drag(page, ...RIGHT);
	await expectTab(page, 0);
	await expectDrawerClosed(page);

	await drag(page, ...RIGHT);
	await expectDrawerOpen(page);
	await expectTab(page, 0);
});

test('the page follows the finger, and a short drag springs back', async ({ page }) => {
	await open(page);
	await dragStart(page, [320, 420], [240, 420]);
	const mid = await trackLeft(page);
	expect(mid).toBeLessThan(-50);
	expect(mid).toBeGreaterThan(-90);
	await page.waitForTimeout(120);
	await page.mouse.up();
	await expectTab(page, 0);
});

test('a vertical scroll changes no tab', async ({ page }) => {
	await open(page);
	await drag(page, [200, 600], [230, 250]);
	await expectTab(page, 0);
	await expectDrawerClosed(page);
	await tab(page, 'artifacts').click();
	await expectTab(page, 1);
	await drag(page, [200, 300], [170, 600]);
	await expectTab(page, 1);
});

test('chat: an image is a thumbnail and other files are chips, under the message that names them', async ({
	page
}) => {
	await open(page);
	const chat = pageOf(page, 'main');
	await expect(chat.locator('.thumb')).toHaveCount(2);
	const thumb = chat.locator('.thumb', { hasText: 'settings-after.png' });
	await expect(thumb).toContainText('settings-after.png');
	await expect(thumb.locator('img')).toHaveJSProperty('naturalWidth', 780);
	// The image is read with the token and shown from memory, never by its API address.
	expect(await thumb.locator('img').getAttribute('src')).toMatch(/^blob:/);
	await expect(chat.locator('.fchip')).toHaveText([/PLAN\.md/, /rotate-tokens\.ts/, /index\.html/]);

	// The plan's chip sits right under the tool row that wrote it.
	const previous = await chat
		.locator('.fchip', { hasText: 'PLAN.md' })
		.evaluate((el) => el.previousElementSibling?.textContent?.trim());
	expect(previous).toBe('Write PLAN.md');

	// A thread with no artifacts draws none.
	await open(page, OTHER);
	await expect(page.locator('[data-artifact]')).toHaveCount(0);
});

test('a thumbnail opens the viewer; back returns to the same message at the same scroll position', async ({
	page
}) => {
	await open(page);
	const scroller = page.locator('[data-view="chat"]');
	const thumb = pageOf(page, 'main').locator('.thumb', { hasText: 'settings-after.png' });
	await thumb.scrollIntoViewIfNeeded();
	await scroller.evaluate((el) => (el.scrollTop -= 40));
	const before = await scroller.evaluate((el) => el.scrollTop);
	expect(before).toBeGreaterThan(0);
	const top = (await thumb.boundingBox())!.y;

	await thumb.click();
	await expectTab(page, 1);
	const viewer = page.locator('[data-viewer]');
	await expect(viewer.locator('.aback b')).toContainText('settings-after.png');
	await expect(viewer.getByRole('button', { name: 'Back' })).toHaveText('‹ Chat');
	await expect(viewer.locator('.stage img')).toHaveJSProperty('naturalWidth', 780);

	await viewer.getByRole('button', { name: 'Back' }).click();
	await expectTab(page, 0);
	await expect(viewer).toHaveCount(0);
	expect(await scroller.evaluate((el) => el.scrollTop)).toBe(before);
	expect((await thumb.boundingBox())!.y).toBe(top);

	// The same by a right swipe: it goes to the chat, not to the sidebar.
	const chip = pageOf(page, 'main').locator('.fchip', { hasText: 'PLAN.md' });
	// The tap itself may scroll the chip into view: measure after that.
	await chip.scrollIntoViewIfNeeded();
	const from = await scroller.evaluate((el) => el.scrollTop);
	await chip.click();
	await expectTab(page, 1);
	await expect(viewer.locator('.md h1')).toHaveText('Plan');
	await drag(page, ...RIGHT);
	await expectTab(page, 0);
	await expectDrawerClosed(page);
	expect(await scroller.evaluate((el) => el.scrollTop)).toBe(from);
	// Opened from the chat and left: the Artifacts tab shows its list again.
	await tab(page, 'artifacts').click();
	await expect(viewer).toHaveCount(0);
});

test('from the list: a right swipe in an open file goes to the list first, then to the chat', async ({
	page
}) => {
	await open(page);
	await tab(page, 'artifacts').click();
	await expectTab(page, 1);
	const list = pageOf(page, 'artifacts');
	await expect(list.locator('[data-file]')).toHaveCount(6);
	await expect(list.locator('[data-file]').first()).toContainText('index.html');
	await expect(list.locator('[data-file].missing')).toContainText('old-notes.txt');
	await expect(list.locator('[data-link]')).toHaveAttribute(
		'href',
		'https://example.com/docs/push-tokens'
	);
	await expect(list.locator('[data-link]')).toHaveAttribute('rel', 'noopener noreferrer');

	await list.locator('[data-file]', { hasText: 'rotate-tokens.ts' }).click();
	const viewer = page.locator('[data-viewer]');
	await expect(viewer.getByRole('button', { name: 'Back' })).toHaveText('‹ Artifacts');
	await expect(viewer.locator('pre.code .hljs-keyword').first()).toBeVisible();

	// The viewer follows the finger.
	await dragStart(page, [70, 420], [200, 424]);
	expect(await viewer.evaluate((el) => el.getBoundingClientRect().left)).toBeGreaterThan(80);
	await page.mouse.move(300, 424, { steps: 6 });
	await page.waitForTimeout(120);
	await page.mouse.up();
	await expect(viewer).toHaveCount(0);
	await expectTab(page, 1);
	await expect(list.getByText('Files · 6')).toBeVisible();

	await drag(page, ...RIGHT);
	await expectTab(page, 0);
	await expectDrawerClosed(page);
});

test('two fingers scale an image in the viewer; the page and the text size stay', async ({
	page
}) => {
	await open(page);
	await pageOf(page, 'main').locator('.thumb', { hasText: 'settings-after.png' }).click();
	const image = page.locator('[data-viewer] .stage img');
	await expect(image).toHaveJSProperty('naturalWidth', 780);
	// The viewer has slid in: the fingers land on the image, not on the chat going out.
	await expectTab(page, 1);
	const text = await page.evaluate(() => localStorage.getItem('mm.textSize'));
	const box = (await page.locator('[data-viewer] .stage').boundingBox())!;
	const y = box.y + box.height / 2;
	// Fingers 100px apart move to 200px apart: twice the size.
	await twoFingers(
		page,
		[
			[145, y],
			[245, y]
		],
		[
			[95, y],
			[295, y]
		]
	);
	expect(await image.evaluate((el) => new DOMMatrix(getComputedStyle(el).transform).a)).toBe(2);
	expect(await page.evaluate(() => window.visualViewport?.scale)).toBe(1);
	expect(await page.evaluate(() => localStorage.getItem('mm.textSize'))).toBe(text);
	await expectTab(page, 1);
});

test('code: a long line scrolls sideways before any tab changes', async ({ page }) => {
	await open(page);
	await tab(page, 'artifacts').click();
	await pageOf(page, 'artifacts').locator('[data-file]', { hasText: 'rotate-tokens.ts' }).click();
	const code = page.locator('[data-viewer] pre.code');
	await expect(code).toBeVisible();
	expect(await code.evaluate((el) => el.scrollWidth > el.clientWidth)).toBe(true);
	const box = (await code.boundingBox())!;
	const y = box.y + 40;

	await drag(page, [320, y], [120, y]);
	expect(await code.evaluate((el) => el.scrollLeft)).toBeGreaterThan(100);
	await expectTab(page, 1);
	await expect(page.locator('[data-viewer]')).toBeVisible();

	// Back at its left edge, the same swipe closes the file.
	await drag(page, [60, y], [380, y]);
	await expect.poll(() => code.evaluate((el) => el.scrollLeft)).toBe(0);
	await expect(page.locator('[data-viewer]')).toBeVisible();
	await drag(page, [70, y], [300, y]);
	await expect(page.locator('[data-viewer]')).toHaveCount(0);
});

test('markdown renders; its raw HTML is text and runs nothing', async ({ page }) => {
	await open(page);
	await tab(page, 'artifacts').click();
	await pageOf(page, 'artifacts').locator('[data-file]', { hasText: 'PLAN.md' }).click();
	const md = page.locator('[data-viewer] .md');
	await expect(md.locator('h1')).toHaveText('Plan');
	await expect(md.locator('li')).toHaveCount(3);
	await expect(md.locator('pre .hljs-keyword').first()).toBeVisible();
	await expect(md.locator('script')).toHaveCount(0);
	await expect(md).toContainText("<script>document.title = 'markdown script ran'</script>");
	expect(await page.title()).not.toContain('ran');
	await expect(md.locator('a')).toHaveAttribute('rel', 'noopener noreferrer');
});

test('an HTML artifact is sandboxed: no script runs, no origin, nothing loads', async ({
	page
}) => {
	const told: string[] = [];
	await page.exposeFunction('__told', (message: string) => told.push(message));
	await page.addInitScript(() => {
		window.addEventListener('message', (event) => {
			void (window as unknown as { __told: (m: string) => void }).__told(String(event.data));
		});
	});
	// What the frame asked the network for, and what the browser refused to send.
	const answered: string[] = [];
	const blocked: string[] = [];
	await open(page);
	await tab(page, 'artifacts').click();
	page.on('response', (response) => {
		if (response.frame() !== page.mainFrame()) answered.push(response.url());
	});
	page.on('requestfailed', (request) => {
		if (request.frame() !== page.mainFrame())
			blocked.push(`${new URL(request.url()).pathname} ${request.failure()?.errorText}`);
	});
	await pageOf(page, 'artifacts').locator('[data-file]', { hasText: 'index.html' }).click();

	const frame = page.locator('[data-viewer] iframe');
	await expect(frame).toBeVisible();
	// No permission at all: no scripts, no same-origin, no forms, no popups.
	expect(await frame.getAttribute('sandbox')).toBe('');
	// The page is handed over as text. The frame has no address that could carry the token.
	expect(await frame.getAttribute('src')).toBeNull();

	const inside = page.frameLocator('[data-viewer] iframe');
	await expect(inside.locator('h2')).toHaveText('Coverage');
	await expect(inside.locator('.ln')).toHaveCount(3);
	// The page's script would have changed this line and called the app.
	await expect(inside.locator('#probe')).toHaveText('Generated nightly');
	// The policy sits after the doctype, so the page keeps standards mode.
	expect(await frame.getAttribute('srcdoc')).toMatch(/^<!doctype html><meta http-equiv/i);
	expect(await inside.locator('html').evaluate(() => document.compatMode)).toBe('CSS1Compat');
	// A tapped link loads nothing in the frame.
	// Also one that asks for this frame or for the whole window by name.
	for (const link of ['#out', '#self', '#top']) {
		await inside.locator(link).click();
		await page.waitForTimeout(300);
		await expect(inside.locator('h2'), link).toHaveText('Coverage');
		await expect(inside.locator('.ln'), link).toHaveCount(3);
	}
	await expect(page).toHaveURL(/\/t\//);
	expect(told).toEqual([]);
	// Its image was stopped by the frame's policy, and its fetch never ran.
	expect(answered).toEqual([]);
	expect(blocked).toEqual(['/icon-192.png csp']);

	// The file itself comes with headers that keep it inert if it is ever opened directly.
	const id = await page.locator('[data-viewer]').getAttribute('data-viewer');
	const direct = await page.request.get(`/api/threads/${encodeURIComponent(MAKER)}/file?id=${id}`, {
		headers: { 'X-MuxMaestro-Token': 'demo-token' }
	});
	expect(direct.headers()['content-security-policy']).toContain('sandbox');
	expect(direct.headers()['x-content-type-options']).toBe('nosniff');
	// And not at all without the token.
	const bare = await page.request.get(`/api/threads/${encodeURIComponent(MAKER)}/file?id=${id}`);
	expect(bare.status()).toBe(401);
});

test('an image zooms with the button and then pans without changing the tab', async ({ page }) => {
	await open(page);
	await tab(page, 'artifacts').click();
	await pageOf(page, 'artifacts').locator('[data-file]', { hasText: 'settings-after.png' }).click();
	const image = page.locator('[data-viewer] .stage img');
	await expect(image).toHaveJSProperty('naturalWidth', 780);
	const width = async (): Promise<number> => Math.round((await image.boundingBox())!.width);
	const fitted = await width();

	await page.getByRole('button', { name: 'Zoom' }).click();
	await expect.poll(width).toBe(Math.round(fitted * 2.5));
	const x = (await image.boundingBox())!.x;
	await drag(page, [120, 420], [300, 424]);
	expect((await image.boundingBox())!.x).toBeGreaterThan(x + 100);
	await expect(page.locator('[data-viewer]')).toBeVisible();
	await expectTab(page, 1);

	await page.getByRole('button', { name: 'Zoom' }).click();
	await expect.poll(width).toBe(fitted);
});

test('share hands the file to the phone', async ({ page }) => {
	await page.addInitScript(() => {
		const shared: string[] = [];
		(window as unknown as { __shared: string[] }).__shared = shared;
		navigator.canShare = () => true;
		navigator.share = async (data?: ShareData) => {
			const file = data?.files?.[0];
			shared.push(`${file?.name}:${file?.size}:${file?.type}`);
		};
	});
	await open(page);
	await tab(page, 'artifacts').click();
	await pageOf(page, 'artifacts').locator('[data-file]', { hasText: 'PLAN.md' }).click();
	await page.locator('[data-viewer]').getByRole('button', { name: 'Share' }).click();
	await expect
		.poll(() => page.evaluate(() => (window as unknown as { __shared: string[] }).__shared))
		.toHaveLength(1);
	const shared = await page.evaluate(() => (window as unknown as { __shared: string[] }).__shared);
	expect(shared[0]).toMatch(/^PLAN\.md:\d+:text\/plain/);
});

test('servers: dev servers, Supabase stacks and containers of the thread', async ({ page }) => {
	await open(page);
	await tab(page, 'servers').click();
	await expectTab(page, 2);
	const list = pageOf(page, 'servers');
	await expect(list.locator('.sect')).toHaveText(['Servers · 2', 'Supabase · 1', 'Docker · 2']);
	await expect(list.locator('[data-server="5173"]')).toContainText('mobile');
	await expect(list.locator('[data-server="5173"]')).toContainText('localhost:5173');
	await expect(list.locator('[data-stack] .lnk')).toHaveText([
		/Studio\s*54323/,
		/API\s*54321/,
		/DB\s*54322/,
		/Mail\s*54324/
	]);
	// A database is not a page, and a port on another host is not this Mac's to publish.
	await expect(list.locator('span.lnk.off')).toHaveCount(2);
	await expect(list.locator('.unknown')).toHaveText('Docker unavailable on devbox');
	// Every row a finger taps is at least 44pt tall.
	for (const row of await list.locator('button.row, .lnk').all()) {
		expect((await row.boundingBox())!.height).toBeGreaterThanOrEqual(44);
	}

	await open(page, OTHER);
	await tab(page, 'servers').click();
	await expect(pageOf(page, 'servers').locator('.empty')).toHaveText('Nothing running');
});

test('opening a server asks once, publishes the port and opens the tailnet link', async ({
	page,
	context
}) => {
	await open(page);
	await tab(page, 'servers').click();
	const list = pageOf(page, 'servers');
	const published = async (): Promise<number[]> =>
		(
			(await (await page.request.post('/__fixture/mappings')).json()) as {
				mappings: { port: number }[];
			}
		).mappings.map((m) => m.port);

	await list.locator('button[data-server="5173"]').click();
	const sheet = page.getByRole('alertdialog');
	await expect(sheet).toContainText('Open port 5173 on your tailnet?');
	await expect(sheet).toContainText('Every device on your tailnet can then open this server');
	await expect(sheet).toContainText('does not need the pairing code');
	expect(await published()).toEqual([]);

	// Cancel publishes nothing.
	await sheet.getByRole('button', { name: 'Cancel' }).click();
	await expect(sheet).toHaveCount(0);
	expect(await published()).toEqual([]);

	await list.locator('button[data-server="5173"]').click();
	const [popup] = await Promise.all([
		context.waitForEvent('page'),
		sheet.getByRole('button', { name: 'Open' }).click()
	]);
	await popup.waitForLoadState();
	expect(popup.url()).toMatch(/\/__mapped\/5173\/$/);
	// The dev server's page gets no way back to this one.
	expect(await popup.evaluate(() => window.opener)).toBeNull();
	await popup.close();
	expect(await published()).toEqual([5173]);

	// The row is a link now, and the port is listed with a way to close it.
	await expect(list.locator('a[data-server="5173"]')).toHaveAttribute(
		'href',
		/\/__mapped\/5173\/$/
	);
	await expect(list.locator('.sect').first()).toHaveText('On tailnet · 1');
	await expect(list.locator('[data-mapping="5173"]')).toContainText('mobile');

	// A second port asks again: each one is a new door on the tailnet.
	await list.locator('button[data-port="54323"]').click();
	await expect(sheet).toContainText('Open port 54323 on your tailnet?');
	expect(await published()).toEqual([5173]);
	await page.evaluate(() => (window.open = () => null));
	// Only numbers go to the Mac.
	const [request] = await Promise.all([
		page.waitForRequest((r) => r.url().endsWith('/api/servers/open')),
		sheet.getByRole('button', { name: 'Open' }).click()
	]);
	expect(request.postDataJSON()).toEqual({ thread: MAKER, port: 54323 });
	await expect(sheet).toHaveCount(0);
	await expect(list.locator('a[data-port="54323"]')).toBeVisible();
	expect(await published()).toEqual([5173, 54323]);

	await page.getByRole('button', { name: 'Close port 5173' }).click();
	await expect(list.locator('[data-mapping="5173"]')).toHaveCount(0);
	await expect(list.locator('button[data-server="5173"]')).toBeVisible();
	expect(await published()).toEqual([54323]);
});

test('a port the Mac will not publish says why and opens nothing', async ({ page, context }) => {
	await open(page);
	await tab(page, 'servers').click();
	await page.request.post('/__fixture/serve-fails?code=taken');
	const list = pageOf(page, 'servers');
	await list.locator('button[data-server="6006"]').click();
	await page.getByRole('alertdialog').getByRole('button', { name: 'Open' }).click();
	await expect(list.getByRole('alert')).toHaveText('Tailscale already serves port 6006');
	await expect(list.locator('button[data-server="6006"]')).toBeVisible();
	expect(context.pages()).toHaveLength(1);
});

test('a feature switched off on the Mac takes its tab away', async ({ page }) => {
	await open(page);
	await tab(page, 'servers').click();
	await expectTab(page, 2);
	await page.request.post('/__fixture/capability?name=localServers&on=0');
	await page.request.post('/__fixture/drop');
	await expect(tab(page, 'servers')).toHaveCount(0);
	await expect(tab(page, 'artifacts')).toBeVisible();
});

/** Record the type of every blob the page turns into an address. */
async function watchBlobs(page: Page): Promise<() => Promise<string[]>> {
	await page.addInitScript(() => {
		const types: string[] = [];
		(window as unknown as { __blobTypes: string[] }).__blobTypes = types;
		const make = URL.createObjectURL.bind(URL);
		URL.createObjectURL = (source: Blob | MediaSource): string => {
			types.push(source instanceof Blob ? source.type : 'media');
			return make(source);
		};
	});
	return () => page.evaluate(() => (window as unknown as { __blobTypes: string[] }).__blobTypes);
}

const SCRIPTABLE = /svg|html|xml/i;

test('an SVG artifact is never given an address in the app origin', async ({ page }) => {
	const blobTypes = await watchBlobs(page);
	await open(page);
	const thumb = pageOf(page, 'main').locator('.thumb', { hasText: 'chart.svg' });
	await expect(thumb.locator('img')).toHaveJSProperty('naturalWidth', 300);
	// A `blob:` address belongs to the app's origin; opened as a page, its script would run there.
	expect(await thumb.locator('img').getAttribute('src')).toMatch(/^data:image\/svg\+xml;base64,/);

	await thumb.click();
	const image = page.locator('[data-viewer] .stage img');
	await expect(image).toHaveJSProperty('naturalWidth', 300);
	expect(await image.getAttribute('src')).toMatch(/^data:image\/svg\+xml;base64,/);

	// Share, on a browser with no share sheet, saves the file: as plain bytes.
	await page.evaluate(() => {
		Object.defineProperty(navigator, 'canShare', { value: undefined, configurable: true });
	});
	const [download] = await Promise.all([
		page.waitForEvent('download'),
		page.locator('[data-viewer]').getByRole('button', { name: 'Share' }).click()
	]);
	expect(download.suggestedFilename()).toBe('chart.svg');

	const types = await blobTypes();
	expect(types.length).toBeGreaterThan(0);
	expect(types.filter((type) => SCRIPTABLE.test(type))).toEqual([]);
	expect(await page.evaluate(() => (window as unknown as { __svgRan?: string }).__svgRan)).toBe(
		undefined
	);
	expect(await page.title()).not.toContain('ran');
});

test('an HTML artifact saved from Share is plain bytes too', async ({ page }) => {
	const blobTypes = await watchBlobs(page);
	await open(page);
	await page.evaluate(() => {
		Object.defineProperty(navigator, 'canShare', { value: undefined, configurable: true });
	});
	await tab(page, 'artifacts').click();
	await pageOf(page, 'artifacts').locator('[data-file]', { hasText: 'index.html' }).click();
	const [download] = await Promise.all([
		page.waitForEvent('download'),
		page.locator('[data-viewer]').getByRole('button', { name: 'Share' }).click()
	]);
	expect(download.suggestedFilename()).toBe('index.html');
	expect((await blobTypes()).filter((type) => SCRIPTABLE.test(type))).toEqual([]);
});

test('the app shell comes with a policy that runs only its own scripts', async ({ page }) => {
	for (const path of ['/', threadPath(MAKER), '/manifest.webmanifest']) {
		const policy = (await page.request.get(path)).headers()['content-security-policy'] ?? '';
		expect(policy, path).toMatch(/script-src 'self'( 'sha256-[A-Za-z0-9+/=]+')*;/);
		expect(policy, path).toContain("object-src 'none'");
		expect(policy, path).toContain("base-uri 'none'");
		expect(policy, path).not.toMatch(/unsafe-eval|script-src[^;]*unsafe-inline|script-src[^;]*\*/);
	}
	// The app runs under it: nothing it needs is refused.
	const refused: string[] = [];
	page.on('console', (message) => {
		if (/Content Security Policy/i.test(message.text())) refused.push(message.text());
	});
	await open(page);
	await tab(page, 'artifacts').click();
	await pageOf(page, 'artifacts').locator('[data-file]', { hasText: 'PLAN.md' }).click();
	await expect(page.locator('[data-viewer] .md h1')).toHaveText('Plan');
	expect(refused).toEqual([]);
	// A script that is not the app's own does not run.
	expect(
		await page.evaluate(() => {
			const script = document.createElement('script');
			script.textContent = 'window.__inline = 1';
			document.head.append(script);
			return (window as unknown as { __inline?: number }).__inline ?? 0;
		})
	).toBe(0);
});

test('the Maestro home is not a thread: it has no Artifacts or Servers tab and asks for none', async ({
	page
}) => {
	const asked: string[] = [];
	page.on('request', (request) => {
		const path = new URL(request.url()).pathname;
		if (/\/(artifacts|running|file)$/.test(path) || path.startsWith('/api/servers'))
			asked.push(path);
	});
	await fresh(page, '/');
	for (const name of ['artifacts', 'localServers'])
		await page.request.post(`/__fixture/capability?name=${name}&on=1`);
	await page.reload();
	await expect(page.locator('[data-thread-pages]')).toBeVisible();
	await page.waitForTimeout(500);
	await expect(tab(page, 'artifacts')).toHaveCount(0);
	await expect(tab(page, 'servers')).toHaveCount(0);
	expect(asked).toEqual([]);
});
