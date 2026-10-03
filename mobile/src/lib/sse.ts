export interface Frame {
	event: string;
	data: string;
}

/**
 * Splits a Server-Sent Events stream into frames. Feed it the text as it
 * arrives, in pieces of any size; it returns the frames each piece completed.
 * A frame ends at a blank line. Lines that start with ":" are comments.
 */
export function frameParser(): (chunk: string) => Frame[] {
	let buffer = '';
	return (chunk) => {
		buffer += chunk.replace(/\r\n?/g, '\n');
		const frames: Frame[] = [];
		for (;;) {
			const end = buffer.indexOf('\n\n');
			if (end < 0) break;
			const block = buffer.slice(0, end);
			buffer = buffer.slice(end + 2);
			let event = 'message';
			const data: string[] = [];
			for (const line of block.split('\n')) {
				if (line.startsWith(':')) continue;
				const colon = line.indexOf(':');
				const field = colon < 0 ? line : line.slice(0, colon);
				const value = colon < 0 ? '' : line.slice(colon + 1).replace(/^ /, '');
				if (field === 'event') event = value;
				else if (field === 'data') data.push(value);
			}
			if (data.length) frames.push({ event, data: data.join('\n') });
		}
		return frames;
	};
}
