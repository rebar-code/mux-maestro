import { tick } from 'svelte';
import { ApiError, fetchFind } from './api';
import { chatHits, countLabel, step, terminalHits, type Hit } from './find';
import { live } from './live.svelte';
import { chatText } from './markdown';
import type { Mode } from './thread.svelte';
import type { ChatMessage, FindResult } from './types';

/** An assistant row is drawn as markdown: a find looks in what it shows. */
const shown = (message: ChatMessage): string =>
	message.role === 'assistant' ? chatText(message.text) : message.text;

const DEBOUNCE_MS = 250;
/** The Mac runs few finds at once: a refused one is asked again, this often. */
const BUSY_RETRY_MS = 300;
const BUSY_TRIES = 6;
export const QUERY_MAX = 200;

/**
 * Find in one open thread. The chat is searched here, in the rows the phone
 * holds; the terminal is searched on the Mac, in the pane's scrollback.
 */
export class Find {
	open = $state(false);
	query = $state('');
	/** The hit that is shown, counted through the view. */
	index = $state(0);
	/** The Mac's answer for the terminal; null until there is one. */
	result = $state.raw<FindResult | null>(null);

	private timer: ReturnType<typeof setTimeout> | null = null;
	private asking: AbortController | null = null;

	readonly chat: { byRow: Map<number, Hit[]>; count: number };
	readonly terminal: Hit[];
	readonly count: number;
	/** The shown hit, kept inside the list when the list gets shorter. */
	readonly current: number;
	readonly label: string;

	constructor(
		readonly id: string,
		messages: () => ChatMessage[],
		private readonly mode: () => Mode
	) {
		this.chat = $derived(chatHits(this.open ? messages() : [], this.query, shown));
		this.terminal = $derived(
			this.result ? terminalHits(this.result.text, this.result.matches) : []
		);
		this.count = $derived(mode() === 'chat' ? this.chat.count : this.terminal.length);
		this.current = $derived(Math.min(this.index, Math.max(this.count - 1, 0)));
		this.label = $derived(
			countLabel(
				this.current,
				this.count,
				mode() === 'terminal' && (this.result?.truncated ?? false)
			)
		);
	}

	toggle = (): void => {
		if (this.open) return this.close();
		this.open = true;
		if (this.query.trim()) this.switched(this.mode());
	};

	close = (): void => {
		this.open = false;
		this.cancel();
		this.result = null;
		this.index = 0;
	};

	/** The query changed: search again, once the typing pauses. */
	typed = (): void => {
		this.index = 0;
		this.cancel();
		if (this.mode() === 'chat') return void this.reveal();
		this.timer = setTimeout(() => void this.search(), DEBOUNCE_MS);
	};

	/** The view switched between chat and terminal with the bar open. */
	switched = (mode: Mode): void => {
		this.index = 0;
		this.cancel();
		if (mode === 'terminal') void this.search();
		else void this.reveal();
	};

	next = (): void => this.move(1);
	previous = (): void => this.move(-1);

	private move(delta: 1 | -1): void {
		this.index = step(this.current, this.count, delta);
		void this.reveal();
	}

	private cancel(): void {
		if (this.timer) clearTimeout(this.timer);
		this.timer = null;
		this.asking?.abort();
		this.asking = null;
	}

	private async search(tries = BUSY_TRIES): Promise<void> {
		const query = this.query.trim();
		if (!query) {
			this.result = null;
			return;
		}
		const asking = new AbortController();
		this.asking = asking;
		try {
			const result = await fetchFind(this.id, query, asking.signal);
			if (asking.signal.aborted) return;
			this.result = result;
			// The newest match is the one nearest to what the pane shows now.
			this.index = Math.max(this.terminal.length - 1, 0);
			await this.reveal();
		} catch (error) {
			if (asking.signal.aborted) return;
			if (error instanceof ApiError && error.code === 'busy' && tries > 1) {
				this.timer = setTimeout(() => void this.search(tries - 1), BUSY_RETRY_MS);
				return;
			}
			this.result = null;
			live.fail(error);
		}
	}

	/** Scroll the shown hit into view, once it is drawn. */
	private async reveal(): Promise<void> {
		await tick();
		document
			.querySelector('[data-find-current]')
			?.scrollIntoView({ block: 'center', inline: 'nearest' });
	}
}
