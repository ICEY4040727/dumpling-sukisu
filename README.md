# dumpling-sukisu · 从零编出第一个内核

目标：把 SukiSU-Ultra 编进 OnePlus 5T（代号 `dumpling`）的 4.4.302 内核，产出一个在 TWRP 里能刷的 zip。

适用前提：手机已经刷了 **LineageOS 22.2**，bootloader 已解锁，能进 TWRP 或 fastboot。

---

## 0. 你要做的，和不用做的

**不用做**：不用手动改 C 代码（hook 与兼容垫片由 `build.sh` 在 CI 里插入）、不编辑 defconfig、不装 Linux（走路线 A）、不装交叉编译器。

**要做**：把工程目录里的文件放进一个 GitHub 仓库 → 点一次 Run workflow → 看懂日志 → 下载 zip → 在手机上备份 `boot.img` → 刷 zip → 装 Manager APK 验证。

工程里的文件：

| 文件 | 干什么 |
|---|---|
| `build.sh` | 主脚本，分 `prepare` / `hooks` / `build` / `pack` 阶段 |
| `toolchain.conf` | 所有已核实的下载 URL、commit 哈希、defconfig 名、编译器版本 |
| `anykernel.sh` | AnyKernel3 的刷入配置，声明设备名和 boot 分区路径 |
| `.github/workflows/build.yml` | GitHub Actions 的一键流程 |
| `.gitattributes` | 强制 `*.sh` / `*.yml` 保持 LF，压过 Windows 的 `core.autocrlf` |
| `README.md` | 这份手册 |

---

## 1. 先建立一条因果链

手机开机时读的是 boot 分区里的 `boot.img`。它装着两样东西：内核（压缩过的二进制 `Image.gz-dtb`）和 ramdisk（开机最早执行的那批文件与脚本）。

root 的授权判断必须在内核态完成。所以 SukiSU 不能以 APK 的形式装上去——APK 只是管理界面，真正干活的代码得编进内核。这就逼出了后面每一步：

1. 拿到和你系统对得上的内核 **C 源码**：LineageOS 22.2 的 `android_kernel_oneplus_msm8998`，版本 4.4.302。
2. 用一份**开关清单**告诉编译器哪些代码要、哪些不要。这份清单叫 defconfig，本工程用 `lineage_oneplus5_defconfig`。脚本往里加 `CONFIG_KSU=y`，`=y` 意为直接编进内核本体而不是做成可插拔的模块，因此最后要换掉整个内核镜像。
3. 用**交叉编译器**编译。你的电脑是 x86_64，手机是 arm64，指令集不同，得用 AOSP clang + GCC 4.9 这套专用工具链，而且它们在 Linux 上才跑得起来。
4. 编译器吐出 `Image.gz-dtb`。它还不是刷机包。
5. AnyKernel3 把**你手机当前的** boot.img 拆开，只换掉内核，ramdisk 原样塞回去，打成 zip。所以刷它不用重刷整个 ROM，也所以刷之前必须留一份原来的 boot.img——那是唯一能一键退回的东西。

一句话：要 root → root 得进内核 → 内核得从源码编译 → 编译需要 Linux 和专用编译器 → 得到镜像 → 只替换 boot.img 里的内核 → 备份让你能反悔。

---

## 2. 路线 A：GitHub Actions（推荐，Windows 上直接做）

需要：一个 GitHub 账号、一个浏览器。GitHub 的云端 runner 是 Ubuntu 22.04，正好和上游 CI 一致，编译器、磁盘、内存都在那边。

### 2.1 建仓库

1. 打开 <https://github.com/new>
2. Repository name 填 `dumpling-sukisu`
3. 选 **Public**。公开仓库的 Actions 时长最宽裕；这个仓库里只有公开 URL 和 commit 哈希，没有账号、密码、token，公开不会泄露什么
4. **不要**勾 "Add a README file"，省一次合并冲突
5. 点 `Create repository`

建好之后你会看到一个蓝色的 **Quick setup** 页面：Codespaces 卡片、协作者卡片、仓库地址、两段命令行示例。**这个页面没有 `Add file` 按钮**，不是你没找到。

原因是 GitHub 仓库等于「一堆文件 + 一串提交 + 一个默认分支」。刚建的空仓库一个提交都没有，默认分支 `main` 还不存在，文件列表视图也就无从显示。官方文档写 `Add file` 下拉菜单位于 "above the list of files"——没有文件列表，按钮自然不出现。只要做出**第一个提交**，页面就切到正常的文件列表视图，`Add file` 立刻出现。

那个蓝框其实是在教你 git：`git init` 把本地目录变成仓库，`git add` 把文件放进待提交区，`git commit` 把这一批改动封成一次提交，`git remote add origin <URL>` 往 `.git/config` 写一条「别名 → URL」的映射（纯本地、不联网），`git push -u origin main` 才第一次连网、按这条映射把提交送上去并记住分支跟踪关系。

