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
4 处 hook 由 `build.sh` 在 CI 里自动插入，不用你碰 C 代码（见 5.5、5.6）。

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
| `MISSING manual hook in fs/xxx.c` / `[FAIL] ... anchor not found` | 只有 `builtin` 会触发；自动插入时锚点没匹配上 | 贴出 `Inserting manual hooks` 那一段完整输出；5.6 起 `[FAIL]` 前会把该函数真实源码带行号打进日志，`bash ./build.sh hooks` 也可预览 |
| `Prepare sources and self-check` 失败、`Compile kernel` 显示 skipped | 自检主动拦下，编译根本没开始 | 看上面的 `MISSING ...` 行；exit code 1 是脚本 `die`，不是编译器给的 2 |
| `unknown stage` | 阶段名拼错 | 只能用 `prepare` / `hooks` / `build` / `pack` / `all` / `clean` |
| `Process completed with exit code 2.` 单独出现在 `Compile kernel` | 这是 GitHub 给步骤盖的结论章，不是报错正文 | 按上面三条取日志；它只说明 `make` 挂了 |

workflow 已补日志留存：`Prepare sources and self-check` 和 `Compile kernel`
各自用 `tee prepare.log` / `tee build.log` 落盘，`set -o pipefail` 保证
退出码不被管道吃掉；失败时把两个日志的错误行和最后 100 行写进 Summary，
并一起传成 artifact。补 `prepare.log` 是因为 Run #3/#4 都挂在编译之前，
当时连日志文件都没生成。这些改动只作用于**下一次**运行，已经结束的 run
补不上。`workflow_dispatch` 是唯一触发器，所以只是 push 不会自动重跑。

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
  声明正是为了绕过它。我接着又错了一句：说 `ksu_handle_sys_reboot`
  "在 `runtime/ksud.c` 里没有定义，因此跳过 reboot hook"。查全量
  tarball 才知道它定义在 `supercall/supercall.c` 的非 SUSFS 分支
  （SUSFS 分支则在 `supercall/dispatch.c`），`ksud.c` 本来就不该有。
  5.6 把 reboot hook 补回去了。官网原话："Check their exact signatures
  against the branch you build; the patches below are for reference only."
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
| `ksu_handle_sys_reboot` 定义在 `supercall/supercall.c` 的非 SUSFS 分支（**不是** `runtime/ksud.c`）；SUSFS 分支在 `supercall/dispatch.c` | builtin 全量 tarball，见 5.6 |
| `builtin/kernel/Kconfig` 全文只有 KSU / KPM / SUSFS 系列，**没有** `CONFIG_KSU_TAMPER_SYSCALL_TABLE` | raw 全文 |

5.5 写补丁时我漏看了 `supercall/` 目录，据此跳过了 reboot hook。5.6
已补上。官网说 ARM64 开 `CONFIG_KSU_TAMPER_SYSCALL_TABLE=y` 就能跳过
全部手工 hook——那出自它引用的 backslashxx/KernelSU 参考表，SukiSU 里
没这个选项，照做只是白改 defconfig。Android 15 还不需要 `sys_newfstat`
的 ret_hook（那是 Android 16+）。

#### 四个锚点，来自你这棵 4.4 树

不是照官网模板抄的，逐字核过 `lineage-22.2` 的 raw 文件（5.6 又拿
GitHub API 重新拉了一遍真实文件做插入测试）：

| 文件 / 函数 | 插在哪一行之前 | 调用 |
|---|---|---|
| `fs/exec.c` `do_execveat_common()` | `if (IS_ERR(filename))` | `ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags)` |
| `fs/open.c` `SYSCALL_DEFINE3(faccessat)` | `if (mode & ~S_IRWXO)` | `ksu_handle_faccessat(&dfd, &filename, &mode, NULL)` |
| `fs/stat.c` `SYSCALL_DEFINE4(newfstatat)` | `error = vfs_fstatat(dfd, filename, &stat, flag);` | `ksu_handle_stat(&dfd, &filename, &flag)` |
| `kernel/reboot.c` `SYSCALL_DEFINE4(reboot)` | `if (!ns_capable(pid_ns->user_ns, CAP_SYS_BOOT))` | `ksu_handle_sys_reboot(magic1, magic2, cmd, &arg)` |

