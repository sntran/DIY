# Contributing to Small Steps Home

## Build and test

Use [`beam.com`](https://github.com/sntran/BEAM.com) 0.1.0-rc.6 for all
the work: it is Erlang/OTP 29.1.1 and Elixir 1.20.4 in one file. Make the
tools `mix.com` and `iex.com` from it:

```sh
mkdir -p ~/bin && cd ~/bin
curl -fLO https://github.com/sntran/BEAM.com/releases/download/v0.1.0-rc.6/beam.com
echo "ac841b72180467773d95d0eec1c7a757b67e003e576a6ba34d8debb40fe6b903  beam.com" | sha256sum -c -
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

The picture of a shared house uses a NIF of resvg in WebAssembly
(`priv/resvg.wasm`, in the repository). The build of the app does not
need Rust. After a change of `native/resvg` or of its fonts, build the
file again with `sh scripts/nif.sh` (it needs rustup). After a change of
the styles of the pictures in `app.css`, write `priv/picture/styles.json`
again: `MIX_ENV=test mix.com assets.build`, then `CHROMIUM=/path/to/chrome
node scripts/picture-styles.mjs`. The browser test fails when the file is
not the same as `app.css`.

The browser test builds a house in Chromium, with axe-core on each
screen. It signs in on a fake Home Assistant on this computer
(`test/browser/fake_ha.mjs`). It needs the assets of the tests and a
Chromium (`CHROMIUM`):

```sh
MIX_ENV=test mix.com assets.build
CHROMIUM=/path/to/chrome DIY_BROWSER=1 mix.com test --only browser
```

The test server serves `PATH.gz` for a file that has one: after `npm run
build`, run `mix.com phx.digest.clean --all`, else the test server gives
the old script.

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

GitHub Actions runs the same checks for each pull request
(`.github/workflows/ci.yml`). A run fails also when `mix.com precommit`
changes a file: format the code before the commit. The minutes of Actions
are few: run the checks on this computer first (the browser test and
`scripts/tlc.sh` too), and push the changes of a pull request together.
TLC runs only when a pull request changes the models or the code that
they check.

The last step of CI runs the browser test against `wrangler dev`, with
the real answers of NASA POWER and Power to Choose. When one of these
services is down, this step fails: the app cannot work then either.
Check the service, and run the job again when it is up.

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
- Each page works on a phone, with a keyboard and with a screen reader.
  The browser test runs axe-core on each screen.
- Keep each change small, and give it one purpose.
- Make a branch from `main` for each change, with the type of the change
  as a prefix: `feat/`, `fix/`, `docs/`, `test/`, `refactor/`. Each push
  to `main` can go to production.
- Write the commit message in the format of
  [Conventional Commits](https://www.conventionalcommits.org/), in
  Simplified Technical English: `feat(house): add the rooms`.
- Update the docs of the behavior that you change.

## The texts of the pages

The pages are in English, Spanish and Vietnamese (`DIY.Gettext`, and the
section "The languages" of `docs/design.md`). The English text is the
key. For a new text of a page:

1. Write it with `gettext/1` (or `ngettext/3`), in Simplified Technical
   English.
2. Run `mix.com gettext.extract --merge`.
3. Write its translation in `priv/gettext/es/LC_MESSAGES/default.po` and
   in `priv/gettext/vi/LC_MESSAGES/default.po`.

A test fails when a text has no translation, or when a translation does
not have the same keys (`%{name}`). `mix.com precommit` fails when the
keys do not follow the code.

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
