import { untrack } from 'svelte';
import { ApiError, dismissReview, fetchManager, MANAGER_PATH, sendManagerText } from './api';
import { live } from './live.svelte';
import { pendingPrompt } from './manager';
import { ThreadFeed } from './thread.svelte';
import type {
	ChatMessage,
	ManagerHome,
	ManagerItem,
	ManagerLive,
	ManagerStatus,
	ManagerTurn,
	ManagerUpdate
} from './types';

const KEY = 'mm.manager';
/** How often the home asks again: the pane's status has no event. */
const POLL_MS = 10_000;

const STATUS_NOTES: Partial<Record<ManagerStatus, string>> = {
	off: 'Manager is not running',
	unknown: 'Manager is not ready',
	waiting: 'Manager is waiting on a prompt',
	busy: 'Manager is busy'
};

/** How many chat rows are kept for the next visit's first paint. */
const KEEP = 30;

interface Cached {
	review: ManagerItem[];
	needsYou: ManagerItem[];
	chat?: ChatMessage[];
}

function cached(): Cached | null {
	try {
		const raw = localStorage.getItem(KEY);
		return raw ? (JSON.parse(raw) as Cached) : null;
	} catch {
		return null;
	}
}

/**
 * The manager home: the board's cards, the manager pane's thread and the turn
 * in flight. One manager pane, one conversation: a turn started on the Mac
 * shows here too.
 */
class Manager {
	private start = cached();
	/** `null`: nothing to show yet, draw skeleton cards. */
	review = $state.raw<ManagerItem[] | null>(this.start?.review ?? null);
	needsYou = $state.raw<ManagerItem[]>(this.start?.needsYou ?? []);
	updates = $state.raw<ManagerUpdate[]>([]);
	status = $state<ManagerStatus>('idle');
	turn = $state.raw<ManagerTurn | null>(null);
	/** The pane's own spinner line while a turn runs, when the Mac could read it. */
	spinner = $state<string | null>(null);
	/** When the turn in flight was first seen here, in epoch milliseconds. */
	turnSince = $state(0);
	/** What the last turn left to say: why it was refused, or that it waits. */
	note = $state<string | null>(null);
	/** The text box. A refused turn puts its text back here. */
	draft = $state('');
	/** This phone has a turn in flight. */
	sending = $state(false);

	/** The manager pane's chat and terminal, read like any thread's. */
	readonly feed = new ThreadFeed('manager', MANAGER_PATH, () => this.save());
	/** The last chat row there was when the turn began. */
	private turnBase = $state(-1);

	readonly busy: boolean = $derived(this.turn !== null);
	/** The turn's prompt, until the chat holds it. */
	readonly pending: string | null = $derived(
		pendingPrompt(this.turn?.prompt ?? null, this.feed.messages, this.turnBase)
	);
	/** What the pane is doing, when a message cannot go to it now. */
	readonly statusNote: string | null = $derived(
		this.turn === null ? (STATUS_NOTES[this.status] ?? null) : null
	);

	constructor() {
		this.feed.seed(this.start?.chat ?? []);
	}

	/** Review items dismissed here that the Mac has not dropped yet. */
	private dismissed = new Set<string>();
	private loading = false;

	private save(): void {
		try {
			localStorage.setItem(
				KEY,
				JSON.stringify({
					review: this.review ?? [],
					needsYou: this.needsYou,
					chat: (this.feed.messages ?? []).slice(-KEEP)
				})
			);
		} catch {
			// Storage is full or blocked: only the instant open is lost.
		}
	}

	private setCards(body: ManagerLive): void {
		for (const key of this.dismissed) {
			if (!body.review.some((item) => item.key === key)) this.dismissed.delete(key);
		}
		this.review = body.review.filter((item) => item.key === null || !this.dismissed.has(item.key));
		this.needsYou = body.needsYou;
		this.updates = body.updates;
	}

	/**
	 * The turn in flight changed. A turn that begins or ends moves the end of
	 * the chat, so the view stays at its end if the reader was there.
	 */
	private setTurn(turn: ManagerTurn | null, mine = false): void {
		const began = turn !== null && this.turn === null;
		const ended = turn === null && this.turn !== null;
		if (!began && !ended) {
			this.turn = turn;
			return;
		}
		void this.feed.keepEnd('chat', mine, () => {
			if (began) {
				this.turnSince = Date.now();
				this.turnBase = this.feed.messages?.at(-1)?.n ?? -1;
				this.spinner = turn?.spinner ?? null;
				this.note = null;
			} else {
				this.spinner = null;
			}
			this.turn = turn;
		});
		if (ended) void this.feed.load('chat');
	}

	/** The `manager` event. */
	apply(body: ManagerLive): void {
		this.setCards(body);
		// This phone's own turn is followed on its own stream.
		if (!this.sending) this.setTurn(body.turn);
		this.save();
	}

	/** The `manager-delta` event: the reply grew, so the chat has more to read. */
	append(): void {
		if (this.turn) void this.feed.load('chat');
	}

	/** The `manager-spinner` event. */
	spin(text: string | null): void {
		if (this.turn) this.spinner = text;
	}

	load = async (): Promise<void> => {
		if (this.loading) return;
		this.loading = true;
		try {
			const home: ManagerHome = await fetchManager();
			this.setCards(home);
			this.status = home.status;
			if (!this.sending) this.setTurn(home.turn);
			this.save();
		} catch (error) {
			live.fail(error);
			if (this.review === null) this.review = [];
		} finally {
			this.loading = false;
		}
	};

	/** Attachment for the manager home: load it when it is shown, then keep it current. */
	watch = (): (() => void) => {
		untrack(() => void this.load());
		const timer = setInterval(() => {
			if (document.visibilityState === 'visible' && !this.busy) void this.load();
		}, POLL_MS);
		return () => clearInterval(timer);
	};

	send = async (): Promise<void> => {
		const text = this.draft.trim();
		// A turn is running, here or on the Mac: Enter must not send a second one.
		if (!text || this.sending || this.busy) return;
		this.sending = true;
		this.draft = '';
		this.note = null;
		this.setTurn({ prompt: text, reply: '' }, true);
		let refused: string | null = null;
		let note: string | null = null;
		try {
			const end = await sendManagerText(text, () => void this.feed.load('chat'));
			if (end.outcome === 'refused' || end.outcome === 'unreachable') {
				refused = end.message ?? 'The manager did not take the message';
			} else {
				note = end.message;
			}
		} catch (error) {
			live.fail(error);
			refused = refusalText(error);
		}
		// The reply is in the transcript now: read it before the turn's line goes.
		if (refused === null) await this.feed.load('chat');
		this.sending = false;
		this.setTurn(null);
		this.note = refused ?? note;
		if (refused !== null && !this.draft) this.draft = text;
		void this.load();
	};

	dismiss = async (key: string): Promise<void> => {
		this.dismissed.add(key);
		this.review = (this.review ?? []).filter((item) => item.key !== key);
		this.save();
		try {
			await dismissReview(key);
		} catch {
			// Not dismissed on the Mac: the card comes back with the next list.
			this.dismissed.delete(key);
			void this.load();
		}
	};
}

/** The sentence for a turn the Mac did not take. */
function refusalText(error: unknown): string {
	if (!(error instanceof ApiError)) return 'The Mac did not answer';
	if (error.detail) return error.detail;
	if (error.status === 413) return 'The message is too long';
	if (error.status === 400) return 'The message has characters that cannot be sent';
	return 'The Mac did not answer';
}

export const manager = new Manager();
