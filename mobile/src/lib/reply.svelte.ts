import { untrack } from 'svelte';
import {
	answerPrompt,
	ApiError,
	fetchCommands,
	fetchPrompt,
	sendKey,
	sendText,
	uploadFile
} from './api';
import { live } from './live.svelte';
import {
	ctrlReduce,
	filterCommands,
	refusalLabel,
	slashQuery,
	type BarKey,
	type LiveTurn
} from './reply';
import type { Command, Prompt } from './types';
import type { VoiceSink } from './voice.svelte';

/** How often a waiting thread is asked for its prompt again. */
const POLL_MS = 3000;
/** How long an answered prompt stays hidden if the pane still shows it. */
const ANSWERED_MS = 10_000;

/** The composer's status line. */
export interface Note {
	text: string;
	/** A refusal, not a confirmation. */
	bad: boolean;
}

export interface ReplyHost {
	/** Load the open view (chat or terminal) again. */
	refresh: () => Promise<void>;
	/** Apply `change`, and stay at the end of the view if the reader was there. */
	stick: (change: () => void) => Promise<void>;
}

/** A thread's commands, asked for once. Nothing is drawn from the map itself. */
// eslint-disable-next-line svelte/prefer-svelte-reactivity
const commandCache = new Map<string, Promise<Command[]>>();

function refusal(error: unknown, what: 'text' | 'file' | 'key' | 'answer'): Note {
	live.fail(error);
	return { text: refusalLabel(error instanceof ApiError ? error : null, what), bad: true };
}

/**
 * Attachment for a control beside the text box: a tap on it does not take the
 * focus, so the keyboard stays open.
 */
export function keepFocus(node: HTMLElement): () => void {
	const keep = (event: Event): void => event.preventDefault();
	node.addEventListener('pointerdown', keep);
	node.addEventListener('mousedown', keep);
	return () => {
		node.removeEventListener('pointerdown', keep);
		node.removeEventListener('mousedown', keep);
	};
}

/** Everything one open thread can be told: text, keys, answers, files, voice. */
export class Reply {
	draft = $state('');
	note = $state<Note | null>(null);
	sending = $state(false);
	/** Sticky Ctrl is on: the next letter typed is a control key. */
	ctrl = $state(false);
	/** What the pane asks, while the thread waits. */
	prompt = $state.raw<Prompt | null>(null);
	/** The option an answer in flight picked. */
	answering = $state<number | null>(null);
	uploading = $state(false);
	/** A spoken turn in flight. */
	turn = $state.raw<LiveTurn | null>(null);
	/** The text box, for the keys that type into it. */
	input: HTMLInputElement | null = null;
	/** Attachment for the text box. */
	box = (node: HTMLInputElement): (() => void) => {
		this.input = node;
		return () => {
			if (this.input === node) this.input = null;
		};
	};

	private commands = $state.raw<Command[] | null>(null);
	/** The slash list: empty when it does not show. */
	readonly matches: Command[] = $derived.by(() => {
		const query = slashQuery(this.draft);
		return query === null || !this.commands ? [] : filterCommands(this.commands, query);
	});

	/** The pane takes no free text now. Keys and answers still go. */
	readonly blocked: boolean = $derived.by(() => {
		const status = live.byId(this.id)?.status;
		return status === 'busy' || status === 'waiting';
	});

	private seenSince: number | null | undefined;
	private loadingPrompt = false;
	private answered: { id: string; at: number } | null = null;

	constructor(
		readonly id: string,
		private readonly host: ReplyHost
	) {}

	// MARK: text

	send = async (): Promise<void> => {
		const text = this.draft.trim();
		if (!text || this.sending || this.blocked) return;
		this.sending = true;
		this.note = null;
		try {
			await sendText(this.id, text);
			this.draft = '';
			void this.host.refresh();
		} catch (error) {
			// The text stays in the box, to send again.
			this.note = refusal(error, 'text');
		} finally {
			this.sending = false;
		}
	};

	/** The box changed: a slash needs the thread's commands. */
	typed = (): void => {
		this.note = null;
		if (this.draft.startsWith('/')) void this.loadCommands();
	};

	private async loadCommands(): Promise<void> {
		if (this.commands) return;
		let asked = commandCache.get(this.id);
		if (!asked) {
			asked = fetchCommands(this.id);
			commandCache.set(this.id, asked);
		}
		try {
			this.commands = await asked;
		} catch (error) {
			commandCache.delete(this.id);
			live.fail(error);
		}
	}

	/** A row of the slash list was tapped. */
	pick = (name: string): void => {
		this.draft = `/${name} `;
		this.input?.focus();
	};

	// MARK: keys

	key = async (name: string): Promise<void> => {
		try {
			await sendKey(this.id, name);
			this.note = null;
			void this.host.refresh();
		} catch (error) {
			this.note = refusal(error, 'key');
		}
	};

