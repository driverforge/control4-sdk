# Contributing

Thanks for your interest in the Anvil Control4 SDK! Contributions are welcome under the project's [MIT license](LICENSE).

## How this repository works

This repository is a **public mirror**. The SDK is developed in a private monorepo alongside other closed-source Driverforge code and synced here automatically with [Copybara](https://github.com/google/copybara). Your workflow is the normal GitHub one — open issues and pull requests here as usual.

## Why your merged PR shows as "closed", not "merged"

When we accept your change it will show as **closed** (red), not **merged** (purple). That's expected, not a rejection: we import your PR into our private monorepo, review and test it there, and merge it internally. The change is then synced back out to this repo, and GitHub closes the original PR.

**Your authorship is preserved** — your commits appear here with you as the author, so they still show on your GitHub profile.

**How to tell an accepted PR from a declined one:** when your change lands, our bot labels the PR **`accepted`** and comments with a link to the commit where it landed in this repo. A closed PR *without* that label was declined — and we'll say why.

## Contributor License Agreement

Contributions require agreeing to our Contributor License Agreement: you keep the copyright to your contribution and grant Driverforge — and its successors and assigns — a licence to use and relicense it. A CLA check runs on your pull request.

**AI assistance is welcome.** However your contribution was produced, you're responsible for it: it must be yours to give, and you must have the right to contribute it under this licence (for example, it must not carry in incompatibly-licensed code). We don't require AI use to be disclosed or attributed — your responsibility for the contribution is the same either way.

## Commit, issue & PR conventions

### Commits

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>: <subject> (#<issue-or-pr>)
```

e.g. `feat: capture errors from C4:SetTimer callbacks (#42)`.

- **Types:** `feat`, `fix`, `docs`, `refactor`, `tweak` (a small change below a feature), `chore` (deps / no-op).
- Use the **imperative mood** — "add", not "added".
- Reference the related GitHub issue/PR number in parentheses; it can be left out until the PR is opened.
- Keep commits small and logical, with messages that say what changed and why.

### Issues

For anything beyond a trivial fix, please open an issue first describing the bug or feature and its use case — it's the best place to agree on the design before code is written. For bugs, include the Control4 context and steps to reproduce where you can.

### Pull requests

- Title the PR in the same format as a commit (e.g. `fix: handle a nil logger in Driverforge:Init`).
- Keep it small and focused; for larger changes, open an issue first.
- Include tests for fixes and new behaviour.

### Code style

- **Naming:** PascalCase for the public, driver-facing surface (the `Driverforge` and `Anvil` APIs and the C4 handler globals — matching the Control4 DriverWorks idiom); camelCase for everything internal, including all methods on the internal client module.
- `if condition then`, not `if(condition) then`.
- Collect varargs with `select('#', ...)`, never `#{...}` — an embedded nil must not truncate the list.
- Library code must not `print` on non-error paths; error-path prints are deliberate (they surface in the Composer Lua output).
- `stacktrace.lua` is a vendored copy of a shared module — its canonical source lives in the private monorepo, so PRs editing it directly will be re-rooted during import; flag it in the PR description and expect the maintainer to handle placement.

The test suite uses [busted](https://lunarmodules.github.io/busted/):

```sh
busted spec/
```

Because this repo is a public mirror, **we don't merge PRs on GitHub directly** — a maintainer imports your change into our private monorepo and it syncs back here (your PR then shows as *closed*, with your authorship preserved — see above). So there's no squash-vs-merge choice for you to make and no release branches to target: just open your PR against the default branch.