两段示例的区别是「本地那个仓库怎么来的」：自己 `git init` 出来的仓库一个 URL 都没有，必须先 `remote add`；从 GitHub `git clone` 下来的仓库，`.git/config` 里已经自带 `[remote "origin"]` 和 `[branch "main"]` 的跟踪关系，不用再加。所以下面 2.2 那条 `git clone` 路线里没有 `remote add`。`origin` 只是惯例名、不是关键字，一个仓库可以登记多个 remote 分别推到不同地方。你走网页路线可以先不敲，但看到它们时知道在说什么，以后学 git 省很多力。

### 2.2 放四个文件（这里有个坑）

Quick setup 里那行 `Get started by creating a new file or uploading an existing file` 有两个蓝色链接，它们就是空仓库的入口：

- `uploading an existing file` → 进上传页
- `creating a new file` → 进网页编辑器

随便用哪个，做出第一个提交即可。

**第一批，三个普通文件**：点 `uploading an existing file`（等仓库有文件后，也可以点 `Add file` → `Upload files`），把 `build.sh`、`anykernel.sh`、`toolchain.conf` 拖进去。commit message 写 `add build scripts`，保持 `Commit directly to the main branch`，点底部 `Commit changes`（若选了新建分支，按钮会叫 `Propose changes`）。

> 官方文档的两条限制：网页上传单文件不超过 25 MiB，一次最多 100 个文件；也可以把整个文件夹拖进浏览器。另有一条值得记：网页上传会忽略 `.gitattributes` 的换行设置。本工程四个脚本都是 LF，网页上传不会改内容，但用 git 推更稳妥。

**第二批，单独建 workflow**：仓库现在有文件了，点 `Add file` → `Create new file`，在**文件名输入框里直接写完整路径** `.github/workflows/build.yml`。官方文档原话是 "To create subdirectories, type the `/` directory separator"——带斜杠的路径会自动建出两级目录，隐藏目录也一样。把 `build.yml` 的内容整段粘进去，点 `Commit changes...`，在弹出的对话框里填 message 再点 `Commit changes`。

> 想顺手学 git，这条路一次搞定，也不怕隐藏目录（空仓库 clone 时提示
> `You appear to have cloned an empty repository` 是正常的）：
> ```bash
> git clone https://github.com/ICEY4040727/dumpling-sukisu.git
> cd dumpling-sukisu
> # 把工程里全部内容（含 .github）拷进这个目录
> git add -A
> git commit -m "init: dumpling sukisu build"
> git push
> ```

#### 如果你直接在工程目录里 `git init`

不 clone，就在 `dumpling-sukisu/` 目录里从头建仓库，顺序是：

```powershell
git init
git remote add origin https://github.com/ICEY4040727/dumpling-sukisu.git
git branch -M main
git add -A
git commit -m "init: dumpling sukisu build"
git push -u origin main
```

`git push -u origin main` 逐字拆开：`push` 把本地提交送到远程；`origin` 是
remote 别名，git 查 `.git/config` 的 `[remote "origin"]` 拿到 URL；`main` 是
refspec，完整写法 `main:main`（本地 main → 远程同名分支），只写一个 `main`
时目标同名；`-u` 是 `--set-upstream`，额外往 config 记一笔：

```ini
[branch "main"]
    remote = origin
    merge = refs/heads/main
```

这笔记录把「本地 main 对应 origin/main」固定下来，以后 `git push` / `git pull`
不用再带参数。第一次 push 时 git 会打印
`branch 'main' set up to track 'origin/main'.`，`git status -sb` 显示
`## main...origin/main`。不加 `-u` 的话，裸 `git push` 报
`fatal: The current branch main has no upstream branch.`。
`git clone` 出来的仓库自带这段跟踪配置，所以 clone 那条路线不用 `-u`。

三个容易撞的点：

- 在 `git init` 之前敲 `git remote add`，会报
  `fatal: not a git repository (or any of the parent directories): .git`。
  git 从当前目录逐级往上找 `.git`，找不到就没有地方写 remote 配置。
- 一个 commit 都还没有就 `git push`，报
  `error: src refspec main does not match any`。
- **分支名必须是 `main`**。`git init` 在 Windows 上常默认建 `master`，而
  GitHub 的默认分支是 `main`。GitHub Docs 原话："To trigger the
  `workflow_dispatch` event, your workflow must be in the default branch."
  推成 `master` 的话，仓库首页默认显示的 `main` 仍是空的，Actions 页面
  也不会出现 `Run workflow` 按钮。`git branch -M main` 在无提交的空仓库上
  同样有效（实测 HEAD 从 `refs/heads/master` 改为 `refs/heads/main`）。

工程里还有一个 `.gitattributes`，把 `*.sh` / `*.yml` / `*.conf` 等声明成
`text eol=lf`。Windows 上常见的 `core.autocrlf=true` 会在 checkout 时把脚本
改写成 CRLF，而 Linux 上的 bash 见到 CRLF 会直接报错；这个文件显式压过全局
设置，保证 GitHub Actions 的 runner 取到的始终是 LF。如果你在加它之前已经
跑过 `git add -A`，再跑一次 `git add -A` 把它纳入暂存。

### 2.3 跑第一次构建

