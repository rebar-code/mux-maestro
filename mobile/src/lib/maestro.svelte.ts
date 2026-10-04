import { tick } from 'svelte';
import { pushState } from '$app/navigation';
import { page } from '$app/state';
import { ui } from './gestures.svelte';
import { can } from './live.svelte';
import { manager } from './manager.svelte';
import { nextStop, panelHeight, panelStops, settlePanel, type PanelStop } from './panel';
import { Reply } from './reply.svelte';

const SLOP = 10;

/**
 * The Maestro panel: a sheet that drops from the top edge over any page, with
 * the Maestro's chat and text box in it. One state for every page, so the
 * panel a jump closes opens again at the stop it was on.
 */
class Maestro {
	stop = $state<PanelStop>(0);
	/** How far below its stop a finger holds the panel, in pixels. */
	down = $state(0);
	dragging = $state(false);
	/** The panel's content is drawn: from the first pull until it has closed. */
	shown = $state(false);
	/** The height the app has, and what the panel always draws (head, text box, grabber). */
	viewport = $state(667);
	chrome = $state(170);
	/** The Maestro's thread shows its terminal, not its chat: here and on the home page. */
	terminal = $state(false);
	/** The user came to this page by a jump: the way back is pointed out once. */
	jumped = $state(false);
	/** The stop the button opens the panel at: the one it was last on. */
	private last: PanelStop = 1;
	/** The page a jump is on its way to. */
	private to: string | null = null;
	/** Where a jump left from, and the stop the panel had: Back opens it there again. */
	private from: { path: string; stop: PanelStop } | null = null;

