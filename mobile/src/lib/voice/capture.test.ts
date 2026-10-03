import { describe, expect, it } from 'vitest';
import { AUTO_MAX_MS, Capture, SILENCE_MS, type FrameResult, type VoiceMode } from './capture';

const RATE = 48000;
const FRAME = 4096;
const FRAME_MS = (FRAME / RATE) * 1000;
const loud = (): Float32Array => new Float32Array(FRAME).fill(0.2);
const quiet = (): Float32Array => new Float32Array(FRAME);

/** Feeds frames on a clock that moves one frame at a time. */
class Mic {
	now = 0;
	readonly capture = new Capture(RATE, 115000);
	constructor(
		readonly mode: VoiceMode,
		public armed = true
	) {}

	/** Feed `ms` of speech or silence; stop at the first frame that is not `none`. */
	feed(ms: number, speech: boolean): FrameResult {
		for (let fed = 0; fed < ms; fed += FRAME_MS) {
			this.now += FRAME_MS;
			const result = this.capture.feed(speech ? loud() : quiet(), this.now, this.mode, this.armed);
			if (result !== 'none') return result;
		}
		return 'none';
	}
}

describe('Auto', () => {
	it('starts a take when speech starts, and not on one loud frame', () => {
		const mic = new Mic('auto');
		expect(mic.feed(2000, false)).toBe('none');
		// One click, then quiet again: no take.
		expect(mic.feed(FRAME_MS, true)).toBe('none');
		expect(mic.feed(500, false)).toBe('none');
		expect(mic.capture.open).toBe(false);
		expect(mic.feed(1000, true)).toBe('began');
		expect(mic.capture.open).toBe(true);
	});

	it('sends the take after about 3 s of silence, not after a short pause', () => {
		const mic = new Mic('auto');
		expect(mic.feed(1000, true)).toBe('began');
		expect(mic.feed(1000, true)).toBe('none');
		// A thinking pause, then more speech: the take stays open.
		expect(mic.feed(SILENCE_MS - 500, false)).toBe('none');
		expect(mic.feed(1000, true)).toBe('none');
		const before = mic.now;
		expect(mic.feed(SILENCE_MS + 1000, false)).toBe('ended');
		expect(mic.now - before).toBeGreaterThanOrEqual(SILENCE_MS);
		expect(mic.now - before).toBeLessThan(SILENCE_MS + 2 * FRAME_MS);
	});

	it('keeps the lead-in and drops the silence it waited through', () => {
		const mic = new Mic('auto');
		mic.feed(2000, false);
		expect(mic.feed(1000, true)).toBe('began');
		mic.feed(2000, true);
		expect(mic.feed(SILENCE_MS + 1000, false)).toBe('ended');
		const seconds = (mic.capture.end('auto')?.length ?? 0) / RATE;
		// About 2 s of speech, a 250 ms lead-in and a 400 ms tail; not the 3 s wait.
		expect(seconds).toBeGreaterThan(2.2);
		expect(seconds).toBeLessThan(3);
		expect(mic.capture.open).toBe(false);
	});

	it('sends a take that reaches 60 s, whatever is being said', () => {
		const mic = new Mic('auto');
		expect(mic.feed(1000, true)).toBe('began');
		const started = mic.now;
		expect(mic.feed(AUTO_MAX_MS + 5000, true)).toBe('ended');
		expect(mic.now - started).toBeGreaterThanOrEqual(AUTO_MAX_MS - FRAME_MS);
		expect(mic.now - started).toBeLessThan(AUTO_MAX_MS + 2 * FRAME_MS);
	});

	it('hears nothing while it is not armed: a reply is playing, or the mic is closed', () => {
		const mic = new Mic('auto', false);
		expect(mic.feed(3000, true)).toBe('none');
		expect(mic.capture.open).toBe(false);
		// Armed again, the speech before that does not count toward the onset.
		mic.armed = true;
		expect(mic.feed(FRAME_MS, true)).toBe('none');
		expect(mic.feed(FRAME_MS, true)).toBe('began');
	});
});

describe('Manual', () => {
	it('never starts a take from speech', () => {
		const mic = new Mic('manual', false);
		expect(mic.feed(5000, true)).toBe('none');
		expect(mic.capture.open).toBe(false);
	});

	it('keeps the take open through any pause and returns it whole', () => {
		const mic = new Mic('manual', false);
		mic.capture.begin(mic.now);
		expect(mic.feed(1000, true)).toBe('none');
		expect(mic.feed(20000, false)).toBe('none');
		expect(mic.feed(1000, true)).toBe('none');
		expect(mic.capture.open).toBe(true);
		const seconds = (mic.capture.end('manual')?.length ?? 0) / RATE;
		expect(seconds).toBeGreaterThan(21.9);
	});

	it('ends only at the longest take the Mac accepts', () => {
		const mic = new Mic('manual', false);
		mic.capture.begin(mic.now);
		expect(mic.feed(114000, true)).toBe('none');
		expect(mic.feed(2000, true)).toBe('ended');
	});

	it('returns nothing for a take with no speech, or one shorter than a tap', () => {
		const mic = new Mic('manual', false);
		mic.capture.begin(mic.now);
		mic.feed(4000, false);
		expect(mic.capture.end('manual')).toBeNull();
		mic.capture.begin(mic.now);
		mic.feed(FRAME_MS, true);
		expect(mic.capture.end('manual')).toBeNull();
		expect(mic.capture.open).toBe(false);
	});

	it('drops a take that is discarded', () => {
		const mic = new Mic('manual', false);
		mic.capture.begin(mic.now);
		mic.feed(1000, true);
		mic.capture.discard();
		expect(mic.capture.open).toBe(false);
		expect(mic.capture.end('manual')).toBeNull();
	});
});
