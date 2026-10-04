import { expect, test, type Locator, type Page } from '@playwright/test';
import { fakeMic, forget, fresh, pairingLink, reset, threadPath, touchDrag } from './helpers';

const MAKER = 'localhost:6';

declare global {
	interface Window {
		__violations: string[];
		__ran?: number;
	}
}

/** Screenshots are taken only when SHOTS names a directory outside the repo. */
async function shot(page: Page, name: string): Promise<void> {
	const dir = process.env.SHOTS;
	if (!dir) return;
	await page.waitForTimeout(300);
	await page.screenshot({ path: `${dir}/${name}.png` });
}

const EVERYTHING = [
	'# Checkout fix',
	'',
	'The total was read **before** the tax row. It now *waits* for `tax.waitFor()`.',
	'Second line of the same paragraph.',
	'',
	'## Steps',
	'',
	'1. Read the spec',
	'2. Wait for the row',
	'   - the tax row',
	'     - and its amount',
	'3. Run it',
	'',
	'- [x] Fix the test',
	'- [ ] Open the PR',
	'',
	'> The bold move pays off.',
	'',
	'---',
	'',
	'| Spec | Before | After | Runs | Notes on what changed in this run |',
	'|---|---|---|---|---|',
	'| checkout | fail | pass | 7 | waits for the tax row before the total |',
	'',
	'```ts',
	"const tax = page.getByTestId('tax'); // a long line that does not fit a phone and must scroll sideways",
	'await tax.waitFor();',
	'```',
	'',
	'Docs: [push tokens](https://example.com/docs/push-tokens), the [plan](PLAN.md),',
	'the [dev server](http://localhost:5173/settings) and a [script](javascript:alert(1)).',
	'',
	'![the settings page](/tmp/settings-after.png) ![a remote pixel](https://example.com/pixel.png)'
].join('\n');

const HOSTILE = [
	'<script>window.__ran = 1</script>',
	'',
	'<img src="https://example.com/track.png" onerror="window.__ran = 2">',
	'',
	'[one](javascript:window.__ran=3) [two](JaVaScRiPt:window.__ran=4) [three](&#106;avascript:window.__ran=5)',
	'[four](data:text/html,<script>window.__ran=6</script>) [five]( javascript:window.__ran=7)',
	'',
	'![pixel](https://example.com/pixel.png) ![svg](data:image/svg+xml,<svg onload="window.__ran=8">)',
	'',
	'```html',
	'</code></pre><script>window.__ran = 9</script><img src=https://example.com/x.png>',
	'```',
	'',
	'<iframe src="https://example.com/"></iframe> safe‮gnp.exe',
	'',
	'```',
	'<style>*{display:none}</style>'
].join('\n');

/** Everything the page asks for that is not this server, and every refusal and error. */
function watch(page: Page): { remote: string[]; problems: string[] } {
	const seen = { remote: [] as string[], problems: [] as string[] };
	page.on('request', (request) => {
		const url = request.url();
		if (!/^(http:\/\/127\.0\.0\.1:\d+\/|blob:|data:)/.test(url)) seen.remote.push(url);
	});
	page.on('console', (message) => {
		if (message.type() === 'error') seen.problems.push(message.text());
	});
	page.on('pageerror', (error) => seen.problems.push(String(error)));
	return seen;
}

async function say(page: Page, text: string, role = 'assistant'): Promise<void> {
	await page.request.post(
		`/__fixture/say?id=${MAKER}&role=${role}&text=${encodeURIComponent(text)}`
	);
}

async function open(page: Page, messages: string[]): Promise<void> {
	await page.addInitScript(() => {
		window.__violations = [];
		document.addEventListener('securitypolicyviolation', (event) => {
			window.__violations.push(`${event.violatedDirective} ${event.blockedURI}`);
		});
	});
	await fresh(page, '/');
	for (const name of ['artifacts', 'localServers', 'find'])
		await page.request.post(`/__fixture/capability?name=${name}&on=1`);
	for (const text of messages) await say(page, text);
	await page.goto(threadPath(MAKER));
	await expect(page.locator('.u').first()).toBeVisible();
}

