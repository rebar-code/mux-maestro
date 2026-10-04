<script lang="ts" module>
	/** Line icons, drawn on a 24-unit grid in the text colour. */
	const PATHS = {
		speaker: ['M11 5 6 9H3v6h3l5 4z', 'M15.5 8.5a5 5 0 0 1 0 7', 'M18.5 5.5a9 9 0 0 1 0 13'],
		speakerOff: ['M11 5 6 9H3v6h3l5 4z', 'm22 9-6 6', 'm16 9 6 6'],
		replay: ['M3 12a9 9 0 1 0 3-6.7', 'M3 4v5h5'],
		skip: ['M5 5l9 7-9 7z', 'M18 5v14'],
		mic: [
			'M12 3a3 3 0 0 0-3 3v6a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3z',
			'M5 11a7 7 0 0 0 14 0',
			'M12 18v3'
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
