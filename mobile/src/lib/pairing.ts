const TOKEN = /^[A-Za-z0-9_-]{8,}$/;

/**
 * The pairing token in what someone pasted: a whole pairing link
 * (`https://host/#pair=<token>`), its fragment, or the bare token.
 */
export function tokenFrom(input: string): string | null {
	const text = input.trim();
	const fromLink = /[#&]pair=([^&\s]+)/.exec(text)?.[1];
	const token = fromLink ?? text;
	return TOKEN.test(token) ? token : null;
}

/** `hash` without its `pair=` part, for putting back in the address bar. */
export function withoutPair(hash: string): string {
	const rest = hash
		.replace(/^#/, '')
		.split('&')
		.filter((part) => part && !part.startsWith('pair='));
	return rest.length ? `#${rest.join('&')}` : '';
}
