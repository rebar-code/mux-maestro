/** The rate the Mac's speech-to-text takes. A take is sent at this rate. */
export const TAKE_RATE = 16000;

/** Loudness of one frame: the root mean square of its samples (0 to 1). */
export function rms(frame: Float32Array): number {
	let sum = 0;
	for (let i = 0; i < frame.length; i += 1) sum += frame[i] * frame[i];
	return frame.length ? Math.sqrt(sum / frame.length) : 0;
}

export function merge(chunks: Float32Array[]): Float32Array {
	const out = new Float32Array(chunks.reduce((n, chunk) => n + chunk.length, 0));
	let at = 0;
	for (const chunk of chunks) {
		out.set(chunk, at);
		at += chunk.length;
	}
	return out;
}

/**
 * Lower the sample rate. Each output sample is the mean of the input it
 * covers, which keeps speech clear of aliasing. A rate that is already at or
 * under `to` is returned as it is.
 */
export function downsample(samples: Float32Array, from: number, to: number): Float32Array {
	if (from <= to) return samples;
	const step = from / to;
	const out = new Float32Array(Math.floor(samples.length / step));
	for (let i = 0; i < out.length; i += 1) {
		const first = Math.floor(i * step);
		const last = Math.min(samples.length, Math.max(first + 1, Math.floor((i + 1) * step)));
		let sum = 0;
		for (let at = first; at < last; at += 1) sum += samples[at];
		out[i] = sum / (last - first);
	}
	return out;
}

/** Mono samples as a 16-bit PCM WAV file. */
export function encodeWav(samples: Float32Array, rate: number): ArrayBuffer {
	const buffer = new ArrayBuffer(44 + samples.length * 2);
	const view = new DataView(buffer);
	const text = (at: number, value: string): void => {
		for (let i = 0; i < value.length; i += 1) view.setUint8(at + i, value.charCodeAt(i));
	};
	text(0, 'RIFF');
	view.setUint32(4, 36 + samples.length * 2, true);
	text(8, 'WAVEfmt ');
	view.setUint32(16, 16, true);
	view.setUint16(20, 1, true);
	view.setUint16(22, 1, true);
	view.setUint32(24, rate, true);
	view.setUint32(28, rate * 2, true);
	view.setUint16(32, 2, true);
	view.setUint16(34, 16, true);
	text(36, 'data');
	view.setUint32(40, samples.length * 2, true);
	for (let i = 0; i < samples.length; i += 1) {
		const sample = Math.max(-1, Math.min(1, samples[i]));
		view.setInt16(44 + i * 2, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true);
	}
	return buffer;
}

/** A take as the Mac wants it: a WAV at `TAKE_RATE`. */
export function takeWav(samples: Float32Array, rate: number): ArrayBuffer {
	return encodeWav(downsample(samples, rate, TAKE_RATE), Math.min(rate, TAKE_RATE));
}
