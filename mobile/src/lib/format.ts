import type { Host, Thread } from './types';

/** "40s", "2m", "3h", "5d" between two epoch-second times. */
export function age(at: number | null | undefined, now: number): string {
	if (at === null || at === undefined) return '';
	const seconds = Math.max(0, Math.floor(now - at));
	if (seconds < 60) return `${seconds}s`;
	if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
	if (seconds < 86_400) return `${Math.floor(seconds / 3600)}h`;
	return `${Math.floor(seconds / 86_400)}d`;
}

const GIB = 1_073_741_824;
const DASH = '—';

function gib(bytes: number): number {
	return bytes / GIB;
}

/** "212 GB", or "1.4 TB" from 1000 GB up. */
export function size(bytes: number): string {
	const g = gib(bytes);
	if (g >= 1000) return `${(g / 1024).toFixed(1)} TB`;
	return `${Math.round(g)} GB`;
}

/** The four numbers on a host card. A value the host has not sent is a dash. */
export function hostStatLabels(host: Host): string[] {
	const s = host.stats;
	const cpu = s?.cpuPercent;
	const load = s?.load1 != null && s.cores ? (s.load1 / s.cores).toFixed(2) : null;
	const mem =
		s?.memUsedBytes != null && s.memTotalBytes != null
			? `${Math.round(gib(s.memUsedBytes))} / ${Math.round(gib(s.memTotalBytes))} GB`
			: null;
	const disk = s?.diskFreeBytes != null ? `${size(s.diskFreeBytes)} free` : null;
	return [
		`CPU ${cpu != null ? `${Math.round(cpu)}%` : DASH}`,
		`load ${load ?? DASH}${load ? '/core' : ''}`,
		mem ?? `RAM ${DASH}`,
		disk ?? `disk ${DASH}`
	];
}

/** A home directory prefix becomes "~". */
export function shortCwd(cwd: string): string {
	const match = /^\/(?:Users|home)\/[^/]+(\/.*)?$/.exec(cwd);
	return match ? `~${match[1] ?? ''}` : cwd;
}

export function threadTitle(thread: Thread): string {
	return thread.panes > 1 ? `${thread.name} · ${thread.command}` : thread.name;
}

export function statusLabel(thread: Thread): string {
	if (thread.status === 'waiting') return 'needs you';
	if (thread.status === 'busy') return 'running';
	if (thread.status === 'idle') return thread.idleStage === 'dozing' ? 'sleeping' : 'idle';
	return thread.command;
}

export function stageTag(thread: Thread): string {
	if (thread.idleStage === 'dozing') return '💤';
	if (thread.idleStage === 'yawning') return '🥱';
	return '';
}

/** The dot colour class: a sleeping thread is grey whatever its status. */
export function dotClass(thread: Pick<Thread, 'status' | 'idleStage'>): string {
	return thread.idleStage === 'dozing' ? 'idle' : thread.status;
}
