import type { Terminal } from '@xterm/xterm';
import { untrack } from 'svelte';
import { openTerminal } from './api';
import { barKeyText, messages, Pacer, typed } from './livekeys';
import { isReport, silenceQueries } from './livequiet';
import {
	fit,
	followTop,
	isFollowing,
	place,
	totalHeight,
	wheelSteps,
	wheelText,
	type Geometry
} from './livescroll';
import { afterClose, closeLabel, serverMessage, type LiveState } from './livesocket';
import type { BarKey, KeySink } from './reply';
import { DEFAULT_SIZE } from './textsize';

const KEY = 'mm.live';
const FONT = 'ui-monospace, SFMono-Regular, Menlo, monospace';
const SCROLLBACK = 5000;
/** The terminal's own padding, left and right together. */
const PAD = 24;
/** A drag is the terminal's once it has gone this far, more down than sideways. */
const SLOP = 8;
/** The wait after the view changed before the pane is asked to follow. */
const FIT_MS = 150;

function stored(): boolean {
	try {
		return localStorage.getItem(KEY) !== '0';
	} catch {
		return true;
	}
}

/**
 * One thread's live terminal: xterm.js over a socket to the pane on the Mac.
 * What is typed goes straight to the pane. The phone says the size it has room
 * for and the pane takes it while this terminal is open; the terminal always
 * has the pane's own size, and the page scrolls over what does not fit.
 */
export class LiveTerm implements KeySink {
	state = $state<LiveState>('off');
	/** Live mode is switched on, on this device. */
	wanted = $state(stored());
	/** The socket gave up: the captured view shows until live is asked for again. */
	failed = $state(false);
	/** Why it gave up, when that is worth a label. */
	note = $state<string | null>(null);
	/** The pane's screen is drawn: the terminal takes the captured view's place. */
	shown = $state(false);
	/** The view keeps to the cursor as output comes. */
	following = $state(true);
	/** Sticky Ctrl is on: the next key typed is its control character. */
	ctrl = $state(false);

	private term: Terminal | null = null;
	private socket: WebSocket | null = null;
	private size = DEFAULT_SIZE;
	private sync: ((follow?: boolean) => void) | null = null;
	private fitSoon: (() => void) | null = null;

	/** What is typed, on its way out: a long paste goes a lot at a time. */
	private readonly pacer = new Pacer<Uint8Array<ArrayBuffer>>((message) => {
		const socket = this.socket;
		if (socket && socket.readyState === WebSocket.OPEN) socket.send(message);
	});

	constructor(private readonly id: string) {}

	/** Live mode is on and has not given up: the terminal is mounted. */
	get active(): boolean {
		return this.wanted && !this.failed;
	}

	/** The switch on the terminal page. */
	toggle = (): void => {
		this.wanted = !this.active;
		this.failed = false;
		this.note = null;
		try {
			localStorage.setItem(KEY, this.wanted ? '1' : '0');
		} catch {
			// Storage is full or blocked: the choice lasts for this visit only.
		}
	};

	focus = (): void => this.term?.focus();

	jump = (): void => {
		this.following = true;
		this.sync?.(true);
	};

	/** A phone cannot paste into the terminal by itself: the key bar has a key for it. */
	readonly pastes = true;

	/** A key of the key bar was tapped. */
	tap = (key: BarKey): void => {
		if (key.paste) return void this.paste();
		if (key.ctrl) {
			this.ctrl = !this.ctrl;
			return;
		}
		const text = barKeyText(key, this.term?.modes.applicationCursorKeysMode ?? false);
		if (text !== null) this.type(text);
	};

	/** Type the phone's clipboard, as a paste: a program that asks for the marks gets them. */
	private async paste(): Promise<void> {
		let text = '';
		try {
			text = await navigator.clipboard.readText();
		} catch {
			// The phone refused, or the tap on its Paste prompt never came.
		}
		if (text) this.term?.paste(text);
	}

	/** Send what was typed, with sticky Ctrl applied. Ctrl holds for one key. */
	private type(text: string): void {
		const out = typed(text, this.ctrl);
		this.ctrl = false;
		const socket = this.socket;
		if (!socket || socket.readyState !== WebSocket.OPEN || this.state !== 'live') return;
		this.pacer.push(messages(out));
		this.jump();
	}

	/** Attachment: the text size, applied without making the terminal again. */
	sized(size: number): () => void {
		return () =>
			untrack(() => {
				this.size = size;
				if (!this.term || this.term.options.fontSize === size) return;
				this.term.options.fontSize = size;
				this.sync?.();
				this.fitSoon?.();
			});
	}

