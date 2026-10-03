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
	TurnEnd,
	VoiceEnd
} from './types';
import type { VoiceSink } from './voice.svelte';

const KEY = 'mm.manager';

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
			if (error instanceof ApiError && error.forbidden) live.forbidden = true;
			if (this.review === null) this.review = [];
		} finally {
			this.loading = false;
		}
	};

	/** Attachment for the manager home: load it when it is shown. */
	watch = (): void => {
		untrack(() => void this.load());
	};

	private begin(text: string): void {
		this.sending = true;
		this.note = null;
		this.turn = { prompt: text, reply: '' };
	}

	private append = (delta: string): void => {
		if (this.turn) this.turn = { ...this.turn, reply: this.turn.reply + delta };
	};

	/**
	 * A turn of this phone is over. `end` is how the Mac ended it; `failed` is
	 * why it never got that far. A turn that did not land leaves its text in
	 * the box, to send again.
	 */
	private finish(end: TurnEnd | VoiceEnd | null, failed: string | null = null): void {
		const text = this.turn?.prompt ?? '';
		let refused = failed;
		if (end?.outcome === 'refused' || end?.outcome === 'unreachable') {
			refused = end.message ?? 'The manager did not take the message';
		} else if (end) {
			const n = (this.chat.at(-1)?.n ?? 0) + 1;
			const reply = this.turn?.reply || end.reply;
			this.chat = [
				...this.chat,
				{ n, role: 'user', text },
				...(reply ? [{ n: n + 1, role: 'assistant' as const, text: reply }] : [])
			];
			this.note = end.message;
		}
		this.turn = null;
		this.sending = false;
		if (refused !== null) {
			this.note = refused;
			if (!this.draft) this.draft = text;
		}
		void this.load();
	}

	send = async (): Promise<void> => {
		const text = this.draft.trim();
		if (!text || this.sending) return;
		this.draft = '';
		this.begin(text);
		try {
			this.finish(await sendManagerText(text, this.append));
		} catch (error) {
			if (error instanceof ApiError && error.forbidden) live.forbidden = true;
			this.finish(
				null,
				error instanceof ApiError && error.detail ? error.detail : 'The Mac did not answer'
			);
		}
	};

	/** A turn this phone spoke: drawn and kept like one it typed. */
	readonly voice: VoiceSink = {
		begin: (prompt) => this.begin(prompt),
		delta: this.append,
		end: (end) => this.finish(end),
		fail: (message) => this.finish(null, message),
		// The Mac still runs the turn: its events draw the rest.
		detach: () => {
			this.sending = false;
			void this.load();
		}
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

export const manager = new Manager();
