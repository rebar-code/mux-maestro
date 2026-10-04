import { describe, expect, it } from 'vitest';
import { canReload } from './update';

const idle = { hidden: false, typing: false, unsent: false, holds: 0, blocked: false };

describe('canReload', () => {
	it('reloads when nothing would be lost', () => {
		expect(canReload(idle)).toBe(true);
		expect(canReload({ ...idle, hidden: true })).toBe(true);
	});

	it('waits while the keyboard is under the fingers', () => {
		expect(canReload({ ...idle, typing: true })).toBe(false);
	});

	it('does not wait for an empty text box once the app is in the background', () => {
		expect(canReload({ ...idle, hidden: true, typing: true })).toBe(true);
	});

	it('waits while a text box holds text that was not sent, focused or not', () => {
		expect(canReload({ ...idle, unsent: true })).toBe(false);
		expect(canReload({ ...idle, unsent: true, hidden: true })).toBe(false);
	});

	it('never cuts a write that is on its way', () => {
		expect(canReload({ ...idle, holds: 1 })).toBe(false);
		expect(canReload({ ...idle, hidden: true, holds: 2 })).toBe(false);
	});

	it('never cuts a voice turn', () => {
		expect(canReload({ ...idle, blocked: true })).toBe(false);
		expect(canReload({ ...idle, hidden: true, blocked: true })).toBe(false);
	});
});
