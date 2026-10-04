import { expect, test, type Locator, type Page } from '@playwright/test';
import { drag, expectDrawerOpen, fresh, threadPath, TOKEN_HEADER, touchDrag } from './helpers';

/** A session that waits on a permission prompt, one that runs, and one with a chat. */
const WAITING = 'localhost:1';
const RUNNING = 'localhost:3';

const button = (page: Page): Locator => page.locator('[data-maestro]');
const panel = (page: Page): Locator => page.locator('[data-panel]');
const grab = (page: Page): Locator => page.locator('[data-panel-grab]');
const ask = (page: Page): Locator => panel(page).getByRole('textbox', { name: 'Ask the manager' });
const said = (page: Page): Locator => panel(page).locator('[data-view="chat"]');
const point = (page: Page, scope: Locator = panel(page)): Locator => scope.locator('[data-point]');

const hook = (page: Page, path: string): Promise<unknown> =>
	page.request.post(path, { headers: TOKEN_HEADER });

async function height(page: Page): Promise<number> {
	return (await panel(page).boundingBox())?.height ?? 0;
}

/** The panel has stopped moving at `stop`. */
async function settled(page: Page, stop: 0 | 1 | 2 | 3): Promise<void> {
	await expect(panel(page)).toHaveAttribute('data-stop', String(stop));
	await expect
		.poll(async () => {
			const first = await height(page);
			await page.waitForTimeout(80);
			return (await height(page)) === first;
		})
		.toBe(true);
}

async function openPanel(page: Page, stop: 1 | 2 | 3 = 1): Promise<void> {
	await button(page).click();
	await settled(page, 1);
	for (let at = 1; at < stop; at += 1) await grab(page).click();
	await settled(page, stop);
}

