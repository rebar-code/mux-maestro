/** The part of `AudioContext` the player uses, so a test can stand in for it. */
export interface PlayerContext {
	readonly destination: AudioNode;
	/** Seconds on the context's clock. It stands still while the context is suspended. */
	readonly currentTime: number;
	decodeAudioData(data: ArrayBuffer): Promise<AudioBuffer>;
	createBufferSource(): AudioBufferSourceNode;
}

/**
 * Plays the reply's clips one after another, in the order they were queued.
 * A clip can take longer to decode than the one after it, so decoding is
 * chained: clip 2 never plays before clip 1. `stop` drops everything, and a
 * clip still decoding when `stop` is called is dropped when it lands.
 *
 * The clips of a reply are kept after they are played, so `seek` can go back
 * through them. Their lengths are the decoded audio's own.
 */
export class Player {
	/** Every clip of this reply, in order: the played ones too. */
	private clips: AudioBuffer[] = [];
	/** The clip that plays, or the one that plays next. */
	private index = 0;
	private current: AudioBufferSourceNode | null = null;
	/** The context's time at which the clip that plays would have begun. */
	private began = 0;
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
		return this.current !== null || this.index < this.clips.length || this.pending > 0;
	}

	/** Seconds of this reply that are decoded. */
	get duration(): number {
		return this.clips.reduce((sum, clip) => sum + clip.duration, 0);
	}

	/** Seconds into the reply: where it plays now, or where it ended. */
	get position(): number {
		const before = this.clips.slice(0, this.index).reduce((sum, clip) => sum + clip.duration, 0);
		if (!this.current) return before;
		const into = this.context.currentTime - this.began;
		return before + Math.max(0, Math.min(this.clips[this.index].duration, into));
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
			if (clip) this.clips.push(clip);
			if (!this.current) this.next();
		});
	}

	stop(): void {
		this.epoch += 1;
		this.pending = 0;
		this.clips = [];
		this.index = 0;
		this.running = false;
		this.cut();
	}

	/**
	 * Move `seconds` through the reply from where it is, back or forward, and
	 * play from there. It stops at the start; past the end there is nothing
	 * left to play. A reply that has ended plays again from the new place.
	 */
	seek(seconds: number): void {
		if (this.clips.length === 0) return;
		let left = Math.max(0, this.position + seconds);
		this.cut();
		this.index = 0;
		while (this.index < this.clips.length && left >= this.clips[this.index].duration) {
			left -= this.clips[this.index].duration;
			this.index += 1;
		}
		this.next(left);
	}

	/** Silence the clip that plays. Its end is not the reply's. */
	private cut(): void {
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

	/** Play the clip at `index`, from `offset` seconds into it. */
	private next(offset = 0): void {
		const clip = this.clips.at(this.index);
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
			this.index += 1;
			this.next();
		};
		const first = !this.running;
		this.running = true;
		this.current = source;
		this.began = this.context.currentTime - offset;
		source.start(0, offset);
		if (first) this.onStarted?.();
	}
}
