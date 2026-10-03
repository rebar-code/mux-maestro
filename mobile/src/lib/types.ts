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
	'keyBar',
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
	/** What a phone starts with until its own voice controls are used. */
	voice?: VoiceDefaults;
	upload?: UploadLimits;
}

export interface UploadLimits {
	/** The largest file the Mac accepts. */
	maxBytes: number;
}

export interface PromptOption {
	/** The number the pane takes for this answer. */
	n: number;
	label: string;
}

/** What a waiting pane asks: a permission, or a question. */
export interface Prompt {
	id: string;
	kind: 'permission' | 'question';
	title: string;
	detail: string;
	question: string;
	options: PromptOption[];
}

/** A slash command of a thread. `name` has no leading slash. */
export interface Command {
	name: string;
	description: string;
	source: 'skill' | 'command' | 'builtin';
}

export type VoiceMode = 'auto' | 'manual';

export interface VoiceDefaults {
	mode: VoiceMode;
	/** On: the reply is spoken. Off: input only. */
	speaker: boolean;
	/** The longest take the Mac accepts. */
	maxSeconds: number;
}

export type ManagerStatus = 'off' | 'idle' | 'busy' | 'waiting';

/** A card on the manager home: an agent that waits, or a review item. */
export interface ManagerItem {
	/** What dismiss takes. Only a review item has one. */
	key: string | null;
	title: string;
	detail: string;
	severity: 'info' | 'warn' | 'blocked' | null;
	at: number;
	/** The thread it opens, when the thread list has it. */
	thread: string | null;
}

export interface ManagerUpdate {
	kind: 'done' | 'notification';
	text: string;
	at: number;
	host: string;
	session: string;
	thread: string | null;
}

/** The manager turn in flight, whichever side started it. */
export interface ManagerTurn {
	prompt: string;
	reply: string;
}

/** The `manager` event: what changes without a request. */
export interface ManagerLive {
	needsYou: ManagerItem[];
	review: ManagerItem[];
	updates: ManagerUpdate[];
	turn: ManagerTurn | null;
}

export interface ManagerHome extends ManagerLive {
	status: ManagerStatus;
	chat: ChatPage;
}

/** The last event of a turn's stream. */
export interface TurnEnd {
	outcome: 'done' | 'permission' | 'timeout' | 'unreachable' | 'refused';
	reply: string;
	/** Set when there is something to tell the human. */
	message: string | null;
}

/** The last event of a voice stream. `empty` and `failed` never reached the target. */
export interface VoiceEnd extends Omit<TurnEnd, 'outcome'> {
	outcome: TurnEnd['outcome'] | 'empty' | 'failed';
}
