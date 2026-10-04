import { describe, expect, it } from 'vitest';
import { downsample, encodeWav, merge, rms, takeWav, TAKE_RATE } from './wav';

const tone = (seconds: number, rate: number, hz = 220): Float32Array =>
	Float32Array.from(
		{ length: Math.floor(seconds * rate) },
		(_, i) => Math.sin((2 * Math.PI * hz * i) / rate) * 0.5
	);

describe('wav', () => {
	it('writes a 16-bit mono PCM header and clips the samples', () => {
		const view = new DataView(encodeWav(Float32Array.from([0, 0.5, -0.5, 2, -2]), 16000));
		const tag = (at: number): string =>
			String.fromCharCode(...[0, 1, 2, 3].map((i) => view.getUint8(at + i)));
		expect(view.byteLength).toBe(44 + 10);
		expect([tag(0), tag(8), tag(12), tag(36)]).toEqual(['RIFF', 'WAVE', 'fmt ', 'data']);
		expect(view.getUint32(4, true)).toBe(36 + 10);
		expect(view.getUint16(20, true)).toBe(1);
		expect(view.getUint16(22, true)).toBe(1);
		expect(view.getUint32(24, true)).toBe(16000);
		expect(view.getUint32(28, true)).toBe(32000);
		expect(view.getUint16(34, true)).toBe(16);
		expect(view.getUint32(40, true)).toBe(10);
		expect([0, 1, 2, 3, 4].map((i) => view.getInt16(44 + i * 2, true))).toEqual([
			0, 16383, -16384, 32767, -32768
		]);
	});

	it('downsamples a phone-rate take to the rate the Mac takes', () => {
		const out = downsample(tone(1, 48000), 48000, TAKE_RATE);
		expect(out.length).toBe(16000);
		// Still the same tone: 220 upward zero crossings in one second.
		let crossings = 0;
		for (let i = 1; i < out.length; i += 1) if (out[i - 1] < 0 && out[i] >= 0) crossings += 1;
		expect(Math.abs(crossings - 220)).toBeLessThanOrEqual(2);
		expect(rms(out)).toBeGreaterThan(0.3);
		// 44.1 kHz is not a whole multiple of 16 kHz.
		expect(downsample(tone(1, 44100), 44100, TAKE_RATE).length).toBe(16000);
	});

	it('leaves a take alone that is already at or under the rate', () => {
		const samples = tone(0.1, 16000);
		expect(downsample(samples, 16000, TAKE_RATE)).toBe(samples);
		expect(new DataView(takeWav(tone(0.1, 8000), 8000)).getUint32(24, true)).toBe(8000);
		const wav = new DataView(takeWav(tone(1, 48000), 48000));
		expect(wav.getUint32(24, true)).toBe(16000);
		expect(wav.byteLength).toBe(44 + 32000);
	});

	it('measures loudness and joins chunks in order', () => {
		expect(rms(new Float32Array(100))).toBe(0);
		expect(rms(new Float32Array(0))).toBe(0);
		expect(rms(Float32Array.from([0.5, -0.5]))).toBeCloseTo(0.5);
		expect([...merge([Float32Array.from([1, 2]), Float32Array.from([3])])]).toEqual([1, 2, 3]);
	});
});
