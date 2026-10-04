/**
 * Attachment for a control beside a text box: a tap on it does not take the
 * focus, so the keyboard stays open and the caret stays where it was.
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
