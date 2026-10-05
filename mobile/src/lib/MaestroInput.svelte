<script lang="ts">
	import AttachButton from './AttachButton.svelte';
	import AttachTiles from './AttachTiles.svelte';
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
	 * page's footer. It sends through the Maestro's one turn.
	 * The attach button and its tiles are a thread's: the box is one thing.
	 */
	const { onfocus, onblur }: { onfocus?: () => void; onblur?: () => void } = $props();

	const managerOn = $derived(can('manager'));
	// A take goes to the Maestro, so voice needs the Maestro's switch too.
	const voiceOn = $derived(managerOn && can('voice'));
	// The keys are the pane's: they show with its terminal, not with the chat.
	const keysOn = $derived(managerOn && can('keyBar') && maestro.terminal);
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
	<!-- Typing clears it, as it does in a thread's box. -->
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
	blocked={manager.files.pending}
	busy={manager.busy}
	onsend={send}
	oninput={() => (reply.note = null)}
	onpaste={managerOn ? reply.pasted : undefined}
	{onfocus}
	{onblur}
>
	{#snippet above()}
		{#if manager.files.items.length}<AttachTiles files={manager.files} />{/if}
	{/snippet}
	{#snippet leading()}
		{#if managerOn}
			<AttachButton off={!can('upload')} onpick={manager.files.add} onoff={reply.uploadOff} />
		{:else}
			<AttachButton disabled />
		{/if}
	{/snippet}
</Composer>
