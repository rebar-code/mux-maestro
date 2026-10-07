import { expect, test } from '@playwright/test';
import { fresh, threadPath } from './helpers';

// The thread with a run of seven tool calls, then one of two.
const BUSY = 'localhost:100';

test('a long run of tool calls shows its last three, and opens to show all', async ({ page }) => {
	await fresh(page, threadPath(BUSY));
	const tools = page.locator('.chat .tool');
	// Three of the seven, and the short run whole.
	await expect(tools).toHaveCount(5);
	await expect(tools.first()).toHaveText('Edit e2e/fixtures.ts');
	await expect(tools.nth(2)).toHaveText(
		'Bash pnpm exec playwright test e2e/checkout.spec.ts --repeat-each 20'
	);
	await expect(tools.nth(4)).toHaveText('Bash git diff --stat');

	// One control, on the long run only, above the rows it left in view.
	const fold = page.locator('.chat .fold');
	await expect(fold).toHaveCount(1);
	await expect(fold).toHaveText('4 more tool calls');
	await expect(fold).toHaveAttribute('aria-expanded', 'false');
	const above = async (): Promise<boolean> =>
		((await fold.boundingBox())?.y ?? 0) < ((await tools.first().boundingBox())?.y ?? 0);
	expect(await above()).toBe(true);

	await fold.click();
	await expect(tools).toHaveCount(9);
	await expect(tools.first()).toHaveText('Read e2e/checkout.spec.ts');
	await expect(fold).toHaveText('Show last 3');
	await expect(fold).toHaveAttribute('aria-expanded', 'true');
	expect(await above()).toBe(true);

	await fold.click();
	await expect(tools).toHaveCount(5);
	await expect(fold).toHaveText('4 more tool calls');
});

test('a run that grows keeps to three rows, and stays open once opened', async ({ page }) => {
	await fresh(page, threadPath(BUSY));
	const tools = page.locator('.chat .tool');
	const folds = page.locator('.chat .fold');
	await expect(tools).toHaveCount(5);
	const say = (text: string): Promise<unknown> =>
		page.request.post(
			`/__fixture/say?id=${BUSY}&role=tool&tool=Bash&text=${encodeURIComponent(text)}`
		);

	// Four new calls after the last reply: a new run, cut to three.
	for (const text of ['pnpm lint', 'pnpm check', 'pnpm test', 'git status']) await say(text);
	await expect(folds).toHaveCount(2, { timeout: 8000 });
	await expect(folds.nth(1)).toHaveText('1 more tool call');
	await expect(tools.last()).toHaveText('Bash git status');
	await expect(tools).toHaveCount(8);

	await folds.nth(1).click();
	await expect(tools).toHaveCount(9);
	await say('git push');
	await expect(tools).toHaveCount(10, { timeout: 8000 });
	await expect(folds.nth(1)).toHaveText('Show last 3');
});

test('what the agent thought is a row of its own, in its place', async ({ page }) => {
	await fresh(page, threadPath(BUSY));
	const think = page.locator('.chat .think');
	await expect(think).toHaveCount(1);
	await expect(think).toContainText('The test passes alone and fails in the suite.');
	// Drawn as markdown, like a reply; not a reply: no menu, nothing to play.
	await expect(think.locator('strong')).toHaveText('Look for shared state first.');
	await expect(page.locator('.chat .a')).toHaveCount(3);

	// Between the prompt and the first reply.
	const order = await page
		.locator('.chat > .u, .chat > .think, .chat > .a')
		.evaluateAll((nodes) => nodes.slice(0, 3).map((node) => node.className.split(' ')[0]));
	expect(order).toEqual(['u', 'think', 'a']);
});

test('a find looks in the tool calls a run hides', async ({ page }) => {
	await fresh(page);
	await page.request.post('/__fixture/capability?name=find&on=1');
	await page.goto(threadPath(BUSY));
	await expect(page.locator('.chat .tool')).toHaveCount(5);
	await page.getByRole('button', { name: 'Find' }).click();
	await page.getByRole('searchbox', { name: 'Find in session' }).fill('beforeEach');
	await expect(page.locator('.chat .tool')).toHaveCount(9);
	await expect(page.locator('.chat .tool mark')).toHaveText('beforeEach');
	await expect(page.locator('.chat .fold')).toHaveCount(0);
});
