import { mkdirSync } from 'node:fs';
import { expect, test, type Locator, type Page } from '@playwright/test';
import { forget, pairingLink, reset, threadPath } from './helpers';

/** Idle, local, with a chat. */
const IDLE = 'localhost:7';
const TEXT = 'run the tests and open a PR';

const box = (page: Page): Locator => page.getByRole('textbox', { name: 'Reply' });
const bar = (page: Page): Locator => page.getByRole('button', { name: 'Suggestion' });

const suggest = (page: Page, text: string, id = IDLE): Promise<unknown> =>
	page.request.post(`/__fixture/suggestion?id=${id}&text=${encodeURIComponent(text)}`);

async function open(page: Page, hooks: string[] = [], keyBar = true): Promise<void> {
	await reset(page);
	for (const name of keyBar ? ['replies', 'keyBar'] : ['replies'])
		await page.request.post(`/__fixture/capability?name=${name}&on=1`);
	for (const hook of hooks) await page.request.post(hook);
	await forget(page);
	await page.goto(pairingLink(threadPath(IDLE)));
	await expect(page.locator('.tbar .title b')).toBeVisible();
}

/** Screenshots are taken only when SHOTS names a directory outside the repo. */
async function shot(page: Page, name: string): Promise<void> {
	const dir = process.env.SHOTS;
	if (!dir) return;
	mkdirSync(dir, { recursive: true });
	await page.waitForTimeout(250);
	await page.screenshot({ path: `${dir}/${name}.png` });
}

const top = async (locator: Locator): Promise<number> => (await locator.boundingBox())!.y;

test('an idle pane with no suggestion shows no bar', async ({ page }) => {
	await open(page);
	await expect(box(page)).toBeVisible();
	await expect(bar(page)).toHaveCount(0);
	await shot(page, 'suggestion-none');
});

test('the suggestion shows above the key bar, and a tap puts it in the box', async ({ page }) => {
	await open(page);
	await suggest(page, TEXT);
	await page.reload();
	await expect(bar(page)).toHaveText(TEXT);
	expect(await top(bar(page))).toBeLessThan(await top(page.locator('[data-keybar]')));
	expect(await top(page.locator('[data-keybar]'))).toBeLessThan(await top(box(page)));
	await shot(page, 'suggestion-shown');

	await bar(page).click();
	await expect(box(page)).toHaveValue(TEXT);
	await expect(bar(page)).toHaveCount(0);
	// Nothing was sent: the human edits it or taps Send.
	const sent = await (await page.request.post('/__fixture/replies')).json();
	expect(sent.texts).toEqual([]);
	await shot(page, 'suggestion-taken');
});

test('without a key bar the suggestion sits above the text box', async ({ page }) => {
	await open(page, [], false);
	await suggest(page, TEXT);
	await page.reload();
	await expect(bar(page)).toBeVisible();
	expect(await top(bar(page))).toBeLessThan(await top(box(page)));
});

test('typing hides the suggestion, and an empty box shows it again', async ({ page }) => {
	await open(page);
	await suggest(page, TEXT);
	await page.reload();
	await expect(bar(page)).toBeVisible();
	await box(page).fill('no, wait');
	await expect(bar(page)).toHaveCount(0);
	await box(page).fill('');
	await expect(bar(page)).toBeVisible();
});

test('a prompt card hides the suggestion', async ({ page }) => {
	await open(page);
	await suggest(page, TEXT);
	await page.reload();
	await expect(bar(page)).toBeVisible();
	await page.request.post(`/__fixture/prompt?id=${IDLE}`);
	await expect(page.locator('[data-prompt]')).toBeVisible();
	await expect(bar(page)).toHaveCount(0);
});

test('a suggestion drawn after the turn ends comes up, and goes when the pane drops it', async ({
	page
}) => {
	await open(page, [`/__fixture/status?id=${IDLE}&value=busy`]);
	await expect(box(page)).toBeVisible();
	await page.request.post(`/__fixture/status?id=${IDLE}&value=idle`);
	// Claude Code draws it a moment after the turn ends: the thread list says nothing of it.
	await page.waitForTimeout(1500);
	await expect(bar(page)).toHaveCount(0);
	await suggest(page, TEXT);
	await expect(bar(page)).toHaveText(TEXT, { timeout: 10_000 });
	await suggest(page, '');
	await expect(bar(page)).toHaveCount(0, { timeout: 10_000 });
});

test('a sent text takes the suggestion away', async ({ page }) => {
	await open(page);
	await suggest(page, TEXT);
	await page.reload();
	await expect(bar(page)).toBeVisible();
	await box(page).fill('ship it');
	await page.getByRole('button', { name: /^Send(ing)?$/ }).click();
	await expect(box(page)).toHaveValue('');
	await expect(bar(page)).toHaveCount(0);
});
