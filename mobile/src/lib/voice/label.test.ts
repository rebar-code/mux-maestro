import { describe, expect, it } from 'vitest';
import { voiceLabel, type LabelState } from './label';

const state = (over: Partial<LabelState> = {}): LabelState => ({
	status: 'idle',
	mode: 'manual',
	micMuted: false,
	paused: false,
	hearing: false,
	...over
});

describe('the voice status line', () => {
	it('says nothing while the voice does nothing', () => {
		expect(voiceLabel(state())).toBe('');
		expect(voiceLabel(state({ mode: 'auto' }))).toBe('');
		// Manual never waits for a take with the mic open.
		expect(voiceLabel(state({ hearing: true }))).toBe('');
	});

	it('says what a turn is doing', () => {
		expect(voiceLabel(state({ status: 'recording' }))).toBe('Recording — tap to send');
		expect(voiceLabel(state({ status: 'recording', mode: 'auto' }))).toBe('Listening…');
		expect(voiceLabel(state({ status: 'thinking' }))).toBe('Thinking…');
		expect(voiceLabel(state({ status: 'speaking' }))).toBe('Speaking…');
		expect(voiceLabel(state({ status: 'speaking', paused: true }))).toBe('Paused');
	});

	it('says Auto listens while it waits for a take', () => {
		expect(voiceLabel(state({ mode: 'auto', hearing: true }))).toBe('Listening…');
	});

	it('says the mic is muted, whatever else goes on', () => {
		expect(voiceLabel(state({ micMuted: true }))).toBe('Mic muted');
		expect(voiceLabel(state({ micMuted: true, status: 'speaking' }))).toBe('Mic muted');
		expect(voiceLabel(state({ micMuted: true, mode: 'auto', hearing: true }))).toBe('Mic muted');
	});
});
