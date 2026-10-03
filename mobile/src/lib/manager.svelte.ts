import { untrack } from 'svelte';
import { ApiError, dismissReview, fetchManager, sendManagerText } from './api';
import { live } from './live.svelte';
import { homeLines, type HomeLine } from './manager';
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

interface Cached {
	review: ManagerItem[];
	needsYou: ManagerItem[];
	chat: ChatMessage[];
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
 * The manager home: the cards, the conversation and the turn in flight. It
 * starts from the copy the last visit left, like the thread list. One manager
 * pane, one conversation: a turn started on the Mac shows here too.
 */
class Manager {
	private start = cached();
	/** `null`: nothing to show yet, draw skeleton cards. */
	review = $state.raw<ManagerItem[] | null>(this.start?.review ?? null);
	needsYou = $state.raw<ManagerItem[]>(this.start?.needsYou ?? []);
	chat = $state.raw<ChatMessage[]>(this.start?.chat ?? []);
	updates = $state.raw<ManagerUpdate[]>([]);
	status = $state<ManagerStatus>('idle');
	turn = $state.raw<ManagerTurn | null>(null);
	/** What the last turn left to say: why it was refused, or that it waits. */
	note = $state<string | null>(null);
	/** The text box. A refused turn puts its text back here. */
	draft = $state('');
	/** This phone has a turn in flight. */
	sending = $state(false);

	readonly lines: HomeLine[] = $derived(homeLines(this.chat, this.turn));
	readonly busy: boolean = $derived(this.turn !== null);
	/** What the pane is doing, when a message cannot go to it now. */
	readonly statusNote: string | null = $derived(
		this.turn === null ? (STATUS_NOTES[this.status] ?? null) : null
	);

	/** Review items dismissed here that the Mac has not dropped yet. */
	private dismissed = new Set<string>();
	private loading = false;

	private save(): void {
		try {
			localStorage.setItem(
				KEY,
				JSON.stringify({ review: this.review ?? [], needsYou: this.needsYou, chat: this.chat })
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

	/** The `manager` event. */
	apply(body: ManagerLive): void {
		this.setCards(body);
		// This phone's own turn is drawn from its own stream.
		if (!this.sending) {
			const ended = this.turn !== null && body.turn === null;
			this.turn = body.turn;
			if (body.turn) this.note = null;
			if (ended) void this.load();
		}
		this.save();
	}

	/** The `manager-delta` event: more of the reply of a turn started elsewhere. */
	append(text: string): void {
		if (this.sending || !this.turn) return;
		this.turn = { prompt: this.turn.prompt, reply: this.turn.reply + text };
	}

	load = async (): Promise<void> => {
		if (this.loading) return;
		this.loading = true;
		try {
			const home: ManagerHome = await fetchManager();
			this.setCards(home);
			this.status = home.status;
			this.chat = home.chat.messages;
			if (!this.sending) this.turn = home.turn;
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
		this.turn = { prompt: text, reply: '' };
		let refused: string | null = null;
		try {
			const end = await sendManagerText(text, (delta) => {
				this.turn = { prompt: text, reply: (this.turn?.reply ?? '') + delta };
			});
			if (end.outcome === 'refused' || end.outcome === 'unreachable') {
				refused = end.message ?? 'The manager did not take the message';
			} else {
				const n = (this.chat.at(-1)?.n ?? 0) + 1;
				const reply = this.turn?.reply || end.reply;
				this.chat = [
					...this.chat,
					{ n, role: 'user', text },
					...(reply ? [{ n: n + 1, role: 'assistant' as const, text: reply }] : [])
				];
				this.note = end.message;
			}
		} catch (error) {
			live.fail(error);
			refused = refusalText(error);
		}
		this.turn = null;
		this.sending = false;
		if (refused !== null) {
			this.note = refused;
			if (!this.draft) this.draft = text;
		}
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
