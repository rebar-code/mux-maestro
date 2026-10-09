import type { Host, Indicator, Status, Thread } from './types';

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

/** A dot's class. Solid: look at it. Ring: nothing to do. `busy` turns. */
export type Dot = 'waiting' | 'unviewed' | 'busy' | 'viewed' | 'idle' | 'none';

const DOT: Record<Indicator, Dot> = {
	needsYou: 'waiting',
	unviewed: 'unviewed',
	working: 'busy',
	viewed: 'viewed',
	idle: 'idle',
	none: 'none'
};

/** The dot of a Mac that sends no `indicator`: it cannot say what was viewed. */
const FROM_STATUS: Record<Status, Dot> = {
	waiting: 'waiting',
	busy: 'busy',
	idle: 'viewed',
	unknown: 'none'
};

/**
 * The dot class. A sleeping thread is a grey ring whatever its status, but
 * one that finished and was never opened stays solid green.
 */
export function dotClass(thread: Pick<Thread, 'status' | 'idleStage' | 'indicator'>): Dot {
	const dot = thread.indicator ? DOT[thread.indicator] : FROM_STATUS[thread.status];
	return thread.idleStage === 'dozing' && dot !== 'unviewed' ? 'idle' : dot;
}
