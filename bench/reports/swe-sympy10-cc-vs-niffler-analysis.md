# SymPy10 failure analysis: Claude Code vs Niffler

Run: `swe-sympy10-cc-vs-niffler`, Synthetic `syn:large:text` (GLM-5.3-Flash).

## Scope and evidence

Claude Code resolved 8/10; Niffler resolved 6/10. Claude Code alone resolved 11618, 12419, and 12481. Niffler alone resolved 12489. Both failed 13091.

This analysis compares saved production patches, transcripts, task issue text, reference patches, hidden test patches, and official evaluator reports. Evaluator runs were matched to harnesses by prediction-patch equality, not evaluator run names. Raw test logs sometimes include failures outside the report's selected tests; those are not automatically scoring failures.

Both agents received the same restrictive workflow: read/grep, minimal production edit, re-read, one-paragraph summary. Project tests, dependency installation, network access, and reading outside the checkout were forbidden. This was a one-shot, no-project-tests experiment, not a comparison of unrestricted development workflows. Niffler attempted standalone Python reproductions on some tasks, but these were blocked by missing `python` or `mpmath`; syntax compilation worked in some cases. The evidence does not justify calling these failures simply “giving up early.”

## 11618 — Mixed-dimensional point distance

**Niffler:** changed `Point.distance` to convert non-Point inputs with `Point(p)`, but still zipped the unpadded coordinate sequences. The issue's arguments are already Points, so this patch does not change that execution path. Python's `zip` still drops the third coordinate. The final answer nevertheless claimed `Point(2,0).distance(Point(1,0,2))` now returns `sqrt(5)`.

**Claude Code:** explicitly padded the shorter coordinate list with zeros before computing the distance, handling both operand orders.

**Grading:** Niffler failed `test_issue_11617`, retaining all four selected preservation tests. Claude Code passed all five. The hidden regression reverses the operand order relative to the issue.

**Lesson:** demand a concrete before/after trace through the actual issue inputs. A conversion is not a dimension-normalization fix. A claimed re-read is insufficient: Niffler's final read began at the continuation line of the return expression, missing the newly inserted conversion and the start of the expression.

## 12419 — Summing identity-matrix entries

**Niffler:** correctly recognized that structural `i == j` must not turn unknown symbolic equality into zero. It returned `Piecewise((1, Eq(i,j)), (0, True))`. This is a plausible mathematical representation, but not equivalent operationally in this version of SymPy's summation machinery.

**Claude Code:** returned `KroneckerDelta(i,j)` for the symbolic case. It also added a broader special case to `Sum.doit` for two-limit delta sums.

**Grading:** Niffler failed the nested-sum assertion in `test_Identity`; the preceding flat-sum assertion succeeded. All 25 selected preservation tests passed. Claude Code passed all selected tests.

**Post-hoc isolation:** in disposable copies of the official task Docker image, with the hidden patch applied, I directly invoked all 26 selected test functions:

- Original Niffler patch: flat sum at `n=3` returned 3; nested sum retained Piecewise expressions containing the supposedly bound `i`, and failed `test_Identity`.
- Claude Code's `matexpr.py` patch alone, omitting its entire `summations.py` change: all 26 functions passed; both sums returned 3.

These were diagnostic function-level checks, not new official benchmark scores. They establish that Claude Code's broad summation edit was unnecessary for the selected tests. The reference production fix likewise uses KroneckerDelta without changing summation machinery. They do not establish that every symbolic variant in the issue works without the broader change.

**Lesson:** follow the representation into its consumers; prefer the library's canonical symbolic object. Do not copy all of a winning patch merely because it passed.

## 12481 — Overlapping permutation cycles

**Niffler:** correctly decided that duplicate rejection should apply to array input, not separate overlapping cycles. However, its replacement deleted `temp = flatten(args)` and left both `has_dups(temp)` and `set(temp)`. The final re-read visibly contained the undefined variable, but no correction followed. The docstring change also misleadingly broadens the duplicate allowance beyond cycle input.

**Claude Code:** retained the initialization and narrowed only the duplicate-validation branch. Existing Cycle composition did the rest.

**Grading:** Niffler's patch caused `UnboundLocalError` during import through polyhedron construction. The official report marks the target test and all seven preservation tests failed; this is an import failure, not eight separate algorithmic errors. Claude Code passed all eight.

