import { untrack } from 'svelte';
import { ApiError, closeServer, fetchMappings, fetchRunning, openServer } from './api';
import { ui } from './gestures.svelte';
import { live } from './live.svelte';
import type { Mapping, RunningList } from './types';

const POLL_MS = 5000;
/** The page key of the Servers tab. */
export const SERVERS = 'servers';

/** One thread's running servers, and the ports the Mac publishes on the tailnet. */
export class Servers {
	running = $state.raw<RunningList | null>(null);
	mappings = $state.raw<Mapping[]>([]);
	/** The port waiting on the confirmation. Every port that is not open yet asks. */
	asking = $state<number | null>(null);
	/** The port being opened or closed. */
	busy = $state<number | null>(null);
	note = $state('');

	private loading = false;

	constructor(readonly id: string) {}

	mapping(port: number): Mapping | undefined {
		return this.mappings.find((mapping) => mapping.port === port);
	}

	load = async (): Promise<void> => {
		if (this.loading) return;
		this.loading = true;
		try {
			const [running, mapped] = await Promise.all([fetchRunning(this.id), fetchMappings()]);
			if (JSON.stringify(running) !== JSON.stringify(this.running)) this.running = running;
			if (JSON.stringify(mapped.mappings) !== JSON.stringify(this.mappings))
				this.mappings = mapped.mappings;
		} catch (error) {
			if (error instanceof ApiError && error.status !== 404) live.fail(error);
		} finally {
			this.loading = false;
		}
	};

	/**
	 * A tap on a server that is not published yet. It always asks: each port is
	 * one more thing the whole tailnet can reach.
	 */
	tap(port: number): void {
		this.note = '';
		this.asking = port;
	}

	private mappable(port: number): boolean {
		const running = this.running;
		if (!running) return false;
		return (
			running.servers.some((server) => server.port === port && server.mappable) ||
			[...running.stacks, ...running.containers].some((row) =>
				row.links.some((link) => link.port === port && link.mappable)
			)
		);
	}

	/**
	 * A tap on a local address in the chat. The phone cannot reach it as
	 * written: a published port opens at its tailnet address, and one that is
	 * not published asks first. Returns whether it opened.
	 */
	reach(port: number, rest: string): boolean {
		const mapping = this.mapping(port);
		if (mapping) {
			const base = mapping.url.endsWith('/') ? mapping.url : `${mapping.url}/`;
			window.open(`${base}${rest.replace(/^\/+/, '')}`, '_blank', 'noopener,noreferrer');
			return true;
		}
		void this.load().then(() => {
			if (!this.mapping(port) && this.mappable(port)) this.tap(port);
		});
		return false;
	}

	confirm = (): void => {
		const port = this.asking;
		this.asking = null;
		if (port !== null) void this.publish(port);
	};

	cancel = (): void => {
		this.asking = null;
	};

	private async publish(port: number): Promise<void> {
		if (this.busy !== null) return;
		this.busy = port;
		try {
			const mapping = await openServer(this.id, port);
			await this.load();
			// The row is a link from now on; this opens it at once where the browser lets it.
			window.open(mapping.url, '_blank', 'noopener,noreferrer');
		} catch (error) {
			this.fail(error);
		} finally {
			this.busy = null;
		}
	}

	close = async (port: number): Promise<void> => {
		if (this.busy !== null) return;
		this.busy = port;
		this.note = '';
		try {
			await closeServer(port);
		} catch (error) {
			if (!(error instanceof ApiError && error.status === 404)) this.fail(error);
		} finally {
			this.busy = null;
			await this.load();
		}
	};

	private fail(error: unknown): void {
		live.fail(error);
		this.note = error instanceof ApiError ? (error.detail ?? 'Not opened') : 'No connection';
	}

	landed(index: number): void {
		if (ui.pages[index] === SERVERS) void this.load();
	}

	/** Attachment: keep the lists current while the Servers tab is on screen. */
	watch = (): (() => void) =>
		untrack(() => {
			const timer = setInterval(() => {
				if (ui.pages[ui.index] === SERVERS) void this.load();
			}, POLL_MS);
			return () => clearInterval(timer);
		});
}
