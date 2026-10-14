import type { Thread } from './types';

/**
 * Where the picker is. `models` and `efforts` are the two lists; `loading`
 * is the wait for the first one, and where a step that failed leaves the sheet.
 */
export type ModelStage = 'closed' | 'loading' | 'models' | 'efforts';

/**
 * Whether the thread's agent can be asked for its model menu now. The menu is
 * opened by `/model`, which only an idle agent takes.
 */
export function modelReady(thread: Thread | undefined): boolean {
	return (
		thread !== undefined && thread.chat && thread.status !== 'busy' && thread.status !== 'waiting'
	);
}

/** Why the Mac did not do a step, for the sheet. */
export function modelRefusal(code: string | null, detail: string | null): string {
	if (detail) return detail;
	if (code === 'not_found') return 'No longer there';
	if (code === 'disabled') return 'Switched off on the Mac';
	return 'Failed';
}

/** The same for whatever a step threw: the Mac's refusal, or no answer at all. */
export function modelError(error: unknown): string {
	if (!(error instanceof Error) || !('status' in error)) return 'Mac unreachable';
	const { code, detail } = error as { code?: string | null; detail?: string | null };
	return modelRefusal(code ?? null, detail ?? null);
}
