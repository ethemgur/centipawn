# Design Critique: Centipawn — Game Review Screen

**Context:** Mobile chess review for semi-pro players. Game-review screen with engine evaluation, suggested lines, eval bar, eval chart, and move list with quality annotations.

## Overall Impression

The board is the clear hero of the screen, which is correct. The trouble is everything that frames it. The top of the viewport stacks three competing analytical zones (engine lines, accuracy chip, the board) and the bottom stacks four more (player chip, eval chart, action toolbar, move list, navigation), with no visual breathing room between them. For a semi-pro audience this density is *probably* what they want — but right now it reads as "many small things" instead of "one structured workspace," and the most valuable navigation primitive (the eval graph) is the most underweighted.

## First Impression (2 seconds)

The eye lands on the chess board — appropriate. Second look: the three engine variation pills at the top, because they have the highest information density and the strongest visual contrast (white pill on near-white background, bold eval chip). Third: the green accuracy chips on the player rows. The eval chart, the most actionable navigation tool on this screen, is essentially invisible — a thin grey strip that I had to look for.

The first big question a reviewer asks — *"where did this game go wrong?"* — is answered slowest. That ordering is backwards.

## Usability

| Finding | Severity | Recommendation |
|---|---|---|
| Three engine lines truncate with `...` and show no expand affordance. Semi-pro users will want to read the full line to compare ideas, not just the first 6 plies. | 🔴 Critical | Either expand the active line to two rows of SAN and collapse the alternatives behind a tap, or make the entire pill horizontally scrollable with a clear visual cue (fade edge). Tapping a line should play it through on the board. |
| Board shows the starting position but the move list is scrolled to moves 18–20. There is no visual link between the current board state and "where am I in the move list." | 🔴 Critical | Highlight the active move in the notation pane with a filled background, and either auto-scroll the move list to the active move or render the move list independently with an "active move" pill that's always pinned. |
| The four-icon action toolbar (refresh, CPU, target, pencil) has no labels and no obvious active state for "engine on/off." | 🟡 Moderate | Add a 1-line caption under each icon, or at minimum make the engine-toggle state explicit (filled vs outlined, color shift, or "ON" pill). Touch targets look ~40px — borderline for thumb taps. |
| Bottom `Back / Next` shows no position context. A semi-pro reviewing 40+ moves wants to know "move 18 of 43" and jump straight to the next blunder. | 🟡 Moderate | Add a move counter between the arrows. Add a "next mistake" button — this is table-stakes for the audience (chess.com and lichess both have it). |
| The eval chart's red and orange dots have no legend. Are red dots blunders, critical moments, opponent moves? | 🟡 Moderate | Either color-code by move quality (matching the `??`/`?!` palette in the move list) and document it once in a help layer, or label on tap. |
| Variations in the move list (the lines `19...`, `20.`, `20...`) are styled identically to mainline moves. A reviewer can't tell at a glance which is the played game and which is a sideline. | 🟡 Moderate | Indent variations, drop the font weight, and tint the background. Consider a left border accent in a subdued color. |
| The `0.5` text below the bottom-left of the board appears to be the current eval, but it floats — disconnected from the eval bar visually. | 🟢 Minor | Anchor the number inside the eval bar (top or bottom pill), or use a single chip adjacent to the bar that clearly belongs to it. |

## Visual Hierarchy

- **What draws the eye first**: the board, then the engine-line pills. The pills are slightly over-weighted for what is essentially "alternative considerations" — they should be subordinate to the board and the eval chart, not competing.
- **Reading flow**: top header → engine lines → opponent chip → board → player chip → eval chart → toolbar → moves → nav. That's eight horizontal bands stacked vertically. The eye has nowhere to rest, and the most important band (eval chart) is the smallest.
- **Emphasis**: the things emphasized most strongly are accuracy badges (`75%`, `82%`) and the engine-line eval chips (`+0.5`, `+0.3`). These are *summary metrics*, not actions. The actions (navigate, toggle engine, jump to mistake) are emphasized least.

**Specific fix:** trade vertical space — collapse the engine-line stack from three rows to one expanded primary line plus a "+2 alternatives" disclosure, and reclaim the saved ~60px for the eval chart. The chart should be roughly 1.5–2× its current height with clear hover/tap-to-jump behavior. That single change inverts the hierarchy in the right direction.

## Consistency

