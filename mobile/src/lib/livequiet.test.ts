import { describe, expect, it } from 'vitest';
import { isReport, silenceQueries, type QueryParser } from './livequiet';

describe('silenceQueries', () => {
	const csi: string[] = [];
	const dcs: string[] = [];
	const osc = new Map<number, (data: string) => boolean>();
	const key = (id: { prefix?: string; intermediates?: string; final: string }): string =>
		`${id.prefix ?? ''}${id.intermediates ?? ''}${id.final}`;
	const parser: QueryParser = {
		registerCsiHandler: (id, callback) => {
			expect(callback([])).toBe(true);
			csi.push(key(id));
		},
		registerDcsHandler: (id, callback) => {
			expect(callback('')).toBe(true);
			dcs.push(key(id));
		},
		registerOscHandler: (ident, callback) => void osc.set(ident, callback)
	};
	silenceQueries(parser);

	it('takes every report request', () => {
		for (const id of ['c', '>c', '=c', 'n', '?n', '$p', '?$p', '>q', 't', '?u']) {
			expect(csi, id).toContain(id);
		}
		expect(dcs).toEqual(['$q', '+q']);
	});

	it('drops a colour question and lets a colour be set', () => {
		for (const ident of [4, 10, 11, 12]) {
			expect(osc.get(ident)?.('?')).toBe(true);
			expect(osc.get(ident)?.('1;?')).toBe(true);
			expect(osc.get(ident)?.('#ff0000')).toBe(false);
		}
	});
});

describe('isReport', () => {
	it('knows the focus reports from typing', () => {
		expect(isReport('\x1b[I')).toBe(true);
		expect(isReport('\x1b[O')).toBe(true);
		expect(isReport('\x1b[A')).toBe(false);
		expect(isReport('I')).toBe(false);
	});
});
