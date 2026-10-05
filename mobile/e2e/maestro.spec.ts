import { expect, test, type Locator, type Page } from '@playwright/test';
import { expectDrawerOpen, fakeMic, fresh, threadPath, TOKEN_HEADER } from './helpers';

/** A session that waits on a permission prompt, one that runs, and one with a chat. */
const WAITING = 'localhost:1';
const RUNNING = 'localhost:3';
const ALSO_RUNNING = 'localhost:4';

const button = (page: Page): Locator => page.locator('[data-maestro]');
const foot = (page: Page): Locator => page.locator('[data-foot]');
const ask = (page: Page): Locator => foot(page).getByRole('textbox', { name: 'Ask the Maestro' });
const said = (page: Page): Locator => page.locator('[data-view="chat"]');
const board = (page: Page): Locator => page.locator('[data-board]');
const point = (page: Page): Locator => board(page).locator('[data-point]');
const keybar = (page: Page): Locator => page.locator('[data-keybar]');

const hook = (page: Page, path: string): Promise<unknown> =>
	page.request.post(path, { headers: TOKEN_HEADER });

const onHome = (page: Page): Promise<void> =>
	expect.poll(() => new URL(page.url()).pathname).toBe('/');

/** The header button opens the Maestro's screen: the button is then the X. */
async function openMaestro(page: Page): Promise<void> {
	await button(page).click();
	await onHome(page);
	await expect(button(page)).toHaveAccessibleName('Close the Maestro');
}

/** The page of a session is open. A link writes the id as it is; `goto` encodes it. */
const onThread = (page: Page, id: string): Promise<void> =>
	expect.poll(() => decodeURIComponent(new URL(page.url()).pathname)).toBe(`/t/${id}`);

/** Show the home's Board tab. */
async function showBoard(page: Page): Promise<void> {
	await page.locator('[data-tab="board"]').click();
	await expect(page.locator('[data-page="board"]')).not.toHaveAttribute('inert', '');
}

const center = async (target: Locator): Promise<[number, number]> => {
	const box = await target.boundingBox();
	if (!box) throw new Error('not on screen');
	return [box.x + box.width / 2, box.y + box.height / 2];
};

