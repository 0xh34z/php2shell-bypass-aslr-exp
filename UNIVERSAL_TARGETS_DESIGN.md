# Design: portable chain — offset database + recon pass

Status: design sketch (follow-up project, after the FPM proof lands).
Goal: one command against any *stock Linux PHP 8.x* host, instead of one
calibrated host per build.  Companion to `pure/RESEARCH_PURE_128M.md`, which
documents the calibrated single-build chain this generalizes.

## 0. Why a single zero-touch exploit can't exist

The primitives are PHP-source-level and portable (rfc1867 OOM bailout leaving
`PS(id)`/`PS(mod_data)`/`PS(send_cookie)` dangling; chunked `post_max_size`
bypass; stale-id OOB read; fake `zend_array` with `pDestructor=zif_system`).
Everything *concrete* is not:

| Axis | What breaks | Port evidence |
|---|---|---|
| Build offsets | `zval_ptr_dtor`/`zif_system` RVAs | mod_php `0x65EB60`/`0x465370` vs FPM `0x418db0`/`0x240390` |
| Heap shape | `S`, bucket fingerprint, A1 filler counts, slot table | calibrated to 128M + one build's startup heap |
| Worker model | same-process cross-request state | prefork pinning vs FPM pool vs threaded MPM (fails) |
| Front-end | body/header size limits | nginx `client_max_body_size`/`fastcgi_buffer_size` (413/502) |
| Hardening | chain death | `disable_functions`, `upload_progress.enabled=Off`, `use_strict_mode=1`, Suhosin |

So the design goal is not "universal exploit" but: **portable engine +
per-build data, with the target itself as the calibration oracle**.

## 1. Architecture — three layers

```
tools/recon.py        pure HTTP  ->  target profile JSON (is it in scope?)
db/builds/*.json      offline    ->  per-build constants (calibrated once)
exploit.py            engine     ->  profile + DB entry -> chain -> proof
tools/calibrate_build.py  offline ->  generates DB entries (gdb, replica)
```

### Layer 1: recon (pure HTTP, no exploitation, no crash risk)

Probe set — most already exist as probe scripts from the FPM port:

1. **Front-end**: `Server` header; oversized-body threshold (binary search the
   413 cutoff -> effective `client_max_body_size`); chunked multipart accepted?
   (the p2s chunked probe); response to a ~100KB `Set-Cookie` oracle page if a
   reflector exists (else infer from server-version defaults).
2. **PHP fingerprint**: `X-Powered-By` when `expose_php=On`; else behavioral:
   session cookie attributes/format, 413-vs-silent-drop posture, error-page
   shape.  Target: (SAPI, version, distro) triple -> DB candidate list.
3. **Session machinery engaged?** staged multipart (PHPSESSID + progress field
   + file part) and observe app-visible side effects; A1-shaped request
   returning 500 = machinery confirmed end-to-end.  This is the "will the
   primitives even fire" gate.
4. **`memory_limit`**: binary search with cheap-oom shaped POSTs; 500 vs 200
   is the oracle.  ~10-15 requests covers 16M..1G.  Turns A1's hardcoded
   filler arithmetic into a parameter.
5. **Worker model**: hold K partial-POST connections, measure whether a normal
   request still completes promptly:
   - stalls -> holders consume PHP workers (prefork/FPM without body
     buffering) -> classic pinning works; K+1 = worker count;
   - responsive -> front-end buffers bodies (nginx default) -> pinning must
     use `fastcgi_request_buffering off` or probabilistic retries;
   - threaded MPM detected (Server/behavior) -> **refuse** (chain premise
     breaks: shared heap across concurrent requests).
