import { describe, expect, it } from 'vitest';
import { Player, type PlayerContext } from './player';

/** An audio context that decodes on demand and plays until told a clip ended. */
class FakeContext {
	readonly destination = {} as AudioNode;
	started: string[] = [];
	stopped: string[] = [];
	private decodes = new Map<string, (ok: boolean) => void>();
	private sources: { name: string; onended: (() => void) | null }[] = [];

	decodeAudioData(data: ArrayBuffer): Promise<AudioBuffer> {
		const name = new TextDecoder().decode(data);
		return new Promise((resolve, reject) => {
			this.decodes.set(name, (ok) =>
				ok ? resolve({ name } as unknown as AudioBuffer) : reject(new Error('bad clip'))
			);
		});
	}

	createBufferSource(): AudioBufferSourceNode {
		const source = {
			buffer: null as { name: string } | null,
			onended: null as (() => void) | null,
			connect: () => {},
			start: () => {
				this.started.push(source.buffer!.name);
				this.sources.push({
					name: source.buffer!.name,
					get onended() {
						return source.onended;
					}
				});
			},
			stop: () => this.stopped.push(source.buffer!.name)
		};
		return source as unknown as AudioBufferSourceNode;
	}

	/** Finish decoding `name`. Clips decode one at a time, in queue order. */
	async decoded(name: string, ok = true): Promise<void> {
		for (let i = 0; i < 10 && !this.decodes.has(name); i += 1) await Promise.resolve();
		this.decodes.get(name)!(ok);
		for (let i = 0; i < 10; i += 1) await Promise.resolve();
	}

	/** The clip that is playing reaches its end. */
	ended(name: string): void {
		this.sources.find((source) => source.name === name)?.onended?.();
	}
}

const clip = (name: string): ArrayBuffer => new TextEncoder().encode(name).buffer as ArrayBuffer;

function setup(): { context: FakeContext; player: Player; events: string[] } {
	const context = new FakeContext();
	const player = new Player(context as unknown as PlayerContext);
	const events: string[] = [];
	player.onStarted = () => events.push('started');
	player.onFailed = () => events.push('failed');
	player.onDrained = () => events.push('drained');
	return { context, player, events };
}

describe('Player', () => {
	it('plays clips one after another in the order they were queued', async () => {
		const { context, player, events } = setup();
		player.enqueue(clip('one'));
		player.enqueue(clip('two'));
		player.enqueue(clip('three'));
		expect(player.busy).toBe(true);
		await context.decoded('one');
		await context.decoded('two');
		expect(context.started).toEqual(['one']);
		context.ended('one');
		expect(context.started).toEqual(['one', 'two']);
		// The third is still decoding when the second ends: not drained yet.
		context.ended('two');
		expect(events).toEqual(['started']);
		expect(player.busy).toBe(true);
		await context.decoded('three');
		expect(context.started).toEqual(['one', 'two', 'three']);
		context.ended('three');
		expect(events).toEqual(['started', 'drained']);
		expect(player.busy).toBe(false);
	});

	it('skips a clip that does not decode and plays the rest', async () => {
		const { context, player, events } = setup();
		player.enqueue(clip('one'));
		player.enqueue(clip('two'));
		await context.decoded('one', false);
		await context.decoded('two');
		expect(context.started).toEqual(['two']);
		context.ended('two');
		// The bad clip is reported, not passed over in silence.
		expect(events).toEqual(['failed', 'started', 'drained']);
	});

	it('stop drops the queue, the clip that plays and a clip still decoding', async () => {
		const { context, player, events } = setup();
		player.enqueue(clip('one'));
		player.enqueue(clip('two'));
		player.enqueue(clip('three'));
		await context.decoded('one');
		await context.decoded('two');
		player.stop();
		expect(context.stopped).toEqual(['one']);
		expect(player.busy).toBe(false);
		// The stopped clip's end and the late decode change nothing.
		context.ended('one');
		await context.decoded('three');
		expect(context.started).toEqual(['one']);
		expect(events).toEqual(['started']);

		// A new reply plays after a stop.
		player.enqueue(clip('four'));
		await context.decoded('four');
		expect(context.started).toEqual(['one', 'four']);
		expect(events).toEqual(['started', 'started']);
	});
});
