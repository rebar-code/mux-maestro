import { postAudio } from '../api';
import { frameParser } from '../sse';
import type { VoiceEnd } from '../types';

export interface VoiceHandlers {
	/** What the Mac heard. */
	onTranscript: (text: string) => void;
	/** The reply's text, as it is written. */
	onDelta: (text: string) => void;
	/** One clip of the spoken reply, a WAV file. They arrive in playing order. */
	onAudio: (wav: ArrayBuffer) => void;
}

function decode(base64: string): ArrayBuffer {
	const binary = atob(base64);
	const bytes = new Uint8Array(binary.length);
	for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
	return bytes.buffer;
}

/** Read a voice stream to its `end` event. */
async function follow(response: Response, handlers: VoiceHandlers): Promise<VoiceEnd> {
	const reader = response.body?.pipeThrough(new TextDecoderStream()).getReader();
	const parse = frameParser();
	while (reader) {
		const { done, value } = await reader.read();
		if (done) break;
		for (const { event, data } of parse(value)) {
			if (event === 'end') return JSON.parse(data) as VoiceEnd;
			const body = JSON.parse(data) as { text?: string; wav?: string };
			if (event === 'transcript') handlers.onTranscript(body.text ?? '');
			else if (event === 'delta') handlers.onDelta(body.text ?? '');
			else if (event === 'audio' && body.wav) handlers.onAudio(decode(body.wav));
		}
	}
	return { outcome: 'timeout', reply: '', message: 'Connection lost' };
}

const query = (target: string, speaker: boolean): string =>
	`target=${encodeURIComponent(target)}&speaker=${speaker ? 1 : 0}`;

/**
 * Send one take. With `speaker` off the Mac synthesizes nothing. A take the
 * Mac refuses to start throws an `ApiError` whose `detail` says why.
 */
export async function sendVoice(
	target: string,
	speaker: boolean,
	wav: ArrayBuffer,
	handlers: VoiceHandlers,
	signal?: AbortSignal
): Promise<VoiceEnd> {
	return follow(await postAudio(`/api/voice?${query(target, speaker)}`, wav, signal), handlers);
}

/** Have the target's last reply read again. */
export async function replayVoice(
	target: string,
	handlers: VoiceHandlers,
	signal?: AbortSignal
): Promise<VoiceEnd> {
	return follow(
		await postAudio(`/api/voice/replay?${query(target, true)}`, null, signal),
		handlers
	);
}

/** A take has started: the Mac loads its models while the human talks. */
export async function warmVoice(speaker: boolean): Promise<void> {
	try {
		await postAudio(`/api/voice/warm?speaker=${speaker ? 1 : 0}`, null);
	} catch {
		// Only the head start is lost; the take itself says what is wrong.
	}
}
