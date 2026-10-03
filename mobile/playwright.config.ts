import { defineConfig } from '@playwright/test';

// The port comes from the environment so a run never assumes one is free.
const port = Number(process.env.PORT);
if (!port) throw new Error('Set PORT to a free port before running the e2e tests.');

export default defineConfig({
	testDir: 'e2e',
	fullyParallel: false,
	workers: 1,
	reporter: [['list']],
	use: {
		baseURL: `http://127.0.0.1:${port}`,
		browserName: 'chromium',
		viewport: { width: 390, height: 844 },
		deviceScaleFactor: 3,
		isMobile: true,
		hasTouch: true,
		userAgent:
			'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
		trace: 'retain-on-failure'
	},
	webServer: {
		command: 'node e2e/fixture-server.mjs',
		port,
		reuseExistingServer: false,
		env: { PORT: String(port) }
	}
});
