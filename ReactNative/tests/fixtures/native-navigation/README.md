# Native navigation patch fixture

`RNSScreenStackAnimator-4.27.0.mm` is the unmodified MIT-licensed
react-native-screens 4.27.0 source captured before the cancelled-pop experiment.
Its accompanying upstream license is retained in `LICENSE`.

Pristine SHA-256: `bd991a1f32dad21f89172cced78edf8f76b16d95c6e75127e7931cbe89dd5cea`.
Legacy patched SHA-256: `f54d7371f28f8dc2a726744fae78369647e1b07f4ad1bb3bdb6b3e2eb45d1513`.
These match the frozen before/after receipt used for the simulator experiment.

The tests qualify exact restoration of the legacy patch to upstream, idempotence, and rejection of unknown inputs. Ordinary iOS navigation uses the native default animator, including native header transitions.
Actual gesture motion, accessibility and state retention require the native UI lane.
