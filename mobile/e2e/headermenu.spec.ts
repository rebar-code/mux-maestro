import { expect, test, type Locator, type Page } from '@playwright/test';
import { fresh, threadPath } from './helpers';

const THREAD = 'localhost:7';
const AGENT = '0a1b2c3d-0000-4000-8000-000000000007';

const sheet = (page: Page): Locator => page.locator('[data-action-sheet]');
const title = (page: Page): Locator => page.locator('.tbar .title');
const copied = (page: Page): Promise<string> => page.evaluate(() => navigator.clipboard.readText());

/** Screenshots are taken only when SHOTS names a directory outside the repo. */
async function shot(page: Page, name: string): Promise<void> {
	const dir = process.env.SHOTS;
	if (!dir) return;
	// Let the sheet's slide-in end.
	await page.waitForTimeout(300);
	await page.screenshot({ path: `${dir}/${name}.png` });
}

/** Press on the header's title and hold, as a finger would. */
async function hold(page: Page, ms = 650): Promise<void> {
	const box = await title(page).boundingBox();
	if (!box) throw new Error('no header');
	await page.mouse.move(box.x + box.width / 3, box.y + box.height / 2);
	await page.mouse.down();
	await page.waitForTimeout(ms);
	await page.mouse.up();
}

async function open(page: Page, ...capabilities: string[]): Promise<void> {
	await page.context().grantPermissions(['clipboard-read', 'clipboard-write']);
	await fresh(page);
	for (const name of capabilities)
		await page.request.post(`/__fixture/capability?name=${name}&on=1`);
	await page.goto(threadPath(THREAD));
	await expect(title(page).locator('b')).toHaveText('acme-app · dark-mode');
}

test('a long press on the header opens the thread menu', async ({ page }) => {
	await open(page, 'sessionActions', 'kill');
	await hold(page);
	await expect(sheet(page)).toBeVisible();
	await expect(sheet(page).locator('.title')).toHaveText('acme-app · dark-mode');
	await expect(sheet(page).getByRole('button')).toHaveText([
		'Flag',
		'New Window…',
		'Rename Window…',
		'Archive Window',
		'Zoom Pane',
		'Copy Session ID',
		'Copy tmux Window',
		'Copy tmux Pane',
		'Kill Window'
	]);
	// The press selected no text.
	expect(await page.evaluate(() => String(getSelection()))).toBe('');
	await shot(page, 'header-menu');

	await sheet(page).getByRole('button', { name: 'Rename Window…' }).click();
	await expect(sheet(page)).toHaveAttribute('data-action-sheet', 'rename');
	await expect(sheet(page).getByLabel('Name')).toHaveValue('dark-mode');
});

test('the copy items put the session id and the tmux targets on the clipboard', async ({
	page
}) => {
	await open(page, 'sessionActions');
	const copies = [
		['Copy Session ID', AGENT],
		['Copy tmux Window', 'acme-app:7'],
		['Copy tmux Pane', '%7']
	];
	for (const [label, value] of copies) {
		await hold(page);
		await sheet(page).getByRole('button', { name: label }).click();
		await expect(sheet(page)).toBeHidden();
		expect(await copied(page)).toBe(value);
	}
});

test('with session actions off the menu holds the copy items alone', async ({ page }) => {
	await open(page);
	await hold(page);
	await expect(sheet(page).getByRole('button')).toHaveText([
		'Copy Session ID',
		'Copy tmux Window',
		'Copy tmux Pane'
	]);
});

test('a pane without an agent has no session id to copy', async ({ page }) => {
	await page.context().grantPermissions(['clipboard-read', 'clipboard-write']);
	await fresh(page, threadPath('buildbox:8'));
	await expect(title(page).locator('b')).toHaveText('reports · csv-export');
	await hold(page);
	await expect(sheet(page).getByRole('button')).toHaveText(['Copy tmux Window', 'Copy tmux Pane']);
});

test('a tap on the header opens nothing', async ({ page }) => {
	await open(page, 'sessionActions');
	await title(page).click();
	await hold(page, 150);
	await expect(sheet(page)).toHaveCount(0);
});