四个位置都在局部变量声明之后、第一条语句之前。4.4 是 C89 风格，
把 `extern` 声明插进语句之后会直接编译失败——所以补丁先用函数签名定位，
再检查从 `{` 到锚点之间只有声明/注释/空行，最后才插入；找不到锚点
就把该函数真实源码打进日志再 `[FAIL]`，不静默跳过。插入带 marker，
重复运行不叠加。

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

#### 那一轮的结果

按上面的命令 push 后跑出来的就是 Run #4：prepare 在 `fs/open.c` 挂了。
所以下面 5.6 才是当前有效的版本，5.5 的补丁已被替换。

**当时没验证的**：hook 调用、自带 `kernel_compat.h` 在 4.4 上能否编过、
以及链接期符号是否齐全。这些到现在仍然没编过一次。

---

### 5.6 Run #4：一个行尾注释，让锚点匹配落空

日志停在：

```
==> Inserting manual hooks for SUKISU_REF=builtin into the 4.4 tree
[FAIL] fs/open.c: insert anchor 'if (mode & ~S_IRWXO)' not found within 60 lines of 'SYSCALL_DEFINE3(faccessat,'
hooked: fs/exec.c (before 'if (IS_ERR(filename))')
```

注意输出顺序：`hooked: fs/exec.c` 在 `[FAIL]` 之后打印，不是又插了一次。
Python 的 `sys.exit("...")` 走 stderr，`print` 走 stdout，CI 把两路合并时
顺序会错开。真正执行的顺序是先 exec.c 成功、再 open.c 失败、stat.c
根本没轮到。

`exit code 1` 依旧来自脚本自己，不是 `make`。

#### 根因

我写的是整行相等比较：

```python
bi = next((i for i in range(si, min(si + 60, len(lines)))
           if lines[i].strip() == before), None)
```

而这棵 `lineage-22.2` 树的 `fs/open.c:356` 是（`cat -A` 输出，`^I` 是 tab）：

```
^Iif (mode & ~S_IRWXO)^I/* where's F_OK, X_OK, W_OK, R_OK? */$
```

`strip()` 只去掉两端空白，去不掉中间的注释。所以这行的字符串是
`if (mode & ~S_IRWXO)\t/* where's F_OK, X_OK, W_OK, R_OK? */`，
和 `"if (mode & ~S_IRWXO)"` 永远不相等。`fs/exec.c` 的
`if (IS_ERR(filename))` 后面干净，所以它能过——报错只挑一个文件，
正是这个原因。

#### 这次拿到的上游证据

Bash 沙箱这轮能连 GitHub 了（raw 主机偶发 TLS 失败，改用
`api.github.com/repos/.../contents/...?ref=<sha>` 取 base64 内容）：

| 事实 | 证据 |
|---|---|
| `fs/open.c:356` 那行带行尾注释 | 固定 commit `9932c9e...` 的 raw 文件 `cat -A` |
| `fs/exec.c:1544` / `fs/stat.c:297` / `kernel/reboot.c:288` 都是各自函数的第一条语句 | 同一 commit 的四个文件 |
| 官网 4.14 及以下版本的 faccessat 补丁，正是插在 `if (mode & ~S_IRWXO)` 之前 | sukisu.org 集成指南原文 |
| builtin HEAD `1cfa573` 的 `feature/sucompat.h` 非 SUSFS 分支三个签名 | GitHub API 取全文 |
| `ksu_handle_sys_reboot` 在 `supercall/supercall.c:137`（非 SUSFS）与 `supercall/dispatch.c:419`（SUSFS），且 `ksu_main.c:105` 无条件 include `supercall.c` | builtin 分支全量 tarball |
| `builtin/kernel/Kconfig` 与 Makefile 全文都没有 `KSU_TAMPER_SYSCALL_TABLE` / `KSU_HACK_ARM64_BRANCH_LINK` / `KSU_KPROBES_KSUD` | 同上 |

最后一行也说明：官网那段"开个 config 就能跳过全部手工 hook"在这条
分支上不成立，手工 hook 躲不掉。

#### 改了什么

- 锚点改成**前缀匹配**，每个位置可以列多个候选，取最早命中的那条；
  找不到时把函数真实源码带行号打进日志，下一轮不用再来回复制。
- 加 C89 声明顺序自检：从函数 `{` 到插入点之间若出现语句，直接
  `[FAIL]`，不再悄悄插出一段编不过的代码。