1. 点仓库顶部的 `Actions` 标签。第一次进来若显示 "Workflows aren't running for this repository"，点那句绿色的 `I understand my workflows, go ahead and enable them`
2. 左侧列表选 `Build dumpling SukiSU kernel`
3. 右侧点开 `Run workflow`：`Use workflow from` 选 `main`，
   `SukiSU-Ultra branch` 选 `builtin`（当前默认值）
4. 点绿色的 `Run workflow`，页面刷新出一条黄色转圈的记录，点进去看实时日志

**点开面板会看到两个都带 branch 的下拉框，它们管的是两个不同仓库。**

`Use workflow from` 是 GitHub 自带的，列的是**你自己这个仓库**
（`ICEY4040727/dumpling-sukisu`）的分支和 tag。它决定两件事：从哪份
`.github/workflows/build.yml` 读步骤，以及 `actions/checkout` 检出哪个 commit。
这个仓库目前只有 `main` 一个分支、0 个 tag，所以这里只有 `main` 可选，
`builtin` 根本不会出现在列表里。GitHub Docs 把这个框叫 "Branch dropdown"，
原文是 "Select the Branch dropdown menu and click a branch to run the workflow on."

`SukiSU-Ultra branch` 是我们在 `build.yml` 的 `workflow_dispatch.inputs` 里
自己加的，GitHub 只把它当一个字符串。workflow 把这个值放进环境变量
`SUKISU_REF`，`build.sh` 拿它去 clone **另一个仓库**：

```bash
git clone --depth 1 -b "$SUKISU_REF" "$SUKISU_REPO" "$ksu"
```

所以 `builtin` / `old` / `main` 是 `SukiSU-Ultra/SukiSU-Ultra` 的分支名，
和你仓库的分支毫无关系。Run #1 证明 `main` 在 4.4 上编不过，Run #2 证明
`old` 缺 4.4 兼容层。当前默认值是 `builtin`——它自带完整垫片，所需的
3 处 hook 由 `build.sh` 在 CI 里自动插入，不用你碰 C 代码（见 5.5）。

点下去之后，GitHub 生成一次 run，并把它**钉在点击那一刻的默认分支 HEAD 上**。
Run #1 钉的是 `76863c4`；`b60a4d5` push 上去之后，新点的 run 会钉在
`b60a4d5`。之后即使又 push 了新 commit，这次运行读的仍是那一版文件；
要让新改动生效，得重新点一次 `Run workflow`。运行记录里的 `head_sha`
就是这个绑定。

反过来，`workflow_dispatch` 只有写在默认分支才会出现按钮（2.2 讲过）。既然
按钮能点，就说明 `.github/workflows/build.yml` 确实在 `main` 上；日志里
`Run actions/checkout@v4` 成功，是文件被真正取到的第二个证据。点完不用再做
任何操作，只剩等。

### 2.4 成功的样子

日志依次跑五步：`System dependencies` → `Prepare sources and self-check` → `Compile kernel` → `Pack AnyKernel3 zip` → `Upload flashable zip`。下载工具链加编译通常十几到三十分钟，中间刷得飞快是正常的。

认这几行，出现就说明对了：

- `Prepare sources and self-check` 里有 **6 行 `OK ...`**，末尾是 `All structural checks passed. Compile compatibility is still unverified on a real host.`
- `Compile kernel` 里出现 `built: .../out/arch/arm64/boot/Image.gz-dtb`
- `Pack AnyKernel3 zip` 里出现 `output: out/dumpling-SukiSU-main-4.4.302-<时间戳>.zip`
- `Upload flashable zip` 显示 `Artifact ... has been successfully uploaded!`
- 整条运行记录变绿

### 2.5 取回 zip

回到这次运行的页面，最下面 `Artifacts` 区点 `dumpling-sukisu-main-4.4.302` 下载。

**注意两层压缩包**：下载到的是 artifact 外壳，解压后里面那个 `dumpling-SukiSU-main-4.4.302-*.zip` 才是要刷进手机的包。别把外壳直接刷进去。

---

## 3. 路线 B：WSL2 / Ubuntu 22.04 本地（可选）

想在自己机器上跑，或者要反复试错时更方便。统一用 `bash ./build.sh ...`，不用管执行位。

```bash
sudo apt update
sudo apt install -y libssl-dev libc6-dev binutils libgcc-11-dev \
  zip unzip wget tar python3 build-essential git bc
```

然后按阶段跑，每一步跑完看输出再走下一步：

```bash
bash ./build.sh prepare   # 下载源码+工具链、集成 SukiSU、写 defconfig、自检
bash ./build.sh build     # 编译
bash ./build.sh pack      # 产出 out/*.zip
```

`prepare` 的自检全 `OK` 之后再 `build`。重跑同一阶段时已下载的文件会走缓存（`  cached   ...`），不会重复下几个 G。

脚本里有一段兼容处理会尝试 `sudo ln -s ... /usr/bin/python`，因为 GCC 4.9 的 wrapper 是 python2 语法。Ubuntu 22.04 上 python2 常常装不上，这段会自动跳过；如果真因此报错，看第 5 节。

