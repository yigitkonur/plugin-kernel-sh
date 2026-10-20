import Kernel from '@onkernel/sdk';
const b = await kernel.browsers.create({ timeout_seconds: 600 });
const store = { redux: { persistence: 'local' } };
const persistent_id = uuid();