- 补 `kernel/reboot.c` 的第四个 hook（5.5 里被我误删的），调用
  `ksu_handle_sys_reboot`。`selfcheck` 相应改成 4 个位置。
- `build.yml` 的 prepare 也 `tee prepare.log`；失败时 `prepare.log` 和
  `build.log` 一起进 Summary 和 artifact。之前 prepare 挂掉时连日志
  文件都没生成，只能靠你手动复制。

#### 本地实测（真源码，不是模拟）

把 `build.sh` 里的 Python 段原样抽出来，对四个**从 GitHub 拉下来的真实
4.4 文件**跑：

```
===== RUN 1 =====
  hooked: fs/exec.c (before 'if (IS_ERR(filename))')
  hooked: fs/open.c (before 'if (mode & ~S_IRWXO)')
  hooked: fs/stat.c (before 'error = vfs_fstatat(dfd, filename, &stat, flag);')
  hooked: kernel/reboot.c (before 'if (!ns_capable(pid_ns->user_ns, CAP_SYS_BOOT))')
===== RUN 2 (idempotency) =====
  already hooked: fs/exec.c
  already hooked: fs/open.c
  already hooked: fs/stat.c
  already hooked: kernel/reboot.c
```

插完的位置逐字查过：`fs/open.c` 的 hook 落在 `unsigned int lookup_flags`
之后、`if (mode & ~S_IRWXO)` 之前；`kernel/reboot.c` 的落在 `int ret = 0`
和注释之后、`if (!ns_capable(...))` 之前。**这验证的是补丁逻辑，不是
C 代码能编过**——本机仍没有 Linux 内核工具链。

#### 那一轮的指令（已执行，结果见 5.8）

```powershell
git add -A
git commit -m "fix: prefix-match hook anchors, add reboot hook, log prepare"
git push
```

Actions → `Run workflow` → `Use workflow from` 选 `main`，
`SukiSU-Ultra branch` 选 `builtin`。prepare 应该出现 4 行 `hooked:` 和
`OK  manual hooks present (4 sites)`，然后才进 `Compile kernel`。
缓存还在，prepare 约 20 秒。**第一次真正编译 C 代码是在这一轮**：
4 处 hook 顺利进了编译，编译器随后停在 `linux/static_call.h`（5.8）。
Summary 先列 `error:` 行，你贴过来的带行号日志就是它。

---

### 5.7 Summary 凭什么"先列 error 行"

这件事不是 GitHub 的开关，是往一个文件里按顺序写 Markdown。

GitHub 给每个 step 注入一个环境变量 `GITHUB_STEP_SUMMARY`，值是一个临时
文件的绝对路径（形如 `/home/runner/work/_temp/_runner_file_commands/
step_summary_<uuid>`）。`>> "$GITHUB_STEP_SUMMARY"` 就是往它**追加**；
job 结束时 GitHub 按**步骤顺序**把各步骤的文件拼成 Summary 页。所以
"谁在上面"只由两件事决定：

1. 哪个步骤第一个写。本 workflow 只有 `Show error lines and log tails
   in job summary` 这一步写 Summary，它必然排在最前面。
2. 同一步骤内部先写什么。这一步跑**两趟**：第一趟遍历两个日志只写
   error 块，第二趟才写所有 tail。

第二点是实测逼出来的。第一版写的是单个循环，每个日志按
"error 块 → tail" 的顺序各写一遍。本地模拟"prepare 成功、compile 失败"
时，Summary 顶部长这样：

```
## prepare.log - error lines
(no line matched ...)
## prepare.log - last 100 lines
...
## build.log - error lines      <- 真正的编译错误被挤到下面
```

prepare 成功也会生成 `prepare.log`，于是它那个空错误块和 100 行 tail
反而排在编译错误前面。改成两趟后，第一趟跳过没有匹配的文件
（`[ -n "$errs" ] || continue`），只有含错误的日志会先写；两份都没匹配
时补一行说明。这样无论挂在哪一步，最顶部一定是第一份含错误的日志。

`grep` 的结果存进变量还有一个好处：一条都没匹配上时不会留下空代码块，
看起来像"日志没抓到"。另外 `prepare.log` / `build.log` 必须先由前面两步
`2>&1 | tee` 落盘，没有 `tee` 就无文件可 grep——Run #1/2 只能靠你手动
复制日志就是这个原因。

