import { describe, expect, it } from 'vitest';
import { canReload } from './update';

describe('canReload', () => {
	it('reloads when nothing would be lost', () => {
		expect(canReload({ hidden: false, typing: false, holds: 0 })).toBe(true);
	});

	it('waits while the keyboard is under the fingers', () => {
		expect(canReload({ hidden: false, typing: true, holds: 0 })).toBe(false);
	});

	it('does not wait for a text box once the app is in the background', () => {
		expect(canReload({ hidden: true, typing: true, holds: 0 })).toBe(true);
	});

	it('never cuts a write that is on its way', () => {
		expect(canReload({ hidden: false, typing: false, holds: 1 })).toBe(false);
		expect(canReload({ hidden: true, typing: false, holds: 2 })).toBe(false);
	});
});
