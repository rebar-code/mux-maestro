import { tick, untrack } from 'svelte';
import { ApiError, fetchChat, fetchScreen, threadPath } from './api';
import { live } from './live.svelte';
import { alignShift, hasOlder, rawLines, toBlocks, viewLines, type Block } from './terminal';
import type { ChatMessage } from './types';

export type Mode = 'chat' | 'terminal';

const POLL_MS = 3000;
/** Within this many pixels of the end counts as "reading the newest". */
const STICK = 80;
/** The terminal follows new output only from the very end. */
const AT_BOTTOM = 8;

/** The pane's text, parsed once per fetch and ready to draw. */
export interface Screen {
	blocks: Block[];
	/** The widest line, in characters. */
	cols: number;
	/** The pane may hold lines above these. */
	hasOlder: boolean;
}

/** One open thread's chat and terminal text, loaded and kept current. */
export class ThreadFeed {
	messages = $state.raw<ChatMessage[] | null>(null);
	screen = $state.raw<Screen | null>(null);
	/** The terminal shows its newest line. */
	atBottom = $state(true);
	loadingOlder = $state(false);
	/** The server no longer knows this thread. */
	gone = $state(false);

	private next: number | undefined;
	/** The chat has not been read from the server yet. */
	private unread = true;
	private scrollers: Partial<Record<Mode, HTMLElement>> = {};
	private inflight: Partial<Record<Mode, Promise<void>>> = {};
	/** The terminal text as last received, to line the next one up with. */
	private raw: string[] = [];
	/** The number of the first line, so a line keeps its number as others come and go. */
	private base = 0;
	private etag: string | null = null;
	private lines: number | undefined;
	private max = 0;
	private wantOlder = false;

	/** `path`: where the chat and screen are read from; a thread's own routes unless given. */
	constructor(
		readonly id: string,
		private readonly path: string = threadPath(id),
		/** Called when the chat changed, for an owner that keeps a copy. */
		private readonly onChat: () => void = () => {}
	) {}

	/** Rows kept from the last visit, shown until the server's replace them. */
	seed(messages: ChatMessage[]): void {
		if (this.unread && messages.length) this.messages = messages;
	}

	/** Attachment for the element that scrolls `mode`'s content. */
	scroller(mode: Mode): (node: HTMLElement) => () => void {
		return (node) => {
			this.scrollers[mode] = node;
			node.scrollTop = node.scrollHeight;
			const onScroll = (): void => {
				this.atBottom = atEnd(node, AT_BOTTOM);
			};
			if (mode === 'terminal') {
				this.atBottom = true;
				node.addEventListener('scroll', onScroll, { passive: true });
			}
			// When the view gets shorter (the footer rises, the keyboard opens), a
			// reader at the end stays at the end. Judged from the height it had
			// before, not from a scroll event, which may come a frame late.
			let height = node.clientHeight;
			const resized = new ResizeObserver(() => {
				const gap = node.scrollHeight - node.scrollTop - height;
				height = node.clientHeight;
				if (gap < (mode === 'chat' ? STICK : AT_BOTTOM)) node.scrollTop = node.scrollHeight;
			});
			resized.observe(node);
			return () => {
				resized.disconnect();
				node.removeEventListener('scroll', onScroll);
				if (this.scrollers[mode] === node) delete this.scrollers[mode];
			};
		};
	}

	/** Attachment: load `mode` now, then on a timer and on each list change. */
	watch(mode: Mode): () => () => void {
		return () =>
			untrack(() => {
				const load = (): void => void this.load(mode);
				load();
				const timer = setInterval(load, POLL_MS);
				let seen = JSON.stringify(live.byId(this.id));
				const off = live.onThreads(() => {
					const row = JSON.stringify(live.byId(this.id));
					if (row === seen) return;
					seen = row;
					load();
				});
				return () => {
					clearInterval(timer);
					off();
				};
			});
	}