**前四次 run 看不到这个效果**：`build.yml` 本身也是仓库文件，
`workflow_dispatch` 把整次运行钉在点击那一刻的 HEAD。旧 run 跑的是
克隆时的旧 workflow，push 之后再点 `Run workflow` 才生效。

Summary 也不在 job 日志页。点运行页左侧菜单的 **Summary**（URL 末尾
没有 `/job/...`），往下滚才是这两个代码块。想 30 秒自测，可以在任意
步骤临时加一行，跑一次看它出现：

```yaml
- run: echo '## smoke test: summary works' >> "$GITHUB_STEP_SUMMARY"
```

---

### 5.8 Run #5：编译器终于见到 C 代码，停在 5.10 的头文件上

这一轮 `Compile kernel` 真的启动了。日志末尾那四行 `Error 2` 不是四个
错误：最内层 `drivers/kernelsu/ksu_main.o` 编译失败，make 沿
`drivers/kernelsu` → `drivers` → 顶层 Makefile 逐级往上冒泡，同一个
退出码被打印了四次。看第一个 `error:` 就行。

```
drivers/kernelsu/kernel_includes.h:76:10: fatal error: 'linux/static_call.h' file not found
```

`kernel_includes.h` 前 75 个 include 全都解析成功了，第 76 行炸。
`static_call` 是 5.10 才进主线的静态调用优化，4.4 树里连这个文件都
没有。同一个文件的第 85 行就写着
`#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)`，第 125 行把
`compiler_types.h` 门控在 `>= 4.14`，第 133 / 138 行把 `sched/*.h` 门控在
`>= 4.11` / `>= 4.10`。作者把版本边界标得很清楚，唯独第 76 行漏在
门控外面，写成无条件包含。

#### 为什么不是补一行就完事

把固定的 4.4 树（`9932c9e...`，57109 个 blob）和 `builtin` HEAD
`1cfa573` 引用的 333 个不同系统头交叉对了一遍，得到 16 个"树里找不到
同名文件"的头。分成三类：

| 类别 | 例子 | 会炸吗 |
|---|---|---|
| 在 `#if` 门控内，4.4 不展开 | `crypto/sha2.h` (>=5.11)、`linux/hex.h` (>=6.4)、`compiler_types.h` (>=4.14)、`sched/task.h` (>=4.10)、`susfs.h` (`CONFIG_KSU_SUSFS`)、`uapi/linux/mount.h` (>=5.0) | 不会 |
| 构建期生成 / uapi 别名 | `generated/compile.h`、`generated/utsrelease.h`、`linux/version.h`、`linux/ioctl.h` | 不会。编译日志第 8、9、72、35 行都过了，编译器找得到它们 |
| **无条件 + 4.4 确实没有** | `linux/static_call.h` (`kernel_includes.h:76`)、`linux/sched/signal.h` (`infra/symbol_resolver.c:5`)、`linux/set_memory.h` (`kpm/compact.c:23`、`kpm/super_access.c:23`) | **会，共 4 行** |

第二类最容易被静态扫描误判：git 树里没有 `include/linux/version.h`，
但 Kbuild 会在构建目录生成它；`linux/ioctl.h` 实际落在
`include/uapi/linux/ioctl.h`，而 uapi 目录也在内核的头文件搜索路径里。
所以判断能不能编，不能只比对源码树的文件名——编译日志本身是更硬的
证据。

第三类为什么躲不掉：`kernel/Makefile` 只有 `ksu-y := ksu_main.o`，
`ksu_main.c` 用 `#include "xxx.c"` 把 40 个 `.c` 拼成**一个翻译单元**
（unity build）。上面四个文件都在这个单元里，任何一行的 include 缺失
都会让整个 `ksu.o` 编不过。修掉 `static_call.h`，下一个 fatal 几乎必然
是 `sched/signal.h`。

#### 注释掉是安全的，依据不是猜

全分支 grep 的结果：没有一处调用 `static_call()`，没有一处调用
`set_memory_*()`，`symbol_resolver.c` 也没用 `sched/signal.h` 才有的类型。
这四行是新版内核的习惯性包含，在 4.4 上是纯噪音。而且
`kernel_includes.h` 已经包含 `<linux/sched.h>`，4.4 的 `signal_struct`
就在那里面。`kernel_includes.h:139` 那个 `<linux/sched/signal.h>` 本身
也包在 `#if >= 4.10` 里——门控正是上游自己的写法。