| Element | Issue | Recommendation |
|---|---|---|
| Pills/chips | The eval pill (`+0.5`) at the top has a white background with light border; the accuracy chip (`75%`) has a green tint. Both are evaluative summary chips but treated as different primitives. | Pick one pill family. Use color tint to *encode quality* (green = good, amber = neutral, red = poor) and apply it consistently. The `82%` and `75%` accuracy chips are both green even though they're different quality bands — undermines the system. |
| Move-quality colors | `??` red and `?!` orange in the move list are correct and well-applied. But the same blunder coloring doesn't appear (clearly) on the eval chart dots, even though both encode the same concept. | Unify the palette: `??` red dots, `?` orange, `?!` yellow, `!` green. Use the same scale in the eval chart, the move list badges, and the player accuracy chips. |
| Coordinate labels on the board | `a–h` and `1–8` overlap visually with the eval bar's edge. Hard to read either cleanly. | Give the eval bar its own column with a small gap before the coordinate strip, or move coordinates to the squares themselves. |
| Iconography | The four toolbar icons appear to mix weights (the CPU icon looks heavier than the others). Hard to tell at this scale. | Audit the icon set for stroke width consistency at 24×24. |

## Accessibility

- **Color contrast**: the engine-line pills' eval text (`+0.5`) on white is fine. The grey caption beneath the variation moves (`...`) likely fails AA at this size. Move annotations relying on color alone (`??` red) are also paired with the glyph, which is good — keep that pairing everywhere.
- **Touch targets**: the four toolbar icons look ~40pt and close-set. Bump to 44pt minimum with 8pt spacing. The eval-chart dots, if tappable, are below the 24pt minimum and need an invisible tap-target padding.
- **Text readability**: the engine-line variations are dense Unicode piece glyphs followed by SAN. Screen readers will read these poorly. Provide an aria-label (e.g., "Knight to f3") or a text-only fallback.
- **Player accuracy chips** read as just "75%" — no label. A screen-reader user gets "75 percent" with no anchor. Add "Accuracy: 75%" or label the chip explicitly.

## What Works Well

- The board takes the visual weight it deserves. Square sizing and contrast are good.
- The on-board move-suggestion arrows are excellent: the opacity gradient (darker = stronger) communicates ranking visually without needing legend text. This is the screen's best idea.
- Move-quality annotations (`??`, `?!`) in the notation pane are clearly colored and immediately scannable — that's exactly right for a review use case.
- Framing the board between the two player rows (opponent above, you below) is the right convention and orients the user instantly.
- Calm, restrained palette overall. The board isn't competing with chrome.

## Priority Recommendations

1. **Promote the eval chart to a real navigation surface.** Roughly double its height, color-code the dots to match move quality, add a vertical "current move" indicator, and make any dot tap jump to that move. This is the single highest-leverage change for a semi-pro game-review experience — it's the first thing your audience uses to find mistakes, and right now it's a decoration.

2. **Collapse the engine-line stack and make it interactive.** Show one expanded "best line" with the full SAN of 6–10 plies, and put the two alternatives behind a "+2 alternatives" disclosure or a swipeable carousel. Tapping a line should play it on the board with a clear "you're viewing an engine line, tap to exit" state.

3. **Add an active-move indicator and a "next mistake" jump.** Highlight the current move in the notation pane, show "Move X of Y" between the Back/Next arrows, and add a dedicated "next inaccuracy" button. Semi-pro reviewers will use this constantly.

4. **Visually distinguish variations from mainline in the move list.** Indent, tint, and lighten variation lines so the played game reads first. Right now `19... Qb1+ 20. Rxb1` looks like part of the game played, not a sideline.

5. **Label the action toolbar and clarify engine-on state.** Even a single-word caption per icon ("Flip", "Engine", "Center", "Edit") fixes the discoverability problem. The engine toggle in particular needs an unambiguous on/off treatment — for an analysis app, this is the most consequential control on the screen.

6. **Unify the pill/chip family.** Pick one chip primitive, use color to encode quality consistently, and make `75%` and `82%` accuracy chips show different tints because they represent different performance bands.

## Open Questions Worth Considering

- When the user opens a reviewed game, should the board start at move 1 or jump to the first critical moment? (Lichess opens at move 1; chess.com offers "review" mode that walks the user through mistakes.) The current screen seems to default to move 1 with the move list scrolled to the end — pick a consistent stance.
- Should the engine lines update as the user navigates, or only at the active position? Make this loud — if engine analysis is live, that needs a "thinking…" indicator; if it's cached from the original review, the source should be visible (depth, date).
- For the semi-pro audience: do you need a "compare to my move" panel that explicitly shows "you played X, engine preferred Y, eval delta Z"? That's the heart of game review and isn't surfaced cleanly here — it's implied through the eval pills but never named.
