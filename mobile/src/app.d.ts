declare global {
	namespace App {
		interface PageState {
			/** The Maestro panel is open on this history entry: Back closes it. */
			maestro?: boolean;
		}
	}
}

export {};
