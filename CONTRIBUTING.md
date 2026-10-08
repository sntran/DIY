# Contributing to Small Steps Home

## Build and test

Use [`beam.com`](https://github.com/sntran/BEAM.com) 0.1.0-rc.5 for all
the work: it is Erlang/OTP 29.1.1 and Elixir 1.20.4 in one file. Make the
tools `mix.com` and `iex.com` from it:

```sh
mkdir -p ~/bin && cd ~/bin
curl -fLO https://github.com/sntran/BEAM.com/releases/download/v0.1.0-rc.5/beam.com
echo "ac36bab20b0cf8a6bcd9b9e02bae1e9d356855a75f4664ac65c58ff6fed8c024  beam.com" | sha256sum -c -
chmod +x beam.com
ln -s beam.com mix.com
ln -s beam.com iex.com
export PATH=~/bin:$PATH LANG=C.UTF-8
mix.com local.hex --force
mix.com local.rebar --force
```

Then, in the directory of the project:

```sh
mix.com setup                   # the deps and the assets
npm ci                          # Node.js 26: the packages of package-lock.json
mix.com test --cover            # the coverage must be 100%
npm test                        # the JavaScript of the page, 100% coverage
mix.com precommit               # before each commit (also npm test)
scripts/tlc.sh                  # the TLA+ models of specs/, with TLC
iex.com -S mix phx.server       # http://localhost:4000
```

The tests of LiveView use the NIF of `lazy_html` 0.1.13 in WebAssembly,
which `beam.com` has. A `_build` from a different Elixir installation has
that NIF as a native library, which `beam.com` cannot load: delete
`_build` before the first `mix.com test`.

`scripts/tlc.sh` needs Java 11 or later and `tla2tools.jar` v1.7.4
(SHA-256 `936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`)
in `~/.tla/`, or in the variable `TLA2TOOLS_JAR`:

```sh
mkdir -p ~/.tla
curl -fsSL -o ~/.tla/tla2tools.jar \
  https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar
```

The build for Cloudflare Workers (`npm run build`) needs Node.js 26
(`.node-version`) and npm. Test the build on this computer with
`npx wrangler dev`.

GitHub Actions runs the same checks for each push and each pull request
(`.github/workflows/ci.yml`). A run fails also when `mix.com precommit`
changes a file: format the code before the commit.

## Rules for a change

- Each change has tests of its behavior, also for errors and limits, not
  only for the normal case. Write property tests (StreamData in Elixir,
  fast-check in JavaScript) where you can.
- The coverage of the tests is 100%: each line runs in a test. Do not
  keep code that no feature uses.
- Write a property of processes that run at the same time as a TLA+ model
  in `specs/`. Give the model a second configuration with the fault, and
  the line `\* TLC must find: TEXT`: it shows that the property can fail.
- Each number that the app shows tells where it comes from (honesty rule
  1 of the plan). Put the source of each constant next to it.
- Keep each change small, and give it one purpose.
- Make a branch from `main` for each change, with the type of the change
  as a prefix: `feat/`, `fix/`, `docs/`, `test/`, `refactor/`. Each push
  to `main` can go to production.
- Write the commit message in the format of
  [Conventional Commits](https://www.conventionalcommits.org/), in
  Simplified Technical English: `feat(house): add the rooms`.
- Update the docs of the behavior that you change.

## The language of the docs

The docs, the code comments, the text of the pages, the log text and the
commit messages use
[ASD-STE100 Simplified Technical English](https://www.asd-ste100.org/):

- Write short sentences: 20 words or fewer for an instruction, 25 words
  or fewer for a description.
- Use the active voice and the present tense.
- Use one word for one meaning, and the same word in all the files.
- Give one instruction in each sentence, and start it with the verb.
- Do not use the "-ing" form of a verb, except in a technical name.
