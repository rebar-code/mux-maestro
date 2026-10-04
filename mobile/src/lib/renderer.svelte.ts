type Markdown = typeof import('./markdown');

/**
 * The markdown renderer. It is large, so it loads after the app has started:
 * until it is here, a message is drawn as its plain text.
 */
class Renderer {
	api = $state.raw<Markdown | null>(null);

	constructor() {
		void import('./markdown').then(
			(api) => (this.api = api),
			() => {
				// Not loaded: the chat stays plain text.
			}
		);
	}
}

export const renderer = new Renderer();