for (const viewport of [
	{ width: 375, height: 667 },
	{ width: 430, height: 932 }
]) {
	test.describe(`${viewport.width}x${viewport.height}`, () => {
		test.use({ viewport });

		test('the Maestro button is on every page, at the same place', async ({ page }) => {
			await fresh(page);
			await expect(button(page)).toHaveAttribute('data-state', 'idle');
			const home = await button(page).boundingBox();
			expect(home?.width).toBeGreaterThanOrEqual(44);
			expect(home?.height).toBeGreaterThanOrEqual(44);
			// Two sessions wait: the count says so.
			await expect(button(page).locator('[data-count]')).toHaveText('2');

			await page.goto(threadPath(RUNNING));
			await expect(page.locator('.tbar .title b')).toBeVisible();
			expect(await button(page).boundingBox()).toEqual(home);
			// Nothing of the header is under it.
			const find = await page.getByRole('button', { name: 'Find' }).boundingBox();
			expect((find?.x ?? 0) + (find?.width ?? 0)).toBeLessThanOrEqual(home?.x ?? 0);

			await openMaestro(page);
			expect(await button(page).boundingBox()).toEqual(home);
		});

		test('the button shows what the Maestro does', async ({ page }) => {
			await fresh(page, threadPath(RUNNING));
			await expect(button(page)).toHaveAttribute('data-state', 'idle');
			await hook(page, '/__fixture/mac-turn?text=hello&reply=one two three four five six&ms=150');
			await expect(button(page)).toHaveAttribute('data-state', 'working');
			await expect(button(page)).toHaveAttribute('data-state', 'idle');
			await hook(page, '/__fixture/manager-prompt?kind=permission');
			// The pane's status has no event of its own: the next poll may be what brings it.
			await expect(button(page)).toHaveAttribute('data-state', 'asks', { timeout: 15_000 });
		});

		test('with the Maestro switched off the button is off and opens nothing', async ({ page }) => {
			await fresh(page, threadPath(RUNNING));
			await hook(page, '/__fixture/capability?name=manager&on=0');
			await expect(button(page)).toHaveAttribute('data-state', 'off');
			await expect(button(page)).toHaveAttribute('aria-disabled', 'true');
			await button(page).click({ force: true });
			await page.waitForTimeout(200);
			await onThread(page, RUNNING);
		});

		test('the button opens the screen the sidebar opens, and its X goes back', async ({ page }) => {
			await fresh(page, threadPath(RUNNING));
			await expect(page.locator('.tbar .title b')).toBeVisible();
			await expect(button(page).locator('.mark')).toHaveText('✦');

			await openMaestro(page);
			await expect(button(page).locator('.mark')).toHaveText('✕');
			// The whole screen is the Maestro's: nothing of the session is under it.
			await expect(page.locator('[data-dock]')).toHaveCount(0);
			await expect(said(page)).toHaveCount(1);
			const stage = await page.locator('.stage').boundingBox();
			const box = await foot(page).boundingBox();
			expect((stage?.y ?? 0) + (stage?.height ?? 0)).toBeLessThanOrEqual((box?.y ?? 0) + 1);
			expect(Math.round((box?.y ?? 0) + (box?.height ?? 0))).toBe(viewport.height);
			const fromButton = {
				stage,
				box,
				html: await page.locator('.view').evaluate((el) => el.children.length)
			};

			await button(page).click();
			await onThread(page, RUNNING);
			await expect(button(page).locator('.mark')).toHaveText('✦');

			// From the sidebar: the same screen, and the same way back.
			await page.getByRole('button', { name: 'Menu' }).click();
			await expectDrawerOpen(page);
			await page.locator('[data-home]').click();
			await onHome(page);
			await expect(button(page)).toHaveAccessibleName('Close the Maestro');
			expect({
				stage: await page.locator('.stage').boundingBox(),
				box: await foot(page).boundingBox(),
				html: await page.locator('.view').evaluate((el) => el.children.length)
			}).toEqual(fromButton);
			await button(page).click();
			await onThread(page, RUNNING);
		});

		test('a pull down on a header opens nothing', async ({ page }) => {
			await fresh(page, threadPath(RUNNING));
			await expect(page.locator('.tbar .title b')).toBeVisible();
			await page.mouse.move(150, 22);
			await page.mouse.down();
			await page.mouse.move(150, 300, { steps: 8 });
			await page.mouse.up();
			await onThread(page, RUNNING);
			await expect(page.locator('[data-panel]')).toHaveCount(0);
		});

		test('the key strip is on the chat and on the terminal, as on a session', async ({ page }) => {
			await fresh(page, threadPath(RUNNING));
			await hook(page, '/__fixture/capability?name=keyBar&on=1');
			// The session's page has the strip: the switch is on.
			await hook(page, '/__fixture/capability?name=replies&on=1');
			await expect(keybar(page)).toBeVisible();
			await openMaestro(page);
			await expect(ask(page)).toBeVisible();
			await expect(keybar(page).getByRole('button', { name: 'Escape', exact: true })).toBeVisible();
			// The same keys as a session's strip, above the text box.
			await expect(keybar(page).locator('.keys button')).toHaveCount(14);
			const strip = (await keybar(page).boundingBox())!;
			expect(strip.y + strip.height).toBeLessThanOrEqual((await ask(page).boundingBox())!.y);
			// A text key types into the Maestro's box, where the caret is.
			await ask(page).fill('ls ');
			await keybar(page).getByRole('button', { name: 'Slash' }).click();
			await expect(ask(page)).toHaveValue('ls /');
			await ask(page).fill('');
			await page.locator('[data-mode="chat"]').click();
			await expect(keybar(page).getByRole('button', { name: 'Escape', exact: true })).toBeVisible();
			await page.locator('[data-mode="terminal"]').click();
			await expect(keybar(page)).toBeVisible();
		});

		test('a message sent while the Maestro works waits, and goes when the turn ends', async ({
			page
		}) => {
			await fresh(page, threadPath(RUNNING));
			await openMaestro(page);
			await hook(page, '/__fixture/mac-turn?text=hello&reply=one two three four&ms=300');
			await expect(button(page)).toHaveAttribute('data-state', 'working');
			await ask(page).fill('And the builds?');
			const send = foot(page).locator('[data-send]');
			await expect(send).toBeEnabled();
			await expect(send).toHaveAttribute('data-send', 'queue');
			await send.click();
			await expect(ask(page)).toHaveValue('');
			const queued = said(page).locator('[data-queued]');
			await expect(queued).toHaveText('And the builds?');
			// It is kept across a reload, like a draft.
			await page.waitForTimeout(500);
			await page.reload();
			await expect(said(page).locator('[data-queued]')).toHaveText('And the builds?');
			// The turn ends: the text goes as the next turn, once.
			await expect(said(page).locator('.u').last()).toHaveText('And the builds?');
			await expect(said(page).locator('[data-queued]')).toHaveCount(0);
			await expect(said(page).locator('.a').last()).toContainText('2 threads need you');
			await expect(button(page)).toHaveAttribute('data-state', 'idle');
			await expect(said(page).locator('.u', { hasText: 'And the builds?' })).toHaveCount(1);
		});

		test('a question asked from a session page is answered, and the X goes back', async ({
			page
		}) => {
			await fresh(page, threadPath(RUNNING));
			await openMaestro(page);
			await ask(page).fill('What needs me?');
			await foot(page).locator('[data-send]').click();
			await expect(said(page).locator('.u').last()).toHaveText('What needs me?');
			await expect(said(page).locator('.a').last()).toContainText('2 threads need you');
			await expect(said(page).locator('.a').last()).toBeInViewport();
			await button(page).click();
			await onThread(page, RUNNING);
		});

		test('a pointer opens its session with Go, and the button brings the Maestro back', async ({
			page
		}) => {
			await fresh(page, threadPath(RUNNING));
			await hook(
				page,
				`/__fixture/point?thread=${WAITING}&title=acme-app&reason=needs your approval`
			);
			await expect(button(page).locator('[data-count]')).toHaveText('2');
			await openMaestro(page);
			await showBoard(page);
			const card = point(page);
			await expect(card).toContainText('acme-app · checkout-fix');
			await expect(card).toContainText('needs your approval');
			await expect(card.locator('.hchip')).toHaveText('localhost');
			await expect(card.locator('.dot')).toHaveClass(/waiting/);
			// The pointer stands for its session: it is not listed a second time.
			await expect(board(page).locator(`[data-thread="${WAITING}"]`)).toHaveCount(1);
			const go = await card.locator('[data-go]').boundingBox();
			expect(go?.width).toBeGreaterThanOrEqual(44);

			await card.locator('[data-go]').click();
			await onThread(page, WAITING);
			await expect(page.locator('.tbar .title b')).toHaveText('acme-app · checkout-fix');
			// The way back is above the reply box, and a touch elsewhere leaves it there.
			const back = page.locator('[data-dock] [data-maestro-back]');
			await expect(back).toBeVisible();
			await page.locator('[data-view="chat"]').first().click();
			await expect(back).toBeVisible();

			await openMaestro(page);
			await expect(back).toHaveCount(0);
			// The X goes back to the session the Maestro was opened from.
			await button(page).click();
			await onThread(page, WAITING);
			await expect(back).toHaveCount(0);

			// Back returns to the Maestro, then to the page it was first opened from.
			await page.goBack();
			await onHome(page);
			await expect(button(page)).toHaveAccessibleName('Close the Maestro');
		});

		test('the way back above the reply box opens the Maestro, or is dismissed', async ({
			page
		}) => {
			await fresh(page);
			await hook(page, `/__fixture/point?thread=${WAITING}`);
			await showBoard(page);
			await point(page).locator('[data-go]').click();
			await onThread(page, WAITING);
			const back = page.locator('[data-dock] [data-maestro-back]');
			// In reach of a thumb: in the lower part of the screen.
			expect((await back.boundingBox())?.y).toBeGreaterThan(viewport.height * 0.6);
			await back.getByRole('button', { name: 'Back to Maestro' }).click();
			await onHome(page);
			await button(page).click();
			await onThread(page, WAITING);
			await expect(back).toHaveCount(0);

			await page.goto('/');
			await showBoard(page);
			await point(page).locator('[data-go]').click();
			await onThread(page, WAITING);
			await back.getByRole('button', { name: 'Dismiss' }).click();
			await expect(back).toHaveCount(0);
			await onThread(page, WAITING);
		});

		test('a stale pointer says so and never leads nowhere', async ({ page }) => {
			await fresh(page, threadPath(RUNNING));
			// One session that no longer waits, one that is gone.
			await hook(
				page,
				`/__fixture/point?key=point:a&thread=${ALSO_RUNNING}&reason=needs your approval`
			);
			await hook(
				page,
				'/__fixture/point?key=point:b&title=acme-app&reason=asks <b>which</b> database'
			);
			await openMaestro(page);
			await showBoard(page);
			const done = board(page).locator('[data-point="point:a"]');
			const gone = board(page).locator('[data-point="point:b"]');
			await expect(done).toHaveAttribute('data-stale', 'done');
			await expect(done.locator('[data-reason]')).toHaveCSS('text-decoration-line', 'line-through');
			await expect(gone).toHaveAttribute('data-stale', 'gone');
			await expect(gone).toContainText('acme-app');
			await expect(gone).toContainText('Closed');
			// The reason is text, never markup.
			await expect(gone.locator('[data-reason]')).toHaveText('asks <b>which</b> database');
			await expect(gone.locator('[data-reason] b')).toHaveCount(0);
			await expect(gone.locator('a')).toHaveCount(0);
			await expect(gone.locator('[data-go]')).toHaveAttribute('aria-disabled', 'true');
			// Neither counts as a session that needs the user.
			await expect(button(page).locator('[data-count]')).toHaveText('2');
			await gone.locator('[data-go]').click();
			await onHome(page);

			// It can be cleared from the phone.
			await gone.getByRole('button', { name: 'Dismiss acme-app' }).click();
			await expect(gone).toHaveCount(0);
			// The one that no longer waits still opens its session.
			await done.locator('[data-go]').click();
			await onThread(page, ALSO_RUNNING);
		});

		test('a session that waits has Go on the board without a pointer', async ({ page }) => {
			await fresh(page);
			await showBoard(page);
			const card = page.locator(`[data-board] a.item[data-thread="${WAITING}"]`);
			await expect(card.locator('[data-go]')).toHaveText('Go');
			await card.locator('[data-go]').click();
			await onThread(page, WAITING);
			await expect(page.locator('[data-dock] [data-maestro-back]')).toBeVisible();
		});

		test("a session draft survives a visit to the Maestro's screen", async ({ page }) => {
			await fresh(page, threadPath(RUNNING));
			await hook(page, '/__fixture/capability?name=replies&on=1');
			const box = page.getByRole('textbox', { name: 'Reply' });
			await box.fill('half a thought');

			await openMaestro(page);
			await ask(page).fill('and one for the Maestro');
			await button(page).click();
			await onThread(page, RUNNING);

			await expect(box).toHaveValue('half a thought');
			await openMaestro(page);
			await expect(ask(page)).toHaveValue('and one for the Maestro');
		});

		test("on the home page the button goes to the page's own text box", async ({ page }) => {
			await fresh(page);
			const box = page.locator('[data-foot]').getByRole('textbox', { name: 'Ask the Maestro' });
			await expect(box).not.toBeFocused();
			await button(page).click();
			await expect(box).toBeFocused();
			// Nothing was open before it: there is no page to go back to, and no X.
			await expect(button(page).locator('.mark')).toHaveText('✦');
			await onHome(page);
		});

		test("a long press on a session's Talk button opens the Maestro", async ({ page }) => {
			await fakeMic(page);
			await fresh(page, threadPath(RUNNING));
			await hook(page, '/__fixture/capability?name=replies&on=1');
			await hook(page, '/__fixture/capability?name=voice&on=1');
			const talk = page.locator('[data-dock] [data-compose] [data-primary="talk"]');
			await expect(talk).toBeEnabled();
			const [x, y] = await center(talk);
			await page.mouse.move(x, y);
			await page.mouse.down();
			await page.waitForTimeout(650);
			await page.mouse.up();
			await onHome(page);
			// The press is not also a tap: no take began.
			expect(await page.evaluate(() => window.__mic.opened)).toBe(0);
		});
	});
}
