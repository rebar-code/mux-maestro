export type Status = 'waiting' | 'busy' | 'idle' | 'unknown';
export type IdleStage = 'awake' | 'yawning' | 'dozing';
export type Reachability = 'reachable' | 'unreachable' | 'tmuxMissing' | 'unknown';

export interface LastPrompt {
	text: string;
	at: number;
}

export interface Thread {
	id: string;
	host: string;
	hostColor: string;
	local: boolean;
	session: string;
	window: number;
	name: string;
	pane: string;
	panes: number;
	command: string;
	cwd: string;
	status: Status;
	since: number | null;
	idleStage: IdleStage;
	lastPrompt: LastPrompt | null;
	lastActivityAt: number | null;
	sessionActivity: number;
	chat: boolean;
}

export interface HostStats {
	cpuPercent: number | null;
	load1: number | null;
	cores: number | null;
	memUsedBytes: number | null;
	memTotalBytes: number | null;
	diskFreeBytes: number | null;
	diskTotalBytes: number | null;
	uptimeSeconds: number | null;
}

export interface Host {
	name: string;
	color: string;
	local: boolean;
	reachability: Reachability;
	threads: number;
	stats: HostStats | null;
}

export interface ChatMessage {
	n: number;
	role: 'user' | 'assistant' | 'tool';
	text: string;
	tool?: string;
}

export interface ChatPage {
	messages: ChatMessage[];
	next: number;
	reset: boolean;
}

export const CAPABILITIES = [
	'access',
	'manager',
	'voice',
	'replies',
	'upload',
	'sessionActions',
	'kill',
	'artifacts',
	'localServers',
	'stopServers',
	'notifications',
	'liveTerminal'
] as const;

export type Capability = (typeof CAPABILITIES)[number];

export interface Config {
	/** A key the server did not send counts as off. */
	capabilities: Partial<Record<Capability, boolean>>;
	grouping: 'recent' | 'host' | 'directory';
}
