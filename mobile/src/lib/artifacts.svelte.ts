import { untrack } from 'svelte';
import { ApiError, fetchArtifacts, fetchFile } from './api';
import { imageUrl, savedBlob } from './artifacts';
import { ui } from './gestures.svelte';
import { live } from './live.svelte';
import type { ArtifactFile, ArtifactList } from './types';

const POLL_MS = 10_000;

/** The page key of the Artifacts tab. */
export const ARTIFACTS = 'artifacts';

/** One thread's artifacts: the list, the file that is open, and the bytes read so far. */
export class Artifacts {
	list = $state.raw<ArtifactList | null>(null);
	/** The file the viewer shows, and where it was opened from. */
	open = $state.raw<ArtifactFile | null>(null);
	from = $state<'chat' | 'list'>('list');

	// Caches, not state: nothing is drawn from them.
	// eslint-disable-next-line svelte/prefer-svelte-reactivity
	private blobs = new Map<string, Promise<Blob>>();
	// eslint-disable-next-line svelte/prefer-svelte-reactivity
	private urls = new Map<string, Promise<string>>();
	private made: string[] = [];
	private loading = false;

	constructor(readonly id: string) {}

	load = async (): Promise<void> => {
		if (this.loading) return;
		this.loading = true;
		try {
			const list = await fetchArtifacts(this.id);
			// The same list again keeps the same rows: nothing redraws.
			if (JSON.stringify(list) !== JSON.stringify(this.list)) this.list = list;
		} catch (error) {
			if (error instanceof ApiError && error.status !== 404) live.fail(error);
		} finally {
			this.loading = false;
		}
	};

	/** A changed file is a new entry: its `at` and size are part of the key. */
	private key(file: ArtifactFile): string {
		return `${file.id}:${file.at}:${file.size}`;
	}

	blob(file: ArtifactFile): Promise<Blob> {
		const key = this.key(file);
		let found = this.blobs.get(key);
		if (!found) {
			found = fetchFile(this.id, file.id);
			this.blobs.set(key, found);
			// A failed read is asked again the next time.
			found.catch(() => this.blobs.delete(key));
		}
		return found;
	}

	/**
	 * The file as an address an `<img>` can show. It needs no token and dies
	 * with the view. See `imageAddress` for which kind of address a type gets.
	 */
	url(file: ArtifactFile): Promise<string> {
		const key = this.key(file);
		let found = this.urls.get(key);
		if (!found) {
			found = this.blob(file).then((blob) =>
				imageUrl(blob, (allowed) => {
					const url = URL.createObjectURL(allowed);
					this.made.push(url);
					return url;
				})
			);
			this.urls.set(key, found);
			found.catch(() => this.urls.delete(key));
		}
		return found;
	}

	async text(file: ArtifactFile): Promise<string> {
		return (await this.blob(file)).text();
	}

	show(file: ArtifactFile, from: 'chat' | 'list'): void {
		this.open = file;
		this.from = from;
		this.sync();
	}

	close = (): void => {
		this.open = null;
		ui.back = null;
	};

	/** The back control: to where the file was opened from. */
	back = (): void => {
		if (this.from === 'chat') ui.goTo(0);
		this.close();
	};

	/** The pager is on page `index` now. */
	landed(index: number): void {
		// Back in the chat, a file opened from the chat is closed.
		if (index === 0 && this.from === 'chat') this.open = null;
		this.sync();
		if (ui.pages[index] === ARTIFACTS) void this.load();
	}

	/**
	 * A file opened from the list closes on a right swipe, before the tab
	 * changes. One opened from the chat lets the swipe go back to the chat.
	 */
	private sync(): void {
		const here = ui.pages[ui.index] === ARTIFACTS;
		ui.back = this.open && this.from === 'list' && here ? this.close : null;
	}

	/** Attachment: keep the list current while the thread is on screen. */
	watch = (): (() => void) =>
		untrack(() => {
			void this.load();
			const timer = setInterval(() => void this.load(), POLL_MS);
			return () => {
				clearInterval(timer);
				ui.back = null;
				for (const url of this.made) URL.revokeObjectURL(url);
				this.made = [];
				this.urls.clear();
				this.blobs.clear();
			};
		});
}

/** Hand a file to the phone's share sheet, or save it where there is none. */
export async function share(blob: Blob, name: string): Promise<void> {
	const file = new File([blob], name, { type: blob.type });
	if (navigator.canShare?.({ files: [file] })) {
		try {
			await navigator.share({ files: [file], title: name });
		} catch {
			// The sheet was closed.
		}
		return;
	}
	// Saved as plain bytes: this address is in the app's origin, and must
	// never be one a browser would open as a page.
	const url = URL.createObjectURL(savedBlob(blob));
	const link = document.createElement('a');
	link.href = url;
	link.download = name;
	link.click();
	setTimeout(() => URL.revokeObjectURL(url), 10_000);
}