`build.sh` 新增 `apply_header_gates()`，把这 4 行换成带 marker 的注释，
不去猜一个没核实过的 `KERNEL_VERSION` 阈值。同一个函数里加了
**preflight**：从 `ksu_main.c` 提取 unity 单元，跟踪 `#if` 深度，只对
未被门控的系统头在真实 `KDIR` 里查存在性（含 uapi、arch、generated
搜索路径，生成头走白名单），把找不到的打成 `WARN`。它只诊断、不 fail
——误报不能挡住一轮 5 分钟的编译。

`selfcheck` 相应改成按「文件 + 头」精确检查。这里有个实测踩到的坑：
整文件 grep `sched/signal.h` 会命中 `kernel_includes.h:139` 那行**被
4.10 门控保护**的 include，把合法源码判成失败；按对查就没事。

#### 本地实测（真源码 + 真 4.4 文件清单）

| 场景 | 结果 |
|---|---|
| RUN 1 | 4 行 `gated:`，每个文件 `+3 -1`，无其它改动 |
| RUN 2 | 4 行 `already gated:`，幂等 |
| preflight | 54 个未门控系统头，`OK no ungated header gaps left` |
| marker 在但原 include 又活了 | `[FAIL] ... still live`，exit 1 |
| 上游自行删掉了目标行 | `WARN ... upstream may have fixed it`，继续 |
| selfcheck 三态 | 未修补报 4 条 / 已修补 `ok=1` / 混合只报没补的那一条 |

`bash -n`、4 个内嵌 Python 块语法、全 LF、`git diff --check` 都过。

#### 那一轮的指令（已执行，结果见 5.9）

```powershell
git add -A
git commit -m "fix: gate 5.x-only headers for 4.4, add header preflight"
git push
```

Actions → `Run workflow` → `Use workflow from` 选 `main`，分支 `builtin`。
prepare 应先出 4 行 `gated:` 和 `OK no ungated header gaps left`，再进
`Compile kernel`。

**当时的判断**：第五轮，`builtin` 的 C 代码第一次被编译，撞上 5.10
设施，不是脚本 bug。后面还有一整片没验证过的 5.x API——
`kernel_compat.h` 的垫片、selinux state、KPM、preinit runner。

Run #6 的结果：4 行 header gate 都过了，编译推进到 `cpu_spoof.c`，撞上
`vdso/datapage.h`。那句 `OK no ungated header gaps left` 被证明是**预检
自己的盲区**造成的，5.9 讲根因。止损判断也在 5.9 重新估过。

---

### 5.9 Run #6：预检自己漏了 `vdso/`，以及第一个结构体级不兼容

```
extension/cpu_spoof.c:29:10: fatal error: 'vdso/datapage.h' file not found
```

`vdso/datapage.h` 是 5.x 把 vDSO 数据结构泛型化之后才有的头。4.4 只有
`arch/arm64/include/asm/vdso_datapage.h` 和
`arch/arm64/kernel/vdso/datapage.h`，没有 `include/vdso/`。

**这次先认自己的错**：5.8 加的 preflight 有两个洞，合起来正好把它放了过去。

1. 扫描只保留一张硬编码前缀表（`linux/`、`asm/`、`crypto/` ...），
   `vdso/` 不在表里，这一行**根本没被检查**。
2. 它把任何 `#if` 里的 include 一律当作"4.4 不展开"。可 29 行外面是
   `#if defined(CONFIG_ARM64) || defined(__aarch64__)`——我们编译的就是
   arm64，这个条件为真，include 会被展开。

所以上一轮那句 `OK no ungated header gaps left` 是**在我划定的小圈子里
成立**，不是对整棵源码成立。教训：白名单过滤会制造盲区，条件判断不能
只数括号。

#### 补头文件不管用，这次是结构体不一样

`cpu_spoof.c` 不只是 include 了 vDSO 头，它真的用了里面的东西：

- `struct vdso_time_data`、`vdso->clock_data[CS_HRES_COARSE].clock_mode`
- `struct vdso_data` 的 `clock_mode` 字段
- `struct clocksource` 的 `vdso_clock_mode` 成员
- `enum vdso_clock_mode`

