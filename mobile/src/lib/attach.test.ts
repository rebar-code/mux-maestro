import { describe, expect, it } from 'vitest';
import {
	attachReduce,
	BUSY_TRIES,
	busyRetry,
	insertPath,
	isImage,
	nextUpload,
	pastedName,
	removePath,
	tileLabel,
	tooLarge,
	uploadFailure,
	uploadsPending,
	type Attached,
	type AttachEvent
} from './attach';

const add = (key: number, size = 10, max: number | null = 100): AttachEvent => ({
	type: 'add',
	key,
	name: `file-${key}.txt`,
	size,
	image: false,
	max
});

const run = (...events: AttachEvent[]): Attached[] =>
	events.reduce<Attached[]>((items, event) => attachReduce(items, event), []);

describe('attachReduce', () => {
	it('adds files in pick order, waiting', () => {
		const items = run(add(1), add(2), add(3));
		expect(items.map((item) => [item.key, item.state])).toEqual([
			[1, 'waiting'],
			[2, 'waiting'],
			[3, 'waiting']
		]);
	});

	it('fails a file over the limit at once, with no retry', () => {
		const [item] = run(add(1, 101));
		expect(item).toMatchObject({ state: 'failed', error: 'Too large', retry: false });
		expect(run(add(1, 100))[0].state).toBe('waiting');
		expect(run(add(1, 1e9, null))[0].state).toBe('waiting');
	});

	it('follows one file from start to done', () => {
		let items = run(add(1), { type: 'start', key: 1 });
		expect(items[0]).toMatchObject({ state: 'uploading', progress: 0 });
		items = attachReduce(items, { type: 'progress', key: 1, progress: 0.4 });
		expect(items[0].progress).toBe(0.4);
		items = attachReduce(items, { type: 'progress', key: 1, progress: 7 });
		expect(items[0].progress).toBe(1);
		items = attachReduce(items, { type: 'done', key: 1, text: '/Users/me/acme-app/a.txt' });
		expect(items[0]).toMatchObject({
			state: 'done',
			progress: 1,
			text: '/Users/me/acme-app/a.txt'
		});
		// Progress that arrives late changes nothing.
		expect(attachReduce(items, { type: 'progress', key: 1, progress: 0.2 })[0].progress).toBe(1);
	});

	it('fails, and goes back to waiting on a retry that is allowed', () => {
		let items = run(
			add(1),
			{ type: 'start', key: 1 },
			{ type: 'fail', key: 1, error: 'Offline', retry: true }
		);
		expect(items[0]).toMatchObject({ state: 'failed', error: 'Offline', retry: true });
		items = attachReduce(items, { type: 'retry', key: 1 });
		expect(items[0]).toMatchObject({ state: 'waiting', error: null, progress: 0 });
		// Too large stays failed.
		const big = attachReduce(run(add(2, 500)), { type: 'retry', key: 2 });
		expect(big[0].state).toBe('failed');
	});

	it('removes one, clears all, and never changes the list it was given', () => {
		const items = run(add(1), add(2));
		const less = attachReduce(items, { type: 'remove', key: 1 });
		expect(less.map((item) => item.key)).toEqual([2]);
		expect(items).toHaveLength(2);
		expect(attachReduce(items, { type: 'clear' })).toEqual([]);
	});
});

describe('the queue', () => {
	it('sends one at a time, in pick order', () => {
		let items = run(add(1), add(2), add(3));
		expect(nextUpload(items)?.key).toBe(1);
		items = attachReduce(items, { type: 'start', key: 1 });
		expect(nextUpload(items)).toBeNull();
		items = attachReduce(items, { type: 'done', key: 1, text: 'a' });
		expect(nextUpload(items)?.key).toBe(2);
	});

	it('skips what failed', () => {
		const items = run(add(1, 500), add(2));
		expect(nextUpload(items)?.key).toBe(2);
	});

	it('holds Send while a file is waiting or on its way', () => {
		expect(uploadsPending([])).toBe(false);
		expect(uploadsPending(run(add(1)))).toBe(true);
		expect(uploadsPending(run(add(1), { type: 'start', key: 1 }))).toBe(true);
		expect(
			uploadsPending(run(add(1), { type: 'start', key: 1 }, { type: 'done', key: 1, text: 'a' }))
		).toBe(false);
		expect(uploadsPending(run(add(1, 500)))).toBe(false);
	});
});

