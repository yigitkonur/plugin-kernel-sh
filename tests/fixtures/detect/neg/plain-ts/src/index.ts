import { chromium } from "playwright-core";
export const run = async () => (await chromium.launch()).close();
