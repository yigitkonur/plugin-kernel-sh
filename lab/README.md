# Lab smoke tests (maintainers)

These scripts re-check, against the live Kernel API, the facts the plugin teaches. Run them after an SDK minor bump or when the weekly freshness issue opens.

```sh
cd lab
npm install
cp .env.example .env   # add a throwaway KERNEL_API_KEY; never commit .env
npm run smoke
```

They create short-lived headless browsers tagged `lab=plugin-smoke` (and one profile named `kplab-smoke-<time>`), delete everything in `finally`, and cost a few cents. Run them on an account where a handful of extra concurrent browsers is fine.
