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

	const press = (over: Partial<Parameters<typeof enterSends>[0]>): boolean =>
		enterSends({ key: 'Enter', shiftKey: false, isComposing: false, hardware: true, ...over });

	it('sends on real keys', () => {
		expect(press({})).toBe(true);
	});

	it('is a new line with Shift, and on a touch keyboard', () => {
		expect(press({ shiftKey: true })).toBe(false);
		expect(press({ hardware: false })).toBe(false);
	});

	it('never sends while a composition is open', () => {
		expect(press({ isComposing: true })).toBe(false);
	});

	it('is only about Enter', () => {
		expect(press({ key: 'a' })).toBe(false);
		expect(press({ key: 'Tab' })).toBe(false);
	});
});
