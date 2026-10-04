import { untrack } from 'svelte';
import { answerPrompt, ApiError, fetchCommands, fetchPrompt, sendKey, sendText } from './api';
import { isImage, insertPath, removePath } from './attach';
import { Attachments } from './attach.svelte';
import { live, OFF_LABEL } from './live.svelte';
import {
	CTRL_MS,
	ctrlReduce,
	filterCommands,
	needsPrompt,
	queueKey,
	refusalLabel,
	slashQuery,
	textRefusal,
	type BarKey,
	type LiveTurn,
	type QueuedKey
} from './reply';
import type { Command, Prompt } from './types';
import type { VoiceSink } from './voice.svelte';

/** How often a thread that waits, or shows a prompt, is asked for its prompt again. */
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
	/** Sticky Ctrl is on: the next key typed is its key. */
	ctrl = $state(false);
	/** What the pane asks. It can ask while the thread's status says nothing of it. */
	prompt = $state.raw<Prompt | null>(null);
	/**
	 * Names what the pane waits on, also when there are no choices to draw. A
	 * card is on screen for it, and the keys carry it: never an id with no card.
	 */
	promptId = $state<string | null>(null);
	/** The option an answer in flight picked. */
	answering = $state<number | null>(null);
	/** A spoken turn in flight. */
	turn = $state.raw<LiveTurn | null>(null);
	/** The text box, for the keys that type into it. */
	input: HTMLInputElement | null = null;
	/** Attachment for the text box. */
	box = (node: HTMLInputElement): (() => void) => {
		this.input = node;
		return () => {
			if (this.input === node) this.input = null;
			this.setCtrl(false);
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
		return status === 'busy' || status === 'waiting' || this.promptId !== null;
	});

	/** The thread's status and its time, as last seen. */
	private seen: string | undefined;
	private ctrlTimer: ReturnType<typeof setTimeout> | undefined;
	/** Key presses that wait for the one in flight. */
	private keys: QueuedKey[] = [];
	/** A prompt was asked for while one was being fetched: fetch again after. */
	private promptAgain = false;
	private pressing = false;
	private loadingPrompt = false;
	private answered: { id: string; at: number } | null = null;

	constructor(
		readonly id: string,
		private readonly host: ReplyHost
	) {
		this.files = new Attachments(id, {
			insert: (text) => (this.draft = insertPath(this.draft, text)),
			remove: (text) => (this.draft = removePath(this.draft, text)),
			sending: () => this.sending
		});
	}

	// MARK: text

	send = async (): Promise<void> => {
		const text = this.draft.trim();
		// One write to a thread at a time: a file on its way goes first.
		if (!text || this.sending || this.blocked || this.files.pending) return;
		this.sending = true;
		this.note = null;
		try {
			await sendText(this.id, text);
			this.draft = '';
			// The paths went with the text.
			this.files.clear();
			void this.host.refresh();
		} catch (error) {
			live.fail(error);
			const refused = error instanceof ApiError ? error : null;
			const { note, keepDraft } = textRefusal(refused);
			this.note = { text: note, bad: true };
			// What the pane still holds must not be sent a second time.
			if (!keepDraft && this.draft.trim() === text) this.draft = '';
			this.recheck(error);
		} finally {
			this.sending = false;
			// A file picked meanwhile waited for this.
			void this.files.pump();
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

	/**
	 * Press a key in the pane. A thread takes one write at a time, so the
	 * presses go one by one, in the order they were tapped.
	 */
	key = (name: string): void => {
		// The id is the card's at this tap, whatever the pane shows when the key goes.
		this.keys = queueKey(this.keys, name, this.promptId);
		void this.press();
	};

	private async press(): Promise<void> {
		if (this.pressing) return;
		this.pressing = true;
		try {
			for (let next = this.keys.shift(); next !== undefined; next = this.keys.shift()) {
				await sendKey(this.id, next.key, next.prompt);
				this.note = null;
				// The key may have moved the pane's cursor: the card and its id follow.
				if (next.prompt !== null) void this.loadPrompt();
			}
			void this.host.refresh();
		} catch (error) {
			// The pane is not where these keys were aimed: none of the rest goes.
			this.keys = [];
			this.note = refusal(error, 'key');
			this.recheck(error);
		} finally {
			this.pressing = false;
		}
	}

	private setCtrl(on: boolean): void {
		clearTimeout(this.ctrlTimer);
		this.ctrl = on;
		// It does not wait for its key for ever.
		if (on) this.ctrlTimer = setTimeout(() => (this.ctrl = false), CTRL_MS);
	}

	/** A key of the key bar was tapped. */
	tap = (key: BarKey): void => {
		const input = this.input;
		if (key.ctrl) {
			this.setCtrl(ctrlReduce(this.ctrl, { type: 'toggle' }).on);
			// The letter comes from the keyboard.
			if (this.ctrl) input?.focus();
			return;
		}
		// Ctrl holds for one key, whichever it is.
		this.setCtrl(false);
		if (key.send) return this.key(key.send);
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

	/** The text box is about to change: with Ctrl on, a letter is a key. */
	beforeInput = (event: InputEvent): void => {
		if (!this.ctrl) return;
		const typed = event.inputType.startsWith('insert') ? event.data : null;
		const next = ctrlReduce(true, { type: 'input', data: typed });
		this.setCtrl(next.on);
		if (!next.key) return;
		event.preventDefault();
		this.key(next.key);
	};

	// MARK: prompts

	/** Attachment: keep the prompt card current. */
	watch = (): (() => void) =>
		untrack(() => {
			const sync = (): void => this.sync();
			sync();
			const off = live.onThreads(sync);
			const timer = setInterval(() => {
				if (document.visibilityState !== 'visible') return;
				// A prompt that shows is asked for again, to see it go.
				if (this.waiting || this.promptId !== null) void this.loadPrompt();
			}, POLL_MS);
			return () => {
				off();
				clearInterval(timer);
			};
		});

	private get waiting(): boolean {
		return live.byId(this.id)?.status === 'waiting';
	}

	/** The thread list changed: a new status or time can mean a new prompt, or none. */
	private sync(): void {
		const thread = live.byId(this.id);
		const seen = `${thread?.status} ${thread?.since}`;
		if (seen === this.seen) return;
		// What was answered before is not what the pane asks now.
		if (this.seen !== undefined) this.answered = null;
		this.seen = seen;
		void this.loadPrompt();
	}

	/** After a refusal that says the pane waits on something: show what. */
	private recheck(error: unknown): void {
		if (needsPrompt(error instanceof ApiError ? error : null)) void this.loadPrompt();
	}

	private async loadPrompt(): Promise<void> {
		if (this.loadingPrompt) {
			// The answer on its way may be older than this request.
			this.promptAgain = true;
			return;
		}
		this.loadingPrompt = true;
		this.promptAgain = false;
		try {
			const state = await fetchPrompt(this.id);
			const answered = this.answered;
			// Just answered here: the pane has not moved on yet.
			const gone = answered?.id === state.id && Date.now() - answered.at < ANSWERED_MS;
			const id = gone ? null : state.id;
			const prompt = gone ? null : state.prompt;
			if (id !== this.promptId || JSON.stringify(prompt) !== JSON.stringify(this.prompt))
				await this.host.stick(() => {
					this.promptId = id;
					this.prompt = prompt;
				});
		} catch (error) {
			live.fail(error);
		} finally {
			this.loadingPrompt = false;
		}
		if (this.promptAgain) await this.loadPrompt();
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
			this.promptId = null;
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

	/** The files picked for this reply. Their paths go into the text box. */
	readonly files: Attachments;

	/** The attach button was tapped while uploads are switched off on the Mac. */
	uploadOff = (): void => {
		this.note = { text: OFF_LABEL, bad: false };
	};

	/** The text box got a paste: images become attachments, text stays text. */
	pasted = (event: ClipboardEvent): void => {
		const images = [...(event.clipboardData?.files ?? [])].filter((file) => isImage(file.type));
		if (!images.length) return;
		// The picture, not also its name or its address as text.
		event.preventDefault();
		if (live.config?.capabilities.upload === true) this.files.paste(images);
		else this.uploadOff();
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
