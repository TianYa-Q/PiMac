# PiMac Goal presentation adapter

Loads the unmodified `@schovest/pi-goal@0.2.1` factory and observes its public
`appendEntry("goal-state", ...)` persistence channel. Only validated presentation
state is mirrored to PiMac; commands, tools, confirmation and scheduling remain
owned by the package. Do not enable the dependency's direct extension alongside
this adapter (duplicate `/goal` registration).

```sh
npm ci --ignore-scripts --legacy-peer-deps
npm run typecheck
npm test
```

Integration, installation, limitations and migration policy: [Pi Goal](../../docs/pi-goal.md).