	/** A key of the key bar was tapped. */
	tap = (key: BarKey): void => {
		if (key.send) return void this.key(key.send);
		const input = this.input;
		if (key.ctrl) {
			this.ctrl = ctrlReduce(this.ctrl, { type: 'toggle' }).on;
			// The letter comes from the keyboard.
			if (this.ctrl) input?.focus();
			return;
		}
		if (!key.insert) return;
		if (input) {
			input.focus();
			input.setRangeText(
				key.insert,
				input.selectionStart ?? input.value.length,
				input.selectionEnd ?? input.value.length,
				'end'
			);
			this.draft = input.value;
		} else {
			this.draft += key.insert;
		}
		this.typed();
	};

	/** The text box is about to take input: with Ctrl on, a letter is a key. */
	beforeInput = (event: InputEvent): void => {
		if (!this.ctrl || !event.inputType.startsWith('insert')) return;
		const next = ctrlReduce(true, { type: 'input', data: event.data });
		this.ctrl = next.on;
		if (!next.key) return;
		event.preventDefault();
		void this.key(next.key);
	};

	// MARK: prompts

	/** Attachment: keep the prompt card current while the thread waits. */
	watch = (): (() => void) =>
		untrack(() => {
			const sync = (): void => this.sync();
			sync();
			const off = live.onThreads(sync);
			const timer = setInterval(() => {
				if (document.visibilityState === 'visible' && this.waiting) void this.loadPrompt();
			}, POLL_MS);
			return () => {
				off();
				clearInterval(timer);
			};
		});

	private get waiting(): boolean {
		return live.byId(this.id)?.status === 'waiting';
	}

	/** The thread list changed. */
	private sync(): void {
		const thread = live.byId(this.id);
		if (thread?.status !== 'waiting') {
			this.seenSince = undefined;
			this.answered = null;
			if (this.prompt) this.prompt = null;
			return;
		}
		if (this.seenSince === thread.since) return;
		// A new wait: what was answered before is not this prompt.
		if (this.seenSince !== undefined) this.answered = null;
		this.seenSince = thread.since;
		void this.loadPrompt();
	}

	private async loadPrompt(): Promise<void> {
		if (this.loadingPrompt) return;
		this.loadingPrompt = true;
		try {
			let prompt = await fetchPrompt(this.id);
			if (!this.waiting) prompt = null;
			const answered = this.answered;
			if (prompt && answered?.id === prompt.id && Date.now() - answered.at < ANSWERED_MS)
				prompt = null;
			if (JSON.stringify(prompt) !== JSON.stringify(this.prompt))
				await this.host.stick(() => (this.prompt = prompt));
		} catch (error) {
			live.fail(error);
		} finally {
			this.loadingPrompt = false;
		}
	}

	answer = async (option: number): Promise<void> => {
		const prompt = this.prompt;
		if (!prompt || this.answering !== null) return;
		this.answering = option;
		this.note = null;
		try {
			await answerPrompt(this.id, prompt.id, option);
			this.answered = { id: prompt.id, at: Date.now() };
			this.prompt = null;
			void this.host.refresh();
		} catch (error) {
			if (error instanceof ApiError && error.code === 'stale') {
				// The pane asks something else now: show that, send nothing.
				await this.loadPrompt();
			} else {
				this.note = refusal(error, 'answer');
			}
		} finally {
			this.answering = null;
		}
	};

	// MARK: files

	upload = async (file: File): Promise<void> => {
		if (this.uploading || this.blocked) return;
		const max = live.config?.upload?.maxBytes;
		if (max !== undefined && file.size > max) {
			this.note = { text: 'Too big', bad: true };
			return;
		}
		this.uploading = true;
		this.note = null;
		try {
			await uploadFile(this.id, file);
			this.note = { text: 'Attached', bad: false };
			void this.host.refresh();
		} catch (error) {
			this.note = refusal(error, 'file');
		} finally {
			this.uploading = false;
		}
	};

	// MARK: voice

	private grow = (delta: string): void => {
		const turn = this.turn;
		if (turn) void this.host.stick(() => (this.turn = { ...turn, reply: turn.reply + delta }));
	};

	/** The chat has the turn now, or will not get it: stop drawing it here. */
	private async settle(note: Note | null): Promise<void> {
		this.note = note;
		await this.host.refresh();
		this.turn = null;
	}

	/** A turn this phone spoke into the thread: drawn at the end of the chat. */
	readonly voice: VoiceSink = {
		begin: (prompt) => {
			this.note = null;
			void this.host.stick(() => (this.turn = { prompt, reply: '' }));
		},
		delta: this.grow,
		end: (end) => void this.settle(end.message ? { text: end.message, bad: true } : null),
		fail: (message) => void this.settle({ text: message, bad: true }),
		// The Mac still runs the turn: the chat draws the rest.
		detach: () => void this.settle(null)
	};
}
