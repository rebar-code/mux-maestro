/**
 * The pages of a thread view, left to right, by name. Kept free of the DOM so
 * the rule for which tabs a view has is tested directly.
 */

/** The chat, or the pane's terminal. Every view has it, and it is first. */
export const MAIN = 'main';
export const ARTIFACTS = 'artifacts';
export const SERVERS = 'servers';
/** What needs the user, the review list and the updates. */
export const BOARD = 'board';
/** What the user asked agents for. */
export const REQUESTS = 'requests';

export interface TabSwitches {
	/** The view shows a listed thread. False for the Maestro's own pane. */
	listed: boolean;
	/** The view lies over another page (the Maestro panel) and has no pager. */
	embedded: boolean;
	/** The Artifacts switch on the Mac. */
	artifacts: boolean;
	/** The Servers switch on the Mac. */
	servers: boolean;
}

/**
 * The tabs of a view. Files and servers belong to a listed thread. The
 * Maestro's pane has none, so its page has the board and the requests as tabs
 * instead. A tab
 * whose feature is off on the Mac is not there at all.
 */
export function viewTabs(on: TabSwitches): string[] {
	return [
		MAIN,
		...(on.listed && on.artifacts ? [ARTIFACTS] : []),
		...(on.listed && on.servers ? [SERVERS] : []),
		// The panel draws the board itself, under its text box.
		...(!on.listed && !on.embedded ? [BOARD, REQUESTS] : [])
	];
}