---

## 4. 手机端：备份 → 刷入 → 验证 → 回滚

**这一步比编译更需要小心。刷错 boot 分区会起不来。**

### 4.1 先备份 boot.img（不可跳过）

进 TWRP，用 adb shell 直接 dd 出当前 boot 分区：

```bash
adb shell "dd if=/dev/block/bootdevice/by-name/boot of=/sdcard/boot-backup.img"
adb pull /sdcard/boot-backup.img .
```

或者在 TWRP 里走图形界面：`Backup` → 只勾 `Boot` → 执行备份。两条路留任意一条即可，把文件**拷到电脑上**再动手。

`/dev/block/bootdevice/by-name/boot` 这个路径来自 `anykernel.sh` 和 LineageOS 的 BoardConfig，5T 是非 A/B 机型，只有一个 boot 分区。

### 4.2 刷入

把第 2.5 节拿到的那个 zip 拷进手机内置存储（TWRP 里若看不到文件，改用 OTG U 盘）。

TWRP → `Install` → 选 zip → 滑动确认刷入。不要勾 `Reboot after install` 之外的多余选项，也不要在同一次里叠刷 Magisk。

刷完再装 **SukiSU-Ultra Manager APK**，从官方 Releases 取：<https://github.com/SukiSU-Ultra/SukiSU-Ultra/releases>。APK 只是界面，装完能打开说明内核那半边已经在了。

### 4.3 验证

设置 → 关于手机 → 内核版本，末尾应带 `-sukisu-dumpling`（脚本里 `localversion` 写的）。打开 Manager，显示已安装/工作中即成。

### 4.4 回滚

开机卡住或进不去系统：回 TWRP，`Restore` 第 4.1 节的 Boot 备份；或者

```bash
adb push boot-backup.img /sdcard/
adb shell "dd if=/sdcard/boot-backup.img of=/dev/block/bootdevice/by-name/boot"
```

这就是备份必须存在的原因——没有它，回滚就得整包重刷 ROM。

---

## 5. 报错怎么读

第一次跑失败不丢人，也大概率不是你操作错。展开红色的那个步骤，把**最后 50 行**原样贴出来即可。

**2026-11-08 第一次真实运行（Run #1）的结果**：`Prepare sources and self-check`
成功，耗时 19 分钟，源码、工具链、三处内核树改动都到位；`Compile kernel` 跑了
3 分 58 秒后以 **exit code 2** 失败，`Pack` / `Upload` 两步被跳过。`build.sh`
里脚本自己的失败都是 `exit 1`（`die()` 和 `[ -f ... ] || die`），`set -euo pipefail`
会让 `make` 的退出码原样传出去，所以 2 是 **make 返回的**——编译阶段的 C
代码报错，不是自检失败、不是下载失败、也不是按钮点错了。具体哪个文件、
哪一行，只有日志正文能回答。

怎么把日志拿到手（四选一）：

1. 运行页面点 `build` → 展开红色的 `Compile kernel` → 滚到底，复制最后 50 行
2. 运行页面 Summary 区：`Keep compile log on failure` 会把最后 100 行写在这里
3. 运行页面底部 `Artifacts` 区点 `compile-log-*-runN` 下载，解压出 `build.log`；
   或右上角 `...` → `Download log archive`，找 `Compile kernel` 那个 txt
4. 想让我读全文，把解压出的文件放到工程目录下、命名 `build.log`，告诉我路径

**artifact 传上去之后，我仍然读不到内容，还得你转交一次。** 三层原因：

- GitHub Docs 下载页写死："People who are signed into GitHub and have
  read access to a repository can download workflow artifacts." 我用的网页
  抓取是匿名请求，不带登录态。
- REST 端点分两档：列 artifact（`GET /actions/artifacts`）这类元数据接口
  注明 "can be used without authentication ... if only public resources are
  requested"，实测匿名返回 200；**下载 zip** 那个端点没有这句豁免，要求
  token 带 "Actions: read"，返回 302 到一个 1 分钟过期的签名 URL。
- 连接器工具集里没有 Actions runs / artifacts / logs 端点，只有仓库文件、
  issue、PR、release；网页抓取也不处理二进制 zip，本机 Bash 沙箱无外网，
  `gh` 未登录。

所以我能自己查到「有没有 artifact、叫什么、多大」，看不到里面的日志正文。
Run #2 产出 `compile-log-old-run2`（id `13619981890`，17129 B）后实测：
匿名 `GET /actions/artifacts/13619981890/zip` 返回
`401 Requires authentication`；网页 artifact 下载 URL 落到 404 页 + Sign in。
Run #1 那轮 job logs 下载接口返回
`403 Must have admin rights to Repository.`，check-run annotations 只有一句
`Process completed with exit code 2.`，网页日志是 JS 渲染的，同一个道理。
另有一个坑：`actions/artifacts` 与 jobs 接口会返回缓存旧值（Run #2 已结束后
仍显示 `total_count: 0` / `in_progress`），加一个随机查询参数才拿到新值。

