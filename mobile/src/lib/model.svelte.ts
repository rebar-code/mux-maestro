import { modelError, type ModelStage } from './model';
import type { EffortOption, ModelMenu, ModelOption } from './types';

/** The four calls the picker makes; a test gives its own. */
export interface ModelApi {
	open(id: string): Promise<ModelMenu>;
	pick(id: string, model: ModelOption): Promise<EffortOption[]>;
	apply(id: string, model: string, effort: string | null): Promise<void>;
	close(id: string): Promise<void>;
}

/**
 * The model sheet of one thread. The lists are the agent's own `/model` menu,
 * which stays open in the pane while the sheet is: closing the sheet closes it.
 */
export class ModelPicker {
	stage = $state<ModelStage>('closed');
	models = $state.raw<ModelOption[]>([]);
	efforts = $state.raw<EffortOption[]>([]);
	/** The model the list of levels is for. */
	picked = $state.raw<ModelOption | null>(null);
	/** A step is on its way to the pane. */
	busy = $state(false);
	error = $state<string | null>(null);
	/** Each time the sheet opens or closes: an answer for an older one is dropped. */
	private visit = 0;
	/**
	 * The agent's menu may be open in the pane. Not state: `close` also runs as
	 * the sheet is taken down, where state still reads as it was before.
	 */
	private live = false;
	/** The step in flight. The Mac takes one write to a pane at a time. */
	private step: Promise<unknown> = Promise.resolve();

	constructor(
		private readonly id: string,
		private readonly api: ModelApi
	) {}

	/** Run one step; null when it failed or the sheet has moved on. */
	private async run<T>(call: () => Promise<T>): Promise<{ value: T } | null> {
		const visit = this.visit;
		this.busy = true;
		this.error = null;
		const step = call();
		this.step = step.catch(() => undefined);
		try {
			const value = await step;
			return visit === this.visit ? { value } : null;
		} catch (error) {
			if (visit !== this.visit) return null;
			// The Mac closes the agent's menu when it refuses: the lists are gone.
			this.stage = 'loading';
			this.error = modelError(error);
			return null;
		} finally {
			if (visit === this.visit) this.busy = false;
		}
	}

	open = async (): Promise<void> => {
		if (this.stage !== 'closed') return;
		this.visit += 1;
		this.live = true;
		this.stage = 'loading';
		this.models = [];
		this.picked = null;
		const menu = await this.run(() => this.api.open(this.id));
		if (menu) {
			this.models = menu.value.models;
			this.stage = 'models';
		}
	};

	/** A tap on a model: its levels are next. A model without levels is taken now. */
	pick = async (model: ModelOption): Promise<void> => {
		if (this.busy || this.stage !== 'models') return;
		const efforts = await this.run(() => this.api.pick(this.id, model));
		if (!efforts) return;
		this.picked = model;
		if (efforts.value.length === 0) return this.apply(null);
		this.efforts = efforts.value;
		this.stage = 'efforts';
	};

	apply = async (effort: string | null): Promise<void> => {
		const model = this.picked;
		if (this.busy || !model) return;
		const done = await this.run(() => this.api.apply(this.id, model.label, effort));
		// The pick is taken and the agent's menu is gone: nothing to cancel.
		if (done) {
			this.live = false;
			this.dismiss();
		}
	};

	/** From the levels to the models again. */
	back = (): void => {
		if (this.busy) return;
		this.error = null;
		this.stage = 'models';
	};

	private dismiss(): void {
		this.visit += 1;
		this.stage = 'closed';
		this.busy = false;
		this.error = null;
	}

	/** Close the sheet, and the agent's menu after the step in flight. */
	close = (): void => {
		if (!this.live) return;
		this.live = false;
		this.dismiss();
		const { id, api } = this;
		void this.step.then(() => api.close(id)).catch(() => undefined);
	};
}
