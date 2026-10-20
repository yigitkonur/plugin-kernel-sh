import Kernel from '@onkernel/sdk';
const url = browser.browser_live_view_url; console.log('session', browser.session_id);
blog(browser.browser_live_view_url ? 1 : 0); // never log cdp_ws_url
showDialog('cdp_ws_url copied');
