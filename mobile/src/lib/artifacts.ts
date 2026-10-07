import type { ArtifactFile, ArtifactKind, ChatMessage } from './types';

export const ICONS: Record<ArtifactKind, string> = {
	image: '🖼',
	pdf: '📕',
	markdown: '📝',
	html: '🌐',
	code: '📄',
	text: '📄',
	other: '📦'
};

/** The largest image the chat loads for a thumbnail; a larger one is a chip. */
export const THUMB_MAX_BYTES = 3_000_000;
/** The largest text the viewer renders; a larger one can still be shared. */
export const TEXT_MAX_BYTES = 1_000_000;

export function hasThumb(file: ArtifactFile): boolean {
	return file.exists && file.kind === 'image' && file.size !== null && file.size <= THUMB_MAX_BYTES;
}

/** Whether the viewer draws the file itself; if not, it offers Share only. */
export function isViewable(file: ArtifactFile): boolean {
	if (!file.exists || file.size === null) return false;
	if (file.kind === 'image') return true;
	if (file.kind === 'pdf' || file.kind === 'other') return false;
	return file.size <= TEXT_MAX_BYTES;
}

/** A finger that moved this far up or down an open file steps to the next one. */
const STEP_PX = 70;

/**
 * Which way a swipe on an open file steps: 1 to the next file (a swipe up),
 * -1 to the previous (a swipe down), 0 for neither. A file that scrolls steps
 * only from its end: `atTop` and `atEnd` are where it was when the finger landed.
 */
export function swipeStep(swipe: {
	dx: number;
	dy: number;
	atTop: boolean;
	atEnd: boolean;
}): -1 | 0 | 1 {
	const { dx, dy } = swipe;
	if (Math.abs(dy) < STEP_PX || Math.abs(dy) < Math.abs(dx) * 1.5) return 0;
	if (dy < 0) return swipe.atEnd ? 1 : 0;
	return swipe.atTop ? -1 : 0;
}

/** The file `step` places from `id` in the list; null past either end. */
export function neighbour(files: ArtifactFile[], id: string, step: number): ArtifactFile | null {
	const index = files.findIndex((file) => file.id === id);
	return index < 0 ? null : (files[index + step] ?? null);
}

const pathOf = (file: ArtifactFile): string => `${file.dir}/${file.name}`;