抓固定 4.4 commit 的原文核对：
`arch/arm64/include/asm/vdso_datapage.h:38` 的 `struct vdso_data` 字段是
`cs_cycle_last` / `raw_time_sec` / `xtime_clock_sec` 那一套，**没有**
`clock_mode`；`include/linux/clocksource.h` 里 `vdso_clock_mode` 出现 0 次，
也没有 `enum vdso_clock_mode`。

更关键的一点：4.4 arm64 **确实导出** `vdso_data` 这个符号。如果伪造一份
5.x 布局的 `struct vdso_data` 垫片，`find_kernel_symbol_exact("vdso_data")`
会成功，然后代码按 5.x 偏移往一块真实的 4.4 内存里写 `clock_mode`。
这不是"功能不可用"，是内核内存破坏。**垫片这条路不能走。**

#### 改法：在 4.4 上关掉这个可选扩展

`cpu_spoof` 是 io-only 扩展，作用只是伪装 MIDR / bogomips / hwcap，
不在 root 链路上。`extension.c:528` 只是把
`ksu_extension_cpu_spoof_io` 注册进 ioctl 分发表。所以 `build.sh` 新增
`gate_cpu_spoof()`：在 `#include <linux/version.h>` 之后插入

```c
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 4, 0)
int ksu_extension_cpu_spoof_io(u32 id, void __user *raw)
{
    (void)id; (void)raw;
    return -EOPNOTSUPP;
}
#else
/* ... 上游原文 ... */
#endif
```

符号还在，注册照常，4.4 上调用这个 ioctl 得到 `-EOPNOTSUPP`，预处理阶段
直接跳过整段 5.x 代码。原文件一个字没改，只加头尾两处，带 marker 幂等。

#### 预检改成全量

- 不再按前缀过滤，扫所有 `#include <...>`。
- 条件栈真正求值：把 `LINUX_VERSION_CODE` 换成 `4.4.302` 的数值、
  `KERNEL_VERSION(a,b,c)` 展开成整数、`defined(CONFIG_ARM64)` 等按本次
  配置取真值；支持 `#elif` / `#else` / 嵌套。求不出来的表达式一律当作
  "会展开"，宁可多报也不漏报。
- 头文件搜索路径补齐 ccflags 里的
  `-Isecurity/selinux{,/include}`，以及 `<../fs/mount.h>` 这种通过
  `include/../` 归一化到 `fs/mount.h` 的写法。
- 仍然只诊断、不 fail。误报不能挡住一轮 5 分钟的编译。

全量清单 12 项，分三类：4 项是 5.8 已门控的（在原始源码上扫描所以还在
表里）、6 项是 ccflags / 路径归一化后能解析的（`security.h`、`ss/*.h`、
`../fs/mount.h`）、**2 项是这次真漏的** `vdso/datapage.h` 和
`vdso/clocksource.h`。修完之后：108 个活跃系统头，0 个 WARN。

#### 本地实测

| 项目 | 结果 |
|---|---|
| 顺序执行 gate → header gates → preflight | 1 行 `gated: cpu_spoof`、4 行 header `gated:`、108 个活跃头零 WARN |
| 二次运行 | 5 行 `already gated:`，仍零 WARN |
| **真实 C 预处理器**（`gcc -E`，`LINUX_VERSION_CODE=4.4.302`） | 输出只剩 `ksu_extension_cpu_spoof_io` stub 和 `return -EOPNOTSUPP`，所有 vdso / `clock_data` 代码消失，`#if`/`#endif` 配平，exit 0 |
| 失败路径 | marker 在但缺 `#endif` → exit 1；缺 `version.h` 锚点 → exit 1；分支无此文件 → skip |
| selfcheck | 原始 `cpu_spoof.c` 报 `MISSING 4.4 cpu_spoof stub`，修补后通过 |

`bash -n`、5 个内嵌 Python 块、全 LF、`git diff --check` 都过。

#### 下一轮，以及一个说清楚的边界

```powershell
git add -A
git commit -m "fix: disable cpu_spoof on 4.4, make header preflight exhaustive"
git push
```

Actions → `Run workflow` → `Use workflow from` 选 `main`，分支 `builtin`。
prepare 应出现 `gated: extension/cpu_spoof.c`、4 行 header `gated:`、
`preflight: 108 ...` 和 `OK no active header gaps left`。

