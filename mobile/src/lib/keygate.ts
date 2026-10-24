/**
 * The link to keygate's phone page for one request, where Face ID decides.
 * The Mac sends `{ id, origin }` on a keygate review row; the origin is what
 * `keygate info` said, never anything the row holds. This file checks both
 * again, and the link opens keygate's page on its own origin: the app never
 * approves.
 */

const ID = /^[a-f0-9]{1,64}$/;

/** `<origin>/?id=<id>`, or null unless the id is 1 to 64 lowercase hex and the origin a bare https origin. */
export function keygateLink(raw: unknown): string | null {
	if (typeof raw !== 'object' || raw === null) return null;
	const { id, origin } = raw as Record<string, unknown>;
	if (typeof id !== 'string' || !ID.test(id) || typeof origin !== 'string') return null;
	let url: URL;
	try {
		url = new URL(origin);
	} catch {
		return null;
	}
	if (
		url.protocol !== 'https:' ||
		!url.hostname ||
		url.username ||
		url.password ||
		url.pathname !== '/' ||
		url.search ||
		url.hash ||
		url.origin !== origin
	) {
		return null;
	}
	return `${url.origin}/?id=${id}`;
}
