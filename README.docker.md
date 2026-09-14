# Redmi K40 / alioth Docker 内核

本分支在上游 `android15-lineage22-mod` 基础上添加 Docker/containerd 的内核配置和构建流程。每次运行原版 `build.sh`，顺序编译两种不同内核：

| 产物 | 使用的系统 |
| --- | --- |
| `Kernel_AOSP_alioth_*.zip` | AOSP ROM，如 LineageOS、PixelExperience；具体 ROM 兼容性仍需实机验证 |
| `Kernel_MIUI_alioth_*.zip` | MIUI / HyperOS |

这是两套 AnyKernel3 刷机包，不是通用 `boot.img`。请按当前 ROM 选择对应版本。包的分区处理、设备适配以及 SukiSU 管理器版本要求沿用上游 README。

## 配置与验证

- `docker.config`：补齐 namespaces、IPC、cgroups、seccomp、keys、OverlayFS、veth/bridge、IPv4/IPv6 iptables NAT，以及 IPVS 等选项。全部要求 `=y`，因为现有 AnyKernel3 打包流程不会另行安装这些内核模块。
- `docker-ci.sh prepare`：加载上游 `alioth_defconfig`，用 `merge_config.sh` 合并片段，执行 `olddefconfig`，逐项检查片段中的所有选项，再以 `savedefconfig` 生成临时 defconfig；从临时 defconfig 重新生成完整配置并再次检查。
- Actions 只临时覆盖 runner 工作区的 `arch/arm64/configs/alioth_defconfig`，让 `build.sh` 两次加载的配置都包含 Docker 选项。Git 提交不修改此 defconfig；`build.sh` 中仅增加由 CI 环境变量启用的配置快照和镜像校验值记录，普通本地构建路径不受影响。
- `build.sh` 在可选的 KPM 补丁改写 Image **之前**，从刚链接的内核中提取 IKCONFIG，并与当时的 `out/.config` 逐字节比较；这样 AOSP 的配置不会因 MIUI 阶段删除 `out/` 而丢失，也不会误把 KPM 改写后镜像中残留的旧 IKCONFIG 当成本次配置。
- `docker-ci.sh collect`：分别解压两套 ZIP 中的 `kernels/Image`，核对它与打包时记录的 SHA-256 完全一致，再逐项严格验证补丁前已确认的最终配置。关闭 KPM 时还会从 ZIP 内 Image 再提取一次配置并交叉比较。
- 同时检查 MIUI 包含 `CONFIG_XIAOMI_MIUI=y`、AOSP 不包含该选项，并确认 MIUI 嵌入配置与最后的 `out/.config` 完全一致。
- 少任意配置、少任意一种 ZIP、ZIP 损坏、配置提取失败或编译失败，任务都会失败；只有两套内核均通过检查才上传正式产物。失败日志和已获得的配置仍作为 diagnostics 上传。

片段针对 **rootful Docker/containerd + overlay2 + iptables/xtables 网络后端**。`USER_NS` 保留上游设置，没有承诺 rootless 或 userns-remap 支持，也没有为 Docker 的原生 nftables 后端作专门适配。

内核选项通过不等于 Android 中 Docker 已能直接启动：还需要 root 权限、适配此 Linux 4.19 内核的 Docker/containerd/runc 用户空间版本、正确的 cgroup 挂载、网络转发和兼容的存储目录。SELinux、Android 挂载布局和 ROM 差异需要实机检查，本流程不修改 SELinux 策略或系统启动配置。

## 使用 GitHub Actions

向 `docker-alioth` 推送提交会触发 `.github/workflows/build-alioth-docker.yml`。如果 fork 的 Actions 尚未启用，先在仓库 Actions 页面启用，再推送一次提交。

手动触发定义了 `ksu` 布尔参数，默认开启上游 SukiSU/SUSFS/KPM；push 同样默认开启。关闭参数时，两套产物都不集成 KernelSU，仍需要其他 root 方案才能使用 rootful Docker。

**GitHub 的手动触发要求 workflow 文件存在于仓库默认分支。** 若默认分支仍是没有该 workflow 的纯上游 `android15-lineage22-mod`，仅在 `docker-alioth` 中声明 `workflow_dispatch` 不会让手动触发立即可用。可将 fork 默认分支设为 `docker-alioth`，保留 `android15-lineage22-mod` 为纯上游镜像；也可以在默认分支维护该 workflow，但这会增加镜像分支的自定义内容。参见 [GitHub 手动运行 workflow 文档](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)。

默认分支满足上述条件后：Actions → Build alioth Docker kernel → Run workflow → 选择 `docker-alioth` 和 `ksu`。工作流限定只构建 `docker-alioth`，选其他分支会跳过。

构建使用 Ubuntu 22.04 和上游指定的 Proton Clang `20210522` 路径。没有给不兼容的新编译器自动降级的逻辑。上游脚本会下载其指定版本的 SukiSU/KPM，并克隆 `AnyKernel3` 的 `kona` 分支；工具链归档校验和、内核提交、构建脚本哈希和 AnyKernel 提交随产物保存。上游 AnyKernel 分支等外部依赖可能更新，因此并非所有输入都按不可变提交固定。

