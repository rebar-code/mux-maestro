import { describe, expect, it } from 'vitest';
import { askedKey, countRequests, groupRequests, isDone, stateLabel, withState } from './requests';
import type { TrackedRequest } from './types';

function request(over: Partial<TrackedRequest>): TrackedRequest {
	return {
		id: 'req-1',
		title: 'Fix the checkout test',
		project: 'acme-app',
		asked: '2026-10-03',
		state: 'todo',
		...over
	};
}

const rows = [
	request({ id: 'a', project: 'acme-app', asked: '2026-10-03' }),
	request({ id: 'b', project: 'devbox', asked: '2026-10-04', state: 'in_progress' }),
	request({ id: 'c', project: 'acme-app', asked: '2026-10-04', state: 'blocked' }),
	request({ id: 'd', project: 'devbox', asked: '2026-10-03', state: 'done' }),
	request({ id: 'e', project: 'acme-app', asked: '2026-10-03', state: 'review' }),
	request({ id: 'f', project: '', asked: '2026-10-02' }),
	request({ id: 'g', project: 'acme-app', asked: '2026-10-04', state: 'done' })
];

const ids = (groups: ReturnType<typeof groupRequests>): [string, string[]][] =>
	groups.map((group) => [group.project, group.requests.map((row) => row.id)]);

describe('isDone', () => {
	it('is true only for done', () => {
		expect(isDone('done')).toBe(true);
		for (const state of ['todo', 'in_progress', 'blocked', 'review', 'parked'])
			expect(isDone(state)).toBe(false);
	});
});

describe('askedKey', () => {
	it('is the last date in the text', () => {
		expect(askedKey('2026-10-04')).toBe('2026-10-04');
		expect(askedKey('earlier, restated 2026-10-04')).toBe('2026-10-04');
		expect(askedKey('2026-09-30, restated 2026-10-02')).toBe('2026-10-02');
	});

	it('is empty when the text holds no date', () => {
		expect(askedKey('earlier')).toBe('');
		expect(askedKey('')).toBe('');
		expect(askedKey('2026-10')).toBe('');
	});
});

describe('groupRequests', () => {
	it('sorts by the last date in a free-form `asked`, rows with no date last', () => {
		const free = [
			request({ id: 'n', asked: 'earlier' }),
			request({ id: 'r', asked: 'earlier, restated 2026-10-04' }),
			request({ id: 'o', asked: '2026-10-03' }),
			request({ id: 's', asked: '2026-10-04' }),
			request({ id: 'm', asked: 'some time ago' })
		];
		expect(ids(groupRequests(free, false))).toEqual([['acme-app', ['r', 's', 'o', 'n', 'm']]]);
	});

	it('groups a project whose only dated row was restated by that date', () => {
		const free = [
			request({ id: 'a', project: 'devbox', asked: '2026-10-03' }),
			request({ id: 'b', project: 'acme-app', asked: 'earlier, restated 2026-10-04' })
		];
		expect(ids(groupRequests(free, false))).toEqual([
			['acme-app', ['b']],
			['devbox', ['a']]
		]);
	});

	it('keeps the open rows, newest first, grouped by the newest row of each project', () => {
		expect(ids(groupRequests(rows, false))).toEqual([
			['devbox', ['b']],
			['acme-app', ['c', 'a', 'e']],
			['Other', ['f']]
		]);
	});

	it('keeps the done rows only', () => {
		expect(ids(groupRequests(rows, true))).toEqual([
			['acme-app', ['g']],
			['devbox', ['d']]
		]);
	});

	it('keeps the file order for rows of one day', () => {
		const same = ['x', 'y', 'z'].map((id) => request({ id }));
		expect(ids(groupRequests(same, false))).toEqual([['acme-app', ['x', 'y', 'z']]]);
	});

	it('counts an unknown state as open', () => {
		expect(ids(groupRequests([request({ id: 'p', state: 'parked' })], false))).toEqual([
			['acme-app', ['p']]
		]);
	});

	it('does not reorder the list it was given', () => {
		const copy = [...rows];
		groupRequests(rows, false);
		expect(rows).toEqual(copy);
	});

	it('is empty for no rows', () => {
		expect(groupRequests([], false)).toEqual([]);
	});
});

describe('countRequests', () => {
	it('counts open and done', () => {
		expect(countRequests(rows)).toEqual({ open: 5, done: 2 });
		expect(countRequests([])).toEqual({ open: 0, done: 0 });
	});
});

describe('withState', () => {
	const list = { schema: 1, requests: rows };

	it('changes one row and leaves the list it was given', () => {
		const next = withState(list, 'a', 'done');
		expect(next.requests.find((row) => row.id === 'a')?.state).toBe('done');
		expect(next.requests.filter((row, i) => row !== rows[i]).map((row) => row.id)).toEqual(['a']);
		expect(rows[0].state).toBe('todo');
	});

	it('with `from`, changes a row only while it is still in that state', () => {
		expect(withState(list, 'b', 'todo', 'done').requests[1].state).toBe('in_progress');
		expect(withState(list, 'b', 'todo', 'in_progress').requests[1].state).toBe('todo');
	});
});

describe('stateLabel', () => {
	it('names the states the checkbox does not show', () => {
		expect(stateLabel('in_progress')).toBe('in progress');
		expect(stateLabel('blocked')).toBe('blocked');
		expect(stateLabel('review')).toBe('review');
		expect(stateLabel('todo')).toBe('');
		expect(stateLabel('done')).toBe('');
		expect(stateLabel('parked')).toBe('parked');
	});
});
