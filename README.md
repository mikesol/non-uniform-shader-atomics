# non-uniform atomics

This is a test repo to explore [Issue 1808](https://bugs.chromium.org/p/tint/issues/detail?id=1808) on the tint issue tracker.

It consists of two branches:
- `if-then-branching`
- `select-statements`

The project is a single-file project in [`./src/Main.purs](./src/Main.purs).

## Build and run

- `pnpm i`
- `pnpm spago build`
- `pnpm vite dev`

The port will show on the command line (usually it's 5173).

Note that, unless you have a PureScript language server running in your editor, you should rebuild the project via `pnpm spago build` whenever you switch branches.