# 离线编译说明

本源码包已包含：
- 内核源码（kernel/）
- 完整工具链（toolchain/，含 .ready 标记和 dl/ 下载缓存）

`scripts/fetch-toolchain.sh` 检测到 toolchain/.ready 存在时会直接跳过工具链准备，
因此解压后编译全程不需要联网。

## 编译

```bash
tar -xzf hotdogb-boot-src-<时间>-<档位>.tar.gz
cd hotdogb-boot-src-<时间>-<档位>
./scripts/build.sh --profile clean --jobs 4