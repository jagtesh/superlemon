# Contributing to Superlemon

Superlemon is a passion project, and I am deeply invested in making it useful,
distinctive, and enjoyable. The most valuable contribution you can make is not
necessarily code: it is telling me what the project feels like to use.

Tell me what you like, what you do not like, what surprised or frustrated you,
and what would make Superlemon better for you. Specific stories and honest
reactions are especially helpful. Please share them in a
[GitHub issue](../../issues) so other users can add context and the discussion
can inform the project openly.

## Conversation before code

Pull requests are welcome, but they are appreciated much more when they are
solicited: an issue was opened first, the idea and approach were discussed, and
a maintainer explicitly invited a PR. This keeps contributors from spending
time on work that may not fit the project and makes the reasoning behind a
change as useful as its implementation.

For anything beyond a tiny, obvious correction:

1. Open a feedback, proposal, or bug issue.
2. Explain the experience or problem before prescribing an implementation.
3. Discuss the desired outcome and constraints.
4. Wait for a maintainer to mark the issue `status: ready for PR` before doing
   substantial implementation work.
5. Link the issue from the PR and keep the change focused on the agreed scope.

Unsolicited PRs may still be considered, but discussion-first contributions
will receive priority. Small documentation, spelling, and clearly mechanical
fixes do not need prior approval.

## An agentic open-source experiment

Development so far has been nearly 100% agentic. One goal of Superlemon is to
find out whether a serious project can become 100% agent-developed and still
succeed. Human taste, judgment, testing, and discussion remain essential to
that experiment: agents can produce code, but the community helps decide what
is worth building and whether the result actually feels good.

You are welcome to use an agent when contributing. Please remain responsible
for the result: review the change, test it, understand its impact, and be ready
to discuss the decisions it contains. In a PR, briefly disclose meaningful
agent use and include the exact validation you performed.

## Giving useful feedback

Use the issue form that best matches your contribution:

- **Experience feedback** — what you liked, disliked, or would change.
- **Proposal** — a new behavior or product direction worth discussing.
- **Bug report** — something reproducibly behaves incorrectly.

Screenshots, short recordings, concrete workflows, macOS and Neovim versions,
and examples of the outcome you expected are useful when relevant. Please do
not include secrets, private files, or sensitive configuration.

## Issue labels

Labels are intentionally namespaced so they remain unambiguous in searches:

- `kind: feedback`, `kind: proposal`, `kind: bug` — what the issue is.
- `status: needs discussion` — no implementation should begin yet.
- `status: ready for PR` — the direction is agreed and a PR is invited.
- `status: blocked` — progress depends on a decision or external change.
- `area: editor`, `area: native UI`, `area: Neovim`, `area: performance`,
  `area: docs` — the main surface affected.

Maintainers may adjust labels as the discussion develops. A `status: ready for
PR` label is the clearest signal that implementation help is currently wanted.

## Pull request expectations

A good PR links its issue, explains the user-visible outcome, stays within the
discussed scope, and lists the tests or manual checks performed. Run the
relevant project checks before submitting; the standard full suite is:

```sh
swift test
bash runtime/tests/run.sh
```

Thank you for spending time with Superlemon. Thoughtful criticism is a real
contribution, and it matters here.