describe('paths in the reply box', () => {
	it('puts a path at the end, with a space to type on from', () => {
		expect(insertPath('', '/Users/me/acme-app/a.png')).toBe('/Users/me/acme-app/a.png ');
		expect(insertPath('look at', '/a.png')).toBe('look at /a.png ');
		expect(insertPath('look at ', '/a.png')).toBe('look at /a.png ');
		expect(insertPath('/a.png ', "'/b c.png'")).toBe("/a.png '/b c.png' ");
	});

	it('takes a path out again when it is still there unchanged', () => {
		expect(removePath('/a.png ', '/a.png')).toBe('');
		expect(removePath('/a.png /b.png ', '/a.png')).toBe('/b.png ');
		expect(removePath('/a.png /b.png ', '/b.png')).toBe('/a.png ');
		expect(removePath('see /a.png please', '/a.png')).toBe('see please');
		expect(removePath("x '/b c.png' y", "'/b c.png'")).toBe('x y');
	});

	it('leaves the text alone when the path was edited or is gone', () => {
		expect(removePath('hello', '/a.png')).toBe('hello');
		expect(removePath('/a.png2 ', '/a.png')).toBe('/a.png2 ');
		expect(removePath('x/a.png ', '/a.png')).toBe('x/a.png ');
		expect(removePath('/a.pn ', '/a.png')).toBe('/a.pn ');
	});
});

describe('uploadFailure', () => {
	const refused = (status: number, detail: string | null = null) => ({
		status,
		code: null,
		detail
	});

	it('labels each kind of failure', () => {
		expect(uploadFailure(refused(413), true)).toEqual({ error: 'Too large', retry: false });
		expect(uploadFailure(refused(403), true)).toEqual({ error: 'Refused', retry: false });
		expect(uploadFailure(refused(400), true)).toEqual({ error: 'Refused', retry: false });
		expect(uploadFailure(refused(409, 'A reply is being sent'), true)).toEqual({
			error: 'A reply is being sent',
			retry: true
		});
		expect(uploadFailure(refused(503), true)).toEqual({ error: 'Refused', retry: true });
	});

	it('says Offline when nothing answered, or the phone has no network', () => {
		expect(uploadFailure(null, true)).toEqual({ error: 'Offline', retry: true });
		expect(uploadFailure(refused(403), false)).toEqual({ error: 'Offline', retry: true });
	});
});

describe('a thread that is taking another write', () => {
	const busy = { status: 409, code: 'busy', detail: 'A reply is being sent' };

	it('sends the file again by itself, a few times', () => {
		expect(busyRetry(busy, 0)).toBe(true);
		expect(busyRetry(busy, BUSY_TRIES - 1)).toBe(true);
		expect(busyRetry(busy, BUSY_TRIES)).toBe(false);
	});

	it('does not do so for any other refusal', () => {
		expect(busyRetry({ status: 409, code: 'waiting', detail: null }, 0)).toBe(false);
		expect(busyRetry({ status: 503, code: 'busy', detail: null }, 0)).toBe(false);
		expect(busyRetry(null, 0)).toBe(false);
	});

	it('puts the file back in the queue, at its place', () => {
		let items = run(add(1), add(2), { type: 'start', key: 1 });
		items = attachReduce(items, { type: 'requeue', key: 1 });
		expect(items[0]).toMatchObject({ state: 'waiting', progress: 0, error: null });
		expect(nextUpload(items)?.key).toBe(1);
	});
});

describe('names and labels', () => {
	it('names a pasted image by its count and type', () => {
		expect(pastedName(1, 'image/png')).toBe('pasted-1.png');
		expect(pastedName(2, 'image/jpeg')).toBe('pasted-2.jpg');
		expect(pastedName(3, 'image/x-unknown')).toBe('pasted-3.png');
	});

	it('knows images and sizes', () => {
		expect(isImage('image/png')).toBe(true);
		expect(isImage('text/plain')).toBe(false);
		expect(isImage('')).toBe(false);
		expect(tooLarge(11, 10)).toBe(true);
		expect(tooLarge(10, 10)).toBe(false);
		expect(tooLarge(11, null)).toBe(false);
	});

	it('writes the state line of a tile', () => {
		const [waiting] = run(add(1));
		expect(tileLabel(waiting)).toBe('Waiting');
		expect(tileLabel({ ...waiting, state: 'uploading', progress: 0.426 })).toBe('43%');
		expect(tileLabel({ ...waiting, state: 'done' })).toBe('Attached');
		expect(tileLabel({ ...waiting, state: 'failed', error: 'Offline' })).toBe('Offline');
	});
});
