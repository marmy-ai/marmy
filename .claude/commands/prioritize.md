Evaluate a proposed feature and recommend where it would belong in TODO.md. Do NOT modify TODO.md — only output the analysis.

## Instructions

1. **Read TODO.md** to understand the current prioritized list.

2. **Read product_vision.md** to ground the evaluation in Marmy's design principles:
   - Glanceable over interactive
   - Don't recreate the laptop experience
   - Connection quality is UX
   - Sessions are cheap, mistakes are recoverable

3. **Score the proposed feature** on these dimensions (1-5 each):

   | Dimension | Question |
   |-----------|----------|
   | **User pain** | How much does the absence of this feature hurt the core use cases (check on agent, kick off task, manage sessions, recover from errors)? |
   | **Frequency** | How often would a typical user encounter or use this feature in a week? |
   | **Mobile-fit** | Is this something that genuinely belongs on a phone, or is it better done at a desk? |
   | **Effort** | How much work is this? (inverted: 5 = trivial, 1 = massive) |
   | **Dependency** | Does this unblock other high-value features? |

4. **Assign a priority tier** based on the total score:
   - **P0 (20-25)**: Core experience gap — must build soon
   - **P1 (15-19)**: High-value enhancement — build after P0s
   - **P2 (10-14)**: Quality of life — nice to have
   - **P3 (5-9)**: Polish — do when everything else is solid

5. **Output the recommendation** in this format:

   ```
   ## Feature: [name]

   Pain: X/5 — [one line why]
   Frequency: X/5 — [one line why]
   Mobile-fit: X/5 — [one line why]
   Effort: X/5 — [one line why]
   Dependency: X/5 — [one line why]

   Total: XX/25 → P[0-3]

   Recommended placement: After "[existing feature]" in the P[X] section
   Rationale: [2-3 sentences on why it belongs there]
   ```

## Rules

- Do NOT edit TODO.md. Only output the analysis and recommendation.
- Be honest about mobile-fit. If a feature is better at a desk, it's P3 at best regardless of other scores.
- Weight "user pain" and "frequency" most heavily — they determine whether anyone will notice the feature exists.
- A feature that unblocks multiple P0/P1 items gets a boost.
- When in doubt, rank lower. It's easier to promote a feature than to waste time building something nobody uses.

$ARGUMENTS
