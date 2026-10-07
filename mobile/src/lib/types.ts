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
	/** The Claude or Codex conversation the pane runs: what a `muxmaestro://thread/` link names. */
	agent?: string | null;
	/** The pull requests the Mac shows on the window. */
	prs?: ThreadPR[];
}

export interface ThreadPR {
	number: number;
	state: 'open' | 'draft' | 'merged' | 'closed';
	url: string;
	title: string;
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
	/** The agent session `next` belongs to. Absent before its first message. */
	session?: string;
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
	'find',
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
	/** The number the pane takes for this answer. Past 9 it has no key: read-only. */
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
	/** The option the pane's cursor is on: what Enter takes. */
	selected?: number;
	/** The menu is scrolled: it has rows above, or below, the ones listed. */
	moreAbove?: boolean;
	moreBelow?: boolean;
	/** The pane shows more of the detail than the Mac sent. */
	truncated?: boolean;
}

/** The answer of `GET /prompt`. */
export interface PromptState {
	prompt: Prompt | null;
	/** Names what the pane waits on, also when it has no readable choices. */
	id: string | null;
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

export type ManagerStatus = 'off' | 'unknown' | 'idle' | 'busy' | 'waiting';

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
	/** A pointer's buttons, as the Mac sent them. Not checked: `parseCard` reads it. */
	card?: unknown;
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
	/** The pane's own spinner line ("Incubating… 4m 48s"), when it could be read. */
	spinner?: string | null;
}

/** The `manager` event: what changes without a request. */
export interface ManagerLive {
	needsYou: ManagerItem[];
	review: ManagerItem[];
	/** Sessions the Maestro points the user at. Left out by a Mac that has no pointers. */
	points?: ManagerItem[];
	updates: ManagerUpdate[];
	turn: ManagerTurn | null;
}

export interface ManagerHome extends ManagerLive {
	status: ManagerStatus;
	/** Whether the Maestro's pane sleeps. An older Mac does not say. */
	idleStage?: IdleStage;
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

/** The last segment of `/api/tmux/<action>`. The Mac takes no other word. */
export type TmuxAction =
	| 'new-session'
	| 'new-window'
	| 'rename-session'
	| 'rename-window'
	| 'archive-window'
	| 'kill-session'
	| 'kill-window'
	| 'kill-pane'
	| 'zoom-pane';

/** What an action is done to: a thread, or the session that holds it. */
export interface ActionTarget {
	thread: string;
}

/** A start and an end offset in a string. */
export type Range = [number, number];

export interface FindMatch {
	/** The line of `text`, from 0. */
	line: number;
	/** Where the query is in that line. */
	ranges: Range[];
}

/** A thread's scrollback and where the query is in it. */
export interface FindResult {
	text: string;
	matches: FindMatch[];
	/** There were more matches than the Mac sends. */
	truncated: boolean;
}

export type ArtifactKind = 'image' | 'pdf' | 'markdown' | 'html' | 'code' | 'text' | 'other';

/** One file a thread's agent made. The Mac reads it by `id`; the phone never sends a path. */
export interface ArtifactFile {
	id: string;
	name: string;
	dir: string;
	kind: ArtifactKind;
	mime: string;
	/** Bytes, when the file is there. */
	size: number | null;
	at: number;
	exists: boolean;
}

export interface ArtifactLink {
	url: string;
	host: string;
	path: string;
	at: number | null;
}

export interface ArtifactList {
	files: ArtifactFile[];
	links: ArtifactLink[];
	/** The thread runs on another host: its files are not read. */
	remote: boolean;
}

/** One port of something that runs. `mappable`: the Mac can publish it on the tailnet. */
export interface RunningLink {
	label: string;
	port: number;
	open: boolean;
	mappable: boolean;
}

interface RunningRow {
	key: string;
	label: string;
	host: string;
	local: boolean;
}

export interface RunningServer extends RunningRow {
	port: number;
	https: boolean;
	mappable: boolean;
}

export interface RunningContainer extends RunningRow {
	count: number;
	links: RunningLink[];
}

/** What a thread has running, as the Mac's Running drawer lists it. */
export interface RunningList {
	/** False while the Mac has not seen everything: an empty list is then not "nothing". */
	known: boolean;
	unknowns: string[];
	servers: RunningServer[];
	stacks: RunningContainer[];
	containers: RunningContainer[];
}

/** A local port the Mac publishes on the tailnet. */
export interface Mapping {
	port: number;
	url: string;
	thread: string;
	label: string;
}

export interface MappingList {
	mappings: Mapping[];
	max: number;
}

/** Where a tracked request stands. The Mac may send a word this app does not know yet. */
export type RequestState = 'todo' | 'in_progress' | 'blocked' | 'review' | 'done' | (string & {});

/** One step in how a request got to where it is. Entries are only ever appended. */
export interface RequestHistoryEntry {
	/** A date. */
	at: string;
	/** `maestro` for the agent's own entries; any other word is the human. */
	by: string;
	/** The human's exact words. */
	verbatim?: string;
	/** What changed. */
	note?: string;
}

/** One thing the human asked an agent for. */
export interface TrackedRequest {
	id: string;
	title: string;
	/** The tmux session the request belongs to. */
	project: string;
	/** When it was asked: an ISO date, or free text that may hold some. */
	asked: string;
	state: RequestState;
	detail?: string;
	blocked_by?: string | null;
	/** How the request got to its state, oldest first. Absent in a schema 1 list. */
	history?: RequestHistoryEntry[];
}

/** The Mac's request list. One that does not exist yet comes with no rows. */
export interface RequestList {
	schema: number;
	updated?: string;
	requests: TrackedRequest[];
	blockers?: unknown[];
	open_questions?: unknown[];
}
