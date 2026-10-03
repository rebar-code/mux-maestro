import { merge, rms } from './wav';

export type VoiceMode = 'auto' | 'manual';

/** A frame louder than this is speech. */
export const THRESHOLD = 0.015;
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

export type FrameResult = 'none' | 'began' | 'ended';

/**
 * One take at a time, fed mic frames. Auto: speech starts a take and silence
 * ends it. Manual: `begin` starts it and only `end` (or the length limit) ends
 * it, so a pause never cuts it. No audio API in here: time and frames come in
 * as arguments.
 */
export class Capture {
	open = false;
	private chunks: Float32Array[] = [];
	private length = 0;
	/** Samples up to the end of the last loud frame. */
	private voicedLength = 0;
	private preroll: Float32Array[] = [];
	private prerollLength = 0;
	private loudFrames = 0;
	private startedAt = 0;
	private lastVoiceAt = 0;

	constructor(
		readonly rate: number,
		/** The longest take the Mac accepts, in milliseconds. */
		private readonly maxMs: number
	) {}

	/**
	 * One mic frame. `armed` means Auto is listening for speech to start a take.
	 * `began`: this frame opened a take. `ended`: the take is over, call `end`.
	 */
	feed(frame: Float32Array, now: number, mode: VoiceMode, armed: boolean): FrameResult {
		const loud = rms(frame) > THRESHOLD;
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
			this.loudFrames = loud ? this.loudFrames + 1 : 0;
			if (this.loudFrames < ONSET_FRAMES) return 'none';
			const lead = this.preroll;
			this.begin(now);
			this.chunks = lead;
			this.length = lead.reduce((n, chunk) => n + chunk.length, 0);
			this.voicedLength = this.length;
			return 'began';
		}
		this.chunks.push(new Float32Array(frame));
		this.length += frame.length;
		if (loud) {
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
		this.startedAt = now;
		this.lastVoiceAt = now;
	}

	/**
	 * Close the take and return its samples; null when nothing was said. Auto
	 * drops the silence it waited through; Manual keeps the take whole.
	 */
	end(mode: VoiceMode): Float32Array | null {
		const samples = merge(this.chunks);
		const voiced = this.voicedLength;
		this.discard();
		if (voiced === 0 || samples.length < (this.rate * MIN_TAKE_MS) / 1000) return null;
		if (mode === 'manual') return samples;
		return samples.subarray(0, Math.min(samples.length, voiced + (this.rate * TAIL_MS) / 1000));
	}

	discard(): void {
		this.open = false;
		this.chunks = [];
		this.length = 0;
		this.voicedLength = 0;
		this.forget();
	}

	private forget(): void {
		this.preroll = [];
		this.prerollLength = 0;
		this.loudFrames = 0;
	}
}
