import { clampPan, pinchScale, ZOOM_STEP } from './zoom';

const DOUBLE_TAP_MS = 300;
const TAP_SLOP = 10;

/** Pinch zoom for one image: two fingers scale it, one finger pans it while zoomed. */
export class Zoom {
	scale = $state(1);
	x = $state(0);
	y = $state(0);
	/** Fingers are on it: it follows them with no easing. */
	moving = $state(false);
	private pinching = $state(false);

	/** The image owns the touch: a drag on it must not change the tab. */
	get holds(): boolean {
		return this.zoomed || this.pinching;
	}

	get zoomed(): boolean {
		return this.scale > 1;
	}

	toggle = (): void => {
		this.scale = this.zoomed ? 1 : ZOOM_STEP;
		this.x = 0;
		this.y = 0;
	};

	/** Attachment for the frame around the image. */
	attach = (node: HTMLElement): (() => void) => {
		// eslint-disable-next-line svelte/prefer-svelte-reactivity -- the touches in flight, not state
		const fingers = new Map<number, { x: number; y: number }>();
		let apart = 0;
		let from = 1;
		let lastTap = 0;
		let down: { x: number; y: number } | null = null;

		const distance = (): number => {
			const [a, b] = [...fingers.values()];
			return Math.hypot(a.x - b.x, a.y - b.y);
		};

		const onDown = (event: PointerEvent): void => {
			fingers.set(event.pointerId, { x: event.clientX, y: event.clientY });
			down = fingers.size === 1 ? { x: event.clientX, y: event.clientY } : null;
			if (fingers.size === 2) {
				apart = distance();
				from = this.scale;
				this.pinching = true;
			}
			// A pinch that starts on a tap target, or a pan, must reach this frame.
			if (fingers.size === 2 || this.zoomed) node.setPointerCapture(event.pointerId);
			this.moving = true;
		};

		const onMove = (event: PointerEvent): void => {
			const last = fingers.get(event.pointerId);
			if (!last) return;
			fingers.set(event.pointerId, { x: event.clientX, y: event.clientY });
			if (fingers.size === 2) {
				this.scale = pinchScale(from, apart, distance());
			} else if (this.zoomed) {
				this.x += event.clientX - last.x;
				this.y += event.clientY - last.y;
			}
			this.x = clampPan(this.x, this.scale, node.clientWidth);
			this.y = clampPan(this.y, this.scale, node.clientHeight);
		};

		const onUp = (event: PointerEvent): void => {
			if (!fingers.delete(event.pointerId)) return;
			if (fingers.size > 0) return;
			this.moving = false;
			this.pinching = false;
			if (this.scale < 1.05) this.scale = 1;
			if (!this.zoomed) this.x = this.y = 0;
			const tap =
				event.type === 'pointerup' &&
				down !== null &&
				Math.hypot(event.clientX - down.x, event.clientY - down.y) < TAP_SLOP;
			if (tap && event.timeStamp - lastTap < DOUBLE_TAP_MS) {
				lastTap = 0;
				this.toggle();
			} else {
				lastTap = tap ? event.timeStamp : 0;
			}
		};

		node.addEventListener('pointerdown', onDown);
		node.addEventListener('pointermove', onMove);
		node.addEventListener('pointerup', onUp);
		node.addEventListener('pointercancel', onUp);
		return () => {
			node.removeEventListener('pointerdown', onDown);
			node.removeEventListener('pointermove', onMove);
			node.removeEventListener('pointerup', onUp);
			node.removeEventListener('pointercancel', onUp);
		};
	};
}