6. **Refusal gates** (fail clean, don't crash the box): no file session
   handler observable, upload_progress clearly off, `disable_functions`
   suspected (B2 callback simply won't fire — report as "exploit failed",
   never as "clean").

Recon output: `profile.json`.  Time budget: seconds, all non-destructive.

### Layer 2: build-offset database (`db/builds/<sapi>-<ver>-<distro>.json`)

Entry contents (exactly what `exploit.py` consumes today):

```json
{
  "id": "php8.4-fpm-8.4.26-debian13-amd64",
  "buildid": "a44ef7b7837af746dc8328f2a795d393ddc86f01",
  "rvas": {"zval_ptr_dtor": "0x418db0", "zif_system": "0x240390"},
  "heap": {"s_offset": "0xF8398", "main_bucket_count": 87,
           "leak_spec": "...", "a1_shape": {"big": 78, "...": "..."},
           "query_slot_table": {"0": 4, "1": 6, "2": 8, "3": 10, "5": 14}},
  "ini_assumed": {"memory_limit": "128M", "post_max_size": "8M"},
  "notes": "calibrated via replica, evidence: <log path>"
}
```

Population: **the WSL replica calibration we are running now, scripted**.
`tools/calibrate_build.py <php-fpm deb | BuildID>`: extract exact .deb ->
run replica (pool pm=static 1) -> gdb-calibrate A1/B1/S/fingerprint ->
emit JSON.  A new build costs one scripted ~10-minute run, no manual gdb.
RVAs additionally auto-fill from debuginfod by BuildID (the workflow used
during the FPM port).

### Layer 3: engine (evolves `exploit.py`)

- Reads `profile.json`, picks DB entries by (SAPI, version, distro); if the
  fingerprint is ambiguous, tries candidates in order — each verification is
  cheap (~3-5s A1+B1) and the **leak itself is the ground-truth oracle**:
  `(zdtor - RVA)` must be page-aligned and consistent across ~1000 pointer
  occurrences.  Wrong build -> alignment check fails -> next candidate.
- `memory_limit` from recon parameterizes the A1 filler arithmetic instead of
  fixed 128M shapes.
- Proof: out-of-band HTTP callback (works on arbitrary hosts; the SSH
  file-drop variant stays for lab use).

## 2. The honest hard parts

1. **S stays per-build.**  Stage 3 needs the exact landing offset of B2's ht
   value inside the main chunk; it is not visible in B1's leak window and not
   derivable from `memory_limit`.  Brute-forcing it over HTTP is a multi-MB
   alignment space.  Resolution: DB-provided per build (generated by the
   calibration script).  This is the main reason "universal zero-touch"
   stays out of reach.
2. **Chicken-and-egg on A1 shape.**  A1 must fire to produce the leak that
   verifies everything.  Mitigation: A1's shape is *mostly* a function of
   `memory_limit` (arithmetic), plus a small discrete slot space swept via
   the query-string knob (each 8-char param shifts the md slot +2, RESEARCH
   §3).  Sweep until B1's leak succeeds = full remote self-calibration of
   that layer without gdb.
3. **No reflector page.**  Some ini probes (exact `post_max_size`) need an
   app-side oracle.  Design the probe hierarchy: app reflector -> status
   oracles -> exploit-outcome oracles; accept coarser answers when the host
   gives us nothing.
4. **Distro variance.**  Alpine/musl, custom prefixes, hardened builds
   (Suhosin), ZTS builds: separate DB entries or explicit refusal.  The
   refusal list is a feature, not a bug.

## 3. Rollout plan

| Phase | Deliverable | Depends on |
|---|---|---|
| 0 | FPM proof on the real box (this session) | calibration running now |
| 1 | `calibrate_build.py` (replica -> DB entry), seeded with mod_php-Docker + FPM-Debian13 entries | Phase 0 |
| 2 | `recon.py` (profile.json; reuses this session's probes) | — |
| 3 | engine reads profile+DB; candidate-verification loop | 1, 2 |
| 4 | validation matrix: stock php:8.4-apache (known good), Ubuntu php8.3-fpm, Debian12 php8.2-fpm, refusal cases (upload_progress off, threaded, `disable_functions`) | 3 |

## 4. Defensive notes (for the writeup)

- Root cause: PHP bug class — request-shutdown bailout during
  `php_session_rfc1867_callback` leaves session globals dangling in the
  worker; next request in the same worker inherits them.
- Reliable mitigations, in order of practicality: `disable_functions`
  covering `system`/`exec` family; `session.upload_progress.enabled=Off`
  where uploads aren't needed; Suhosin; avoiding thread MPMs is *not* a
  mitigation here (it just changes the failure mode).
- Detection signatures: chunked multipart with `PHPSESSID` + progress field +
  extreme nesting depth; OOM-bailout 500s followed by oversized
  `Set-Cookie` responses from the same client; FPM/Apache worker churn.
