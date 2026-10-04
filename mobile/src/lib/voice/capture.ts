import { merge, rms } from './wav';

export type VoiceMode = 'auto' | 'manual';

/** In a silent room, a frame louder than this is speech. */
export const MIN_THRESHOLD = 0.008;
/** Speech is at least this many times the room's own noise. */
export const NOISE_RATIO = 3;
/** ...but never needs to be more than this much over it. */
export const NOISE_MARGIN = 0.05;
/** Inside a take, sound under this share of the voice's level is a pause. */
export const VOICE_RATIO = 0.25;
/** Frames Auto listens to the room for before it can hear a take start. */
export const SETTLE_FRAMES = 3;
/** This many loud frames in a row start a take in Auto. */
export const ONSET_FRAMES = 2;
/** Auto sends a take after this much silence. A thinking pause is shorter. */
export const SILENCE_MS = 3000;
/** Auto sends a take that runs this long, whatever is being said. */
export const AUTO_MAX_MS = 60000;
/** Kept from before the onset, so the first syllable is not cut. */
export const PREROLL_MS = 250;
/** Kept after the last speech when Auto trims the silence it waited through. */
export const TAIL_MS = 400;
/** A take shorter than this is a tap, not speech. */
export const MIN_TAKE_MS = 300;
/** A take that never gets louder than this is a dead mic, not a quiet voice. */
export const DEAD_LEVEL = 0.002;

export type FrameResult = 'none' | 'began' | 'ended';

/**
 * A closed take: its samples, or why there are none. `empty`: the mic gave no
 * frames at all. `silent`: frames came, with nothing in them to send.
 */
export type Take = { samples: Float32Array } | { dropped: 'empty' | 'silent' };

/**
 * One take at a time, fed mic frames. Auto: speech starts a take and silence
 * ends it. Manual: `begin` starts it and only `end` (or the length limit) ends
 * it, so a pause never cuts it. No audio API in here: time and frames come in
 * as arguments.
 *
 * What counts as speech is measured against the room, not fixed: a phone mic
 * in a noisy room sits well above a fixed threshold all the time, and a soft
 * voice sits under it.
 */
export class Capture {
	open = false;
	/** The loudness of the last frame, 0 to 1: the level meter. */
	level = 0;
	private chunks: Float32Array[] = [];
	private length = 0;
	/** Samples up to the end of the last loud frame. */
	private voicedLength = 0;
	private preroll: Float32Array[] = [];
	private prerollLength = 0;
	private loudFrames = 0;
	private startedAt = 0;
	private lastVoiceAt = 0;
	/** The room's noise: it follows a drop at once and a rise slowly. */
	private floor: number | null = null;
	/** Frames heard since Auto began to listen. */
	private settled = 0;
	/** The voice's own level in this take. */
	private voice = 0;
	/** The loudest frame of this take. */
	private peak = 0;

	constructor(
		readonly rate: number,
		/** The longest take the Mac accepts, in milliseconds. */
		private readonly maxMs: number
	) {}

	/** Follow the room's noise. `rise` is how fast a louder room is believed. */
	private hear(level: number, rise: number): number {
		const floor = this.floor ?? level;
		this.floor = floor + (level - floor) * (level < floor ? 0.5 : rise);
		return this.floor;
	}

	private static speechOver(floor: number): number {
		return Math.max(MIN_THRESHOLD, Math.min(floor * NOISE_RATIO, floor + NOISE_MARGIN));
	}

	/**
	 * One mic frame. `armed` means Auto is listening for speech to start a take.
	 * `began`: this frame opened a take. `ended`: the take is over, call `end`.
	 */
	feed(frame: Float32Array, now: number, mode: VoiceMode, armed: boolean): FrameResult {
		const level = rms(frame);
		this.level = level;
		if (!this.open) {
			if (!armed) {
				this.forget();
				return 'none';
			}
			this.preroll.push(new Float32Array(frame));
			this.prerollLength += frame.length;
			const keep = (this.rate * PREROLL_MS) / 1000 + frame.length * ONSET_FRAMES;
			while (this.prerollLength > keep && this.preroll.length > 1) {
				this.prerollLength -= this.preroll.shift()!.length;
			}
			// Measured before this frame is heard, so speech does not hide itself.
			const threshold = Capture.speechOver(this.floor ?? level);
			this.hear(level, 0.02);
			this.settled += 1;
			const loud = this.settled > SETTLE_FRAMES && level > threshold;
			this.loudFrames = loud ? this.loudFrames + 1 : 0;
			if (this.loudFrames < ONSET_FRAMES) return 'none';
			const lead = this.preroll;
			const floor = this.floor;
			this.begin(now);
			this.floor = floor;
			this.chunks = lead;
			this.length = lead.reduce((n, chunk) => n + chunk.length, 0);
			this.voicedLength = this.length;
			this.voice = level;
			this.peak = level;
			return 'began';
		}
		this.chunks.push(new Float32Array(frame));
		this.length += frame.length;
		this.peak = Math.max(this.peak, level);
		// A gap between words is enough to find the room again. Speech raises
		// the floor so slowly that a minute of it without a breath stays speech.
		const floor = this.hear(level, 0.001);
		const loud = level > Math.max(Capture.speechOver(floor), this.voice * VOICE_RATIO);
		if (loud) {
			this.voice = this.voice ? this.voice * 0.9 + level * 0.1 : level;
			this.lastVoiceAt = now;
			this.voicedLength = this.length;
		}
		const limit = mode === 'auto' ? Math.min(AUTO_MAX_MS, this.maxMs) : this.maxMs;
		if (now - this.startedAt >= limit) return 'ended';
		return mode === 'auto' && now - this.lastVoiceAt >= SILENCE_MS ? 'ended' : 'none';
	}

	/** Open a take now: the Talk tap. */
	begin(now: number): void {
		this.forget();
		this.open = true;
		this.chunks = [];
		this.length = 0;
		this.voicedLength = 0;
		this.voice = 0;
		this.peak = 0;
		this.startedAt = now;
		this.lastVoiceAt = now;
	}

	/**
	 * Close the take. Auto drops the silence it waited through; Manual keeps
	 * the take whole. Manual sends a quiet take too: the Mac decides what was
	 * said. Only a take with no sound in it at all is dropped.
	 */
	end(mode: VoiceMode): Take {
		const samples = merge(this.chunks);
		const voiced = this.voicedLength;
		const peak = this.peak;
		this.discard();
		if (samples.length === 0) return { dropped: 'empty' };
		const short = samples.length < (this.rate * MIN_TAKE_MS) / 1000;
		if (short || peak < DEAD_LEVEL) return { dropped: 'silent' };
		if (mode === 'manual') return { samples };
		if (voiced === 0) return { dropped: 'silent' };
		return {
			samples: samples.subarray(0, Math.min(samples.length, voiced + (this.rate * TAIL_MS) / 1000))
		};
	}

	discard(): void {
		this.open = false;
		this.chunks = [];
		this.length = 0;
		this.voicedLength = 0;
		this.forget();
	}

	/** Stop listening for an onset: the room is measured again next time. */
	private forget(): void {
		this.preroll = [];
		this.prerollLength = 0;
		this.loudFrames = 0;
		this.floor = null;
		this.settled = 0;
	}
}