	/** Load `mode`. While a load is under way, a second call joins it. */
	load = (mode: Mode): Promise<void> => {
		const running = this.inflight[mode];
		if (running) return running;
		const run = this.run(mode).finally(() => delete this.inflight[mode]);
		this.inflight[mode] = run;
		return run;
	};

	private async run(mode: Mode): Promise<void> {
		try {
			if (mode === 'chat') await this.loadChat();
			else await this.loadScreen();
			this.gone = false;
		} catch (error) {
			if (error instanceof ApiError && error.status === 404) this.gone = true;
			live.fail(error);
		}
	}

	/** Ask for twice as many lines of scrollback, up to the server's limit. */
	loadOlder = async (): Promise<void> => {
		if (this.loadingOlder) return;
		this.loadingOlder = true;
		this.wantOlder = true;
		try {
			// A load that began before this one did not ask for more: wait, then ask.
			await this.inflight.terminal;
			if (this.wantOlder) await this.load('terminal');
		} finally {
			this.loadingOlder = false;
		}
	};

	jumpToBottom = (): void => {
		const el = this.scrollers.terminal;
		if (!el) return;
		const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
		el.scrollTo({ top: el.scrollHeight, behavior: still ? 'auto' : 'smooth' });
	};

	private async loadChat(): Promise<void> {
		const page = await fetchChat(this.path, this.next);
		const first = this.unread;
		this.unread = false;
		this.next = page.next;
		if (!first && !page.reset && page.messages.length === 0) return;
		await this.keepEnd('chat', first, () => {
			this.messages =
				page.reset || first ? page.messages : [...(this.messages ?? []), ...page.messages];
		});
		this.onChat();
	}

	private async loadScreen(): Promise<void> {
		const older = this.wantOlder && this.lines !== undefined;
		this.wantOlder = false;
		const want = older ? Math.min((this.lines ?? 0) * 2, this.max) : this.lines;
		// Unchanged text comes back as null: nothing is parsed or drawn again.
		const page = await fetchScreen(this.path, want, older ? null : this.etag);
		if (page === null) return;

		const raw = rawLines(page.text);
		const first = this.screen === null;
		const shift = first ? 0 : alignShift(this.raw, raw);
		if (shift !== null) this.base -= shift;
		const { lines, cols } = viewLines(page.text, this.base);

		const before = this.scrollers.terminal;
		const follow = first || !before || (atEnd(before, AT_BOTTOM) && !older);
		const topBefore = before?.querySelector('[data-lines]')?.getBoundingClientRect().top;

		this.raw = raw;
		this.etag = page.etag;
		this.lines = page.lines;
		this.max = page.max;
		this.screen = {
			blocks: toBlocks(lines),
			cols,
			hasOlder: hasOlder(raw.length, page.lines, page.max)
		};
		await tick();

		const el = this.scrollers.terminal;
		if (!el) return;
		if (follow) {
			el.scrollTop = el.scrollHeight;
			return;
		}
		// Reading further up: keep the lines on screen where they are. Every line
		// is the same height, so a shift of whole lines is a known distance.
		const list = el.querySelector('[data-lines]');
		if (!list || topBefore === undefined || shift === null) return;
		const lineHeight = parseFloat(getComputedStyle(list).lineHeight);
		el.scrollTop += list.getBoundingClientRect().top - topBefore + shift * lineHeight;
	}

	/** Apply `change`; stay at the end if the reader was there (or on first load). */
	async keepEnd(mode: Mode, force: boolean, change: () => void): Promise<void> {
		const before = this.scrollers[mode];
		const atEnd =
			force || !before || before.scrollHeight - before.scrollTop - before.clientHeight < STICK;
		change();
		await tick();
		const el = this.scrollers[mode];
		if (atEnd && el) el.scrollTop = el.scrollHeight;
	}
}

function atEnd(el: HTMLElement, within: number): boolean {
	return el.scrollHeight - el.scrollTop - el.clientHeight < within;
}
