# casefix：Windows 大小写不敏感导致的内核源码合并修复

## 背景

Windows / NTFS 文件名大小写不敏感，而 Linux 内核源码里有一批**仅靠大小写区分**的文件。
在 Windows 上整理并提交源码时，它们会被合并成一个（通常保留小写那份），
于是 Linux CI 上编译时出现：

```
make[3]: *** No rule to make target 'net/netfilter/xt_DSCP.o', needed by 'net/netfilter/built-in.o'.  Stop.
```

或 `fatal error: linux/netfilter/xt_DSCP.h: No such file or directory`。
这与 `core.ignorecase`、`core.filemode` 是同一类问题，但**无法靠 `.gitignore` 或 `chmod` 修复**——
Windows 文件系统根本不允许两个只有大小写不同的文件共存于同一目录。

## 方案

大写原件放在本目录（树内只有大写版本，Windows 上也能正常入库），
目录结构镜像 `kernel/`。`scripts/build-kernel.sh` 在编译前、且**仅在大小写敏感的
文件系统上**（`uname -s` = Linux），把这里的文件还原到 `kernel/` 对应位置：

```sh
while IFS= read -r -d '' src; do
  rel="${src#$CASEFIX/}"
  dst="$K/$rel"
  [ -e "$dst" ] || cp "$src" "$dst"     # 已存在就跳过，绝不覆盖小写版本
done < <(find "$CASEFIX" -type f -print0)
```

Windows / Git Bash 会走 `skip` 分支，不会把小写文件覆盖掉；WSL / CI / Linux 主机则自动补齐。
**因此本仓库必须经 `scripts/build.sh` 或 `scripts/build-kernel.sh` 编译**，
直接 `make -C kernel` 会因为缺这些文件而失败。

## 文件清单（12 个）

即原始源码树里全部「仅靠大小写区分」的 12 组文件对中的大写原件。

| 还原到 `kernel/` 的路径 | 本地已有的小写孪生文件 | 用途 |
|---|---|---|
| `net/netfilter/xt_DSCP.c` | `xt_dscp.c` | `CONFIG_NETFILTER_XT_TARGET_DSCP` |
| `net/netfilter/xt_HL.c` | `xt_hl.c` | `CONFIG_NETFILTER_XT_TARGET_HL` |
| `net/netfilter/xt_RATEEST.c` | `xt_rateest.c` | `CONFIG_NETFILTER_XT_TARGET_RATEEST` |
| `net/netfilter/xt_TCPMSS.c` | `xt_tcpmss.c` | `CONFIG_NETFILTER_XT_TARGET_TCPMSS` |
| `include/uapi/linux/netfilter/xt_DSCP.h` | `xt_dscp.h` | 上述 target 的 uAPI 头 |
| `include/uapi/linux/netfilter/xt_RATEEST.h` | `xt_rateest.h` | 同上 |
| `include/uapi/linux/netfilter/xt_TCPMSS.h` | `xt_tcpmss.h` | 同上 |
| `include/uapi/linux/netfilter/xt_CONNMARK.h` | `xt_connmark.h` | uAPI 头，内核 `.c` 未直接 include（编译不依赖，但属原始源码） |
| `include/uapi/linux/netfilter/xt_MARK.h` | `xt_mark.h` | 同上 |
| `include/uapi/linux/netfilter_ipv4/ipt_ECN.h` | `ipt_ecn.h` | `ipt_ECN.c` 引用 |
| `include/uapi/linux/netfilter_ipv4/ipt_TTL.h` | `ipt_ttl.h` | `xt_HL.c` 引用 |
| `include/uapi/linux/netfilter_ipv6/ip6t_HL.h` | `ip6t_hl.h` | `xt_HL.c` 引用 |

## 来源

与工程内核同源：`LineageOS/android_kernel_oneplus_sm8150` 分支 `lineage-18.1`
（sm8150 / Linux 4.14），按上述路径逐个取原文，未做任何代码修改。
其中 `xt_RATEEST.c` 与上游 `torvalds/linux v4.14` 有差异（LineageOS 有下游补丁），
故统一采用 LineageOS 版本。

**逐字节校验**：用打包前的原始 7z 源码快照（在大小写敏感环境生成，76,790 个文件，
附全量 `SHA256SUMS.txt`）比对，本目录 12 个文件的 sha256 与快照记录**全部一致**。
这同时证明快照里确实有 12 组仅大小写不同的文件对，且没有遗漏。

## 自检

```sh
# 列出所有「Makefile 引用了 X.o，但磁盘上只有 x.c」的冲突
python3 - <<'PY'
import os,re
for dp,dn,fns in os.walk('kernel'):
    if 'Makefile' not in fns: continue
    names=set(fns)
    for l in open(os.path.join(dp,'Makefile'),errors='replace'):
        if l.lstrip().startswith('#') or not l.lstrip().startswith('obj-'): continue
        for t in re.findall(r'([A-Za-z0-9_-]+\.o)\b',l):
            s=t[:-2]
            if any(s+e in names for e in ('.c','.S','.s')): continue
            tw=[f for f in names if f.lower() in (s.lower()+'.c',s.lower()+'.s')]
            if tw: print(t,'<-',tw,'@',dp)
PY
```

该自检应为 0 条（当前内核树里 4 处 Makefile 冲突均已由本目录覆盖）。
注意它只能查出「Makefile 引用了 `X.o` 却没有 `X.c`」的情况，查不出纯头文件冲突
（`xt_CONNMARK.h` / `xt_MARK.h`）；要完整核对须用大小写敏感环境下的原始快照。

## 已知遗留：`AUX` 是 Windows 保留设备名

除大小写外，Windows 还不允许创建名为 `aux.*` 的文件，因此原始快照里这 3 个文件
在 Windows 侧被改名加了下划线前缀：

- `kernel/drivers/gpu/drm/nouveau/nvkm/subdev/i2c/aux.c` → `_aux.c`
- `kernel/drivers/gpu/drm/nouveau/nvkm/subdev/i2c/aux.h` → `_aux.h`
- `kernel/include/soc/arc/aux.h` → `_aux.h`

`nouveau/.../i2c/Kbuild` 仍写着 `nvkm-y += nvkm/subdev/i2c/aux.o`，但 clean 档的
`CONFIG_DRM_NOUVEAU is not set`、arc 头也只在 ARC 架构使用，所以当前编译不受影响。
将来若启用 nouveau 或编译 ARC，需要在 Linux 还原阶段把 `_aux.*` 重命名回 `aux.*`；
本目录暂不覆盖这一项。
