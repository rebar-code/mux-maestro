import { describe, expect, it } from 'vitest';
import { ModelPicker, type ModelApi } from './model.svelte';
import type { EffortOption, ModelOption } from './types';

const MODELS: ModelOption[] = [
	{ n: 1, label: 'Opus 5.5', current: true },
	{ n: 2, label: 'Haiku 5.5', current: false },
	{ n: 3, label: 'Haiku 4.5', current: false }
];
const EFFORTS: EffortOption[] = [
	{ label: 'Low', current: false },
	{ label: 'High', current: true }
];

/** A refusal, as `ApiError` carries it. */
class Refusal extends Error {
	constructor(
		readonly status: number,
		readonly code: string,
		readonly detail: string
	) {
		super(detail);
	}
}

/** The Mac, scripted: it records each call, and `fail` refuses the next one. */
class FakeMac implements ModelApi {
	calls: string[] = [];
	fail: Error | null = null;
	/** Set to hold the next call until `release` runs. */
	hold = false;
	release: () => void = () => undefined;

	private async answer<T>(call: string, value: T): Promise<T> {
		this.calls.push(call);
		if (this.hold) {
			this.hold = false;
			await new Promise<void>((resolve) => (this.release = resolve));
		}
		if (this.fail) {
			const error = this.fail;
			this.fail = null;
			throw error;
		}
		return value;
	}

	open = (): Promise<{ agent: 'claude'; models: ModelOption[] }> =>
		this.answer('open', { agent: 'claude' as const, models: MODELS });
	pick = (_id: string, model: ModelOption): Promise<EffortOption[]> =>
		this.answer(`pick ${model.n} ${model.label}`, model.label === 'Haiku 4.5' ? [] : EFFORTS);
	apply = (_id: string, model: string, effort: string | null): Promise<void> =>
		this.answer(`apply ${model} ${effort}`, undefined);
	close = (): Promise<void> => this.answer('close', undefined);
}

const settle = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0));

describe('ModelPicker', () => {
	it('lists the models, then the levels, and takes a pick', async () => {
		const mac = new FakeMac();
		const picker = new ModelPicker('localhost:1', mac);
		const opening = picker.open();
		expect(picker.stage).toBe('loading');
		expect(picker.busy).toBe(true);
		await opening;
		expect(picker.stage).toBe('models');
		expect(picker.models).toEqual(MODELS);

		await picker.pick(MODELS[1]);
		expect(picker.stage).toBe('efforts');
		expect(picker.picked).toEqual(MODELS[1]);
		expect(picker.efforts).toEqual(EFFORTS);

		await picker.apply('Low');
		expect(picker.stage).toBe('closed');
		// The agent's menu went with the pick: no cancel follows.
		await settle();
		expect(mac.calls).toEqual(['open', 'pick 2 Haiku 5.5', 'apply Haiku 5.5 Low']);
	});

	it('takes a model without levels at once', async () => {
		const mac = new FakeMac();
		const picker = new ModelPicker('localhost:1', mac);
		await picker.open();
		await picker.pick(MODELS[2]);
		expect(picker.stage).toBe('closed');
		expect(mac.calls).toEqual(['open', 'pick 3 Haiku 4.5', 'apply Haiku 4.5 null']);
	});

	it('goes back from the levels to the models', async () => {
		const mac = new FakeMac();
		const picker = new ModelPicker('localhost:1', mac);
		await picker.open();
		await picker.pick(MODELS[1]);
		picker.back();
		expect(picker.stage).toBe('models');
		await picker.pick(MODELS[0]);
		expect(picker.picked).toEqual(MODELS[0]);
	});

	it('closing the sheet closes the menu in the pane', async () => {
		const mac = new FakeMac();
		const picker = new ModelPicker('localhost:1', mac);
		await picker.open();
		picker.close();
		expect(picker.stage).toBe('closed');
		await settle();
		expect(mac.calls).toEqual(['open', 'close']);
		// Closed already: nothing more is sent.
		picker.close();
		await settle();
		expect(mac.calls).toEqual(['open', 'close']);
	});

	it('closes the menu only after the step in flight, and drops its answer', async () => {
		const mac = new FakeMac();
		const picker = new ModelPicker('localhost:1', mac);
		mac.hold = true;
		const opening = picker.open();
		picker.close();
		await settle();
		expect(mac.calls).toEqual(['open']);
		mac.release();
		await opening;
		await settle();
		expect(mac.calls).toEqual(['open', 'close']);
		expect(picker.stage).toBe('closed');
		expect(picker.models).toEqual([]);
	});

	it('shows a refusal and drops the lists', async () => {
		const mac = new FakeMac();
		const picker = new ModelPicker('localhost:1', mac);
		mac.fail = new Refusal(409, 'busy', 'Thread is busy');
		await picker.open();
		expect(picker.stage).toBe('loading');
		expect(picker.error).toBe('Thread is busy');
		expect(picker.busy).toBe(false);

		picker.close();
		await picker.open();
		mac.fail = new Refusal(409, 'changed', 'The model menu changed');
		await picker.pick(MODELS[1]);
		expect(picker.stage).toBe('loading');
		expect(picker.error).toBe('The model menu changed');

		picker.close();
		await picker.open();
		mac.fail = new Error('Failed to fetch');
		await picker.pick(MODELS[1]);
		expect(picker.error).toBe('Mac unreachable');
	});

	it('takes one step at a time', async () => {
		const mac = new FakeMac();
		const picker = new ModelPicker('localhost:1', mac);
		await picker.open();
		mac.hold = true;
		const first = picker.pick(MODELS[1]);
		await picker.pick(MODELS[0]);
		mac.release();
		await first;
		expect(mac.calls).toEqual(['open', 'pick 2 Haiku 5.5']);
	});
});
