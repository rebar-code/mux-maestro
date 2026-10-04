import { describe, expect, it } from 'vitest';
import {
	AUTO_MAX_MS,
	Capture,
	SILENCE_MS,
	type FrameResult,
	type Take,
	type VoiceMode
} from './capture';

const RATE = 48000;
const FRAME = 4096;
const FRAME_MS = (FRAME / RATE) * 1000;
/** A frame of sound at one loudness (its RMS). */
const at = (level: number): Float32Array => new Float32Array(FRAME).fill(level);
const seconds = (take: Take): number => ('samples' in take ? take.samples.length / RATE : 0);

/** Feeds frames on a clock that moves one frame at a time. */
class Mic {
	now = 0;
	readonly capture = new Capture(RATE, 115000);
	constructor(
		readonly mode: VoiceMode,
		public armed = true
	) {}

	/**
	 * Feed `ms` of sound; stop at the first frame that is not `none`. `sound` is
	 * speech (true), silence (false), or a loudness.
	 */
	feed(ms: number, sound: boolean | number): FrameResult {
		const level = sound === true ? 0.2 : sound === false ? 0 : sound;
		for (let fed = 0; fed < ms; fed += FRAME_MS) {
			this.now += FRAME_MS;
			const result = this.capture.feed(at(level), this.now, this.mode, this.armed);
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
		mic.feed(500, false);
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
		const length = seconds(mic.capture.end('auto'));
		// About 2 s of speech, a 250 ms lead-in and a 400 ms tail; not the 3 s wait.
		expect(length).toBeGreaterThan(2.2);
		expect(length).toBeLessThan(3);
		expect(mic.capture.open).toBe(false);
	});

	it('sends a take that reaches 60 s, whatever is being said', () => {
		const mic = new Mic('auto');
		mic.feed(500, false);
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
		// Armed again, it first listens to the room, then hears speech start.
		mic.armed = true;
		expect(mic.feed(500, false)).toBe('none');
		expect(mic.feed(FRAME_MS, true)).toBe('none');
		expect(mic.feed(FRAME_MS, true)).toBe('began');
	});

	it('in a noisy room: the noise starts no take, speech does, and the take still ends', () => {
		const mic = new Mic('auto');
		// A fan, a street: steady sound well over the quiet-room threshold.
		expect(mic.feed(8000, 0.03)).toBe('none');
		expect(mic.capture.open).toBe(false);
		expect(mic.feed(1000, 0.2)).toBe('began');
		expect(mic.feed(2000, 0.2)).toBe('none');
		// The speaker stops; the noise goes on. About 3 s later the take is sent.
		const before = mic.now;
		expect(mic.feed(SILENCE_MS + 2000, 0.03)).toBe('ended');
		expect(mic.now - before).toBeLessThan(SILENCE_MS + 500);
		expect(seconds(mic.capture.end('auto'))).toBeLessThan(3.6);
	});

	it('a take started by a tap in a noisy room ends too', () => {
		const mic = new Mic('auto');
		mic.capture.begin(mic.now);
		expect(mic.feed(2000, 0.2)).toBe('none');
		expect(mic.feed(300, 0.03)).toBe('none');
		expect(mic.feed(2000, 0.2)).toBe('none');
		expect(mic.feed(SILENCE_MS + 2000, 0.03)).toBe('ended');
	});

	it('hears a quiet voice in a quiet room', () => {
		const mic = new Mic('auto');
		mic.feed(1000, 0.001);
		// Under the old fixed threshold of 0.015.
		expect(mic.feed(1000, 0.012)).toBe('began');
		expect(mic.feed(1500, 0.012)).toBe('none');
		expect(mic.feed(SILENCE_MS + 1000, 0.001)).toBe('ended');
		expect(seconds(mic.capture.end('auto'))).toBeGreaterThan(1.5);
	});

	it('a tap with nothing said after it ends, and says no speech was heard', () => {
		const mic = new Mic('auto');
		mic.capture.begin(mic.now);
		expect(mic.feed(SILENCE_MS + 1000, 0.001)).toBe('ended');
		expect(mic.capture.end('auto')).toEqual({ dropped: 'silent' });
	});

	it('armed in the middle of a sentence, it starts at the next phrase', () => {
		const mic = new Mic('auto');
		// The first thing it hears is speech, so it takes that for the room...
		expect(mic.feed(1500, 0.2)).toBe('none');
		// ...until a gap between phrases shows the room as it is.
		expect(mic.feed(300, 0.001)).toBe('none');
		expect(mic.feed(1000, 0.2)).toBe('began');
	});

	it('reports the loudness of the last frame, for the level meter', () => {
		const mic = new Mic('auto');
		expect(mic.capture.level).toBe(0);
		mic.feed(FRAME_MS, 0.2);
		expect(mic.capture.level).toBeCloseTo(0.2);
		mic.feed(FRAME_MS, false);
		expect(mic.capture.level).toBe(0);
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
		expect(seconds(mic.capture.end('manual'))).toBeGreaterThan(21.9);
	});

	it('ends only at the longest take the Mac accepts', () => {
		const mic = new Mic('manual', false);
		mic.capture.begin(mic.now);
		expect(mic.feed(114000, true)).toBe('none');
		expect(mic.feed(2000, true)).toBe('ended');
	});

	it('says why a take is dropped: a dead mic, no speech, or only a tap', () => {
		const mic = new Mic('manual', false);
		// No frame ever arrived: the mic gave nothing.
		mic.capture.begin(mic.now);
		expect(mic.capture.end('manual')).toEqual({ dropped: 'empty' });
		// Frames arrived, all of them digital silence.
		mic.capture.begin(mic.now);
		mic.feed(4000, false);
		expect(mic.capture.end('manual')).toEqual({ dropped: 'silent' });
		// Shorter than a tap.
		mic.capture.begin(mic.now);
		mic.feed(FRAME_MS, true);
		expect(mic.capture.end('manual')).toEqual({ dropped: 'silent' });
		expect(mic.capture.open).toBe(false);
	});

	it('sends a quiet take: the Mac decides what was said, not a threshold', () => {
		const mic = new Mic('manual', false);
		mic.capture.begin(mic.now);
		// A soft voice on a phone held away: under any speech threshold.
		mic.feed(3000, 0.006);
		expect(seconds(mic.capture.end('manual'))).toBeGreaterThan(2.9);
	});

	it('drops a take that is discarded', () => {
		const mic = new Mic('manual', false);
		mic.capture.begin(mic.now);
		mic.feed(1000, true);
		mic.capture.discard();
		expect(mic.capture.open).toBe(false);
		expect(mic.capture.end('manual')).toEqual({ dropped: 'empty' });
	});
});