/** Whether `text` names the file: by its whole path, a tail of it, or its name alone. */
function names(text: string, file: ArtifactFile): boolean {
	const path = pathOf(file);
	for (const [word] of text.matchAll(/[\w@%+=,.~/-]+/g)) {
		const token = word.replace(/^\.\//, '').replace(/[.,]+$/, '');
		if (token === file.name || token === path || (token && path.endsWith(`/${token}`))) return true;
	}
	return false;
}

/**
 * The file a path in a message names: its whole path, a tail of it, or its
 * name alone. Null when the thread has no such file.
 */
export function resolveArtifact(path: string, files: ArtifactFile[]): ArtifactFile | null {
	const token = path.replace(/^\.\//, '');
	if (!token) return null;
	const there = files.filter((file) => file.exists);
	return (
		there.find((file) => pathOf(file) === token) ??
		there.find((file) => pathOf(file).endsWith(`/${token}`)) ??
		there.find((file) => file.name === token) ??
		null
	);
}

/** The agent's own rows count: what it wrote and what it said, not what the human typed. */
function mentions(message: ChatMessage, file: ArtifactFile): boolean {
	return message.role !== 'user' && names(message.text, file);
}

/**
 * Which files to draw under which chat message: each file once, at the last
 * message that names it. Keyed by the message's `n`.
 */
export function inlineArtifacts(
	messages: ChatMessage[],
	files: ArtifactFile[]
): Map<number, ArtifactFile[]> {
	const out = new Map<number, ArtifactFile[]>();
	for (const file of files) {
		if (!file.exists) continue;
		for (let i = messages.length - 1; i >= 0; i -= 1) {
			if (!mentions(messages[i], file)) continue;
			const n = messages[i].n;
			out.set(n, [...(out.get(n) ?? []), file]);
			break;
		}
	}
	return out;
}

/** "3.2 MB", "14 KB", "620 B". */
export function fileSize(bytes: number | null): string {
	if (bytes === null) return '';
	if (bytes >= 1_048_576) return `${(bytes / 1_048_576).toFixed(1)} MB`;
	if (bytes >= 1024) return `${Math.round(bytes / 1024)} KB`;
	return `${bytes} B`;
}

/** The folder a file is in, from the home folder or the last two names. */
export function shortDir(dir: string): string {
	const parts = dir.split('/').filter(Boolean);
	return parts.length <= 2 ? dir : `…/${parts.slice(-2).join('/')}`;
}

const RASTER = new Set(['image/png', 'image/jpeg', 'image/gif', 'image/webp']);

/**
 * How an image of this type gets an address for an `<img>`.
 *
 * A `blob:` address has the app's origin. Opened as a page (a long press, "open
 * image in new tab"), a blob typed SVG runs its scripts there, next to the
 * pairing token. So only formats that cannot hold a script get a blob, and
 * with that exact type. SVG gets a `data:` address, which has no origin.
 * Anything else is not shown as an image at all.
 */
export function imageAddress(mime: string): { as: 'blob' | 'data'; type: string } | null {
	const type = mime.split(';')[0].trim().toLowerCase();
	if (RASTER.has(type)) return { as: 'blob', type };
	if (type === 'image/svg+xml') return { as: 'data', type };
	return null;
}

/** The type a file is saved under: bytes, never something a browser would open as a page. */
export const SAVED_TYPE = 'application/octet-stream';

/** `blob` as bytes to save: its own type is dropped. */
export function savedBlob(blob: Blob): Blob {
	return new Blob([blob], { type: SAVED_TYPE });
}

async function dataAddress(blob: Blob, type: string): Promise<string> {
	const bytes = new Uint8Array(await blob.arrayBuffer());
	let binary = '';
	for (let i = 0; i < bytes.length; i += 0x8000) {
		binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
	}
	return `data:${type};base64,${btoa(binary)}`;
}

/**
 * The address an `<img>` shows `blob` from. `makeBlobUrl` is
 * `URL.createObjectURL`; it only ever gets a blob that `imageAddress` allows,
 * typed again with the allowed type. Throws for a type that is not an image.
 */
export async function imageUrl(blob: Blob, makeBlobUrl: (blob: Blob) => string): Promise<string> {
	const address = imageAddress(blob.type);
	if (!address) throw new Error('not an image');
	if (address.as === 'data') return dataAddress(blob, address.type);
	return makeBlobUrl(new Blob([blob], { type: address.type }));
}

const CSP =
	"default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; form-action 'none'; base-uri 'none'";
// A link in the page asks for a new window, and the sandbox allows none: a tap
// loads nothing. The first `<base target>` in a page is the one that counts.
const HEAD = `<meta http-equiv="Content-Security-Policy" content="${CSP}"><base target="_blank">`;
const DOCTYPE = /^(?:\s|<!--[\s\S]*?-->)*<!doctype[^>]*>\s*/i;

/**
 * `html` with nothing in it that names a window. A link with `target="_self"`
 * would load its page in the frame, where the app's policy refuses it and an
 * error page takes the artifact's place. With no target of its own, a link
 * takes the `<base target>` that `framedHtml` adds. The page is parsed here as
 * a document that is never shown: nothing in it runs or loads.
 */
export function withoutTargets(html: string): string {
	const page = new DOMParser().parseFromString(html, 'text/html');
	for (const element of page.querySelectorAll('[target], [formtarget]')) {
		element.removeAttribute('target');
		element.removeAttribute('formtarget');
	}
	for (const element of page.querySelectorAll('base, meta[http-equiv="refresh" i]'))
		element.remove();
	return `${page.doctype ? '<!doctype html>' : ''}${page.documentElement.outerHTML}`;
}

/**
 * An HTML artifact as the frame's `srcdoc`. The frame is sandboxed with no
 * permissions, so its scripts do not run and it has no origin; this policy
 * also stops it loading anything from the network. It goes right after the
 * doctype, which must stay first for the page to keep standards mode.
 */
export function framedHtml(html: string): string {
	const doctype = DOCTYPE.exec(html)?.[0] ?? '';
	return `${doctype}${HEAD}${html.slice(doctype.length)}`;
}
