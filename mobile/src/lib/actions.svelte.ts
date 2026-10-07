import { goto } from '$app/navigation';
import { resolve } from '$app/paths';
import { page } from '$app/state';
import {
	actionTarget,
	currentName,
	killed,
	refusalText,
	validName,
	validPrompt,
	type ItemKey,
	type KillKind,
	type MenuTarget,
	type StartKind
} from './actions';
import { ApiError, fetchDirs, tmuxAction } from './api';
import { ui } from './gestures.svelte';
import { live } from './live.svelte';

export type Stage = 'menu' | 'rename' | 'kill' | 'dirs' | 'agent' | 'prompt' | 'start';

const APPEAR_TRIES = 8;
const APPEAR_MS = 350;

/** The bottom sheet a long press opens, and the actions it runs. */
class Menu {
	target = $state.raw<MenuTarget | null>(null);
	stage = $state<Stage>('menu');
	/** Which kill the confirmation is for. */
	killKind = $state<KillKind>('kill-window');
	name = $state('');
	/** The directories the host offers; null until they are loaded. */
	dirs = $state.raw<string[] | null>(null);
	/** The folder `dirs` is the inside of; null on the list of where threads work. */
	folder = $state.raw<{ path: string; parent: string | null } | null>(null);
	/** The host's home directory, where browsing starts; null when the host does not say. */
	home = $state<string | null>(null);
	/** A list is on its way. */
	loading = $state(false);
	/** Where the new session starts; null for the host's home. */
	dir = $state<string | null>(null);
	/** The agent the prompt is for. */
	agent = $state<'claude' | 'codex'>('claude');
	prompt = $state('');
	/** The last list asked for: an older answer is dropped. */
	private asked = 0;
	busy = $state(false);
	error = $state<string | null>(null);

	readonly nameOk: boolean = $derived(validName(this.name));
	readonly promptOk: boolean = $derived(validPrompt(this.prompt));

	open(target: MenuTarget): void {
		this.target = target;
		this.stage = 'menu';
		this.busy = false;
		this.error = null;
	}

	close = (): void => {
		this.target = null;
	};

	pick(key: ItemKey): void {
		const target = this.target;
		if (!target || this.busy) return;
		this.error = null;
		if (key === 'rename') {
			this.name = currentName(target);
			this.stage = 'rename';
		} else if (key === 'kill-pane' || key === 'kill-window' || key === 'kill-session') {
			this.killKind = key;
			this.stage = 'kill';
		} else if (key === 'new-session') {
			if (target.kind === 'host') this.openDirs(target.host);
		} else if (key === 'new-window') {
			this.stage = 'start';
		} else if (key === 'archive-window') {
			void this.archive(target);
		} else {
			void this.zoom(target);
		}
	}

	/** The ＋ on a host card: pick where the new session starts. */
	openDirs(host: string): void {
		this.open({ kind: 'host', host });
		this.stage = 'dirs';
		this.dirs = null;
		this.folder = null;
		this.home = null;
		this.browse(null);
	}

	/** List the inside of `path`, or with null where the host's threads work. */
	browse = (path: string | null): void => {
		const target = this.target;
		if (target?.kind !== 'host') return;
		const asked = (this.asked += 1);
		const mine = (): boolean => asked === this.asked && this.target === target;
		this.loading = true;
		this.error = null;
		void fetchDirs(target.host, path).then(
			(list) => {
				if (!mine()) return;
				this.loading = false;
				this.dirs = list.dirs;
				this.home = list.home ?? this.home;
				this.folder =
					list.path === undefined ? null : { path: list.path, parent: list.parent ?? null };
			},
			(error: unknown) => {
				if (!mine()) return;
				this.loading = false;
				this.fail(error);
			}
		);
	};

	/** One folder up; from the home directory, back to where the threads work. */
	up = (): void => this.browse(this.folder?.parent ?? null);

	/** `dir`: where the new session starts, or null for the host's home. Next: what runs in it. */
	choose(dir: string | null): void {
		if (this.busy) return;
		this.dir = dir;
		this.prompt = '';
		this.error = null;
		this.stage = 'agent';
	}

