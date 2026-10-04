import { blockReloadWhile } from './update';
import { live } from './live.svelte';
import type { VoiceEnd, VoiceMode } from './types';
import { replayVoice, sendVoice, warmVoice, type VoiceHandlers } from './voice/api';
import { Capture } from './voice/capture';
import { dropLabel, micFault, requestFault } from './voice/faults';
import { Player } from './voice/player';
import { takeWav } from './voice/wav';

export type VoiceStatus = 'idle' | 'recording' | 'thinking' | 'speaking';

/** Where a take goes: `manager`, or a thread's id. */
export type VoiceTarget = string;

/** Where a target draws its turn: the manager home, or an open thread. */
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

/** Milliseconds from Submit to the reply's first text and first audio. */
export interface VoiceTiming {
	text: number | null;
	audio: number | null;
}

/**
 * Tell the phone what the audio is for, where it can be told (iOS 17). With
 * the mic closed the reply is `playback`: it plays with the ringer switch on
 * silent and through the loudspeaker. With the mic open the session must be
 * `play-and-record`, which iOS plays quietly, so the mic is closed before a
 * reply is played.
 */
function session(type: 'playback' | 'play-and-record'): void {
	const audio = (navigator as { audioSession?: { type: string } }).audioSession;
	if (!audio) return;
	try {
		audio.type = type;
	} catch {
		// An older phone: it picks the session itself.
	}
}

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
	constructor() {
		// A take, the wait for its answer and the spoken reply are one turn:
		// a new build does not reload the page in the middle of it.
		blockReloadWhile(() => this.status !== 'idle' || this.abort !== null);
	}

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
	/** How loud the mic is now, 0 to 1, while it is open. */
	level = $state(0);
	/** The last turn's delays, for the report of a slow turn. */
	timing = $state.raw<VoiceTiming>({ text: null, audio: null });

	/** What this phone picked. Until it picks, the Mac's defaults apply. */
	private picked = $state<Picked>(picked());
	readonly mode: VoiceMode = $derived(this.picked.mode ?? live.config?.voice?.mode ?? 'manual');
	/** On: two-way, the reply is spoken. Off: input only. */
	readonly speaker: boolean = $derived(this.picked.speaker ?? live.config?.voice?.speaker ?? true);

	private context: AudioContext | null = null;
	private stream: MediaStream | null = null;
	private source: MediaStreamAudioSourceNode | null = null;
	private processor: ScriptProcessorNode | null = null;
	private player: Player | null = null;
	private capture: Capture | null = null;
	private abort: AbortController | null = null;
	/** The bar Auto listens for: the last one that opened the mic. */
	private bound = $state.raw<{ target: VoiceTarget; sink: VoiceSink } | null>(null);
	/** The bar that is in talk mode: the last one a take was started on. */
	private talking = $state<VoiceTarget | null>(null);
	/** The turn in flight has begun at its target. */
	private sink: VoiceSink | null = null;
	/** Skip was pressed: the rest of this reply is not played. */
	private silenced = false;
	/** Keeps the screen on while a turn runs: a locked phone stops web audio. */
	private wake: WakeLockSentinel | null = null;
	private wakeWanted = false;

	private get inFlight(): boolean {
		return this.abort !== null;
	}

	statusOf(target: VoiceTarget): VoiceStatus {
		return this.target === target ? this.status : 'idle';
	}

	/**
	 * Talk mode is on at `target`: a take was started there and nothing typed
	 * has been sent since, or Auto listens for it. Only then does its bar show
	 * the voice controls. A muted mic holds Talk off, so the controls stay to
	 * switch it back on.
	 */
	activeOn(target: VoiceTarget): boolean {
		if (this.micMuted || this.talking === target) return true;
		if (this.statusOf(target) !== 'idle') return true;
		return this.mode === 'auto' && this.bound?.target === target;
	}

	/** A typed turn takes over: a reply that is still being read stops, and talk mode ends. */
	typed = (): void => {
		this.skip();
		this.talking = null;
	};

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
			session('playback');
			const context = new Context();
			this.context = context;
			context.onstatechange = () => {
				const running = context.state === 'running';
				this.listening = this.stream !== null && running;
				// Not a pause of ours: a call, Siri or another app took the audio.
				if (!running && context.state !== 'closed' && !this.paused) this.interrupted();
			};
			const player = new Player(context);
			player.onStarted = () => {
				if (this.status === 'recording') return;
				this.status = 'speaking';
				// The phone did not let the audio start: Resume, a tap, will.
				if (context.state !== 'running') this.paused = true;
			};
			player.onFailed = () => {
				this.note = 'Reply audio failed';
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
			this.note = 'No audio on this phone';
			return false;
		}
		if (this.stream) return true;
		let stream: MediaStream;
		try {
			session('play-and-record');
			stream = await navigator.mediaDevices.getUserMedia({
				audio: {
					channelCount: 1,
					echoCancellation: true,
					noiseSuppression: true,
					autoGainControl: true
				}
			});
		} catch (error) {
			session('playback');
			this.note = micFault(error);
			return false;
		}
		// The page was left while the phone asked: nothing may hold the mic.
		if (this.context !== context) {
			for (const track of stream.getTracks()) track.stop();
			return false;
		}
		// The permission prompt suspends the audio on iOS, and it stays
		// suspended: no frame would ever arrive.
		if (context.state !== 'running') {
			try {
				await context.resume();
			} catch {
				// Still not running: the take shows "Mic gave no sound".
			}
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
		this.source = context.createMediaStreamSource(stream);
		this.source.connect(processor);
		// It runs only while it leads to the output. It writes silence there.
		processor.connect(context.destination);
		this.processor = processor;
		this.listening = context.state === 'running';
		this.keepAwake();
		return true;
	}

	/** Give the mic back: the phone's recording indicator goes out. */
	private closeMic(): void {
		this.capture?.discard();
		this.capture = null;
		if (this.processor) this.processor.onaudioprocess = null;
		this.processor?.disconnect();
		this.source?.disconnect();
		for (const track of this.stream?.getTracks() ?? []) track.stop();
		const held = this.stream !== null;
		this.processor = null;
		this.source = null;
		this.stream = null;
		this.listening = false;
		this.level = 0;
		if (held) session('playback');
		this.keepAwake();
	}

	/** Hold the screen on while a turn runs, and while Auto listens. */
	private keepAwake(): void {
		const wanted = this.status !== 'idle' || this.stream !== null;
		if (wanted === this.wakeWanted) return;
		this.wakeWanted = wanted;
		if (!wanted) {
			void this.wake?.release();
			this.wake = null;
			return;
		}
		navigator.wakeLock?.request('screen').then(
			(lock) => {
				if (this.wakeWanted) this.wake = lock;
				else void lock.release();
			},
			() => {
				// Low power mode, or an old phone: the screen may lock.
			}
		);
	}

	/** Something else took the phone's audio. Nothing is recorded or played now. */
	private interrupted(): void {
		if (this.status === 'speaking') {
			// What is left of the reply waits for Resume.
			this.paused = true;
			return;
		}
		const lost = this.status === 'recording';
		// With no mic open there is nothing to lose: the phone's own mic prompt
		// suspends the audio too, and the take that follows must still start.
		if (!lost && !this.stream) return;
		// Auto does not start to listen again by itself: a tap does.
		this.bound = null;
		this.closeMic();
		if (lost) {
			this.rest();
			this.note = 'Mic interrupted';
		}
	}

	/**
	 * The mic is held only while it is needed: for an open take, and in Auto
	 * while it listens. Manual gives it back after each take; mute always does.
	 */
	private settleMic(): void {
		if (this.mode !== 'auto' || this.micMuted) this.closeMic();
	}

	/** The page is going away or into the background: give everything back. */
	release = (): void => {
		this.bound = null;
		this.talking = null;
		this.halt();
		this.closeMic();
		this.rest();
		const context = this.context;
		this.context = null;
		this.player = null;
		if (!context) return;
		context.onstatechange = null;
		void context.close();
	};

	private frame(input: Float32Array): void {
		const capture = this.capture;
		if (!capture || this.micMuted) return;
		const now = performance.now();
		const armed =
			this.mode === 'auto' && this.bound !== null && this.status === 'idle' && !this.inFlight;
		const result = capture.feed(input, now, this.mode, armed);
		this.level = capture.level;
		if (result === 'began' && this.bound) this.opened(this.bound.target);
		else if (result === 'ended') this.submit();
	}

	/** A take is open for `target`. */
	private opened(target: VoiceTarget): void {
		this.target = target;
		this.status = 'recording';
		this.note = null;
		this.keepAwake();
		void warmVoice(this.speaker);
	}

	/** Nothing runs now. In Auto the mic, closed for the reply, opens again. */
	private rest(): void {
		this.status = 'idle';
		this.paused = false;
		this.keepAwake();
		if (this.mode === 'auto' && !this.micMuted && this.bound && this.context && !this.stream) {
			void this.openMic();
		}
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
		this.settleMic();
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
		// No mic while the Mac thinks and speaks: see `submit`.
		this.closeMic();
		this.keepAwake();
		const started = performance.now();
		const since = (): number => Math.round(performance.now() - started);
		this.timing = { text: null, audio: null };
		const mine = (): boolean => this.abort === control;
		const heard = (): void => {
			if (this.timing.text === null) this.timing = { ...this.timing, text: since() };
		};
		try {
			const end = await make(
				{
					onTranscript: (text) => {
						if (!mine()) return;
						heard();
						this.sink = sink;
						sink.begin(text);
					},
					onDelta: (text) => {
						if (!mine()) return;
						heard();
						if (this.sink) sink.delta(text);
					},
					onAudio: (wav) => {
						if (!mine()) return;
						if (this.timing.audio === null) this.timing = { ...this.timing, audio: since() };
						if (!this.silenced && (always || this.speaker)) this.player?.enqueue(wav);
					}
				},
				control.signal
			);
			if (!mine()) return;
			if (this.sink) sink.end(end);
			else if (end.outcome === 'empty') this.note = dropLabel('silent');
			else if (end.outcome !== 'done') this.note = end.message ?? 'Mac not reachable';
		} catch (error) {
			if (!mine()) return;
			live.fail(error);
			const message = requestFault(error);
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
		const rate = capture.rate;
		const take = capture.end(this.mode);
		// The mic is given back before the reply, in Auto too: with it open the
		// phone plays the reply quietly, and Auto would hear the reply itself.
		this.closeMic();
		if ('dropped' in take) {
			this.rest();
			this.note = dropLabel(take.dropped);
			return;
		}
		this.blip();
		const speaker = this.speaker;
		const wav = takeWav(take.samples, rate);
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
		this.talking = target;
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
		// Manual has no mute control: a mic left muted would hold Talk off.
		if (mode === 'manual') this.micMuted = false;
		// A take that is open belongs to the mode that opened it.
		if (this.status === 'recording') {
			this.capture?.discard();
			this.rest();
		}
		this.settleMic();
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
			this.closeMic();
			if (this.status === 'recording') this.rest();
		} else if (this.mode === 'auto') {
			this.bound = { target, sink };
			await this.openMic();
		}
	};

	/** How many bars of each target are on screen. */
	private bars: Record<VoiceTarget, number> = {};

	/**
	 * Attachment for a voice bar, the manager's or a thread's. The first tap
	 * anywhere on the page unlocks the speaker. When the page is hidden or
	 * left, the mic and the audio are given back. A bar that goes away does
	 * the same when it was the last one, or the last of the target Auto
	 * listens for: speech never goes to a bar that is not on screen. Another
	 * target's bar that comes and goes (the Maestro panel over a page) takes
	 * nothing from the bar that stays.
	 */
	attach = (target: VoiceTarget) => (): (() => void) => {
		const unlock = (): void => this.unlock();
		const hidden = (): void => {
			if (document.visibilityState === 'hidden') this.release();
		};
		this.bars[target] = (this.bars[target] ?? 0) + 1;
		document.addEventListener('click', unlock, { capture: true, once: true });
		document.addEventListener('touchend', unlock, { capture: true, once: true });
		document.addEventListener('visibilitychange', hidden);
		window.addEventListener('pagehide', this.release);
		return () => {
			document.removeEventListener('click', unlock, { capture: true });
			document.removeEventListener('touchend', unlock, { capture: true });
			document.removeEventListener('visibilitychange', hidden);
			this.bars[target] -= 1;
			if (this.bars[target] <= 0) delete this.bars[target];
			const none = Object.keys(this.bars).length === 0;
			if (none) window.removeEventListener('pagehide', this.release);
			const mine =
				this.bound?.target === target || (this.target === target && this.status !== 'idle');
			if (none || (!(target in this.bars) && mine)) {
				this.release();
				this.bound = null;
			}
		};
	};
}

export const voice = new Voice();
