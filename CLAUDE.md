# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

PrivateGPT is an API layer (FastAPI) that exposes a Claude/Anthropic-compatible API (`/v1/messages`, …) on top of *any* OpenAI-compatible inference server. It does **not** run models itself — it talks to `OPENAI_API_BASE`. It adds ingestion, retrieval with citations, built-in + custom tools, MCP, skills, database/tabular access, and embeddings. A static demo UI is served at `/ui`.

Python 3.11 only (`>=3.11,<3.12`), dependencies managed by `uv`.

## Commands

All day-to-day work goes through the `Makefile`:

```bash
make dev              # serve with --reload on 0.0.0.0:8080
make run              # private-gpt serve
make check            # format + lint + typecheck (what CI runs)
make fix              # ruff check --fix + ruff format
make test             # full suite (wipes local_data/tests first)
make test-changed     # only tests related to changed files
make test-coverage
make api-docs         # regenerate fern/openapi/openapi.json (PGPT_PROFILES=mock)
make wipe             # clear $PGPT_HOME/local_data
make ingest <path>    # scripts/ingest_folder.py
```

Typechecking uses Astral's `ty` (pinned in the `typecheck` extra), **not** mypy. Lint/format is `ruff` (config in `pyproject.toml`; docstring rules `D` are on, with most `D1xx` ignored).

### Running a subset of tests

`make test` passes `PYTEST_ARGS` through, and `tests/conftest.py` adds custom options:

```bash
make test PYTEST_ARGS="tests/server/chat/test_chat_routes.py::test_name"
make test PYTEST_ARGS="--block server"          # only tests under tests/server/
make test PYTEST_ARGS="--git-target origin/main" # only tests touching changed files
```

Direct invocation needs the same env the Makefile sets — `PGPT_HOME=$(pwd) PYTHONPATH=. uv run pytest …` — otherwise settings and `local_data` resolve to the user's home directory.

A dev container is defined in `.devcontainer/` — it builds the repo `Dockerfile`'s `os-deps` stage (system libs for the extras, no baked-in app code) and provisions the venv with `.devcontainer/post-create.sh`. VS Code debug configs for the server, the arq/celery workers and pytest live in `.vscode/launch.json` (untracked — `.vscode/` is gitignored).

Installing dev deps: `uv sync --inexact --extra dev` (the `quality-dependencies` target). CI additionally installs `--extra core` plus most provider extras (see `.github/workflows/actions/install_dependencies/action.yml`).

## Architecture

### Settings: layered YAML profiles

`private_gpt/settings/settings.py` is a single large Pydantic tree (`Settings`) — ~60 nested models covering server, chat, tools, vector store, workers, sandbox, etc. It is the main knob surface; read it before adding configuration.

Profiles are merged in order by `settings_loader.py`: `settings.yaml` → `settings.override.yaml` (if present) → each profile in `PGPT_PROFILES` → `test` (auto-activated whenever `tests.fixtures` is imported, loading `settings-test.yaml`). `PGPT_SETTINGS_FOLDER` (comma-separated) changes where profile files are looked up. YAML values support `${ENV_VAR:default}` interpolation.

Consequences: tests always run against `settings-test.yaml` (mock LLM/embedding, local Qdrant under `local_data/tests`, `celery.use_workers: false`); `make api-docs` uses the `mock` profile so the spec doesn't require a live model.

### Dependency injection

Everything is wired with `injector`. Components are `@singleton` classes with `@inject` constructors; `auto_bind=True` means most classes need no explicit binding.

`private_gpt/di.py` keeps **one injector per asyncio event loop** (attached to the loop object) with a global fallback — this matters because workers and the server create separate loops. `launcher.py`'s HTTP middleware attaches the injector to `request.state`, resets the request-scoped context bag (`private_gpt/context`), and builds the `Principal` from allow-listed forwarded headers/cookies.

In tests, use the `injector` fixture (`tests/fixtures/mock_injector.py`): `injector.bind_mock(Interface)` and `injector.bind_settings({...})` to override settings before app creation. `test_client` / `async_test_client` build the app from that injector.

### Layering

```
private_gpt/server/<domain>/   HTTP: *_router.py (FastAPI), *_service.py, *_facade.py, *_models.py
private_gpt/components/<area>/ swappable infrastructure, selected by settings
private_gpt/chat, events/      request/response models and the event stream protocol
```

Routers stay thin: validate, map (`chat_request_mapper.py`), delegate to a service/facade, and stream `Event` objects. `components/` is where provider choice lives — most areas have a `factory.py`/`factories/` + `registry.py` pair that resolves an implementation from settings (`llm`, `embedding`, `vector_store`, `readers`, `database`, `tools`, `sandbox`, …). Add a provider by registering it in that area's factory/registry, not by branching in callers.

`eager_loading.py` warms component groups per *profile* (base/stores/streaming/tools/chat) so a given process only loads what its role needs; add a new worker role by adding a profile entry there.

### Workers and schedulers

Work can run in-process or be dispatched. `scheduler.{ingestion,chat,tools}.mode` selects `local` | `arq` | `celery` per subsystem; `local` keeps everything in the API process (what tests use).

Workers are launched through `scripts/worker_entrypoint` with `PGPT_WORKER_MODE` (`celery` | `arq` | `flower`) resolved by `private_gpt/worker/registry.py`, plus `PGPT_*` env vars for queues, task packages and warm profile. The Makefile has the canonical invocations: `make celery-worker`, `make arq-worker`, `make chat-worker`, `make tools-worker`, `make flower`. Task implementations live under `private_gpt/celery/tasks/` and `private_gpt/arq/tasks/`.

### Optional dependencies

Heavy dependencies are optional extras (`core`, `ingest*`, `database*`, `queue*`, `media*`, `tools`, `observability`, …). Code must tolerate their absence: imports of optional libraries are done lazily inside functions or guarded with `except ImportError` (~56 sites, e.g. `private_gpt/cli/main.py` hiding the `worker` command when Celery is missing). Follow that pattern rather than adding a top-level import of an extra-only package.

### Data on disk

`PGPT_HOME` (default `~/.local/share/private-gpt`) roots `local_data`, models and caches via `private_gpt/paths.py`. Tests set `PGPT_HOME` to the repo root.

## Docs, spec and the UI

- `fern/openapi/openapi.json` is generated — never hand-edit it; run `make api-docs`. Prose docs live in `fern/docs/pages`, previewed with `make docs`.
- `ui/` is a deliberately single-file static app (`ui/index.html`) with its own `ui/CLAUDE.md`, `ui/docs/SOURCE_OF_TRUTH.md`, `PRD.md` and `STYLE_GUIDE.md`. Read those before touching the UI, keep `index.html` the only runtime file, and update the matching doc in the same change.
- `launcher.py` rewrites the UI's `DEFAULT_BASE_URL` constant at startup by string replacement — don't reformat that line in `index.html`.

## Conventions

- Commits follow Conventional Commits; releases are cut by release-please, which owns `version.txt` and `project.version` in `pyproject.toml`. Don't bump versions or edit `CHANGELOG.md` by hand.
- When behavior changes, the settings tree, the generated OpenAPI spec and the fern docs are the three things that usually need updating alongside the code.