/** The page of a session is open. A link writes the id as it is; `goto` encodes it. */
const onThread = (page: Page, id: string): Promise<void> =>
	expect.poll(() => decodeURIComponent(new URL(page.url()).pathname)).toBe(`/t/${id}`);

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

			await openPanel(page);
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
			await fresh(page);
			await hook(page, '/__fixture/capability?name=manager&on=0');
			await expect(button(page)).toHaveAttribute('data-state', 'off');
			await expect(button(page)).toHaveAttribute('aria-disabled', 'true');
			await button(page).click({ force: true });
			await expect(panel(page)).toHaveCount(0);
			// A pull on the header opens nothing either.
			await drag(page, [150, 20], [150, 300]);
			await expect(panel(page)).toHaveCount(0);
		});

		test('tap opens the peek; the grabber steps to half and full; the button closes', async ({
			page
		}) => {
			await fresh(page, threadPath(RUNNING));
			await openPanel(page);
			const peek = await height(page);
			expect(peek).toBeGreaterThan(180);
			expect(peek).toBeLessThan(viewport.height * 0.5);
			// The peek: the Maestro's latest line and one text box.
			await expect(said(page).locator('.a').last()).toBeInViewport();
			await expect(ask(page)).toBeInViewport();
			await expect(panel(page).locator('.tabs')).toBeHidden();

			await grab(page).click();
			await settled(page, 2);
			expect(await height(page)).toBeGreaterThan(peek);
			await expect(panel(page).locator('.tabs')).toBeVisible();

			await grab(page).click();
			await settled(page, 3);
			expect(await height(page)).toBe(viewport.height);
			await expect(panel(page).locator('[data-panel-board]')).toContainText('Needs you · 2');
			await expect(ask(page)).toBeInViewport();

			await button(page).click();
			await settled(page, 0);
			expect(await height(page)).toBe(0);
			// It opens again at the stop it was on.
			await button(page).click();
			await settled(page, 3);
		});

		test('the panel follows a drag between its stops and closes on a swipe up', async ({
			page
		}) => {
			await fresh(page, threadPath(RUNNING));
			await expect(page.locator('.tbar .title b')).toBeVisible();
			// Pulled down from the page's header.
			await touchDrag(page, [150, 22], [150, 150]);
			await settled(page, 1);
			const peek = await height(page);

			// Mid-drag it is where the finger is.
			const from = await center(grab(page));
			await page.mouse.move(from[0], from[1]);
			await page.mouse.down();
			await page.mouse.move(from[0], from[1] + 60, { steps: 8 });
			await expect.poll(() => height(page)).toBeGreaterThan(peek + 30);
			await page.mouse.move(from[0], viewport.height * 0.56, { steps: 8 });
			await page.waitForTimeout(120);
			await page.mouse.up();
			await settled(page, 2);

			// One long pull passes to full.
			await touchDrag(page, await center(grab(page)), [150, viewport.height - 20]);
			await settled(page, 3);

			// From full, a pull up on the head goes back to half; a long one closes.
			await touchDrag(page, await center(grab(page)), [150, viewport.height * 0.55]);
			await settled(page, 2);
			await touchDrag(page, await center(grab(page)), [150, 4]);
			await settled(page, 0);
			await expect(ask(page)).toHaveCount(0);
		});

		test('a question asked from the peek on a session page is answered there', async ({ page }) => {
			await fresh(page, threadPath(RUNNING));
			await openPanel(page);
			await ask(page).fill('What needs me?');
			await panel(page).locator('[data-send]').click();
			await expect(said(page).locator('.u').last()).toHaveText('What needs me?');
			await expect(said(page).locator('.a').last()).toContainText('2 threads need you');
			// Still on the session's page.
			await onThread(page, RUNNING);
			await expect(said(page).locator('.a').last()).toBeInViewport();
		});

		test('a pointer opens its session with Go, and the button brings the panel back', async ({
			page
		}) => {
			await fresh(page, threadPath(RUNNING));
			await hook(
				page,
				`/__fixture/point?thread=${WAITING}&title=acme-app&reason=needs your approval`
			);
			await expect(button(page).locator('[data-count]')).toHaveText('2');
			await openPanel(page, 3);
			const card = point(page);
			await expect(card).toContainText('acme-app · checkout-fix');
			await expect(card).toContainText('needs your approval');
			await expect(card.locator('.hchip')).toHaveText('localhost');
			await expect(card.locator('.dot')).toHaveClass(/waiting/);
			// The pointer stands for its session: it is not listed a second time.
			await expect(panel(page).locator(`[data-thread="${WAITING}"]`)).toHaveCount(1);
			const go = await card.locator('[data-go]').boundingBox();
			expect(go?.width).toBeGreaterThanOrEqual(44);

			await card.locator('[data-go]').click();
			await onThread(page, WAITING);
			await settled(page, 0);
			await expect(page.locator('.tbar .title b')).toHaveText('acme-app · checkout-fix');
			// The way back is pointed out, until the first touch.
			await expect(page.locator('[data-maestro-back]')).toBeVisible();
			await page.locator('[data-view="chat"]').first().click();
			await expect(page.locator('[data-maestro-back]')).toHaveCount(0);

			await button(page).click();
			await settled(page, 3);
			await expect(point(page)).toBeVisible();
			await button(page).click();
			await settled(page, 0);

			// Back returns to the page the jump left from, with the panel as it was.
			await page.goBack();
			await onThread(page, RUNNING);
			await settled(page, 3);
		});

		test('the chip under the header goes back to the Maestro', async ({ page }) => {
			await fresh(page);
			await hook(page, `/__fixture/point?thread=${WAITING}`);
			await page.locator('[data-grab]').click();
			await point(page, page.locator('[data-board]')).locator('[data-go]').click();
			await onThread(page, WAITING);
			await page.locator('[data-maestro-back]').click();
			await settled(page, 1);
			await expect(page.locator('[data-maestro-back]')).toHaveCount(0);
		});

		test('a stale pointer says so and never leads nowhere', async ({ page }) => {
			await fresh(page);
			// One session that no longer waits, one that is gone.
			await hook(page, `/__fixture/point?key=point:a&thread=${RUNNING}&reason=needs your approval`);
			await hook(
				page,
				'/__fixture/point?key=point:b&title=compass&reason=asks <b>which</b> database'
			);
			await openPanel(page, 3);
			const done = panel(page).locator('[data-point="point:a"]');
			const gone = panel(page).locator('[data-point="point:b"]');
			await expect(done).toHaveAttribute('data-stale', 'done');
			await expect(done.locator('[data-reason]')).toHaveCSS('text-decoration-line', 'line-through');
			await expect(gone).toHaveAttribute('data-stale', 'gone');
			await expect(gone).toContainText('compass');
			await expect(gone).toContainText('Closed');
			// The reason is text, never markup.
			await expect(gone.locator('[data-reason]')).toHaveText('asks <b>which</b> database');
			await expect(gone.locator('[data-reason] b')).toHaveCount(0);
			await expect(gone.locator('a')).toHaveCount(0);
			await expect(gone.locator('[data-go]')).toHaveAttribute('aria-disabled', 'true');
			// Neither counts as a session that needs the user.
			await expect(button(page).locator('[data-count]')).toHaveText('2');
			await gone.locator('[data-go]').click();
			expect(new URL(page.url()).pathname).toBe('/');

			// It can be cleared from the phone.
			await gone.getByRole('button', { name: 'Dismiss compass' }).click();
			await expect(gone).toHaveCount(0);
			// The one that no longer waits still opens its session.
			await done.locator('[data-go]').click();
			await onThread(page, RUNNING);
		});

		test('a session that waits has Go on the board without a pointer', async ({ page }) => {
			await fresh(page);
			await page.locator('[data-grab]').click();
			const card = page.locator(`[data-board] a.item[data-thread="${WAITING}"]`);
			await expect(card.locator('[data-go]')).toHaveText('Go');
			await card.locator('[data-go]').click();
			await onThread(page, WAITING);
			await expect(page.locator('[data-maestro-back]')).toBeVisible();
		});

		test('a session draft and its scroll survive the panel', async ({ page }) => {
			await fresh(page, threadPath(RUNNING));
			await hook(page, '/__fixture/capability?name=replies&on=1');
			const box = page.getByRole('textbox', { name: 'Reply' });
			await box.fill('half a thought');
			const chat = page.locator('[data-view="chat"]').first();
			await chat.evaluate((el) => (el.scrollTop = 0));
			const top = await chat.evaluate((el) => el.scrollTop);

			await openPanel(page, 2);
			await ask(page).fill('and one for the Maestro');
			await button(page).click();
			await settled(page, 0);

			await expect(box).toHaveValue('half a thought');
			expect(await chat.evaluate((el) => el.scrollTop)).toBe(top);
			// The Maestro's own draft is kept too, and is the home page's.
			await page.goto('/');
			await expect(page.getByRole('textbox', { name: 'Ask the manager' })).toHaveValue(
				'and one for the Maestro'
			);
		});

		test('text typed in the panel shows in the home page box', async ({ page }) => {
			await fresh(page);
			await openPanel(page);
			await ask(page).fill('same words');
			await expect(
				page.locator('[data-foot]').getByRole('textbox', { name: 'Ask the manager' })
			).toHaveValue('same words');
		});

		test('the panel leaves the other gestures alone', async ({ page }) => {
			await fresh(page, threadPath(RUNNING));
			const tab = page.locator('[data-thread-pages]');
			await expect(page.locator('.tbar .title b')).toBeVisible();

			// Panel closed: the tabs still swipe, the sidebar still opens from the header.
			const tabs = page.locator('.view [role="tab"]');
			if ((await tabs.count()) > 1) {
				await drag(page, [300, 400], [40, 400]);
				await expect(tabs.nth(1)).toHaveAttribute('aria-selected', 'true');
				await drag(page, [40, 400], [300, 400]);
				await expect(tabs.first()).toHaveAttribute('aria-selected', 'true');
			}

			await openPanel(page, 2);
			const [x, y] = await center(said(page));
			// Sideways in the panel does not turn the page under it.
			await drag(page, [x + 120, y], [x - 120, y]);
			await expect(tabs.first()).toHaveAttribute('aria-selected', 'true');
			await settled(page, 2);
			// A scroll in the panel's chat does not move the panel.
			await touchDrag(page, [x, y - 40], [x, y + 60]);
			await settled(page, 2);
			await touchDrag(page, [x, y + 60], [x, y - 40]);
			await settled(page, 2);
			await expect(tab).toBeVisible();
			// A right swipe in the panel opens the sidebar, over it.
			await drag(page, [20, y], [300, y]);
			await expectDrawerOpen(page);
			await settled(page, 2);
		});

		test('the home board drawer still rises under an open-and-closed panel', async ({ page }) => {
			await fresh(page);
			await openPanel(page);
			await button(page).click();
			await settled(page, 0);
			await page.locator('[data-grab]').click();
			await expect(page.locator('[data-board]')).toHaveAttribute('data-stop', '1');
		});

		test('with little room, as with the keyboard open, the text box stays in view', async ({
			page
		}) => {
			await fresh(page, threadPath(RUNNING));
			await page.setViewportSize({ width: viewport.width, height: 320 });
			await openPanel(page);
			await expect(ask(page)).toBeInViewport({ ratio: 1 });
			await grab(page).click();
			await grab(page).click();
			await expect(ask(page)).toBeInViewport({ ratio: 1 });
			expect(await height(page)).toBeLessThanOrEqual(320);
		});

		test('with reduced motion the panel opens and closes without a transition', async ({
			page
		}) => {
			await page.emulateMedia({ reducedMotion: 'reduce' });
			await fresh(page, threadPath(RUNNING));
			await button(page).click();
			await expect(panel(page)).toHaveAttribute('data-stop', '1');
			expect(await height(page)).toBeGreaterThan(180);
			await button(page).click();
			expect(await height(page)).toBe(0);
			await expect(ask(page)).toHaveCount(0);
		});
	});
}