| 日志里出现 | 是什么 | 怎么办 |
|---|---|---|
| `download failed: https://...` | 某个源没下下来，`fetch` 会直接停 | 贴出整行 URL，我换源或校验 URL；别自己改 `toolchain.conf` 里的哈希 |
| `self-check failed` 且上面有 `MISSING ...` | 内核树三处改动没落上 | 看是哪条 MISSING，连同上下文贴出来 |
| `fatal error: xxx.h: No such file or directory` / 大量 `error:` 出现在 `Compile kernel` | 4.4.302 与所选 SukiSU 分支不兼容，或自动补丁没覆盖到 | 把 Summary 里的 `error:` 行贴出来逐条补；别自己改 `toolchain.conf` 哈希 |
| `No space left on device` | runner 磁盘被工具链和 `out/` 占满 | 贴日志，可以加清理步骤，不是你的操作问题 |
| `/usr/bin/python: bad interpreter` 或 GCC wrapper 报 python 语法错 | Ubuntu 22.04 上 python2 装不上 | 贴日志，我改 workflow 的兼容处理 |
| `MISSING manual hook in fs/xxx.c` / `[FAIL] ... anchor not found` | 只有 `builtin` 会触发；自动插入时锚点没匹配上 | 贴出 `Inserting manual hooks` 那一段完整输出；`bash ./build.sh hooks` 可预览真实位置 |
| `Prepare sources and self-check` 失败、`Compile kernel` 显示 skipped | 自检主动拦下，编译根本没开始 | 看上面的 `MISSING ...` 行；exit code 1 是脚本 `die`，不是编译器给的 2 |
| `unknown stage` | 阶段名拼错 | 只能用 `prepare` / `hooks` / `build` / `pack` / `all` / `clean` |
| `Process completed with exit code 2.` 单独出现在 `Compile kernel` | 这是 GitHub 给步骤盖的结论章，不是报错正文 | 按上面三条取日志；它只说明 `make` 挂了 |

workflow 已补日志留存：`Compile kernel` 的输出用 `tee build.log` 落盘，
`set -o pipefail` 保证 `make` 的退出码不被管道吃掉；失败时把最后 100 行写进
运行页的 Summary，并把完整 `build.log` 传成 artifact。这个改动只作用于
**下一次**运行，已经结束的 Run #1 补不上。`workflow_dispatch` 是唯一触发器，
所以只是 push 这两个文件不会自动重跑，不用担心白等 23 分钟。

### 5.1 Run #1 的真实报错，和它说明的事

`Compile kernel` 的 5 条错误全在 `drivers/kernelsu/core/init.o`：

| 报错 | 源码依据（已抓 raw 文件核对） |
|---|---|
| `unknown type name 'syscall_fn_t'` ×3 | `main/kernel/hook/syscall_hook.h` 只在 `__x86_64__` 和 `__riscv` 下 typedef 这个类型；arm64 靠内核头提供，4.4 没有 |
| `MODULE_IMPORT_NS(...) type specifier missing` ×2 | `main/kernel/core/init.c` 末尾无条件调用该宏，只按 6.13 区分字符串/标识符两种写法；该宏 5.4 才引入，4.4 不存在，clang 把它当隐式函数声明，撞 `-Werror,-Wimplicit-int` |

这不是两个孤立符号。`main` 分支的 `kernel/Kbuild` 把 40 多个对象文件
（BTF parser、seccomp cache、mount namespace、dynamic manager…）全部无条件
编入，没有 4.4 兼容裁剪，也不 include `kernel_compat.h`。补上这两个符号
只会暴露下一批错误。

官网 Integration 的分工写得很清楚：`main` 是 kprobes + `sys_enter`
tracepoint，给 GKI / LKM；`builtin` 不用 kprobes，由内核源码调用 hook 入口，
给 "Kernels you patch by hand"。`builtin` / `old` 分支带 `kernel_compat.h`
（<4.14 的 `kernel_read/write`、<4.12 的 `kvmalloc`、<5.2 的 `strscpy`…），
`builtin` 的 `ksu_main.c` 还会按 `>= 5.10` 裁掉 `selinux_hide`。但
**`old/kernel/ksu.c` 末尾同样无条件调用 `MODULE_IMPORT_NS`**，所以换分支
绕不开这一处。

### 5.2 已加的兼容层、分支选项、缓存

`build.sh` 的 `apply_compat_patches()` 在 `prepare` 阶段生成
`ksu_44_compat.h` 并注入源码，处理三处已核实的 4.4 缺口：中和
`MODULE_IMPORT_NS(...)`（4.4 无 module symbol namespace，语义空操作，外层
`#if/#else/#endif` 保留）、`#define TWA_RESUME 1`、以及用
`vfs_read`/`vfs_write` 垫片替换 `kernel_read`/`kernel_write`。补丁幂等，
单测覆盖注入位置、子目录相对路径、二次运行 0 改动、无关文件不变。
依据见 5.3 / 5.4，后续错误仍要一轮轮收。

`build.yml`：

