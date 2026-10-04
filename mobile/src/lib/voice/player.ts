/** The part of `AudioContext` the player uses, so a test can stand in for it. */
export interface PlayerContext {
	readonly destination: AudioNode;
	decodeAudioData(data: ArrayBuffer): Promise<AudioBuffer>;
	createBufferSource(): AudioBufferSourceNode;
}

/**
 * Plays the reply's clips one after another, in the order they were queued.
 * A clip can take longer to decode than the one after it, so decoding is
 * chained: clip 2 never plays before clip 1. `stop` drops everything, and a
 * clip still decoding when `stop` is called is dropped when it lands.
 */
export class Player {
	private queue: AudioBuffer[] = [];
	private current: AudioBufferSourceNode | null = null;
	private decoding: Promise<void> = Promise.resolve();
	private pending = 0;
	private running = false;
	/** Bumped by `stop`: a clip queued before it does not play after it. */
	private epoch = 0;
	/** Called when the last queued clip has finished playing. */
	onDrained: (() => void) | null = null;
	/** Called when a clip could not be decoded. The rest still plays. */
	onFailed: (() => void) | null = null;
	/** Called when a clip starts to play and nothing was playing before it. */
	onStarted: (() => void) | null = null;

	constructor(private readonly context: PlayerContext) {}

	/** Something is playing or is about to. */
	get busy(): boolean {
		return this.current !== null || this.queue.length > 0 || this.pending > 0;
	}

	enqueue(wav: ArrayBuffer): void {
		const epoch = this.epoch;
		this.pending += 1;
		this.decoding = this.decoding.then(async () => {
			let clip: AudioBuffer | null = null;
			try {
				clip = await this.context.decodeAudioData(wav);
			} catch {
				// A clip that does not decode is skipped; the rest still plays.
				if (epoch === this.epoch) this.onFailed?.();
			}
			if (epoch !== this.epoch) return;
			this.pending -= 1;
			if (clip) this.queue.push(clip);
			if (!this.current) this.next();
		});
	}

	stop(): void {
		this.epoch += 1;
		this.pending = 0;
		this.queue = [];
		this.running = false;
		const playing = this.current;
		this.current = null;
		if (!playing) return;
		playing.onended = null;
		try {
			playing.stop();
		} catch {
			// It had already ended.
		}
	}

	private next(): void {
		const clip = this.queue.shift();
		if (!clip) {
			if (this.pending > 0) return;
			this.running = false;
			this.onDrained?.();
			return;
		}
		const source = this.context.createBufferSource();
		source.buffer = clip;
		source.connect(this.context.destination);
		source.onended = () => {
			if (this.current !== source) return;
			this.current = null;
			this.next();
		};
		const first = !this.running;
		this.running = true;
		this.current = source;
		source.start();
		if (first) this.onStarted?.();
	}
}