	/** A terminal starts at once; an agent can take a first prompt. */
	pickAgent(kind: StartKind): void {
		if (kind === 'terminal') return void this.newSession(kind);
		this.agent = kind;
		this.stage = 'prompt';
	}

	/** A session with an agent opens once the list has it. */
	async newSession(kind: StartKind): Promise<void> {
		const target = this.target;
		if (target?.kind !== 'host' || (kind !== 'terminal' && !this.promptOk)) return;
		const prompt = this.prompt.trim();
		await this.run(async () => {
			const { thread } = await tmuxAction('new-session', {
				host: target.host,
				...(this.dir ? { dir: this.dir } : {}),
				...(kind === 'terminal' ? {} : { agent: kind, ...(prompt ? { prompt } : {}) })
			});
			await this.show(thread);
		});
	}

	/** The ＋ on a session row: pick what the new window starts with. */
	openStart(target: MenuTarget): void {
		this.open(target);
		this.stage = 'start';
	}

	/** The new window opens once the list has it. */
	async newWindow(kind: StartKind): Promise<void> {
		const to = this.target && actionTarget(this.target);
		if (!to) return;
		await this.run(async () => {
			const { thread } = await tmuxAction('new-window', {
				...to,
				...(kind === 'terminal' ? {} : { agent: kind })
			});
			await this.show(thread);
		});
	}

	/** Open the thread an action made, once the list has it. Without one, the list is read again. */
	private async show(thread: string | undefined): Promise<void> {
		if (!thread) return void live.refresh();
		for (let n = 0; n < APPEAR_TRIES && !live.byId(thread); n += 1) {
			await live.refresh();
			if (!live.byId(thread)) await new Promise((done) => setTimeout(done, APPEAR_MS));
		}
		ui.closeDrawer();
		await goto(resolve('/t/[id]', { id: thread }));
	}

	async rename(): Promise<void> {
		const target = this.target;
		const to = target && actionTarget(target);
		if (!target || !to || !this.nameOk) return;
		await this.run(async () => {
			await tmuxAction(target.kind === 'thread' ? 'rename-window' : 'rename-session', {
				...to,
				name: this.name.trim()
			});
			void live.refresh();
		});
	}

	/** Archive a thread's window. Nothing asks first: the Mac keeps it and can undo. */
	async archive(target: MenuTarget): Promise<void> {
		const to = actionTarget(target);
		if (target.kind !== 'thread' || !to) return;
		const gone = killed(target, 'kill-window', live.threads ?? []);
		await this.run(async () => {
			await tmuxAction('archive-window', to);
			ui.revealed = null;
			if (gone.some((thread) => thread.id === page.params.id)) await goto(resolve('/'));
			void live.refresh();
		});
	}

	/** The human tapped Kill on the confirmation. */
	async kill(): Promise<void> {
		const target = this.target;
		const to = target && actionTarget(target);
		if (!target || !to) return;
		const gone = killed(target, this.killKind, live.threads ?? []);
		await this.run(async () => {
			await tmuxAction(this.killKind, { ...to, confirm: true });
			if (gone.some((thread) => thread.id === page.params.id)) await goto(resolve('/'));
			void live.refresh();
		});
	}

	private async zoom(target: MenuTarget): Promise<void> {
		const to = actionTarget(target);
		if (!to) return;
		await this.run(async () => void (await tmuxAction('zoom-pane', to)));
	}

	/** Run one action; the sheet closes when it worked and says why when not. */
	private async run(action: () => Promise<void>): Promise<void> {
		if (this.busy) return;
		this.busy = true;
		this.error = null;
		try {
			await action();
			this.close();
		} catch (error) {
			this.fail(error);
		} finally {
			this.busy = false;
		}
	}

	private fail(error: unknown): void {
		live.fail(error);
		this.error =
			error instanceof ApiError ? refusalText(error.code, error.detail) : 'Connection lost';
	}
}

export const menu = new Menu();
