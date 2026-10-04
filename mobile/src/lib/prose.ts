import { resolveArtifact } from './artifacts';
import { openThreadLink } from './jump';
import type { ArtifactFile } from './types';

/** What a tap inside rendered markdown can reach. Without it, a path or a local address is text. */
export interface ProseLinks {
	/** The thread's files. */
	readonly files: ArtifactFile[];
	/** A file as an address an `<img>` can show. */
	url(file: ArtifactFile): Promise<string>;
	open(file: ArtifactFile): void;
	/** A local address: the port and the rest of the address. Null where no server can be opened. */
	readonly local: ((port: number, rest: string) => void) | null;
}

const COPIED_MS = 1500;

async function copy(button: Element): Promise<void> {
	const code = button.parentElement?.querySelector('pre')?.textContent ?? '';
	try {
		await navigator.clipboard.writeText(code.replace(/\n$/, ''));
	} catch {
		// No clipboard here: the code can still be selected.
		return;
	}
	button.setAttribute('data-copied', '');
	setTimeout(() => button.removeAttribute('data-copied'), COPIED_MS);
}

/**
 * Attachment for an element that holds rendered markdown: the copy buttons,
 * and the links that are not web addresses. One listener for the element, so
 * the HTML itself carries no handler.
 */
export function proseTaps(links: () => ProseLinks | undefined) {
	return (node: HTMLElement): (() => void) => {
		const act = (event: Event): void => {
			const target = event.target as Element;
			const button = target.closest('[data-copy]');
			if (button) return void copy(button);
			const session = target.closest<HTMLElement>('[data-thread-link]');
			if (session) return openThreadLink(session);
			const local = target.closest<HTMLElement>('[data-local]');
			if (local) {
				links()?.local?.(Number(local.dataset.local), local.dataset.rest ?? '/');
				return;
			}
			const named = target.closest<HTMLElement>('[data-file], [data-img]');
			if (!named) return;
			const reach = links();
			const file = resolveArtifact(
				named.dataset.file ?? named.dataset.img ?? '',
				reach?.files ?? []
			);
			if (file) reach?.open(file);
		};
		const onKey = (event: KeyboardEvent): void => {
			if (event.key === 'Enter' && (event.target as Element).matches('[role="link"]')) act(event);
		};
		// A tap on Copy does not take the focus: a text box that is being typed
		// in keeps its keyboard and its caret.
		const keep = (event: Event): void => {
			if ((event.target as Element).closest('[data-copy]')) event.preventDefault();
		};
		node.addEventListener('click', act);
		node.addEventListener('keydown', onKey);
		node.addEventListener('pointerdown', keep);
		node.addEventListener('mousedown', keep);
		return () => {
			node.removeEventListener('click', act);
			node.removeEventListener('keydown', onKey);
			node.removeEventListener('pointerdown', keep);
			node.removeEventListener('mousedown', keep);
		};
	};
}