const chat = (page: Page): Locator => page.locator('[data-page="main"]');
const last = (page: Page): Locator => chat(page).locator('.a .prose').last();

test('an assistant message renders markdown; a user message and a tool row stay as they were', async ({
	page
}) => {
	const seen = watch(page);
	await open(page, [EVERYTHING]);
	const prose = last(page);

	await expect(prose.locator('h1')).toHaveText('Checkout fix');
	await expect(prose.locator('h2')).toHaveText('Steps');
	await expect(prose.locator('strong')).toHaveText('before');
	await expect(prose.locator('em')).toHaveText('waits');
	await expect(prose.locator('p code')).toHaveText('tax.waitFor()');
	await expect(prose.locator('p').first().locator('br')).toHaveCount(1);
	await expect(prose.locator('ol > li')).toHaveCount(3);
	await expect(prose.locator('ol ul ul li')).toHaveText('and its amount');
	await expect(prose.locator('li.task input')).toHaveCount(2);
	await expect(prose.locator('li.task input').first()).toBeChecked();
	await expect(prose.locator('li.task input').first()).toBeDisabled();
	await expect(prose.locator('blockquote')).toHaveText('The bold move pays off.');
	await expect(prose.locator('hr')).toHaveCount(1);
	await expect(prose.locator('td')).toHaveCount(5);
	await expect(prose.locator('pre.hljs .hljs-keyword').first()).toHaveText('const');
	// No markdown symbol is left in the text.
	expect(await prose.innerText()).not.toMatch(/\*\*|^#|```|^\s*- \[/m);

	// A heading is a little larger than the text, not a page title.
	const size = (locator: Locator): Promise<number> =>
		locator.evaluate((el) => parseFloat(getComputedStyle(el).fontSize));
	const body = await size(prose);
	expect(await size(prose.locator('h1'))).toBeGreaterThan(body);
	expect(await size(prose.locator('h1'))).toBeLessThanOrEqual(body * 1.3);

	// The code and the table do not wrap and do not widen the page: they scroll.
	for (const wide of [prose.locator('pre'), prose.locator('.tablebox')]) {
		const box = await wide.evaluate((el) => ({
			scroll: el.scrollWidth,
			client: el.clientWidth,
			right: el.getBoundingClientRect().right
		}));
		expect(box.scroll).toBeGreaterThan(box.client);
		expect(box.right).toBeLessThanOrEqual(390);
	}
	const pre = prose.locator('pre');
	await pre.scrollIntoViewIfNeeded();
	const at = await pre.boundingBox();
	if (!at) throw new Error('no code block');
	const y = at.y + at.height / 2;
	await touchDrag(page, [300, y], [80, y]);
	await expect.poll(() => pre.evaluate((el) => el.scrollLeft)).toBeGreaterThan(100);
	// The drag moved the code, not the tab.
	await expect(page.locator('[data-tab="main"]')).toHaveAttribute('aria-selected', 'true');

	// The rows that are not prose are as before: text, with their symbols.
	await expect(chat(page).locator('.u .prose')).toHaveCount(0);
	await expect(chat(page).locator('.tool .prose')).toHaveCount(0);
	await expect(chat(page).locator('.tool').first()).toHaveText('Write PLAN.md');

	await pre.evaluate((el) => (el.scrollLeft = 0));
	await prose.locator('h1').scrollIntoViewIfNeeded();
	await shot(page, 'markdown-chat-top');
	await pre.evaluate((el) => {
		el.scrollLeft = 0;
		el.scrollIntoView({ block: 'end' });
	});
	await shot(page, 'markdown-chat-code');

	expect(seen.remote).toEqual([]);
	expect(seen.problems).toEqual([]);
	expect(await page.evaluate(() => window.__violations)).toEqual([]);
});

test('a user message with markdown symbols is plain text with its line breaks', async ({
	page
}) => {
	const typed = '**not bold**\n- not a list <b>x</b>';
	await open(page, []);
	await say(page, typed, 'user');
	const row = chat(page).locator('.u', { hasText: 'not bold' });
	await expect(row).toBeVisible();
	expect(await row.innerText()).toBe(typed);
	await expect(row.locator('strong, b, li')).toHaveCount(0);
});

test('a hostile message runs no script and loads nothing', async ({ page }) => {
	const seen = watch(page);
	await open(page, [HOSTILE, 'after']);
	const prose = chat(page).locator('.a .prose');
	const hostile = prose.nth(-2);
	await expect(prose.last()).toHaveText('after');
	await expect(hostile).toContainText('<script>window.__ran = 1</script>');
	await expect(hostile).toContainText('[one](javascript:window.__ran=3)');
	await expect(hostile).toContainText('safegnp.exe');

	// Nothing in the chat is an element the message asked for.
	await expect(chat(page).locator('script, iframe, style, object, embed, form')).toHaveCount(0);
	await expect(hostile.locator('img')).toHaveCount(0);
	// The only links are web addresses written out in full.
	expect(
		await hostile.locator('a').evaluateAll((all) => all.map((a) => a.getAttribute('href')))
	).toEqual(['https://example.com/track.png', 'https://example.com/']);
	expect(
		await hostile.evaluate((el) =>
			[...el.querySelectorAll('*')].flatMap((node) =>
				node.getAttributeNames().filter((name) => name.startsWith('on'))
			)
		)
	).toEqual([]);
	// A remote image is its alt text; one in a `data:` address is not an image at all.
	await expect(hostile.locator('.mdimg')).toHaveText('pixel');
	// The rest of the chat is still there: an open block hid nothing after it.
	await expect(prose.last()).toBeVisible();

	// A tap on what looks like a link goes nowhere.
	await hostile.getByText('[one]').click();
	await page.waitForTimeout(300);
	await expect(page).toHaveURL(/\/t\/localhost(:|%3A)6$/);
	await shot(page, 'markdown-hostile');

	expect(await page.evaluate(() => window.__ran)).toBeUndefined();
	expect(seen.remote).toEqual([]);
	expect(seen.problems).toEqual([]);
	expect(await page.evaluate(() => window.__violations)).toEqual([]);
});

test('a code block has a copy button of a full touch target', async ({ page, context }) => {
	await context.grantPermissions(['clipboard-read', 'clipboard-write']);
	await open(page, [EVERYTHING]);
	const button = last(page).getByRole('button', { name: 'Copy' });
	await button.scrollIntoViewIfNeeded();
	const box = await button.boundingBox();
	expect(box?.width).toBeGreaterThanOrEqual(44);
	expect(box?.height).toBeGreaterThanOrEqual(44);
	await button.click();
	await expect(button).toHaveAttribute('data-copied', '');
	expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(
		"const tax = page.getByTestId('tax'); // a long line that does not fit a phone and must scroll sideways\nawait tax.waitFor();"
	);
	await expect(button).not.toHaveAttribute('data-copied', '');
});

test('links: the web in a new tab, a file in Artifacts, a local address through Servers', async ({
	page,
	context
}) => {
	const seen = watch(page);
	await open(page, [EVERYTHING]);
	const prose = last(page);

	const web = prose.getByRole('link', { name: 'push tokens' });
	await expect(web).toHaveAttribute('href', 'https://example.com/docs/push-tokens');
	await expect(web).toHaveAttribute('target', '_blank');
	await expect(web).toHaveAttribute('rel', 'noopener noreferrer');

	// A script link is text.
	await expect(prose).toContainText('[script](javascript:alert(1))');
	await expect(prose.locator('a', { hasText: 'script' })).toHaveCount(0);

	// An image that is a file of the thread is shown from the thread's own read.
	const image = prose.locator('.mdimg[data-known] img');
	await expect(image).toHaveJSProperty('naturalWidth', 780);
	expect(await image.getAttribute('src')).toMatch(/^blob:/);
	// It is drawn once: not again as a thumbnail under the message.
	await expect(chat(page).locator('.thumb', { hasText: 'settings-after.png' })).toHaveCount(0);
	// A remote image is a chip with the alt text, and no picture.
	const remote = prose.locator('.mdimg', { hasText: 'a remote pixel' });
	await expect(remote.locator('img')).toHaveCount(0);
	await expect(remote).not.toHaveAttribute('data-known');
	await remote.evaluate((el) => el.scrollIntoView({ block: 'end' }));
	await shot(page, 'markdown-chat-links');

	// A file of the thread opens in the Artifacts tab, as its chip does.
	const plan = prose.locator('a[data-file="PLAN.md"]');
	await expect(plan).toHaveAttribute('data-known', '');
	await expect(plan).not.toHaveAttribute('href');
	await plan.click();
	await expect(page.locator('[data-tab="artifacts"]')).toHaveAttribute('aria-selected', 'true');
	await expect(page.locator('[data-viewer] .md h1')).toHaveText('Plan');
	await page.locator('[data-tab="main"]').click();

	// A local address has no address of its own. Not published: Servers asks first.
	const local = prose.locator('a[data-local="5173"]');
	await expect(local).not.toHaveAttribute('href');
	await local.click();
	await expect(page.locator('[data-tab="servers"]')).toHaveAttribute('aria-selected', 'true');
	const sheet = page.getByRole('alertdialog');
	await expect(sheet).toContainText('Open port 5173 on your tailnet?');
	const [first] = await Promise.all([
		context.waitForEvent('page'),
		sheet.getByRole('button', { name: 'Open' }).click()
	]);
	expect(first.url()).toMatch(/\/__mapped\/5173\/$/);
	await first.close();

	// Published: the tap opens the tailnet address, with the path of the link.
	await page.locator('[data-tab="main"]').click();
	const [second] = await Promise.all([context.waitForEvent('page'), local.click()]);
	expect(second.url()).toMatch(/\/__mapped\/5173\/settings$/);
	expect(await second.evaluate(() => window.opener)).toBeNull();
	await second.close();
	await expect(page.locator('[data-tab="main"]')).toHaveAttribute('aria-selected', 'true');

	expect(seen.remote).toEqual([]);
	expect(seen.problems).toEqual([]);
});

test('an SVG file of the thread in a message is shown from a data address, and runs nothing', async ({
	page
}) => {
	const seen = watch(page);
	// Every object address the page makes, by the type of its blob.
	await page.addInitScript(() => {
		const made: string[] = [];
		const create = URL.createObjectURL.bind(URL);
		URL.createObjectURL = (source: Blob | MediaSource): string => {
			made.push(source instanceof Blob ? source.type : 'media');
			return create(source);
		};
		(window as unknown as { __blobTypes: string[] }).__blobTypes = made;
	});
	await open(page, [
		'The trend: ![coverage trend](coverage/chart.svg)\n\n[open the chart](coverage/chart.svg)'
	]);
	const prose = last(page);
	const image = prose.locator('.mdimg[data-known] img');
	await expect(image).toHaveJSProperty('naturalWidth', 300);
	// A `blob:` address belongs to the app's origin; opened as a page, its script would run there.
	expect(await image.getAttribute('src')).toMatch(/^data:image\/svg\+xml;base64,/);
	await expect(prose.locator('.mdimg')).toContainText('coverage trend');
	await expect(prose.locator('img')).toHaveCount(1);
	// Drawn in the message, so not again as a thumbnail under it.
	await expect(chat(page).locator('.thumb', { hasText: 'chart.svg' })).toHaveCount(0);

	// The link to the same file opens it in Artifacts, from a data address too.
	await prose.locator('a[data-file="coverage/chart.svg"]').click();
	const viewed = page.locator('[data-viewer] .stage img');
	await expect(viewed).toHaveJSProperty('naturalWidth', 300);
	expect(await viewed.getAttribute('src')).toMatch(/^data:image\/svg\+xml;base64,/);

	const types = await page.evaluate(
		() => (window as unknown as { __blobTypes: string[] }).__blobTypes
	);
	expect(types.filter((type) => /svg|html|xml|javascript/i.test(type))).toEqual([]);
	expect(
		await page.evaluate(() => (window as unknown as { __svgRan?: string }).__svgRan)
	).toBeUndefined();
	expect(await page.title()).not.toContain('ran');
	expect(seen.remote).toEqual([]);
	expect(seen.problems).toEqual([]);
	expect(await page.evaluate(() => window.__violations)).toEqual([]);
});

test('a link whose text names another host shows the host it goes to', async ({ page }) => {
	await open(page, ['Sign in at [https://good.example/login](https://evil.example/login) now.']);
	const prose = last(page);
	await expect(prose.locator('a')).toHaveAttribute('href', 'https://evil.example/login');
	await expect(prose.locator('.mdhost')).toHaveText('(evil.example)');
	await expect(prose).toHaveText('Sign in at https://good.example/login (evil.example) now.');
	// The host is beside the link, not part of it.
	await expect(prose.locator('a .mdhost')).toHaveCount(0);
	await shot(page, 'markdown-host');
});

test('find looks in the rendered text and scrolls to it', async ({ page }) => {
	await open(page, [EVERYTHING, ...Array.from({ length: 12 }, (_, n) => `Later line ${n + 1}.`)]);
	await page.getByRole('button', { name: 'Find' }).click();
	const box = page.getByRole('searchbox', { name: 'Find in session' });
	const count = page.locator('[data-find-count]');
	const current = page.locator('[data-find-current]');

	// The source says `**before** the tax row`: the reader sees no stars.
	await box.fill('before the tax row');
	await expect(count).toHaveText('1/1');
	await expect(current).toHaveText('before');
	await expect(current).toBeInViewport();
	await expect(chat(page).locator('.prose mark')).toHaveText(['before', ' the tax row']);
	await shot(page, 'markdown-find');

	// The symbols are not text any more.
	await box.fill('**before**');
	await expect(count).toHaveText('0/0');

	// Inside highlighted code, and in a table.
	await box.fill('tax.waitFor');
	await expect(count).toHaveText('1/2');
	await page.getByRole('button', { name: 'Next match' }).click();
	await expect(count).toHaveText('2/2');
	await expect(current).toBeInViewport();
	expect(await current.evaluate((el) => el.closest('pre') !== null)).toBe(true);
	await box.fill('waits for the tax');
	await expect(count).toHaveText('1/1');
	expect(await current.evaluate((el) => el.closest('td') !== null)).toBe(true);

	await page.getByRole('button', { name: 'Close find' }).click();
	await expect(chat(page).locator('mark')).toHaveCount(0);
});

test('the stored text size applies to rendered markdown', async ({ page }) => {
	await open(page, [EVERYTHING]);
	const prose = last(page);
	const sizes = (): Promise<number[]> =>
		prose.evaluate((el) =>
			['h1', 'p', 'pre', 'td', 'li'].map((name) =>
				parseFloat(getComputedStyle(el.querySelector(name) as Element).fontSize)
			)
		);
	const before = await sizes();
	// A pinch stores the size on the phone; the chat is drawn from the stored one.
	await page.evaluate(() => localStorage.setItem('mm.textSize', '18'));
	await page.reload();
	await expect(prose.locator('h1')).toBeVisible();
	const after = await sizes();
	for (const [index, size] of after.entries()) expect(size).toBeGreaterThan(before[index]);
});

const VIOLATIONS = (): void => {
	window.__violations = [];
	document.addEventListener('securitypolicyviolation', (event) => {
		window.__violations.push(`${event.violatedDirective} ${event.blockedURI}`);
	});
};

const REPLY = [
	'the audit.',
	'',
	'Two threads **need you**.',
	'',
	'- `checkout-fix` waits on a permission',
	'- `proration` asks a question',
	'',
	'```sh',
	'make test && make app',
	'```',
	'',
	'<script>window.__ran = 1</script> and [x](javascript:window.__ran=2)',
	'',
	...Array.from({ length: 30 }, (_, n) => `Thread ${n + 1} is still running its tests.`)
].join('\n');

test('a reply that is still arriving renders as it grows, and only its last block is redrawn', async ({
	page
}) => {
	const IDLE = 'localhost:7';
	const seen = watch(page);
	await fakeMic(page);
	await page.addInitScript(VIOLATIONS);
	await reset(page);
	for (const name of ['replies', 'voice'])
		await page.request.post(`/__fixture/capability?name=${name}&on=1`);
	// The spoken turn is answered with "Done: <what was heard>. ...", a word at a time.
	await page.request.post(`/__fixture/voice?heard=${encodeURIComponent(REPLY)}&delay=100`);
	await forget(page);
	await page.goto(pairingLink(threadPath(IDLE)));
	const primary = page.locator('[data-primary]');
	await expect(primary).toHaveText('Talk');
	await primary.click();
	await expect(primary).toHaveText('↑ Submit');
	await page.evaluate(() => window.__mic.speak(true));
	await page.waitForTimeout(600);
	await page.evaluate(() => window.__mic.speak(false));
	await primary.click();

	// What was said is the user's line: plain text, with its symbols.
	await expect(page.locator('.u').last()).toContainText('Two threads **need you**.');
	await expect(page.locator('.u').last().locator('strong, pre, li')).toHaveCount(0);

	const live = page.locator('.a[data-live] .prose');
	// While it arrives: a block that is complete is drawn once and then left alone.
	await expect(live.locator('strong')).toHaveText('need you');
	await live
		.locator('p')
		.first()
		.evaluate((el) => el.setAttribute('data-kept', ''));
	// A code block whose fence is not closed yet is already a code block.
	await expect(live.locator('pre')).toContainText('make');
	expect(await live.locator('pre').innerText()).not.toContain('```');
	await expect(live.locator('ul li')).toHaveCount(2);
	await expect(live).toContainText('Thread 5 is still');
	await expect(live.locator('p[data-kept]')).toHaveText('Done: the audit.');
	await expect(live).not.toContainText('Thread 30 is still running its tests.');
	await page
		.locator('.u')
		.last()
		.evaluate((el) => el.scrollIntoView({ block: 'start' }));
	await shot(page, 'markdown-streaming');

	// When it has all arrived the chat's own row takes over, with the same markdown.
	await expect(page.locator('[data-live]')).toHaveCount(0, { timeout: 20_000 });
	const done = page.locator('.a .prose').last();
	await expect(done).toContainText('Thread 30 is still running its tests.');
	await expect(done.locator('pre code')).toHaveText('make test && make app\n');
	await expect(done).toContainText('<script>window.__ran = 1</script>');
	await expect(done.locator('a')).toHaveCount(0);
	await expect(done.getByRole('button', { name: 'Copy' })).toHaveCount(1);

	expect(await page.evaluate(() => window.__ran)).toBeUndefined();
	expect(seen.remote).toEqual([]);
	expect(seen.problems).toEqual([]);
	expect(await page.evaluate(() => window.__violations)).toEqual([]);
});

test('the manager home renders the same markdown', async ({ page }) => {
	const seen = watch(page);
	await page.addInitScript(VIOLATIONS);
	await fresh(page, '/');
	const said = page.locator('[data-view="chat"]');
	await expect(said.locator('.a').first()).toBeVisible();
	await page.request.post(
		`/__fixture/mac-turn?text=${encodeURIComponent('what needs me?')}&reply=${encodeURIComponent(REPLY)}`
	);
	const done = said.locator('.a .prose').last();
	await expect(done).toContainText('Thread 30 is still running its tests.', { timeout: 20_000 });
	await expect(done.locator('strong')).toHaveText('need you');
	await expect(done.locator('ul li code')).toHaveText(['checkout-fix', 'proration']);
	await expect(done.locator('pre code')).toHaveText('make test && make app\n');
	await expect(done.getByRole('button', { name: 'Copy' })).toHaveCount(1);
	await expect(done).toContainText('<script>window.__ran = 1</script>');
	await expect(done.locator('a')).toHaveCount(0);
	// The code block ends inside the page, with the chat's own margin.
	const edges = await done.locator('.codeblock').evaluate((el) => {
		const box = el.getBoundingClientRect();
		return { left: box.left, right: innerWidth - box.right };
	});
	expect(edges.right).toBeGreaterThanOrEqual(edges.left - 1);
	await done.locator('strong').evaluate((el) => el.scrollIntoView({ block: 'start' }));
	await shot(page, 'markdown-manager');

	expect(await page.evaluate(() => window.__ran)).toBeUndefined();
	expect(seen.remote).toEqual([]);
	expect(seen.problems).toEqual([]);
	expect(await page.evaluate(() => window.__violations)).toEqual([]);
});
