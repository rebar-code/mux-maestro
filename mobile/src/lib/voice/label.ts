import type { VoiceMode } from '../types';

export type VoiceStatus = 'idle' | 'recording' | 'thinking' | 'speaking';

/** What a bar's status line is worked out from. */
export interface LabelState {
	/** The status of the bar's own target. */
	status: VoiceStatus;
	mode: VoiceMode;
	micMuted: boolean;
	/** The reply is paused, not stopped. */
	paused: boolean;
	/** Auto has the mic open for this bar and waits for a take. */
	hearing: boolean;
}

/**
 * The status line of a voice bar: what the voice is doing now. A bar that does
 * nothing says nothing, and its line is not drawn.
 */
export function voiceLabel(state: LabelState): string {
	if (state.micMuted) return 'Mic muted';
	switch (state.status) {
		case 'recording':
			return state.mode === 'auto' ? 'Listening…' : 'Recording — tap to send';
		case 'thinking':
			return 'Thinking…';
		case 'speaking':
			return state.paused ? 'Paused' : 'Speaking…';
		default:
			return state.mode === 'auto' && state.hearing ? 'Listening…' : '';
	}
}
