import type { RequestList, RequestState, TrackedRequest } from './types';

/** The heading of the rows that name no project. */
export const NO_PROJECT = 'Other';

export function isDone(state: RequestState): boolean {
	return state === 'done';
}

export interface RequestGroup {
	project: string;
	requests: TrackedRequest[];
}

/**
 * What a row sorts by: the last `YYYY-MM-DD` in `asked`, which may be free
 * text such as "earlier, restated 2026-10-04". `''` when it holds none.
 */
export function askedKey(asked: string): string {
	return asked.match(/\d{4}-\d{2}-\d{2}/g)?.at(-1) ?? '';
}

/**
 * The done rows, or the open ones, newest first by the day asked; rows with no
 * date go last. Rows of one day keep the file's order. Each project is one
 * group, in the order of its newest row.
 */
export function groupRequests(requests: TrackedRequest[], done: boolean): RequestGroup[] {
	const rows = requests
		.filter((request) => isDone(request.state) === done)
		.map((request) => ({ request, key: askedKey(request.asked ?? '') }))
		// `sort` is stable: rows of one day keep the file's order. `''` sorts last.
		.sort((a, b) => (a.key < b.key ? 1 : a.key > b.key ? -1 : 0))
		.map(({ request }) => request);
	const groups = new Map<string, TrackedRequest[]>();
	for (const request of rows) {
		const project = request.project || NO_PROJECT;
		const group = groups.get(project);
		if (group) group.push(request);
		else groups.set(project, [request]);
	}
	return [...groups].map(([project, list]) => ({ project, requests: list }));
}

export interface RequestCounts {
	open: number;
	done: number;
}

export function countRequests(requests: TrackedRequest[]): RequestCounts {
	const done = requests.filter((request) => isDone(request.state)).length;
	return { open: requests.length - done, done };
}

/**
 * The list with one row put in `state`. With `from`, only a row still in that
 * state changes: a newer answer from the Mac is not undone.
 */
export function withState(
	list: RequestList,
	id: string,
	state: RequestState,
	from?: RequestState
): RequestList {
	return {
		...list,
		requests: list.requests.map((request) =>
			request.id === id && (from === undefined || request.state === from)
				? { ...request, state }
				: request
		)
	};
}

/** The chip a row shows. Empty for todo and done: the checkbox says those. */
export function stateLabel(state: RequestState): string {
	switch (state) {
		case 'todo':
		case 'done':
			return '';
		case 'in_progress':
			return 'in progress';
		default:
			return state;
	}
}
