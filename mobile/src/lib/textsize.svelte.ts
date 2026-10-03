import { chatSize, clampSize, DEFAULT_SIZE, MAX_SIZE, MIN_SIZE, stepSize } from './textsize';

const KEY = 'mm.textSize';

function stored(): number {
	try {
		const raw = localStorage.getItem(KEY);
		return raw === null ? DEFAULT_SIZE : clampSize(Number(raw));
	} catch {
		return DEFAULT_SIZE;
	}
}

/** The thread view's text size, kept on this device. */
class TextSize {
	/** Read before the first paint, so the text never starts at another size. */
	size = $state(stored());

	readonly chat = $derived(chatSize(this.size));
	readonly atMin = $derived(this.size <= MIN_SIZE);
	readonly atMax = $derived(this.size >= MAX_SIZE);

	/** Change the size without storing it: for each frame of a pinch. */
	preview(size: number): void {
		this.size = clampSize(size);
	}

	save(): void {
		try {
			localStorage.setItem(KEY, String(this.size));
		} catch {
			// Storage is full or blocked: the size lasts for this visit only.
		}
	}

	set(size: number): void {
		this.preview(size);
		this.save();
	}

	step(direction: 1 | -1): void {
		this.set(stepSize(this.size, direction));
	}

	reset(): void {
		this.set(DEFAULT_SIZE);
	}
}

export const text = new TextSize();