	/** Attachment for the scrolling box: the terminal and its socket live as long as it. */
	mount = (scroller: HTMLElement): (() => void) =>
		untrack(() => {
			const box = scroller.querySelector<HTMLElement>('[data-box]')!;
			const pin = scroller.querySelector<HTMLElement>('[data-pin]')!;
			const host = scroller.querySelector<HTMLElement>('[data-term]')!;
			let disposed = false;
			let timer: ReturnType<typeof setTimeout> | undefined;
			let tries = 0;
			let busy = false;

			const geometry = (term: Terminal): Geometry => {
				const screen = host.querySelector<HTMLElement>('.xterm-screen');
				const height = screen?.getBoundingClientRect().height ?? 0;
				return {
					base: term.buffer.active.baseY,
					rows: term.rows,
					cell: height / term.rows,
					view: scroller.clientHeight
				};
			};

			// The page's scroll position decides what the terminal shows.
			const sync = (follow = this.following): void => {
				const term = this.term;
				if (!term || busy) return;
				busy = true;
				const g = geometry(term);
				const cursor = term.buffer.active.cursorY;
				box.style.height = `${totalHeight(g)}px`;
				pin.style.height = `${g.view}px`;
				if (follow) scroller.scrollTop = followTop(g, cursor);
				const { line, shift } = place(scroller.scrollTop, g);
				if (term.buffer.active.viewportY !== line) term.scrollToLine(line);
				host.style.transform = `translate3d(0, ${-shift}px, 0)`;
				const following = isFollowing(scroller.scrollTop, g, cursor);
				if (following !== this.following) this.following = following;
				busy = false;
			};
			this.sync = sync;

			// The size this view has room for, said to the Mac: the pane takes it.
			let fitTimer: ReturnType<typeof setTimeout> | undefined;
			let asked = '';
			const cells = (term: Terminal): { width: number; height: number } => {
				const screen = host.querySelector<HTMLElement>('.xterm-screen')?.getBoundingClientRect();
				return {
					width: (screen?.width ?? 0) / term.cols,
					height: (screen?.height ?? 0) / term.rows
				};
			};
			const sendSize = (): void => {
				const term = this.term;
				const socket = this.socket;
				if (!term || !socket || socket.readyState !== WebSocket.OPEN) return;
				if (this.state !== 'live') return;
				// Asked once for each view and text size: the pane's answer changes
				// neither, so the phone never asks twice or fights the Mac for it.
				const view = { width: scroller.clientWidth - PAD, height: scroller.clientHeight };
				const key = `${view.width}x${view.height}@${term.options.fontSize}`;
				if (key === asked) return;
				const size = fit(view, cells(term));
				if (!size) return;
				asked = key;
				socket.send(JSON.stringify({ type: 'size', ...size }));
			};
			const fitSoon = (): void => {
				clearTimeout(fitTimer);
				fitTimer = setTimeout(sendSize, FIT_MS);
			};
			this.fitSoon = fitSoon;

			// A program on the alternate screen scrolls itself: a drag up or
			// down over it becomes wheel reports, or arrow keys, for the program.
			let sgr = false;
			let touch: { x: number; y: number; rest: number; mine: boolean | null } | null = null;
			const onTouchStart = (event: TouchEvent): void => {
				const first = event.touches[0];
				touch =
					event.touches.length === 1
						? { x: first.clientX, y: first.clientY, rest: 0, mine: null }
						: null;
			};
			const onTouchMove = (event: TouchEvent): void => {
				const term = this.term;
				if (!touch || !term || event.touches.length !== 1) return;
				if (term.buffer.active.type !== 'alternate' || this.state !== 'live') return;
				const { clientX, clientY } = event.touches[0];
				if (touch.mine === null) {
					const dx = Math.abs(clientX - touch.x);
					const dy = Math.abs(clientY - touch.y);
					if (Math.max(dx, dy) < SLOP) return;
					touch.mine = dy > dx;
					touch.y = clientY;
				}
				if (!touch.mine) return;
				if (event.cancelable) event.preventDefault();
				const cell = cells(term);
				const { steps, rest } = wheelSteps(touch.rest, clientY - touch.y, cell.height);
				touch.y = clientY;
				touch.rest = rest;
				if (steps === 0) return;
				const screen = host.querySelector<HTMLElement>('.xterm-screen')?.getBoundingClientRect();
				const at = {
					col: Math.min(((clientX - (screen?.left ?? 0)) / cell.width || 0) + 1, term.cols),
					row: Math.min(((clientY - (screen?.top ?? 0)) / cell.height || 0) + 1, term.rows)
				};
				const mode = {
					mouse: sgr && term.modes.mouseTrackingMode !== 'none',
					application: term.modes.applicationCursorKeysMode
				};
				const socket = this.socket;
				if (socket && socket.readyState === WebSocket.OPEN)
					this.pacer.push(messages(wheelText(steps, mode, at)));
			};
			const onTouchEnd = (): void => {
				touch = null;
			};

			const stop = (): void => {
				clearTimeout(timer);
				clearTimeout(fitTimer);
				const socket = this.socket;
				this.socket = null;
				this.pacer.clear();
				socket?.close();
			};

			const connect = (): void => {
				if (disposed || !this.term || document.hidden) return;
				const term = this.term;
				this.state = this.shown ? 'reconnecting' : 'connecting';
				const socket = openTerminal(this.id);
				this.socket = socket;
				let ready = false;
				socket.addEventListener('message', (event: MessageEvent) => {
					if (socket !== this.socket) return;
					if (typeof event.data !== 'string') {
						// The pane's bytes: for the terminal, and for nothing else.
						if (ready) term.write(new Uint8Array(event.data as ArrayBuffer));
						return;
					}
					const message = serverMessage(event.data);
					if (!message) return;
					if (message.type === 'ready') {
						term.reset();
						sgr = false;
						asked = '';
						ready = true;
						tries = 0;
						this.state = 'live';
						this.shown = true;
						this.following = true;
					}
					term.resize(message.cols, message.rows);
					sync();
					// Not at once: the view is laid out anew when the first screen shows.
					if (message.type === 'ready') fitSoon();
				});
				socket.addEventListener('close', (event: CloseEvent) => {
					if (socket !== this.socket || disposed) return;
					this.socket = null;
					this.pacer.clear();
					const next = afterClose(event.code, tries);
					if ('stop' in next) {
						this.note = closeLabel(event.code);
						this.failed = true;
						return;
					}
					tries += 1;
					this.state = this.shown ? 'reconnecting' : 'connecting';
					timer = setTimeout(connect, next.retry);
				});
			};

			// A page that is not on screen holds no keyboard on a pane.
			const onVisibility = (): void => {
				stop();
				if (document.hidden) {
					if (this.state === 'live') this.state = 'reconnecting';
					return;
				}
				tries = 0;
				connect();
			};
			const onScroll = (): void => sync(false);
			// A focused text box can scroll the box it is in: keep that one still.
			const onPinScroll = (): void => {
				if (pin.scrollTop !== 0) pin.scrollTop = 0;
			};

			void import('@xterm/xterm').then(({ Terminal }) => {
				if (disposed) return;
				const term = new Terminal({
					cols: 80,
					rows: 24,
					fontSize: this.size,
					fontFamily: FONT,
					lineHeight: 1.2,
					scrollback: SCROLLBACK,
					cursorBlink: false,
					scrollOnUserInput: false,
					theme: { background: '#0a0a0a', foreground: '#cfcfcf' }
				});
				term.open(host);
				this.term = term;
				// Only the keyboard types. The terminal answers no question from
				// the pane, so nothing the pane prints comes back as a key press.
				silenceQueries(term.parser);
				// Whether the program wants its mouse reports in the SGR form:
				// the terminal does not say, so the mode is watched as it is set.
				const watch = (on: boolean) => (params: (number | number[])[]) => {
					if (params.includes(1006)) sgr = on;
					return false;
				};
				term.parser.registerCsiHandler({ prefix: '?', final: 'h' }, watch(true));
				term.parser.registerCsiHandler({ prefix: '?', final: 'l' }, watch(false));
				term.onData((data) => {
					if (!isReport(data)) this.type(data);
				});
				term.onWriteParsed(() => sync());
				term.onResize(() => sync());
				connect();
			});

			// The view changed: a turn of the phone, or the keyboard coming or going.
			const resized = new ResizeObserver(() => {
				sync();
				fitSoon();
			});
			resized.observe(scroller);
			scroller.addEventListener('touchstart', onTouchStart, { passive: true });
			scroller.addEventListener('touchmove', onTouchMove, { passive: false });
			scroller.addEventListener('touchend', onTouchEnd, { passive: true });
			scroller.addEventListener('touchcancel', onTouchEnd, { passive: true });
			scroller.addEventListener('scroll', onScroll, { passive: true });
			pin.addEventListener('scroll', onPinScroll, { passive: true });
			document.addEventListener('visibilitychange', onVisibility);

			return () => {
				disposed = true;
				stop();
				resized.disconnect();
				scroller.removeEventListener('scroll', onScroll);
				scroller.removeEventListener('touchstart', onTouchStart);
				scroller.removeEventListener('touchmove', onTouchMove);
				scroller.removeEventListener('touchend', onTouchEnd);
				scroller.removeEventListener('touchcancel', onTouchEnd);
				pin.removeEventListener('scroll', onPinScroll);
				document.removeEventListener('visibilitychange', onVisibility);
				this.term?.dispose();
				this.term = null;
				this.sync = null;
				this.fitSoon = null;
				this.state = 'off';
				this.shown = false;
				this.ctrl = false;
			};
		});
}