**预检的边界**：它只能查"这个头文件在不在"，查不了"这个结构体字段在
不在""这个 API 签名对不对"。`cpu_spoof` 这次就是头文件缺失先暴露、底下
藏着结构体不兼容。后面还有 KPM、version_spoof、selinux、preinit runner
没被编译器碰过，同类问题静态扫不出来。

这是第六轮。目前每次都是撞一个、修一个，且这次已经从"缺个头"升级成
"整个扩展的模型和 4.4 不一样"。如果 Run #7 再冒出三处以上需要裁剪的
功能，就别继续了——那说明 `builtin` 分支压根没把 4.4 当支持目标，
换老 KernelSU non-GKI 路线比继续做减法划算。老包只有出包证据、没有
本机开机验证，换之前要重新核实。

---

## 6. 边界，说清楚

- 到 2026-11-10 跑过六轮，**端到端编译一次都没成功过**。Run #1 卡在
  `MODULE_IMPORT_NS` / `syscall_fn_t`（5.1），Run #2 卡在 `TWA_RESUME`
  与 `kernel_read/write` 签名（5.3），两次 `Compile kernel` 都是 exit 2；
  Run #3 在 prepare 自检被拦下（5.5），Run #4 在 prepare 的 hook 插入
  被拦下（5.6），这两次 `Compile kernel` 是 skipped。Run #5 第一次让
  `builtin` 的 C 代码进编译器，停在 `linux/static_call.h`（5.8）；
  Run #6 推进到 `cpu_spoof.c`，停在 `vdso/datapage.h`（5.9）。
  换句话说：前四轮连编译器都没见到，后两轮每次往前走一小段。
- 脚本在 Windows 主机上写。Bash 沙箱能连 GitHub（raw 主机偶发 TLS
  失败，API 可用），所以 hook 锚点、签名、Kconfig 选项、4.4 头文件树
  都是抓真实上游文件核过的；本机还有 MinGW GCC，可以做 `gcc -E`
  预处理验证。但**没有 Linux 内核工具链**，C 兼容垫片、四处 hook 调用、
  `builtin` 自带 compat 层在 4.4 上的表现，全都没在真实树上编译过。
  能抓源码、能跑预处理器 ≠ 能编译内核。
- 本地验证过的部分：`bash -n` 语法、配置变量展开、Kconfig 插入只出一行、
  Makefile 匹配、defconfig 去重追加、兼容补丁单测、hook 插入**对四个
  真实 4.4 源文件**的实测、头文件门控与 cpu_spoof 裁剪**对真实 builtin
  源码 + 真实 4.4 文件清单**的实测（只改该改的行、幂等、全量 preflight
  108 个活跃头零 WARN、失败路径、selfcheck 各态）、`gcc -E` 证明 4.4
  分支只保留 stub、交付文件全是 LF 换行。没做 YAML 解析器级语法检查
  （本机无 PyYAML）。
- `SUKISU_REF=builtin` 现在是默认分支：4 处 hook 按 4.4 源码锚点自动
  插入，4 行 5.x-only 头被门控，`cpu_spoof` 扩展在 4.4 上返回
  `-EOPNOTSUPP`，不用你改 C 代码。`main` 已在 Run #1 证伪，`old` 已
  证伪"最老即最兼容"的假设。
- **止损线（5.9 重估）**：预检只能查头文件在不在，查不了结构体字段和
  API 签名。Run #6 已经从"缺个头"升级到"整个扩展的模型不匹配"。
  Run #7 若再冒出三处以上需要裁剪的功能，就停手换老 KernelSU non-GKI
  路线，不再做减法。老包只有出包证据、没有本机开机验证，换之前要
  重新核实，不能当现成退路。
- 5.5 里关于 `ksu_handle_sys_reboot` 不存在的结论是错的，5.6 已纠正。
  官网引用的 `CONFIG_KSU_TAMPER_SYSCALL_TABLE` 等选项不属于这条分支，
  手工 hook 没有捷径。
- 官网还提到 `sys_fstatat64` 的 hook："Optionally hook sys_fstatat64 if
  32-bit su is needed"。我们没加。若 Manager 或 su 走 32 位路径才发现
  缺它，那时再补第五个 hook；现在不为了"可能用得上"预先改代码。
- 刷机有变砖风险。备份 `boot.img` 是唯一的一步回滚，别跳过。
