# Legacy 8M / display_errors=On line (archived)

This directory keeps the earlier one-shot exploit (`exploit.py`) and its
mechanism notes. That target used a **custom** `docker/php.ini`
(`display_errors=On`, `memory_limit=8M`, `max_input_vars=1000`), not the
stock official `php.ini-production`.

The current target of this repository is the official
`php:8.4.26-apache` image with the untouched official `php.ini-production`
(`display_errors=Off`, `display_errors`/`display_startup_errors` off,
`memory_limit=128M`) and a single prefork worker. See the root
[README.md](../../README.md) and [pure/RESEARCH_PURE_128M.md](../../pure/RESEARCH_PURE_128M.md).

The legacy setup files (`docker/php.ini`, `docker/docker-compose.yml`,
`docker/offsets.py`) remain under `docker/` so the archived exploit can
still be run. Paths inside these notes may refer to the old root layout;
`tools/`, `logs/`, and `lab/` remain at the repository root.
