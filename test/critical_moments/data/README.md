# Critical-moment regression fixtures

Frozen `AnalysedGame` JSON — the full Stage A + B output for a game, including
every PV and the per-depth best-move map.

Stage C is pure, so these give sub-second tests and weight sweeps over the whole
scoring pipeline with no engine in the loop. Capture them early; it makes tuning
iterative instead of painful.

## Capturing

`tool/capture_critical_fixture.dart` needs a real engine, so it must run on a
platform where the `stockfish` package works (desktop or mobile) — not on web,
and not from a plain `dart run`. Wire `captureFixture(...)` to a debug action or
an `integration_test` target and write the returned string here as
`<game-id>.json`.

Aim for five games spanning different characters: a quiet positional game, a
sharp tactical one, a game decided in an endgame, a game with a long forced
sequence, and one you lost to a single decision.

## Labelling

`labels.json` maps a fixture id to the plies that were genuinely decision
points, judged by you:

```json
{ "game-01": [24, 38, 57], "game-02": [12, 40] }
```

Ply indices are 0-based from the start of the game and match `PlyData.ply`, so
White's move 13 is ply 24.

## Validating

```
dart run tool/validate_critical_moments.dart \
    --fixtures test/critical_moments/data --labels labels.json --top 5
```

Target ≥70% precision. `--no-damps` shows the undamped ranking, which is how you
check the damps are not suppressing genuine content; `--sweep` varies one weight
at a time.
