import { describe, expect, it } from 'vitest';
import { ARTIFACTS, BOARD, MAIN, REQUESTS, SERVERS, viewTabs, type TabSwitches } from './tabs';

const view = (over: Partial<TabSwitches> = {}): TabSwitches => ({
	listed: true,
	embedded: false,
	artifacts: true,
	servers: true,
	...over
});

describe('the tabs of a thread view', () => {
	it('gives a listed thread its files and servers, and no board', () => {
		expect(viewTabs(view())).toEqual([MAIN, ARTIFACTS, SERVERS]);
	});

	it('leaves out a tab whose feature is off on the Mac', () => {
		expect(viewTabs(view({ artifacts: false }))).toEqual([MAIN, SERVERS]);
		expect(viewTabs(view({ servers: false }))).toEqual([MAIN, ARTIFACTS]);
		expect(viewTabs(view({ artifacts: false, servers: false }))).toEqual([MAIN]);
	});

	it('gives the Maestro page the board and the requests, and no files or servers', () => {
		expect(viewTabs(view({ listed: false }))).toEqual([MAIN, BOARD, REQUESTS]);
		// Neither waits for a switch: the Maestro page is their switch.
		expect(viewTabs(view({ listed: false, artifacts: false, servers: false }))).toEqual([
			MAIN,
			BOARD,
			REQUESTS
		]);
	});

	it('gives a listed thread no requests', () => {
		expect(viewTabs(view())).not.toContain(REQUESTS);
	});

	it('gives the Maestro panel one page: it draws the board itself', () => {
		expect(viewTabs(view({ listed: false, embedded: true }))).toEqual([MAIN]);
	});

	it('always starts with the chat', () => {
		for (const listed of [true, false])
			for (const embedded of [true, false])
				expect(viewTabs(view({ listed, embedded }))[0]).toBe(MAIN);
	});
});
