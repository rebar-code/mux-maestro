import type { Terminal } from '@xterm/xterm';
import { untrack } from 'svelte';
import { openTerminal } from './api';
import { barKeyText, messages, typed } from './livekeys';
import { followTop, isFollowing, place, totalHeight, type Geometry } from './livescroll';
import { afterClose, serverMessage, type LiveState } from './livesocket';
import type { BarKey, KeySink } from './reply';
import { DEFAULT_SIZE } from './textsize';

const KEY = 'mm.live';
const FONT = 'ui-monospace, SFMono-Regular, Menlo, monospace';
const SCROLLBACK = 5000;

function stored(): boolean {
	try {
		return localStorage.getItem(KEY) !== '0';
	} catch {
		return true;
	}
}

/**
 * One thread's live terminal: xterm.js over a socket to the pane on the Mac.
 * What is typed goes straight to the pane. The terminal has the pane's own
 * size and is never fitted to the phone: the page scrolls over it instead.
 */
export class LiveTerm implements KeySink {
	state = $state<LiveState>('off');
	/** Live mode is switched on, on this device. */
	wanted = $state(stored());
	/** The socket gave up: the captured view shows until live is asked for again. */
	failed = $state(false);
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

	constructor(private readonly id: string) {}

	/** Live mode is on and has not given up: the terminal is mounted. */
	get active(): boolean {
		return this.wanted && !this.failed;
	}

	/** The switch on the terminal page. */
	toggle = (): void => {
		this.wanted = !this.active;
		this.failed = false;
		try {
			localStorage.setItem(KEY, this.wanted ? '1' : '0');
		} catch {
			// Storage is full or blocked: the choice lasts for this visit only.
		}
	};

	/** What the key bar's hide-keyboard button blurs. */
	get input(): { blur(): void } | null {
		return this.term;
	}

	focus = (): void => this.term?.focus();

	jump = (): void => {
		this.following = true;
		this.sync?.(true);
	};

	/** A key of the key bar was tapped. */
	tap = (key: BarKey): void => {
		if (key.ctrl) {
			this.ctrl = !this.ctrl;
			return;
		}
		const text = barKeyText(key, this.term?.modes.applicationCursorKeysMode ?? false);
		if (text !== null) this.type(text);
	};

	/** Send what was typed, with sticky Ctrl applied. Ctrl holds for one key. */
	private type(text: string): void {
		const out = typed(text, this.ctrl);
		this.ctrl = false;
		const socket = this.socket;
		if (!socket || socket.readyState !== WebSocket.OPEN || this.state !== 'live') return;
		for (const message of messages(out)) socket.send(message);
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

			const stop = (): void => {
				clearTimeout(timer);
				const socket = this.socket;
				this.socket = null;
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
						ready = true;
						tries = 0;
						this.state = 'live';
						this.shown = true;
						this.following = true;
					}
					term.resize(message.cols, message.rows);
					sync();
				});
				socket.addEventListener('close', (event: CloseEvent) => {
					if (socket !== this.socket || disposed) return;
					this.socket = null;
					const next = afterClose(event.code, tries);
					if ('stop' in next) {
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
				term.onData((data) => this.type(data));
				term.onWriteParsed(() => sync());
				term.onResize(() => sync());
				connect();
			});

			const resized = new ResizeObserver(() => sync());
			resized.observe(scroller);
			scroller.addEventListener('scroll', onScroll, { passive: true });
			pin.addEventListener('scroll', onPinScroll, { passive: true });
			document.addEventListener('visibilitychange', onVisibility);

			return () => {
				disposed = true;
				stop();
				resized.disconnect();
				scroller.removeEventListener('scroll', onScroll);
				pin.removeEventListener('scroll', onPinScroll);
				document.removeEventListener('visibilitychange', onVisibility);
				this.term?.dispose();
				this.term = null;
				this.sync = null;
				this.state = 'off';
				this.shown = false;
				this.ctrl = false;
			};
		});
}
