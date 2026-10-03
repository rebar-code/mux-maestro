import { tick, untrack } from 'svelte';
import { ApiError, fetchChat, fetchScreen } from './api';
import { live } from './live.svelte';
import type { ChatMessage } from './types';

export type Mode = 'chat' | 'terminal';

const POLL_MS = 3000;
/** Within this many pixels of the end counts as "reading the newest". */
const STICK = 80;

/** One open thread's chat and terminal text, loaded and kept current. */
export class ThreadFeed {
	messages = $state.raw<ChatMessage[] | null>(null);
	screen = $state<string | null>(null);
	/** The server no longer knows this thread. */
	gone = $state(false);

	private next: number | undefined;
	private scrollers: Partial<Record<Mode, HTMLElement>> = {};
	private loading: Partial<Record<Mode, boolean>> = {};

	constructor(readonly id: string) {}

	/** Attachment for the element that scrolls `mode`'s content. */
	scroller(mode: Mode): (node: HTMLElement) => () => void {
		return (node) => {
			this.scrollers[mode] = node;
			node.scrollTop = node.scrollHeight;
			return () => {
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

	load = async (mode: Mode): Promise<void> => {
		if (this.loading[mode]) return;
		this.loading[mode] = true;
		try {
			if (mode === 'chat') await this.loadChat();
			else await this.loadScreen();
			this.gone = false;
		} catch (error) {
			if (error instanceof ApiError && error.status === 404) this.gone = true;
			live.fail(error);
		} finally {
			this.loading[mode] = false;
		}
	};

	private async loadChat(): Promise<void> {
		const page = await fetchChat(this.id, this.next);
		const first = this.messages === null;
		this.next = page.next;
		if (!first && !page.reset && page.messages.length === 0) return;
		await this.keepEnd('chat', first, () => {
			this.messages =
				page.reset || first ? page.messages : [...(this.messages ?? []), ...page.messages];
		});
	}

	private async loadScreen(): Promise<void> {
		const text = (await fetchScreen(this.id)).replace(/\s+$/, '');
		if (text === this.screen) return;
		await this.keepEnd('terminal', this.screen === null, () => (this.screen = text));
	}

	/** Apply `change`; stay at the end if the reader was there (or on first load). */
	private async keepEnd(mode: Mode, force: boolean, change: () => void): Promise<void> {
		const before = this.scrollers[mode];
		const atEnd =
			force || !before || before.scrollHeight - before.scrollTop - before.clientHeight < STICK;
		change();
		await tick();
		const el = this.scrollers[mode];
		if (atEnd && el) el.scrollTop = el.scrollHeight;
	}
}
