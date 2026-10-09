<script lang="ts" module>
	/** Line icons, drawn on a 24-unit grid in the text colour. */
	const PATHS = {
		speaker: ['M11 5 6 9H3v6h3l5 4z', 'M15.5 8.5a5 5 0 0 1 0 7', 'M18.5 5.5a9 9 0 0 1 0 13'],
		speakerOff: ['M11 5 6 9H3v6h3l5 4z', 'm22 9-6 6', 'm16 9 6 6'],
		replay: ['M3 12a9 9 0 1 0 3-6.7', 'M3 4v5h5'],
		skip: ['M5 5l9 7-9 7z', 'M18 5v14'],
		skipBack: ['M19 5l-9 7 9 7z', 'M6 5v14'],
		// An open circle with an arrowhead at its top: the number sits inside.
		back: ['M12 4a8.5 8.5 0 1 1-7.4 4.3', 'M12 1 8.5 4 12 7'],
		forward: ['M12 4a8.5 8.5 0 1 0 7.4 4.3', 'M12 1l3.5 3L12 7'],
		// Lucide `file-up`.
		fileUp: [
			'M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z',
			'M14 2v4a2 2 0 0 0 2 2h4',
			'M12 12v6',
			'm15 15-3-3-3 3'
		],
		play: ['M7 4.5l12 7.5-12 7.5z'],
		stop: ['M6.5 6.5h11v11h-11z'],
		copy: ['M9 9h11v11H9z', 'M5 15H4V4h11v1'],
		check: ['m5 12.5 4.5 4.5L19 7.5'],
		mic: [
			'M12 3a3 3 0 0 0-3 3v6a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3z',
			'M5 11a7 7 0 0 0 14 0',
			'M12 18v3'
		],
		keyboardDown: [
			'M3 5h18a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1z',
			'M6 9h.01',
			'M10 9h.01',
			'M14 9h.01',
			'M18 9h.01',
			'M8 12h8',
			'm9 19 3 3 3-3'
		],
		send: ['M12 19V5', 'm5 12 7-7 7 7'],
		// The arrow over two lines: it goes, and waits in line.
		sendQueued: ['M12 14V3', 'm7 8 5-5 5 5', 'M6 18h12', 'M8 21.5h8'],
		// The arrow over a stop square: stop the turn, then send.
		interrupt: ['M7.5 12h9v9h-9z', 'M12 8V2', 'm9 5 3-3 3 3'],
		// Three dots, one over the other: the row's menu.
		more: [
			'M12 4a1 1 0 1 0 0 2 1 1 0 1 0 0-2',
			'M12 11a1 1 0 1 0 0 2 1 1 0 1 0 0-2',
			'M12 18a1 1 0 1 0 0 2 1 1 0 1 0 0-2'
		],
		// Lucide `archive`.
		archive: ['M3 4h18v4H3z', 'M5 8v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8', 'M10 12h4'],
		// Lucide `list-filter`.
		filter: ['M3 6h18', 'M7 12h10', 'M10 18h4'],
		chevronDown: ['m6 9 6 6 6-6'],
		// Two sliders: the model and its effort.
		sliders: [
			'M4 7h10',
			'M18 7h2',
			'M14 7a2 2 0 1 0 4 0 2 2 0 1 0-4 0',
			'M4 17h2',
			'M10 17h10',
			'M6 17a2 2 0 1 0 4 0 2 2 0 1 0-4 0'
		],
		micOff: [
			'M12 3a3 3 0 0 0-3 3v6a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3z',
			'M5 11a7 7 0 0 0 14 0',
			'M12 18v3',
			'M4 4l16 16'
		]
	} as const;

	export type IconName = keyof typeof PATHS;
</script>

<script lang="ts">
	const { name, size = 18 }: { name: IconName; size?: number } = $props();
</script>

<svg
	width={size}
	height={size}
	viewBox="0 0 24 24"
	fill="none"
	stroke="currentColor"
	stroke-width="2"
	stroke-linecap="round"
	stroke-linejoin="round"
	aria-hidden="true"
	data-icon={name}
>
	{#each PATHS[name] as d (d)}<path {d} />{/each}
</svg>

<style>
	svg {
		display: block;
		flex: none;
	}
</style>
