import { ApiError, uploadFile } from './api';
import {
	attachReduce,
	busyRetry,
	isImage,
	nextUpload,
	pastedName,
	uploadFailure,
	uploadsPending,
	type Attached,
	type AttachEvent
} from './attach';
import { live } from './live.svelte';

/** The wait before a file goes again to a thread that was taking another write. */
const BUSY_WAIT_MS = 300;

export interface AttachHost {
	/** A file is on the Mac: put its path in the reply box. */
	insert: (text: string) => void;
	/** A file was taken off: its path goes from the reply box, if it is still there. */
	remove: (text: string) => void;
	/** A reply is being sent. A thread takes one write at a time, so files wait. */
	sending: () => boolean;
}

/** The files picked for one thread's reply: sent one by one, each with its tile. */
export class Attachments {
	items = $state.raw<Attached[]>([]);
	/** Thumbnails, by key. Object URLs: each is revoked when its tile goes. */
	urls = $state.raw<Record<number, string>>({});
	/** Send has to wait for these. */
	readonly pending: boolean = $derived(uploadsPending(this.items));

	private files: Record<number, Blob> = {};
	private flights: Record<number, AbortController> = {};
	/** How often each file met a thread that was taking another write. */
	private tries: Record<number, number> = {};
	private seq = 0;
	private pasted = 0;

	constructor(
		readonly id: string,
		private readonly host: AttachHost
	) {}

	private apply(event: AttachEvent): void {
		this.items = attachReduce(this.items, event);
	}

	private take(blob: Blob, name: string): void {
		this.seq += 1;
		const key = this.seq;
		const image = isImage(blob.type);
		this.files[key] = blob;
		if (image) this.urls = { ...this.urls, [key]: URL.createObjectURL(blob) };
		this.apply({
			type: 'add',
			key,
			name,
			size: blob.size,
			image,
			max: live.config?.upload?.maxBytes ?? null
		});
	}

	/** Files picked in the file dialog, in pick order. */
	add = (files: File[]): void => {
		for (const file of files) this.take(file, file.name);
		void this.pump();
	};

	/** Images pasted from the clipboard. They come without a name of their own. */
	paste = (images: File[]): void => {
		for (const image of images) {
			this.pasted += 1;
			this.take(image, pastedName(this.pasted, image.type));
		}
		void this.pump();
	};

	/** Send the next file that waits, unless a write to this thread is in flight. */
	pump = async (): Promise<void> => {
		if (this.host.sending()) return;
		const next = nextUpload(this.items);
		if (!next) return;
		const { key } = next;
		const file = this.files[key];
		if (!file) return this.apply({ type: 'remove', key });
		if (!navigator.onLine) {
			this.apply({ type: 'fail', key, ...uploadFailure(null, false) });
			return this.pump();
		}
		const flight = new AbortController();
		this.flights[key] = flight;
		this.apply({ type: 'start', key });
		try {
			const saved = await uploadFile(
				this.id,
				file,
				next.name,
				(sent, total) => this.apply({ type: 'progress', key, progress: total ? sent / total : 0 }),
				flight.signal
			);
			// Taken off while it was on its way: its path goes nowhere.
			if (!flight.signal.aborted) {
				this.apply({ type: 'done', key, text: saved.text });
				this.host.insert(saved.text);
			}
		} catch (error) {
			live.fail(error);
			if (!flight.signal.aborted) {
				const refusal = error instanceof ApiError ? error : null;
				const tries = this.tries[key] ?? 0;
				if (busyRetry(refusal, tries)) {
					this.tries[key] = tries + 1;
					this.apply({ type: 'requeue', key });
					await new Promise((done) => setTimeout(done, BUSY_WAIT_MS * (tries + 1)));
				} else {
					this.apply({ type: 'fail', key, ...uploadFailure(refusal, navigator.onLine) });
				}
			}
		} finally {
			delete this.flights[key];
		}
		return this.pump();
	};

	retry = (key: number): void => {
		this.apply({ type: 'retry', key });
		void this.pump();
	};

	private forget(key: number): void {
		this.flights[key]?.abort();
		delete this.files[key];
		delete this.tries[key];
		const url = this.urls[key];
		if (url) {
			URL.revokeObjectURL(url);
			const rest = { ...this.urls };
			delete rest[key];
			this.urls = rest;
		}
	}

	/** Take a file off: out of the queue, off the wire, or out of the reply box. */
	remove = (key: number): void => {
		const item = this.items.find((one) => one.key === key);
		if (!item) return;
		this.forget(key);
		this.apply({ type: 'remove', key });
		if (item.state === 'done' && item.text) this.host.remove(item.text);
	};

	/** The reply went: the tiles have done their work. Their paths went with the text. */
	clear = (): void => {
		for (const item of this.items) this.forget(item.key);
		this.apply({ type: 'clear' });
	};

	/** Attachment for the bar that shows the tiles: when it goes, so do the uploads. */
	watch = (): (() => void) => this.clear;
}
