import type { AfterNavigate } from '@sveltejs/kit';
import { goto } from '$app/navigation';
import { resolve } from '$app/paths';
import { page } from '$app/state';
import { can } from './live.svelte';
import { manager } from './manager.svelte';
import { Reply } from './reply.svelte';

/**
 * The Maestro's screen is the home page: the sidebar and the header button
 * open the same one. This is what the button needs to know of it: whether it
 * is open over another page, and the way back to that page.
 */
class Maestro {
	/** The Maestro's thread shows its terminal, not its chat. */
	terminal = $state(false);
	/** The user came to this page by a jump: the way back is pointed out once. */
	jumped = $state(false);
	/** The page that was open before the Maestro's: the button goes back to it. */
	private last = $state<string | null>(null);
	/** That page is the entry before this one: the browser's Back is the way to it. */
	private behind = false;
	/** The page a jump is on its way to. */
	private to: string | null = null;

	/** The Maestro pane's prompts and keys. Its text goes through the Maestro's own turn. */
	readonly reply = new Reply(
		'manager',
		{
			refresh: () => {
				// An answer or a key can end the wait: the pane's status is read again too.
				void manager.load();
				return manager.feed.load(this.terminal ? 'terminal' : 'chat');
			},
			// A card that comes up is what the human has to act on: it is brought into view.
			stick: (change, appeared) =>
				manager.feed.keepEnd(this.terminal ? 'terminal' : 'chat', appeared, change),
			terminal: () => this.terminal
		},
		manager.target,
		// A file's path goes into the Maestro's own text box.
		manager.files
	);

	/** The Maestro's screen is open, and there is a page to go back to. */
	get open(): boolean {
		return onHome() && this.last !== null;
	}

	/**
	 * The header button: open the Maestro's screen, or go back to the page it
	 * was opened from. With no such page the button goes to the text box.
	 */
	toggle = (): void => {
		if (!can('manager')) return;
		if (!onHome()) return this.show();
		if (this.last === null) {
			const box = document.querySelector<HTMLElement>('[data-foot] textarea');
			box?.scrollIntoView({ block: 'nearest' });
			box?.focus();
		} else if (this.behind) history.back();
		// A path the router gave: it has the base already.
		// eslint-disable-next-line svelte/no-navigation-without-resolve
		else void goto(this.last);
	};

	/** Open the Maestro's screen: the way back after a jump, and a long press on Talk. */
	show = (): void => {
		if (can('manager') && !onHome()) void goto(resolve('/'));
	};

	/** A Go control was tapped: the session's page shows the way back. */
	jump = (href: string): void => {
		const to = decodeURI(href);
		this.to = to === decodeURI(location.pathname) ? null : to;
	};

	/** The way back was dismissed. */
	seen = (): void => {
		this.jumped = false;
	};

	/** A navigation ended. The page a jump opened shows the way back. */
	arrived = ({ type, from, to }: AfterNavigate): void => {
		const path = to?.url.pathname ?? location.pathname;
		const jump = this.to;
		this.to = null;
		this.jumped = jump !== null && decodeURI(path) === jump;
		if (to?.route.id !== '/') {
			this.last = path;
			this.behind = false;
			return;
		}
		// A link or the button opened it from another page: that page is one Back away.
		this.behind = (type === 'link' || type === 'goto') && from !== null && from.route.id !== '/';
	};
}

/** The home page is the Maestro's own page. */
function onHome(): boolean {
	return page.route.id === '/';
}

export const maestro = new Maestro();
