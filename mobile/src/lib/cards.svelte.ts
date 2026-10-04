import { SvelteMap } from 'svelte/reactivity';
import { actOnCard, ApiError } from './api';
import type { ActionCard } from './cards';
import { manager } from './manager.svelte';

/** What a tap that did not land says when the Mac gave no reason. */
const NOT_SENT = 'Not sent';

/**
 * The taps on action cards: which one is on its way, and which did not land.
 * An answer that landed is not kept here: the Mac's own list says it, at once.
 * Kept by the card's id, so a card that the Maestro changes starts clean.
 */
class Cards {
	/** The card a tap is on its way for. One at a time: an answer is not sent twice. */
	sending = $state<string | null>(null);
	/** Why the last tap on a card did not land. */
	private failed = new SvelteMap<string, string>();

	failure(card: ActionCard): string | null {
		return this.failed.get(card.id) ?? null;
	}

	/** Tap action `index` of the card under `key`. The Mac picks the pane and the text. */
	act = async (key: string, card: ActionCard, index: number): Promise<void> => {
		if (this.sending !== null || card.answered) return;
		this.sending = card.id;
		this.failed.delete(card.id);
		try {
			await actOnCard(key, index, card.id);
		} catch (error) {
			// Said on the card: a tap that fails without a word reads as answered.
			this.failed.set(card.id, error instanceof ApiError ? (error.detail ?? NOT_SENT) : NOT_SENT);
		}
		// The card as the Mac holds it now: answered, changed or gone. The
		// buttons stay off until it is read, so the answer is not sent twice.
		try {
			await manager.load();
		} finally {
			this.sending = null;
		}
	};
}

export const cards = new Cards();
