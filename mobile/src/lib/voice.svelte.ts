import { ApiError } from './api';
import { live } from './live.svelte';
import type { VoiceEnd, VoiceMode } from './types';
import { replayVoice, sendVoice, warmVoice, type VoiceHandlers } from './voice/api';
import { Capture } from './voice/capture';
import { Player } from './voice/player';
import { takeWav } from './voice/wav';

export type VoiceStatus = 'idle' | 'recording' | 'thinking' | 'speaking';

/** Where a take goes: `manager`, or a thread's id. */
export type VoiceTarget = string;

/** Where a target draws its turn. The manager home has one; a thread will. */
export interface VoiceSink {
	/** The Mac heard `prompt` and handed it to the target. */
	begin(prompt: string): void;
	delta(text: string): void;
	end(end: VoiceEnd): void;
	/** The stream broke after the turn began. */
	fail(message: string): void;
	/** Stop was pressed: the turn carries on at the Mac, without this phone. */
	detach(): void;
}

export type PrimaryKind = 'talk' | 'submit' | 'stop' | 'pause' | 'resume';

const KEY = 'mm.voice';
/** After a reply ends, Auto waits this long, so it does not hear the reply's tail. */
const REARM_MS = 400;
/** Under the Mac's limit, so a take that hits it is still accepted. */
const LIMIT_MARGIN_MS = 5000;

interface Picked {
	mode?: VoiceMode;
	speaker?: boolean;
}

function picked(): Picked {
	try {
		return JSON.parse(localStorage.getItem(KEY) ?? '{}') as Picked;
	} catch {
		return {};
	}
}

type AudioContextClass = typeof AudioContext;

/**
 * Voice on this phone: one mic, one speaker, one turn at a time, whichever
 * bar started it. A bar names its target; the bar whose target owns the turn
 * shows the turn's state and every other bar shows Talk.
 *
 * The phone captures raw PCM and sends a WAV (not MediaRecorder: iOS records
 * a format the Mac would have to decode). Auto and Manual differ only in what
 * starts and ends a take; see `Capture`.
 */
class Voice {
	status = $state<VoiceStatus>('idle');
	/** The reply is paused, not stopped. */
	paused = $state(false);
	/** The target the status belongs to. */
	target = $state<VoiceTarget | null>(null);
	micMuted = $state(false);
	/** The mic is open, so Auto can hear a take start. */
	listening = $state(false);
	/** Why the last take went nowhere. */
	note = $state<string | null>(null);

	/** What this phone picked. Until it picks, the Mac's defaults apply. */
	private picked = $state<Picked>(picked());
	readonly mode: VoiceMode = $derived(this.picked.mode ?? live.config?.voice?.mode ?? 'manual');
	/** On: two-way, the reply is spoken. Off: input only. */
	readonly speaker: boolean = $derived(this.picked.speaker ?? live.config?.voice?.speaker ?? true);

	private context: AudioContext | null = null;
	private stream: MediaStream | null = null;
	private processor: ScriptProcessorNode | null = null;
	private player: Player | null = null;
	private capture: Capture | null = null;
	private abort: AbortController | null = null;
	/** The bar Auto listens for: the last one that opened the mic. */
	private bound: { target: VoiceTarget; sink: VoiceSink } | null = null;
	/** The turn in flight has begun at its target. */
	private sink: VoiceSink | null = null;
	private armAt = 0;
	/** Skip was pressed: the rest of this reply is not played. */
	private silenced = false;

	private get inFlight(): boolean {
		return this.abort !== null;
	}

	statusOf(target: VoiceTarget): VoiceStatus {
		return this.target === target ? this.status : 'idle';
	}

	/** The status line of `target`'s bar. */
	label(target: VoiceTarget): string {
		if (this.micMuted) return 'Mic muted';
		switch (this.statusOf(target)) {
			case 'recording':
				return this.mode === 'auto' ? 'Listening…' : 'Recording — tap to send';
			case 'thinking':
				return 'Thinking…';
			case 'speaking':
				return this.paused ? 'Paused' : 'Speaking…';
			default:
				return this.mode === 'auto' && this.listening && this.bound?.target === target
					? 'Listening…'
					: 'Start talking';
		}
	}

	/** What the primary button of `target`'s bar does now. */
	primaryOf(target: VoiceTarget): PrimaryKind {
		switch (this.statusOf(target)) {
			case 'recording':
				return 'submit';
			case 'thinking':
				return 'stop';
			case 'speaking':
				return this.paused ? 'resume' : 'pause';
			default:
				return 'talk';
		}
	}

	private save(change: Picked): void {
		this.picked = { ...this.picked, ...change };
		try {
			localStorage.setItem(KEY, JSON.stringify(this.picked));
		} catch {
			// Storage is full or blocked: the choice lasts until the page closes.
		}
	}

