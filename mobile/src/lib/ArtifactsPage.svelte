<script lang="ts">
	import { fileSize, ICONS, shortDir } from './artifacts';
	import { ARTIFACTS, type Artifacts } from './artifacts.svelte';
	import ArtifactViewer from './ArtifactViewer.svelte';
	import { age } from './format';
	import { pullToRefresh } from './gestures.svelte';
	import { live } from './live.svelte';
	import PullIndicator from './PullIndicator.svelte';

	const { artifacts }: { artifacts: Artifacts } = $props();

	const list = $derived(artifacts.list);
</script>

<!-- eslint-disable svelte/no-navigation-without-resolve -- every link here is an outside address, not a route -->

<div
	class="scroll"
	data-pull={ARTIFACTS}
	inert={artifacts.open !== null}
	{@attach pullToRefresh(ARTIFACTS, artifacts.load)}
>
	<PullIndicator key={ARTIFACTS} />
	{#if list === null}
		<div class="sect">Files</div>
		{#each [58, 44, 66] as width (width)}
			<div class="row">
				<span class="skel" style:width="22px" style:height="20px"></span>
				<span class="main"
					><span class="skel" style:width="{width}%" style:height="15px"></span></span
				>
			</div>
		{/each}
	{:else if list.files.length === 0 && list.links.length === 0}
		<div class="empty">No artifacts</div>
	{:else}
		{#if list.files.length}
			<div class="sect">Files · {list.files.length}</div>
			{#each list.files as file (file.id)}
				<button
					class="row"
					class:missing={!file.exists}
					data-file={file.id}
					onclick={() => artifacts.show(file, 'list')}
				>
					<span class="fico">{ICONS[file.kind]}</span>
					<span class="main">
						<span class="l1">
							<span class="name">{file.name}</span>
							<span class="age">{age(file.at, live.now)}</span>
						</span>
						<span class="sub mono"
							>{shortDir(file.dir)}{file.exists ? ` · ${fileSize(file.size)}` : ' · missing'}</span
						>
					</span>
				</button>
			{/each}
		{/if}
		{#if list.links.length}
			<div class="sect">Links · {list.links.length}</div>
			{#each list.links as link (link.url)}
				<a class="row" href={link.url} target="_blank" rel="noopener noreferrer" data-link>
					<span class="fico">🔗</span>
					<span class="main">
						<span class="l1">
							<span class="name">{link.host}</span>
							<span class="age">{age(link.at, live.now)}</span>
						</span>
						{#if link.path}<span class="sub mono">{link.path}</span>{/if}
					</span>
					<span class="go">↗</span>
				</a>
			{/each}
		{/if}
		<div class="foot"></div>
	{/if}
</div>

{#if artifacts.open}
	{#key artifacts.open.id}
		<ArtifactViewer file={artifacts.open} {artifacts} />
	{/key}
{/if}

<style>
	.row {
		display: flex;
		align-items: center;
		gap: 11px;
		width: 100%;
		min-height: 52px;
		padding: 9px 14px;
		border-bottom: 1px solid #161616;
		text-align: left;
	}

	a.row:active,
	button.row:active {
		background: var(--surface);
	}

	.fico {
		flex: none;
		width: 22px;
		text-align: center;
	}

	.main {
		flex: 1;
		min-width: 0;
	}

	.l1 {
		display: flex;
		align-items: baseline;
		gap: 6px;
	}

	.name {
		font-weight: 600;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.missing .name {
		color: var(--muted);
		font-weight: 500;
	}

	.age {
		margin-left: auto;
		flex: none;
		font-size: 12px;
		color: var(--muted);
	}

	.sub {
		display: block;
		margin-top: 1px;
		font-size: 12px;
		color: var(--muted);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.go {
		flex: none;
		color: var(--accent);
		font-size: 18px;
	}

	.empty {
		display: flex;
		align-items: center;
		justify-content: center;
		height: 100%;
		color: var(--muted);
	}

	.foot {
		height: calc(16px + env(safe-area-inset-bottom));
	}
</style>