**Post-hoc isolation:** restored only `temp = flatten(args)` to Niffler's patch in a disposable official task image, applied hidden tests, and directly invoked all eight selected functions. All passed. Original benchmark artifacts and scores were not changed.

**Lesson:** this was edit-integrity failure, not missing mathematical insight. Review deleted definitions and surviving uses, not only the intended condition change. An undefined-name check or viable import smoke check would target this failure more directly than a larger reasoning budget. Syntax compilation alone would not catch it.

## 13091 — Unknown-type rich comparisons (both failed)

**Niffler:** changed `Basic.__eq__` to return NotImplemented on sympification failure and correctly propagated that sentinel through `Basic.__ne__`. It did not update numeric overrides. Its transcript explicitly narrowed the scope to Basic even though the issue asked whether other sites needed edits.

**Claude Code:** updated Basic and equality implementations in Float, Rational, and NumberSymbol, but left inequality methods as `not self.__eq__(other)`. That boolean-negates NotImplemented instead of preserving Python's comparison fallback.

**Grading:** Niffler passed the new Basic `test_equality` but failed `test_comparisons_with_unknown_type` at `assert n == bar`; all selected preservation tests passed. Claude Code failed both target tests and regressed `test_dont_accept_str`. Its numeric unknown-type failure occurs at `n != foo`; raw logs show NotImplemented-in-boolean-context warnings treated as exceptions. Both patches also fail the new NumberSymbol ordering check in raw logs, but that test is not in this instance's selected scoring lists.

**Lesson:** changing a protocol's possible return values requires auditing both overrides and consumers. Search for equality overrides and direct `__eq__` calls; check `==` and `!=` in both operand orders with both an unaware object and a cooperating custom object. Neither “edit just the named line” nor “replace matching False returns everywhere” is sufficient.

## Reverse case: 12489 — Permutation subclassing

Claude Code repaired constructor dispatch and the `_af_new` factory, but left operation paths using the global base-class factory. The hidden test failed specifically at `type(p * q) == CustomPermutation`.

Niffler followed `_af_new` call sites into multiplication, powers, inversion, and several class factories, preserving subclass dispatch. It even caught and repaired an intermediate mistake that introduced `self` into a staticmethod during its review. All selected tests passed.

This is a useful counterexample: broader call-site investigation helped Niffler here, and its review loop sometimes caught real errors. It is not evidence of complete subclass correctness: Niffler's patch still differs from the reference fix in other factory and dispatch paths.

## Practical priorities

1. **Replace generic re-read guidance with an explicit review rubric:** trace the issue inputs, inspect every changed hunk with surrounding context, check removed definitions, and audit sibling overrides/callers where a contract changes.
2. **Make conclusions evidence-qualified:** distinguish reasoned expectations, successful execution, and blocked execution. “Re-read” and “compiles” do not establish behavioral correctness.
3. **Offer useful verification in a separate benchmark track:** provision dependencies and permit focused reproductions/static checks/public tests for both harnesses. Keep hidden tests evaluator-only. Do not silently change the current no-project-tests protocol or feed post-hoc hidden assertions back into the agents.
4. **Evaluate harness changes through controlled ablations:** same model, protocol, tasks, and repeated runs; vary the review prompt, edit feedback, or verification access separately. Compare failure categories as well as pass rates.

The strongest conclusions are patch-local: one ineffective repair, one incompatible symbolic representation, one deleted initialization, and one incomplete protocol audit. This single ten-task run does not identify a universal context-loop weakness, prove that more turns cause success, or isolate harness effects from sampling and API/thinking differences.

## Artifact locations

- Raw results: `var/bench/results/swe-sympy10-cc-vs-niffler/`
- Task metadata/reference and hidden patches: `var/bench/swe/tasks-sympy.jsonl`
- Official grading logs: `var/bench/swe/evaluations/`
- Readable extracted traces, matched grading reports, diagnostic script and outputs (temporary local artifacts): `/tmp/niffler-sym10-analysis/`

Diagnostic script: `/tmp/niffler-sym10-analysis/check_counterfactuals.py`. Containers used `--rm`, disabled networking, and a read-only mount of diagnostic inputs. No original checkout, submitted patch, or benchmark score was modified.
