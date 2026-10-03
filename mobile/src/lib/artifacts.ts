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

const CSP =
	"default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; form-action 'none'; base-uri 'none'";

/**
 * An HTML artifact as the frame's `srcdoc`. The frame is sandboxed with no
 * permissions, so its scripts do not run and it has no origin; this policy
 * also stops it loading anything from the network.
 */
export function framedHtml(html: string): string {
	return `<meta http-equiv="Content-Security-Policy" content="${CSP}">${html}`;
}
