/**
 * The short label the voice bar shows for each way a take can fail. A fault is
 * never silent: the bar always says what went wrong.
 */

/** Why `getUserMedia` refused. */
export function micFault(error: unknown): string {
	switch (error instanceof Error ? error.name : '') {
		case 'NotAllowedError':
		case 'SecurityError':
			return 'Mic blocked';
		case 'NotFoundError':
		case 'OverconstrainedError':
			return 'No microphone';
		case 'NotReadableError':
		case 'AbortError':
			return 'Mic in use';
		default:
			return 'Mic not available';
	}
}

interface Refusal {
	status: number;
	code: string | null;
	detail: string | null;
}

function isRefusal(error: unknown): error is Refusal {
	return typeof error === 'object' && error !== null && 'status' in error && 'code' in error;
}

/** Why a voice request failed: the Mac refused it (an `ApiError`), or never answered. */
export function requestFault(error: unknown): string {
	if (!isRefusal(error)) return 'Mac not reachable';
	if (error.status === 401) return 'Not paired';
	if (error.code === 'forbidden') return 'Not allowed';
	if (error.code === 'disabled') return 'Off in MuxMaestro Settings';
	// The models are still being fetched on the Mac.
	if (error.code === 'models') return 'Voice models loading';
	if (error.status === 413) return 'Take too long';
	if (error.detail) return error.detail;
	// The tailnet proxy answered for a Mac that did not.
	if (error.status === 502 || error.status === 504) return 'Mac not reachable';
	return `Mac error ${error.status}`;
}

/** Why a closed take was not sent. */
export function dropLabel(dropped: 'empty' | 'silent'): string {
	return dropped === 'empty' ? 'Mic gave no sound' : 'No speech heard';
}
