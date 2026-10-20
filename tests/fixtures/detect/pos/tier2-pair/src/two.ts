const kernel = new Kernel({ apiKey });
const b = await kernel.browsers.create();
const url = b.cdp_ws_url;
