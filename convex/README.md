# RoachNet Convex

Convex is the optional RoachWares control plane for public release metadata,
company status, and future account-backed services.

RoachNet itself must keep working without Convex. The native app owns the local
runtime, vault, RoachClaw, and release-gate checks. Convex is for online public
surfaces and account-aware coordination when the user chooses to use them.

## Local

```bash
npm run convex:codegen
```

Use `npx convex dev` only after the RoachWares Convex project is selected in the
CLI. That command writes `.env.local`; do not commit it.

## CI

The GitHub workflow expects `CONVEX_DEPLOY_KEY` in the RoachWares organization or
repository secrets. Without the secret, CI still typechecks the Convex functions
and skips deployment.
