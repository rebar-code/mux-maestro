import { describe, expect, it } from 'vitest';
import { clampPan, pinchScale, ZOOM_MAX } from './zoom';

describe('pinch zoom', () => {
	it('scales with the distance between the fingers, between 1 and the limit', () => {
		expect(pinchScale(1, 100, 200)).toBe(2);
		expect(pinchScale(2, 200, 100)).toBe(1);
		expect(pinchScale(1, 100, 50)).toBe(1);
		expect(pinchScale(4, 100, 400)).toBe(ZOOM_MAX);
		expect(pinchScale(2, 0, 100)).toBe(2);
	});

	it('pans a zoomed image only as far as its own edge', () => {
		expect(clampPan(500, 2, 390)).toBe(195);
		expect(clampPan(-500, 2, 390)).toBe(-195);
		expect(clampPan(40, 2, 390)).toBe(40);
		expect(clampPan(40, 1, 390)).toBe(0);
	});
});