	readonly heights = $derived(panelStops(this.viewport, this.chrome));
	readonly height = $derived(panelHeight(this.heights, this.stop, this.down));

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
		manager.target
	);

	get open(): boolean {
		return this.stop > 0;
	}

	/** The panel, to move the focus into it. */
	private node: HTMLElement | null = null;
	/** What had the focus when the panel opened: it gets it back. */
	private focused: HTMLElement | null = null;
	/** The panel has its own history entry: Back closes the panel, not the page. */
	private entry = false;

	/**
	 * Move to a stop. `how` is what closes it: a control (`ui`, the entry is
	 * taken back), the browser's Back (`back`, it is gone already), or a link
	 * that leaves from it (`forward`, the entry stays behind the new page).
	 */
	private go(stop: PanelStop, how: 'ui' | 'back' | 'forward' = 'ui'): void {
		const was = this.stop;
		if (stop > 0) {
			this.shown = true;
			this.last = stop;
			this.jumped = false;
			if (!this.entry) {
				pushState('', { maestro: true });
				this.entry = true;
			}
			if (was === 0) {
				this.focused =
					document.activeElement instanceof HTMLElement ? document.activeElement : null;
				void tick().then(() => this.node?.focus({ preventScroll: true }));
			}
		} else {
			// Nothing animates or nothing is left to: no transition ends, so the content goes now.
			if (still() || this.height < 1) this.shown = false;
			if (this.entry) {
				this.entry = false;
				if (how === 'ui') history.back();
			}
			// After the page under the panel is in use again: it takes no focus while it is inert.
			const focused = this.focused;
			if (was > 0 && how !== 'forward' && focused) {
				void tick().then(() => focused.isConnected && focused.focus({ preventScroll: true }));
			}
			this.focused = null;
		}
		this.stop = stop;
		this.down = 0;
	}

	/**
	 * The header button: open at the stop it was last on, or close. The home
	 * page is the Maestro's own page: there the button goes to the page's text box.
	 */
	toggle = (): void => {
		if (!can('manager')) return;
		if (onHome()) {
			const box = document.querySelector<HTMLElement>('[data-foot] textarea');
			box?.scrollIntoView({ block: 'nearest' });
			box?.focus();
			return;
		}
		this.go(this.open ? 0 : this.last);
	};

	close = (): void => this.go(0);

	/** A long press on a session's Talk button: the peek, in reach of a thumb. */
	peek = (): void => {
		if (can('manager') && !onHome() && !this.open) this.go(1);
	};

	/** The way back after a jump: the panel, at the stop it was last on. */
	back = (): void => {
		if (can('manager')) this.go(this.last);
	};

	/** The grabber's tap: one stop down, and from full back to the peek. */
	step = (): void => this.go(nextStop(this.stop));

	/** The close animation is over. */
	settled = (): void => {
		if (this.stop === 0 && !this.dragging) this.shown = false;
	};

	/**
	 * A Go control was tapped: the link it is on opens the session. The panel
	 * closes, and the session's page shows the way back.
	 */
	jump = (href: string): void => {
		const here = location.pathname;
		const to = decodeURI(href);
		if (to === decodeURI(here)) return this.go(0);
		const stop = this.stop;
		this.go(0, 'forward');
		this.from = { path: here, stop };
		this.to = to;
	};

	/** The way back was dismissed. */
	seen = (): void => {
		this.jumped = false;
	};

	/**
	 * A navigation ended. The page a jump opened shows the way back. Back to
	 * the page a jump left from opens the panel there again.
	 */
	arrived = (type: string, path: string): void => {
		const to = this.to;
		this.to = null;
		if (to !== null && decodeURI(path) === to) {
			this.jumped = true;
			return;
		}
		this.jumped = false;
		const from = this.from;
		this.from = null;
		// A link in the sidebar left from an open panel: it stays behind.
		if (this.open) this.go(0, 'forward');
		if (type === 'popstate' && from && from.path === path && from.stop > 0 && can('manager')) {
			// The entry Back came to is the one the panel had.
			this.entry = true;
			this.go(from.stop);
		}
	};

	/** Attachment for the panel: its stops follow the room the app has. */
	measure = (node: HTMLElement): (() => void) => {
		const app = node.parentElement ?? node;
		this.node = node;
		const fit = (): void => {
			this.viewport = app.clientHeight;
			const fixed = [...node.querySelectorAll<HTMLElement>('[data-panel-chrome]')];
			if (fixed.length) this.chrome = fixed.reduce((sum, el) => sum + el.offsetHeight, 0);
		};
		const observer = new ResizeObserver(fit);
		observer.observe(app);
		for (const el of node.querySelectorAll('[data-panel-chrome]')) observer.observe(el);
		fit();
		return () => {
			observer.disconnect();
			this.node = null;
		};
	};

	/**
	 * Attachment for the app root: a vertical drag that begins on a
	 * `data-maestro-grab` element moves the panel. Those are the page headers,
	 * the header button, and the panel's own head and grabber: none of them
	 * scrolls, so the drag takes nothing from a scroller.
	 */
	drag = (node: HTMLElement): (() => void) => {
		let start: { id: number; x: number; y: number } | null = null;
		let active = false;
		let base = 0;
		let lastY = 0;
		let lastT = 0;
		let vy = 0;
		let suppressClick = false;

		const onDown = (event: PointerEvent): void => {
			suppressClick = false;
			start = null;
			active = false;
			const target = event.target as Element;
			if (!event.isPrimary || (event.pointerType === 'mouse' && event.button !== 0)) return;
			if (!can('manager') || ui.drawer > 0 || onHome()) return;
			if (!target.closest('[data-maestro-grab]') || target.closest('input, textarea')) return;
			start = { id: event.pointerId, x: event.clientX, y: event.clientY };
			lastY = event.clientY;
			lastT = event.timeStamp;
			vy = 0;
		};

		const onMove = (event: PointerEvent): void => {
			if (!start || event.pointerId !== start.id) return;
			const dx = event.clientX - start.x;
			const dy = event.clientY - start.y;
			if (!active) {
				if (Math.max(Math.abs(dx), Math.abs(dy)) < SLOP) return;
				// Sideways is the sidebar's; up on a closed panel is nothing.
				if (Math.abs(dx) >= Math.abs(dy) || (this.stop === 0 && dy < 0)) {
					start = null;
					return;
				}
				active = true;
				base = dy;
				node.setPointerCapture(start.id);
				this.shown = true;
				this.dragging = true;
			}
			const dt = event.timeStamp - lastT;
			if (dt > 0) vy = 0.7 * ((event.clientY - lastY) / dt) + 0.3 * vy;
			lastY = event.clientY;
			lastT = event.timeStamp;
			this.down = dy - base;
		};

		const onEnd = (event: PointerEvent): void => {
			if (!start || event.pointerId !== start.id) return;
			start = null;
			if (!active) return;
			active = false;
			const stale = event.type === 'pointercancel' || event.timeStamp - lastT > 80;
			const stop = settlePanel(this.heights, this.stop, this.down, stale ? 0 : vy);
			this.dragging = false;
			this.go(stop);
			suppressClick = true;
		};

		// A drag that ends on the button or the grabber must not also tap it.
		const onClick = (event: MouseEvent): void => {
			if (!suppressClick) return;
			suppressClick = false;
			event.preventDefault();
			event.stopPropagation();
		};

		const onKey = (event: KeyboardEvent): void => {
			if (event.key !== 'Escape' || !this.open || ui.drawer > 0) return;
			event.preventDefault();
			this.go(0);
		};
		// The browser's Back took the panel's entry: the panel closes, the page stays.
		const onPop = (): void => {
			if (this.entry && this.open) this.go(0, 'back');
		};

		window.addEventListener('keydown', onKey);
		window.addEventListener('popstate', onPop);
		node.addEventListener('pointerdown', onDown);
		node.addEventListener('pointermove', onMove);
		node.addEventListener('pointerup', onEnd);
		node.addEventListener('pointercancel', onEnd);
		node.addEventListener('click', onClick, true);
		return () => {
			window.removeEventListener('keydown', onKey);
			window.removeEventListener('popstate', onPop);
			node.removeEventListener('pointerdown', onDown);
			node.removeEventListener('pointermove', onMove);
			node.removeEventListener('pointerup', onEnd);
			node.removeEventListener('pointercancel', onEnd);
			node.removeEventListener('click', onClick, true);
		};
	};
}

/** The home page is the Maestro's own page: no panel opens over it. */
function onHome(): boolean {
	return page.route.id === '/';
}

function still(): boolean {
	return matchMedia('(prefers-reduced-motion: reduce)').matches;
}

export const maestro = new Maestro();
