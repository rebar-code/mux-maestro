import { describe, expect, it } from 'vitest';
import {
	BOX_MIN,
	boxCap,
	byteLength,
	bytesOver,
	enterSends,
	hasHardwareKeyboard,
	limitLabel,
	normalizeText,
	remainingDraft,
	TEXT_MAX_BYTES
} from './compose';

describe('normalizeText', () => {
	it('turns carriage returns into newlines', () => {
		expect(normalizeText('a\r\nb\rc\nd')).toBe('a\nb\nc\nd');
		expect(normalizeText('one\r\n\r\ntwo')).toBe('one\n\ntwo');
	});

	it('keeps line breaks and tabs', () => {
		expect(normalizeText('a\n\tb\n')).toBe('a\n\tb\n');
	});
});

describe('the byte cap', () => {
	it('counts bytes, not characters', () => {
		expect(byteLength('abc')).toBe(3);
		expect(byteLength('é')).toBe(2);
		expect(byteLength('日本')).toBe(6);
		expect(byteLength('🙂')).toBe(4);
	});

	it('takes exactly the limit and no more', () => {
		expect(bytesOver('x'.repeat(TEXT_MAX_BYTES))).toBe(0);
		expect(bytesOver('x'.repeat(TEXT_MAX_BYTES + 1))).toBe(1);
		expect(bytesOver('é'.repeat(TEXT_MAX_BYTES / 2))).toBe(0);
		expect(bytesOver('é'.repeat(TEXT_MAX_BYTES / 2 + 1))).toBe(2);
	});

	it('counts the text as it is sent: trimmed, with single-byte line ends', () => {
		expect(bytesOver(`  ${'x'.repeat(TEXT_MAX_BYTES)}\n\n`)).toBe(0);
		expect(bytesOver('a\r\n'.repeat(TEXT_MAX_BYTES / 2))).toBe(0);
	});

	it('says how far over', () => {
		expect(limitLabel('hello')).toBeNull();
		expect(limitLabel('x'.repeat(TEXT_MAX_BYTES + 1))).toBe('Too long by 1 byte');
		expect(limitLabel('x'.repeat(TEXT_MAX_BYTES + 120))).toBe('Too long by 120 bytes');
	});
});

describe('boxCap', () => {
	it('is eight lines on a tall screen', () => {
		expect(boxCap(22, 22, 932)).toBe(8 * 22 + 22);
	});

	it('is 40% of what is visible when that is less', () => {
		// The keyboard is up: 300px are left.
		expect(boxCap(22, 22, 300)).toBe(120);
		expect(boxCap(22, 22, 667)).toBe(8 * 22 + 22);
		expect(boxCap(22, 22, 400)).toBe(160);
	});

	it('still caps when the line could not be measured', () => {
		expect(boxCap(NaN, NaN, 932)).toBe(8 * 22 + 22);
		expect(boxCap(0, 22, 932)).toBe(8 * 22 + 22);
	});

	it('is never shorter than a touch target', () => {
		expect(boxCap(22, 22, 60)).toBe(BOX_MIN);
	});
});

describe('Enter', () => {
	it('needs a pointer that is fine and can hover to count as real keys', () => {
		expect(hasHardwareKeyboard({ fine: true, hover: true })).toBe(true);
		expect(hasHardwareKeyboard({ fine: false, hover: false })).toBe(false);
		expect(hasHardwareKeyboard({ fine: true, hover: false })).toBe(false);
		expect(hasHardwareKeyboard({ fine: false, hover: true })).toBe(false);
	});

	/** A phone: coarse pointer, the box focused, its on-screen keyboard up. */
	const phone = { finePointer: false, focused: true, keyboardUp: true };
	const press = (over: Partial<Parameters<typeof enterSends>[0]>): boolean =>
		enterSends({
			key: 'Enter',
			shiftKey: false,
			metaKey: false,
			ctrlKey: false,
			isComposing: false,
			keyCode: 13,
			...phone,
			...over
		});

	it('is a new line on a phone with its on-screen keyboard up', () => {
		expect(press({})).toBe(false);
	});

	it('sends with a fine pointer that hovers', () => {
		expect(press({ finePointer: true })).toBe(true);
		expect(press({ finePointer: true, keyboardUp: false })).toBe(true);
	});

	it('sends on a touch device whose keys are real: the box has focus and no keyboard is up', () => {
		expect(press({ keyboardUp: false })).toBe(true);
		// Not focused: the key is not for this box.
		expect(press({ keyboardUp: false, focused: false })).toBe(false);
	});

	it('sends with Cmd or Ctrl everywhere', () => {
		expect(press({ metaKey: true })).toBe(true);
		expect(press({ ctrlKey: true })).toBe(true);
		expect(press({ metaKey: true, finePointer: true })).toBe(true);
	});

	it('is always a new line with Shift', () => {
		expect(press({ shiftKey: true })).toBe(false);
		expect(press({ shiftKey: true, finePointer: true })).toBe(false);
		expect(press({ shiftKey: true, keyboardUp: false })).toBe(false);
		expect(press({ shiftKey: true, metaKey: true })).toBe(false);
	});

	it('never sends while a composition is open, however the browser says so', () => {
		expect(press({ isComposing: true, finePointer: true })).toBe(false);
		// Safari: the Enter that ends a composition says it is not composing.
		expect(press({ keyCode: 229, finePointer: true })).toBe(false);
		expect(press({ keyCode: 229, metaKey: true })).toBe(false);
	});

	it('is only about Enter', () => {
		expect(press({ key: 'a', finePointer: true })).toBe(false);
		expect(press({ key: 'Tab', metaKey: true })).toBe(false);
	});
});

describe('remainingDraft', () => {
	it('empties the box when it still holds what was sent', () => {
		expect(remainingDraft('ship it', 'ship it')).toBe('');
		expect(remainingDraft('  ship it \n', 'ship it')).toBe('');
	});

	it('keeps what was typed while the send was on its way', () => {
		expect(remainingDraft('ship it and then deploy', 'ship it')).toBe('and then deploy');
		expect(remainingDraft('ship it\nsecond thought', 'ship it')).toBe('second thought');
		expect(remainingDraft('one\r\ntwo more', 'one\ntwo')).toBe('more');
	});

	it('leaves a box that was changed in another way alone', () => {
		expect(remainingDraft('something else', 'ship it')).toBe('something else');
		expect(remainingDraft('do ship it', 'ship it')).toBe('do ship it');
		expect(remainingDraft('', 'ship it')).toBe('');
	});
});
