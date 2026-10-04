<script lang="ts">
	import Composer from './Composer.svelte';
	import KeyBar from './KeyBar.svelte';
	import { can, isOff, OFF_LABEL } from './live.svelte';
	import { maestro } from './maestro.svelte';
	import { manager } from './manager.svelte';
	import NoteLine from './NoteLine.svelte';
	import { voice } from './voice.svelte';
	import VoiceBar from './VoiceBar.svelte';

	/**
	 * The Maestro's text box with its voice bar and its pane's keys: the home
	 * page's footer and the panel's. Both write the same draft, so text typed
	 * in one shows in the other, and both send through the Maestro's one turn.
	 */
	const { onfocus, onblur }: { onfocus?: () => void; onblur?: () => void } = $props();

	const managerOn = $derived(can('manager'));
	// A take goes to the Maestro, so voice needs the Maestro's switch too.
	const voiceOn = $derived(managerOn && can('voice'));
	const keysOn = $derived(managerOn && can('keyBar'));
	const boxLabel = $derived(isOff('manager') ? OFF_LABEL : 'Ask the Maestro');
	const reply = maestro.reply;

	function send(): void {
		// A typed turn takes over: a reply that is still being read stops.
		if (voiceOn) voice.skip();
		void manager.send();
	}
</script>

{#if managerOn}
	<!--
		The Maestro pane's keys, and what the last one came to. Above the voice
		bar and the text box, so nothing that rises under them covers the keys.
	-->
	{#if reply.note}<NoteLine note={reply.note} />{/if}
	{#if keysOn}<KeyBar {reply} composer={false} hides />{/if}
	<VoiceBar target="manager" sink={manager.voice} off={!voiceOn} />
{/if}
<Composer
	bind:value={manager.draft}
	label={boxLabel}
	target="manager"
	sink={manager.voice}
	{voiceOn}
	off={!managerOn}
	blocked={manager.busy}
	sending={manager.sending}
	onsend={send}
	{onfocus}
	{onblur}
/>
