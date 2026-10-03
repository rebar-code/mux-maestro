const HOLD_MS = 480;
const SLOP = 10;

/**
 * Attachment for a row with a menu: a long press opens it, the phone's
 * right click. The press must not also tap the row, so the click that follows
 * it is dropped. A real right click opens the menu too. A press on a
 * `data-no-hold` control inside the row is that control's own.
 */
export function longPress(open: () => void): (node: HTMLElement) => () => void {
	return (node) => {
		let timer: ReturnType<typeof setTimeout> | null = null;
		let x = 0;
		let y = 0;
		let fired = false;

		const cancel = (): void => {
			if (timer) clearTimeout(timer);
			timer = null;
		};
		const own = (event: Event): boolean =>
			(event.target as Element).closest('[data-no-hold]') === null;

		const down = (event: PointerEvent): void => {
			fired = false;
			cancel();
			if (!event.isPrimary || (event.pointerType === 'mouse' && event.button !== 0)) return;
			if (!own(event)) return;
			x = event.clientX;
			y = event.clientY;
			timer = setTimeout(() => {
				timer = null;
				fired = true;
				open();
			}, HOLD_MS);
		};
		// A finger that moves is a scroll or a swipe, not a press.
		const move = (event: PointerEvent): void => {
			if (timer && Math.abs(event.clientX - x) + Math.abs(event.clientY - y) > SLOP) cancel();
		};
		const click = (event: MouseEvent): void => {
			if (!fired) return;
			fired = false;
			event.preventDefault();
			event.stopPropagation();
		};
		// The browser's own menu (and the iOS callout) never shows on the row.
		const menu = (event: Event): void => {
			if (!own(event)) return;
			event.preventDefault();
			if (fired) return;
			cancel();
			open();
		};

		node.dataset.hold = '';
		node.addEventListener('pointerdown', down);
		node.addEventListener('pointermove', move);
		node.addEventListener('pointerup', cancel);
		node.addEventListener('pointercancel', cancel);
		node.addEventListener('pointerleave', cancel);
		node.addEventListener('click', click, true);
		node.addEventListener('contextmenu', menu);
		return () => {
			cancel();
			node.removeEventListener('pointerdown', down);
			node.removeEventListener('pointermove', move);
			node.removeEventListener('pointerup', cancel);
			node.removeEventListener('pointercancel', cancel);
			node.removeEventListener('pointerleave', cancel);
			node.removeEventListener('click', click, true);
			node.removeEventListener('contextmenu', menu);
		};
	};
}