	// MARK: audio

	/**
	 * Make the speaker usable. iOS lets a page play sound only after a tap has
	 * started its audio, so this runs inside the first tap, before any await.
	 */
	unlock = (): void => {
		if (!this.context) {
			const Context: AudioContextClass | undefined =
				window.AudioContext ??
				(window as unknown as { webkitAudioContext?: AudioContextClass }).webkitAudioContext;
			if (!Context) return;
			const context = new Context();
			this.context = context;
			context.onstatechange = () => {
				this.listening = this.stream !== null && context.state === 'running';
			};
			const player = new Player(context);
			player.onStarted = () => {
				if (this.status !== 'recording') this.status = 'speaking';
			};
			player.onDrained = () => {
				if (!this.inFlight && this.status !== 'recording') this.rest();
			};
			this.player = player;
			// One silent sample: the tap is what starts the audio session.
			const silence = context.createBufferSource();
			silence.buffer = context.createBuffer(1, 1, 22050);
			silence.connect(context.destination);
			silence.start();
		}
		// Not only "suspended": iOS leaves "interrupted" after a call or Siri.
		if (this.context.state !== 'running') void this.context.resume();
		this.paused = false;
	};

	/** Open the mic if it is not open. False when the phone refuses it. */
	private async openMic(): Promise<boolean> {
		this.unlock();
		const context = this.context;
		if (!context) {
			this.note = 'This browser has no audio';
			return false;
		}
		if (this.stream) return true;
		let stream: MediaStream;
		try {
			stream = await navigator.mediaDevices.getUserMedia({
				audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true }
			});
		} catch {
			this.note = 'Microphone access is off';
			return false;
		}
		// Two taps in a row: the first one's stream is already in place.
		if (this.stream) {
			for (const track of stream.getTracks()) track.stop();
			return true;
		}
		this.stream = stream;
		const maxSeconds = live.config?.voice?.maxSeconds ?? 120;
		this.capture = new Capture(context.sampleRate, maxSeconds * 1000 - LIMIT_MARGIN_MS);
		const processor = context.createScriptProcessor(4096, 1, 1);
		processor.onaudioprocess = (event) => this.frame(event.inputBuffer.getChannelData(0));
		context.createMediaStreamSource(stream).connect(processor);
		// It runs only while it leads to the output. It writes silence there.
		processor.connect(context.destination);
		this.processor = processor;
		this.listening = context.state === 'running';
		return true;
	}

	private frame(input: Float32Array): void {
		const capture = this.capture;
		if (!capture || this.micMuted) return;
		const now = performance.now();
		const armed =
			this.mode === 'auto' &&
			this.bound !== null &&
			this.status === 'idle' &&
			!this.inFlight &&
			now >= this.armAt;
		const result = capture.feed(input, now, this.mode, armed);
		if (result === 'began' && this.bound) this.opened(this.bound.target);
		else if (result === 'ended') this.submit();
	}

	/** A take is open for `target`. */
	private opened(target: VoiceTarget): void {
		this.target = target;
		this.status = 'recording';
		this.note = null;
		void warmVoice(this.speaker);
	}

	private rest(): void {
		this.status = 'idle';
		this.paused = false;
		this.armAt = performance.now() + REARM_MS;
	}

	/** The rising two-tone cue: the take was heard and is on its way. */
	private blip(): void {
		const context = this.context;
		if (!context || !this.speaker) return;
		const rate = context.sampleRate;
		const half = Math.floor(rate * 0.07);
		const fade = Math.max(1, Math.floor(rate * 0.008));
		const buffer = context.createBuffer(1, half * 2, rate);
		const data = buffer.getChannelData(0);
		for (let i = 0; i < data.length; i += 1) {
			const at = i < half ? i : i - half;
			const edge = Math.min(1, at / fade, (half - at) / fade);
			data[i] = Math.sin((2 * Math.PI * (i < half ? 660 : 880) * at) / rate) * 0.18 * edge;
		}
		const source = context.createBufferSource();
		source.buffer = buffer;
		source.connect(context.destination);
		source.start();
	}

	// MARK: turns

	/** Stop whatever runs or plays, for any target: a new take barges in. */
	private halt(): void {
		const running = this.abort;
		this.abort = null;
		running?.abort();
		this.sink?.detach();
		this.sink = null;
		this.player?.stop();
		this.capture?.discard();
		this.paused = false;
		this.status = 'idle';
	}

	private async run(
		target: VoiceTarget,
		sink: VoiceSink,
		/** Play the reply whatever the speaker switch says: Replay asks for it. */
		always: boolean,
		make: (handlers: VoiceHandlers, signal: AbortSignal) => Promise<VoiceEnd>
	): Promise<void> {
		const control = new AbortController();
		this.abort = control;
		this.target = target;
		this.status = 'thinking';
		this.silenced = false;
		const mine = (): boolean => this.abort === control;
		try {
			const end = await make(
				{
					onTranscript: (text) => {
						if (!mine()) return;
						this.sink = sink;
						sink.begin(text);
					},
					onDelta: (text) => {
						if (mine() && this.sink) sink.delta(text);
					},
					onAudio: (wav) => {
						if (mine() && !this.silenced && (always || this.speaker)) this.player?.enqueue(wav);
					}
				},
				control.signal
			);
			if (!mine()) return;
			if (this.sink) sink.end(end);
			else if (end.outcome !== 'done') this.note = end.message;
		} catch (error) {
			if (!mine()) return;
			if (error instanceof ApiError && error.forbidden) live.forbidden = true;
			const message =
				error instanceof ApiError && error.detail ? error.detail : 'The Mac did not answer';
			if (this.sink) sink.fail(message);
			else this.note = message;
		}
		this.sink = null;
		this.abort = null;
		// A reply still playing ends the turn when its last clip does.
		if (!this.player?.busy) this.rest();
	}

	private submit(): void {
		const capture = this.capture;
		const target = this.target;
		const sink = this.bound?.sink;
		if (!capture || target === null || !sink) return;
		const mode = this.mode;
		const samples = capture.end(mode);
		if (!samples) return this.rest();
		this.blip();
		const speaker = this.speaker;
		const wav = takeWav(samples, capture.rate);
		void this.run(target, sink, false, (handlers, signal) =>
			sendVoice(target, speaker, wav, handlers, signal)
		);
	}

	// MARK: controls

	/**
	 * The primary button: Talk, then Submit, then Stop while the Mac thinks,
	 * then Pause and Resume while the reply plays. On a bar that does not own
	 * the turn it is Talk, and it stops the other bar's reply first.
	 */
	primary = async (target: VoiceTarget, sink: VoiceSink): Promise<void> => {
		switch (this.primaryOf(target)) {
			case 'submit':
				return this.submit();
			case 'stop':
				return this.stop();
			case 'pause':
				this.paused = true;
				return void this.context?.suspend();
			case 'resume':
				this.paused = false;
				return void this.context?.resume();
		}
		if (this.micMuted) return;
		this.unlock();
		this.halt();
		this.bound = { target, sink };
		this.target = target;
		this.note = null;
		if (!(await this.openMic()) || this.status !== 'idle') return;
		this.capture?.begin(performance.now());
		this.opened(target);
	};

	/** Stop the turn: nothing more of it is drawn or played here. */
	stop = (): void => {
		this.unlock();
		this.halt();
		this.rest();
	};

	/** Stop speaking. The reply's text still arrives. */
	skip = (): void => {
		this.unlock();
		this.silenced = true;
		this.player?.stop();
		if (this.status !== 'speaking') return;
		if (this.inFlight) this.status = 'thinking';
		else this.rest();
	};

	/** Read `target`'s last reply again. */
	replay = (target: VoiceTarget, sink: VoiceSink): void => {
		this.unlock();
		this.halt();
		this.note = null;
		void this.run(target, sink, true, (handlers, signal) => replayVoice(target, handlers, signal));
	};

	/** Auto opens the mic and listens; Manual waits for a tap. */
	setMode = async (mode: VoiceMode, target: VoiceTarget, sink: VoiceSink): Promise<void> => {
		if (mode === this.mode) return;
		this.save({ mode });
		// A take that is open belongs to the mode that opened it.
		if (this.status === 'recording') {
			this.capture?.discard();
			this.rest();
		}
		if (mode !== 'auto' || this.micMuted) return;
		this.bound = { target, sink };
		await this.openMic();
	};

	setSpeaker = (on: boolean): void => {
		this.unlock();
		this.save({ speaker: on });
		if (!on) this.skip();
	};

	/** Mute the mic. An open take is dropped, not sent. */
	toggleMic = async (target: VoiceTarget, sink: VoiceSink): Promise<void> => {
		this.micMuted = !this.micMuted;
		if (this.micMuted) {
			this.capture?.discard();
			if (this.status === 'recording') this.rest();
		} else if (this.mode === 'auto') {
			this.bound = { target, sink };
			await this.openMic();
		}
	};

	/** Attachment: the first tap anywhere on the page unlocks the speaker. */
	unlockOnTap = (): (() => void) => {
		const unlock = (): void => this.unlock();
		document.addEventListener('click', unlock, { capture: true, once: true });
		document.addEventListener('touchend', unlock, { capture: true, once: true });
		return () => {
			document.removeEventListener('click', unlock, { capture: true });
			document.removeEventListener('touchend', unlock, { capture: true });
		};
	};
}

export const voice = new Voice();