- 分支下拉框扩成 `old` / `builtin-new` / `builtin` / `main`，当时默认 `old`
  —— 按"最老的代码快照、Kbuild 只有 16 个对象"选的。**Run #2 证明这个
  判断不成立**，见 5.4：`old` 几乎没有 4.4 兼容层，真正带完整垫片的是
  `builtin`。（这一节记录 Run #2 之后的改动；默认值已在 5.5 改为
  `builtin`，选项顺序也调过。）
- 加 `actions/cache/restore@v4` + `actions/cache/save@v4`，只缓存
  `work/*.zip`、`*.tar.gz`、clang、prebuilts；`prepare` 成功后立刻保存，
  因为编译失败会跳过 cache 的 post 步骤。内核树和 KernelSU checkout 不缓存，
  避免换分支时复用错的源码。首次仍要下载，之后每轮省约 19 分钟。

当时记下的三处坑（现状见 5.5）：

- `builtin` 选项会触发 `selfcheck` 的 manual hooks 检查，没打 hook 会直接
  `MISSING manual hooks`。当时的结论是"先别选它"；Run #3 正是撞在这里，
  5.5 已把 hook 改成自动插入，现在 `builtin` 是默认分支。
- 官网指南写 `ksu_handle_execveat(...)`。我上一轮说"`builtin` 真实头文件
  只有 `ksu_handle_execveat_sucompat` / `_ksud`，照抄会链接失败"——
  **这句是错的**。抓 `feature/sucompat.c` 全文核实：非 SUSFS 分支确实
  **定义了** `ksu_handle_execveat`，只是没在头文件里声明，官网用 `extern`
  声明正是为了绕过它。真正不存在的只有 `ksu_handle_sys_reboot`，5.5
  因此跳过 reboot hook。官网原话："Check their exact signatures against
  the branch you build; the patches below are for reference only."
- `CONFIG_KSU_TAMPER_SYSCALL_TABLE` 不在 SukiSU-Ultra 的
  `builtin/kernel/Kconfig` 里（全文只有 KSU / KPM / SUSFS 系列）；那一段是
  官网引用的 backslashxx/KernelSU Kconfig 参考表。别去 defconfig 里开它。

### 5.3 Run #2 的真实报错，和那三条 warning

Run #2（`42485901023`，`head_sha=b60a4d5`，12m37s）`Prepare` 与缓存保存
都成功，`Compile kernel` 跑 5m01s 后 exit code 2。致命错误只有一条：

```
../drivers/kernelsu/allowlist.c:427:32: error: use of undeclared identifier 'TWA_RESUME'
  427 |     if (task_work_add(tsk, cb, TWA_RESUME)) {
```

`TWA_RESUME` 不是 4.4 的东西。抓 raw 头核对过：

| 内核 | `task_work_add` 第三参数 | `TWA_RESUME` |
|---|---|---|
| 4.4（LineageOS msm8998） | `bool` | 不存在 |
| v5.9 | `int` | `#define TWA_RESUME 1` |
| v5.10 | `enum task_work_notify_mode` | 枚举值，等于 1 |

所以外部那条"换成 4.4 支持的 task-work flag"的建议**前提不成立**：4.4 没有
flag 概念，只有一个 bool `notify`。`TWA_RESUME` 在新内核里的值就是 1，语义
等价于 `notify=true`，因此 `#define TWA_RESUME 1` 是精确对应，不是凑合。
另外它给的链接指向
`ICEY4040727/dumpling-sukisu/blob/.../drivers/kernelsu/allowlist.c`，
实测该路径返回 `404 Not Found` —— 这个文件不在你的仓库里，是 CI 在 runner
上 clone 到内核树的 SukiSU 源码。改你仓库里的任何文件都碰不到它。

**三条 warning 不是"非致命可忽略"**，它们揭示了一个运行时 bug：

```
allowlist.c:385  kernel_write(fp, &magic, sizeof(magic), &off)
include/linux/fs.h:2660  extern ssize_t kernel_write(struct file *, const char *, size_t, loff_t);
```

4.4 的 `kernel_write` 第四参数是 `loff_t` **值**，`kernel_read` 更是完全不同的
参数顺序 `kernel_read(file*, loff_t, char*, unsigned long)`。SukiSU 传的是
5.x 的 `(buf, count, loff_t *)`。`&off` 会被当成整数偏移，allowlist 持久化
会写到错误位置。所以补丁用 `vfs_read` / `vfs_write`（这两者本来就收
`loff_t *` 并自动推进）做垫片，而不是只把 warning 压掉。

### 5.4 分支格局纠正：选错的是 `old`

我上一轮写"`builtin` / `old` 分支才带 `kernel_compat.h`（<4.14 的
kernel_read/write、<4.12 的 kvmalloc、<5.2 的 strscpy）"——**把两个分支
混成了一句**。抓全文核对：

- `old/kernel/kernel_compat.h` 只有一个 `ksu_copy_from_user_retry()`，而且它
  直接调用 `copy_from_user_nofault()`（5.8+）。`allowlist.c` 连这个头都没
  include。
