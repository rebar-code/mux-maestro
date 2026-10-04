/** Less than this is a browser toolbar that moved, not a keyboard. */
const KEYBOARD_MIN = 80;

/**
 * Attachment for the bar at the bottom of a view: keep it on top of the
 * on-screen keyboard. The keyboard covers the page without resizing it; the
 * visual viewport says by how much. Sets `--kb` (the covered height) on the
 * node and, while the keyboard is up, `data-kb` and a zero `--safe-bottom`:
 * there is no home indicator under the bar then.
 */
export function overKeyboard(node: HTMLElement): () => void {
	const viewport = window.visualViewport;
	if (!viewport) return () => {};
	const sync = (): void => {
		const covered = Math.round(document.documentElement.clientHeight - viewport.height);
		const open = viewport.scale <= 1.01 && covered > KEYBOARD_MIN;
		node.style.setProperty('--kb', open ? `${covered}px` : '0px');
		node.toggleAttribute('data-kb', open);
		if (open) node.style.setProperty('--safe-bottom', '0px');
		else node.style.removeProperty('--safe-bottom');
		// iOS scrolls the page to show the focused box. The bar has moved up
		// by itself, so put the page back where its header is on screen.
		if (open && (viewport.offsetTop > 0 || window.scrollY > 0)) window.scrollTo(0, 0);
	};
	sync();
	viewport.addEventListener('resize', sync);
	viewport.addEventListener('scroll', sync);
	return () => {
		viewport.removeEventListener('resize', sync);
		viewport.removeEventListener('scroll', sync);
	};
}
