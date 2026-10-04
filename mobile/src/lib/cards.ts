/**
 * An action card: a pointer the user can answer where it is shown. The Maestro
 * writes one with `mux point --action`; the Mac sends it under the pointer's
 * `card`. This is format version 1.
 *
 * The card holds no answer text and no tmux address. A tap names the card and
 * the position of one action; the Mac reads the text from its own row and
 * types it into the pane the card came from.
 */
export interface ActionCard {
	v: typeof CARD_VERSION;
	/** Names this state of the question. A tap sends it back, so a card that changed takes no answer. */
	id: string;
	title: string;
	body: string | null;
	/** The thread an answer goes to. Null when the Mac finds no one pane for it. */
	source: string | null;
	actions: CardAction[];
	/** A route inside this app (`/t/<id>`), never an address outside it. */
	link: string | null;
	answered: CardAnswer | null;
}

export interface CardAction {
	label: string;
}

/** The action that reached the pane, and when. */
export interface CardAnswer {
	label: string;
	at: number;
}

/** The card format this build draws. A card of another version shows as a plain pointer. */
export const CARD_VERSION = 1;
/** The most buttons on one card. The Mac caps them too; a card is not trusted. */
export const CARD_ACTIONS_MAX = 4;
const TITLE_MAX = 120;
const LABEL_MAX = 40;
const BODY_MAX = 280;

/** Zero-width and direction characters: they can hide or reorder what a line says. */
const UNSEEN = /[\u200B-\u200F\u202A-\u202E\u2066-\u2069]/g;

/** One short line: no hidden characters, one space between words, cut with an ellipsis. */
export function capped(text: string, max: number): string {
	const flat = text.replace(UNSEEN, '').replace(/\s+/g, ' ').trim();
	return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
}

/** A route to one thread, and nothing else: one path segment under `/t/`. */
const THREAD_ROUTE = /^\/t\/([^/?#]+)$/;

/** The thread a card's link opens; null for a link that is not a thread's route. */
export function linkThread(link: string | null): string | null {
	const segment = link === null ? null : (THREAD_ROUTE.exec(link)?.[1] ?? null);
	if (segment === null) return null;
	try {
		return decodeURIComponent(segment);
	} catch {
		return null;
	}
}

function record(value: unknown): Record<string, unknown> | null {
	return typeof value === 'object' && value !== null && !Array.isArray(value)
		? (value as Record<string, unknown>)
		: null;
}

function answer(value: unknown): CardAnswer | null | undefined {
	if (value === null || value === undefined) return null;
	const raw = record(value);
	if (!raw || typeof raw.label !== 'string' || typeof raw.at !== 'number') return undefined;
	return { label: capped(raw.label, LABEL_MAX), at: raw.at };
}

/**
 * Check what the Mac sent against the format. Null for anything that is not a
 * version 1 card: a card is drawn whole or not at all.
 */
export function parseCard(value: unknown): ActionCard | null {
	const raw = record(value);
	if (!raw || raw.v !== CARD_VERSION) return null;
	if (typeof raw.id !== 'string' || raw.id === '') return null;
	if (typeof raw.title !== 'string') return null;
	const title = capped(raw.title, TITLE_MAX);
	if (title === '') return null;
	if (raw.body !== null && raw.body !== undefined && typeof raw.body !== 'string') return null;
	if (raw.source !== null && typeof raw.source !== 'string') return null;
	if (raw.link !== null && (typeof raw.link !== 'string' || linkThread(raw.link) === null)) {
		return null;
	}
	if (!Array.isArray(raw.actions) || raw.actions.length > CARD_ACTIONS_MAX) return null;
	const actions: CardAction[] = [];
	for (const entry of raw.actions) {
		const label = capped(String(record(entry)?.label ?? ''), LABEL_MAX);
		if (typeof record(entry)?.label !== 'string' || label === '') return null;
		actions.push({ label });
	}
	const answered = answer(raw.answered);
	if (answered === undefined) return null;
	const lines = (raw.body ?? '')
		.split('\n')
		.map((line) => capped(line, BODY_MAX))
		.filter((line) => line !== '');
	const body = lines.join('\n');
	return {
		v: CARD_VERSION,
		id: raw.id,
		title,
		body: body === '' ? null : body.length > BODY_MAX ? `${body.slice(0, BODY_MAX - 1)}…` : body,
		source: raw.source,
		actions,
		link: raw.link,
		answered
	};
}

/** A card still asks: it has a button and no answer has reached its pane. */
export function isOpen(card: ActionCard | null): boolean {
	return card !== null && card.actions.length > 0 && card.answered === null;
}