- `builtin/kernel/kernel_compat.h` 才是完整的 4.4 兼容层：`<4.14` 的
  `ksu_kernel_read_compat` / `ksu_kernel_write_compat`、`<4.12` 的 kvmalloc、
  `<5.2` 的 strscpy、`<5.7` 的 `#define TWA_RESUME 1`，外加 close_fd、
  groups_sort、selinux_inode/cred 等一整套。

也就是说 Run #2 撞的两处，`builtin` 早就解决了。代价是 `builtin` 不用
kprobes，得在 4.4 源码里打 hook（见 5.2 的三个坑；5.5 已把这件事自动化）。

当时选了"借用 `builtin` 的垫片、留在 `old` 的 kprobes 路线"：新建
`ksu_44_compat.h`，只摘取上述两段官方垫片，注入到所有用到
`TWA_RESUME` / `kernel_read` / `kernel_write` 的 `.c`。没有整包复制
`builtin` 的 compat 头，因为它 `<4.10` 分支 extern 了
`install_session_keyring_to_cred`，在 4.4 上未必有定义；也没有追加到
`old` 自带的 `kernel_compat.h`，因为那个文件里的
`copy_from_user_nofault()` 会引出新的 5.8+ 依赖。

**当时给的下一轮指令**（已被 5.5 取代）：push 三个改动 → Actions →
`Run workflow` → 仓库分支 `main`，SukiSU-Ultra branch 选 `old`。实际跑的
是 Run #3，选了 `builtin`。失败时 Summary 会先列所有 `error:` 行（不再是
只有尾部 100 行）。

**当时的止损点**：Run #1 是 `MODULE_IMPORT_NS`，Run #2 是 `TWA_RESUME` +
kernel_read/write，都是"5.x API 直接用在 4.4"的同一模式。若 Run #3 还成片
出现这类符号（`copy_from_user_nofault`、BTF、namespace、seccomp cache），
就该换 `builtin` 并接受手工 hook，而不是继续逐条打垫片。社区
`Seshiria/op5dc` 的 `4.4.302v20241202` release 里仍有
`Deprecated-op5lin21-dc-ksu11804-44302v20241202.zip`（Asset URL 可见），
但那是 **LineageOS 21 / Android 14** 的 KernelSU 包，不是 SukiSU，与当前
22.2 是否兼容没验证过。

### 5.5 Run #3：exit 1 不是编译失败，hook 现在自动打

Run #3（`42488783553`，`head_sha=b9ffa34`）只跑了 1 分 22 秒。job 步骤表
把因果钉死了：

| 步骤 | 结论 |
|---|---|
| 1–4（checkout / 缓存恢复 / 系统依赖） | 成功，6 项下载全 `cached` |
| 5 `Prepare sources and self-check` | **失败**，19 秒 |
| 6 `Save source and toolchain cache` | skipped（上一步失败，条件不成立） |
| 7 `Compile kernel` | **skipped** |
| 8 / 9 日志留存 | 步骤成功，但 `build.log` 根本没生成 |

`exit code 1` 来自 `build.sh` 的 `die()`，不是 `make`。前两轮的 `exit 2`
才是 `make` 的退出码。这次连编译器都没启动。

拦在 `selfcheck()` 里：选了 `builtin` 就数 `fs/` / `kernel/` 下有多少文件
出现 `ksu_handle_`，少于 3 个直接 `die`。这次是 0 个，于是打印
`MISSING manual hooks (found 0 files with ksu_handle_)` 后退出。你贴的日志
在 6 行 `OK` 和最后那行 Error 之间少了这几行，应该是复制时略过了；
`Compile kernel` 显示 skipped，和代码路径完全对得上。

自检拦得对。`builtin` 不注册 kprobes，那几个 hook 调用就是驱动唯一的
入口。没打 hook 编出来的内核能开机，但 SukiSU 永远不会被触发，拿不到
root。与其花 5 分钟编一个死内核，不如在 prepare 就停。

#### 核实过的 builtin 源码

| 事实 | 来源 |
|---|---|
| `kernel_compat.h` 有 `<4.14` 的 `ksu_kernel_read_compat/write_compat`、`<5.7` 的 `#define TWA_RESUME 1`，另有 kvmalloc、strscpy、close_fd、groups_sort | raw 全文 |
| `ksu_main.c` 是 unity build：先 `#include "kernel_compat.h"`，再 include 所有 `.c` | raw 全文 |
| `ksu_handle_execveat` / `ksu_handle_faccessat` / `ksu_handle_stat` 都在 `feature/sucompat.c` 的非 SUSFS 分支定义，签名与官网 `extern` 声明一致 | raw 全文 |
| `ksu_handle_sys_reboot` 在 `runtime/ksud.c` 里**没有定义** | raw 全文 |
| `builtin/kernel/Kconfig` 全文只有 KSU / KPM / SUSFS 系列，**没有** `CONFIG_KSU_TAMPER_SYSCALL_TABLE` | raw 全文 |

最后两条决定补丁怎么写。官网说 ARM64 开
`CONFIG_KSU_TAMPER_SYSCALL_TABLE=y` 就能跳过全部手工 hook——那出自它
引用的 backslashxx/KernelSU 参考表，SukiSU 里没这个选项，照做只是白改
defconfig。官网的 reboot hook 也跳过：符号不存在，插进去只会链接期
`undefined reference`。Android 15 还不需要 `sys_newfstat` 的 ret_hook
（那是 Android 16+）。

