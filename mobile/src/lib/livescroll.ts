/**
 * The live terminal scrolls like a page: one tall, empty box gives the
 * browser's own scrolling (and its momentum) something to move over, and the
 * terminal, which draws only its screen, is kept in view inside it. Where the
 * box is scrolled to says which line the terminal shows at its top, and how
 * far the terminal is shifted to show the rest.
 */
export interface Geometry {
	/** Lines of scrollback above the screen. */
	base: number;
	/** Lines of the screen. */
	rows: number;
	/** Height of one line, in pixels. */
	cell: number;
	/** Height of the part of the page the terminal is seen through. */
	view: number;
}

/** The height of the screen's own lines. */
const screen = (g: Geometry): number => g.rows * g.cell;

/** The height of the tall box: the scrollback, then the screen or the view if that is taller. */
export function totalHeight(g: Geometry): number {
	return g.base * g.cell + Math.max(screen(g), g.view);
}

export function maxScroll(g: Geometry): number {
	return Math.max(0, totalHeight(g) - g.view);
}

export interface Place {
	/** The line of the buffer at the top of the terminal's screen. */
	line: number;
	/** How far up the terminal is shifted, in pixels. */
	shift: number;
}

/** What to show when the box is scrolled to `top`. */
export function place(top: number, g: Geometry): Place {
	if (g.cell <= 0) return { line: 0, shift: 0 };
	const at = Math.min(Math.max(top, 0), maxScroll(g));
	const line = Math.min(Math.floor(at / g.cell), g.base);
	const most = Math.max(0, screen(g) - g.view);
	return { line, shift: Math.min(Math.max(at - line * g.cell, 0), most) };
}

/** Lines kept in view below the cursor's line. */
const BELOW = 2;

/**
 * Where to scroll so the cursor's line is in view, with what is below it when
 * there is room: the end of the screen, or less when the cursor is higher up
 * than the view is tall (a prompt at the top of an empty pane, or the keyboard
 * taking half the page).
 */
export function followTop(g: Geometry, cursorY: number): number {
	const end = maxScroll(g);
	const cursorBottom = (g.base + Math.min(cursorY + 1 + BELOW, g.rows)) * g.cell;
	// The end shows the cursor when its line is inside the last `view` pixels.
	if (cursorBottom > end) return end;
	return Math.max(0, cursorBottom - g.view);
}

/** Whether `top` is where following would put it, to within a line. */
export function isFollowing(top: number, g: Geometry, cursorY: number): boolean {
	return Math.abs(top - followTop(g, cursorY)) < Math.max(g.cell, 1);
}

/**
 * A program on the alternate screen (an editor, an agent's own interface) has
 * no scrollback here: it scrolls itself, when it is told to. A drag over it
 * becomes steps for the program, one for each line the finger travels.
 */
export const MAX_STEPS = 40;

export interface Steps {
	/** Lines to scroll: more than 0 towards what is above. */
	steps: number;
	/** Travel, in pixels, that is not yet a line. */
	rest: number;
}

/** The steps of a move of `moved` pixels (down is more than 0), with `rest` carried from the last. */
export function wheelSteps(rest: number, moved: number, cell: number): Steps {
	if (!(cell > 0)) return { steps: 0, rest: 0 };
	const total = rest + moved;
	const steps = Math.trunc(total / cell);
	if (Math.abs(steps) > MAX_STEPS) return { steps: Math.sign(steps) * MAX_STEPS, rest: 0 };
	return { steps, rest: total - steps * cell };
}

export interface WheelMode {
	/** The program asked for mouse reports in the SGR form. */
	mouse: boolean;
	/** The program's cursor-key mode. */
	application: boolean;
}

/**
 * What `steps` type into the pane: wheel reports at the cell under the finger
 * for a program that reads the mouse, arrow keys for one that does not.
 */
export function wheelText(
	steps: number,
	mode: WheelMode,
	at: { col: number; row: number }
): string {
	const count = Math.min(Math.abs(Math.trunc(steps)), MAX_STEPS);
	const up = steps > 0;
	const cell = (n: number): number => Math.max(1, Math.floor(n));
	const one = mode.mouse
		? `\x1b[<${up ? 64 : 65};${cell(at.col)};${cell(at.row)}M`
		: `\x1b${mode.application ? 'O' : '['}${up ? 'A' : 'B'}`;
	return one.repeat(count);
}

/** The limits of the Mac for a size the phone asks for. */
const COLS = [20, 300] as const;
const ROWS = [5, 200] as const;

export interface Size {
	cols: number;
	rows: number;
}

/** The cells of `cell` pixels that fit `view`, or null when either is not measured. */
export function fit(
	view: { width: number; height: number },
	cell: { width: number; height: number }
): Size | null {
	if (!(cell.width > 0) || !(cell.height > 0) || !(view.width > 0) || !(view.height > 0))
		return null;
	const within = (n: number, [least, most]: readonly [number, number]): number =>
		Math.min(Math.max(Math.floor(n), least), most);
	return {
		cols: within(view.width / cell.width, COLS),
		rows: within(view.height / cell.height, ROWS)
	};
}