成功运行的 `alioth-docker-both-roms-*` artifact 包含：

- 两套 `Kernel_AOSP_alioth_*.zip` 和 `Kernel_MIUI_alioth_*.zip`。
- `alioth-aosp-final.config`、`alioth-miui-final.config`：来自各自 KPM 改写前的已编译 Image，并已与对应 `out/.config` 逐字节比较。
- `alioth-*-unpatched-image.sha256`、`alioth-*-packaged-image.sha256`：KPM 改写前及 ZIP 内最终 Image 的关联校验值。
- `alioth-docker-resolved.config` 和 `alioth-docker.defconfig`：编译前验证的完整配置与临时 defconfig。
- `docker.config`、提交记录、环境记录和 `SHA256SUMS`。

完整 `.config` 以有含义的文件名上传，避免 artifact 默认忽略以点开头的隐藏文件。产物保存 14 天，需长期保留时请自行下载。`alioth-docker-diagnostics-*` 包含配置合并、编译和打包验证日志。

## 安全同步上游

初始检查（2026-09-14）：fork 默认分支和上游目标分支均为 `android15-lineage22-mod`，均指向 `3ebb63388f1c84d894a719411b51c131b64c729b`；fork 当时不存在 `docker-alioth`，本分支从该提交创建。

每个新克隆都需要配置 remote；remote 是本地 Git 设置，不随提交传播：

```bash
git clone https://github.com/wfgzsdq/kernel_xiaomi_sm8250_docker_mod.git
cd kernel_xiaomi_sm8250_docker_mod
git remote add upstream https://github.com/liyafe1997/kernel_xiaomi_sm8250_mod.git
git remote -v
```

如果 `upstream` 已存在，先检查 URL，必要时执行：

```bash
git remote set-url upstream https://github.com/liyafe1997/kernel_xiaomi_sm8250_mod.git
```

开始同步前确认 `git status --short` 为空；先提交或保存自己的未完成修改。然后获取双方更新，检查差异：

```bash
git fetch origin
git fetch upstream
git log --oneline --left-right origin/android15-lineage22-mod...upstream/android15-lineage22-mod
```

更新纯上游镜像分支（首次没有本地分支时，用 `git switch --track origin/android15-lineage22-mod`）：

```bash
git switch android15-lineage22-mod
git merge --ff-only origin/android15-lineage22-mod
git merge --ff-only upstream/android15-lineage22-mod
git push origin android15-lineage22-mod
```

任何 `--ff-only` 失败都应停下来检查分叉原因，不用 `reset --hard` 或强制推送覆盖历史。

把更新合并到 Docker 分支，并在提交前检查。备份分支名称应保持唯一：

```bash
git switch docker-alioth
git merge --ff-only origin/docker-alioth
git branch "backup/docker-alioth-$(date +%Y%m%d-%H%M%S)"
git merge --no-ff --no-commit upstream/android15-lineage22-mod
git diff --cached --stat
git diff --cached -- build.sh arch/arm64/configs/alioth_defconfig scripts/extract-ikconfig
bash -n build.sh docker-ci.sh
actionlint .github/workflows/build-alioth-docker.yml
```

发生冲突时逐文件处理；不确定就 `git merge --abort`。尤其检查上游的工具链路径、AOSP/MIUI 构建方式、ZIP 文件名和包内 `kernels/Image` 路径是否变化。原 defconfig 随上游变化属于正常更新，不应拿旧的 Docker 生成配置覆盖它。

确认处于待提交的 merge 状态且检查通过后：

```bash
git commit -m "Merge upstream android15-lineage22-mod into docker-alioth"
git push origin docker-alioth
```

如果 merge 提示 Already up to date，则无需创建 merge 提交。push 会触发完整配置验证和双版本构建；核对该提交的 Actions 和两个最终 `.config` 后，再决定刷入。这个流程使用普通 merge，不要求 rebase 或 force-push。

## 刷机后的验证

在手机端检查实际运行内核的 `/proc/config.gz`，再运行官方 [Moby check-config.sh](https://github.com/moby/moby/blob/master/contrib/check-config.sh)。该脚本也会读取运行机器的 cgroup 挂载、sysctl 和设备状态，因此在 GitHub runner 上执行不能替代手机端验证。

```bash
su
zcat /proc/config.gz | grep -E 'CONFIG_(PID_NS|IPC_NS|CGROUP_DEVICE|CGROUP_PIDS|OVERLAY_FS|BRIDGE_NETFILTER|SECCOMP_FILTER)='
# 将已下载并检查的官方 check-config.sh 放到手机后运行：
sh check-config.sh /proc/config.gz
docker info
docker run --rm hello-world
```

另外测试容器 DNS、外网访问、端口发布、卷读写和所需的资源限制。完整的手机运行测试与 AOSP/MIUI 启动兼容性测试需要实机完成。