#### 三个锚点，来自你这棵 4.4 树

不是照官网模板抄的，逐字核过 `lineage-22.2` 的 raw 文件：

| 文件 / 函数 | 插在哪一行之前 | 调用 |
|---|---|---|
| `fs/exec.c` `do_execveat_common()` | `if (IS_ERR(filename))` | `ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags)` |
| `fs/open.c` `SYSCALL_DEFINE3(faccessat)` | `if (mode & ~S_IRWXO)` | `ksu_handle_faccessat(&dfd, &filename, &mode, NULL)` |
| `fs/stat.c` `SYSCALL_DEFINE4(newfstatat)` | `error = vfs_fstatat(dfd, filename, &stat, flag);` | `ksu_handle_stat(&dfd, &filename, &flag)` |

三个位置都在局部变量声明之后、第一条语句之前。4.4 是 C89 风格，
把 `extern` 声明插进声明区会直接编译失败——所以补丁先用函数签名定位，
再在锚点前插入；找不到锚点就报 `[FAIL] ... anchor not found`，不静默
跳过。插入带 marker，重复运行不叠加。

#### 修掉的两个自己的坑

`apply_compat_patches()` 原来无条件把 `ksu_44_compat.h` 注进所有用到
`TWA_RESUME` / `kernel_read` / `kernel_write` 的 `.c`。在 `old` 上这是对的；
在 `builtin` 上会出事：它自带的 `kernel_compat.h` 已定义同名的
`ksu_kernel_read_compat`（非 static），而我的是 `static inline`，同一个
unity 编译单元里两份定义就是重定义错误。Run #3 被自检提前拦下，这个错
还没暴露。现在脚本检测到自带垫片就跳过注入，日志会打
`builtin kernel_compat.h already provides 4.4 shims; injection skipped`。

另有一句写死的提示 "…or switch to the 'builtin' branch"，在你已经选了
`builtin` 时照样打印，纯属误导，去掉了。

#### 下一轮

```powershell
git add -A
git commit -m "feat: auto-insert builtin manual hooks, skip builtin compat injection"
git push
```

Actions → `Run workflow` → `Use workflow from` 选 `main`，
`SukiSU-Ultra branch` 选 `builtin`（现在是默认值）。prepare 阶段应该出现
`hooked: fs/exec.c` / `fs/open.c` / `fs/stat.c` 三行，自检多一行
`OK  manual hooks present (3 sites)`，然后才进 `Compile kernel`。

缓存已保存，这轮 prepare 约 20 秒，编译 5 分钟左右。若编译再红，
Summary 会列出 `error:` 行，复制给我。

**没验证的**：三处 hook 调用、自带 `kernel_compat.h` 在 4.4 上能否编过、
以及链接期符号是否齐全，全部只在 Run #4 见分晓。本机没有 Linux 内核
工具链，Bash 沙箱无外网，本地只验过 Python 补丁逻辑和 `bash -n`。

---

## 6. 边界，说清楚

- 2026-11-08 跑过三轮：`prepare` 与缓存三轮都成功。**端到端编译尚未成功**。
  Run #1 卡在 `MODULE_IMPORT_NS` / `syscall_fn_t`（5.1），Run #2 卡在
  `TWA_RESUME` 与 `kernel_read/write` 签名（5.3），两次 `Compile kernel`
  都是 exit code 2。Run #3 选了 `builtin`，在 prepare 自检被拦下，
  `Compile kernel` 是 skipped（5.5）。
- 脚本在 Windows 主机上写，本机 Bash 沙箱无外网（`curl` HTTP 000），也没有
  Linux 内核工具链。所有 URL、哈希、defconfig 名、构建命令、AK3 属性都从
  上游 raw 文件核实。**生成的 C 兼容垫片、自动插入的三处 hook 调用、
  `builtin` 自带 compat 层在 4.4 上的表现，全都没有在真实树上编译过**，
  Run #4 才是它们的第一次验证。
- 本地验证过的部分：`bash -n` 语法、配置变量展开、Kconfig 插入只出一行、
  Makefile 匹配、defconfig 去重追加、兼容补丁单测（注入位置、相对路径、
  幂等性、无关文件不变、builtin 分支跳过注入）、hook 插入单测（三处锚点
  命中、插在声明之后锚点之前、幂等、锚点缺失时明确报错）、交付文件全是
  LF 换行。没做 YAML 解析器级语法检查（本机无 PyYAML）。
- `SUKISU_REF=builtin` 现在是默认分支，3 处 hook 由脚本按 4.4 源码锚点
  自动插入，不用你改 C 代码。它带完整 4.4 兼容层（5.4）；代价是这些
  hook 的 C 代码尚未编译验证。`main` 已在 Run #1 证伪，`old` 已证伪
  "最老即最兼容"的假设。
- 刷机有变砖风险。备份 `boot.img` 是唯一的一步回滚，别跳过。
