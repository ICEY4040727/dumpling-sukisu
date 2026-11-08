# dumpling-sukisu · 从零编出第一个内核

目标：把 SukiSU-Ultra 编进 OnePlus 5T（代号 `dumpling`）的 4.4.302 内核，产出一个在 TWRP 里能刷的 zip。

适用前提：手机已经刷了 **LineageOS 22.2**，bootloader 已解锁，能进 TWRP 或 fastboot。

---

## 0. 你要做的，和不用做的

**不用做**：不改任何 C 代码、不手动打 hook、不编辑 defconfig、不装 Linux（走路线 A）、不装交叉编译器。

**要做**：把 4 个文件放进一个 GitHub 仓库 → 点一次 Run workflow → 看懂日志 → 下载 zip → 在手机上备份 `boot.img` → 刷 zip → 装 Manager APK 验证。

工程里四个文件：

| 文件 | 干什么 |
|---|---|
| `build.sh` | 主脚本，分 `prepare` / `build` / `pack` 阶段 |
| `toolchain.conf` | 所有已核实的下载 URL、commit 哈希、defconfig 名、编译器版本 |
| `anykernel.sh` | AnyKernel3 的刷入配置，声明设备名和 boot 分区路径 |
| `.github/workflows/build.yml` | GitHub Actions 的一键流程 |

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

### 2.3 跑第一次构建

1. 点仓库顶部的 `Actions` 标签。第一次进来若显示 "Workflows aren't running for this repository"，点那句绿色的 `I understand my workflows, go ahead and enable them`
2. 左侧列表选 `Build dumpling SukiSU kernel`
3. 右侧点开 `Run workflow` 下拉：仓库分支选 `main`，**SukiSU-Ultra branch 保持 `main`**（这是 SukiSU 源码分支，默认走 kprobes，不用手工打 hook）
4. 点绿色的 `Run workflow`，页面刷新出一条黄色转圈的记录，点进去看实时日志

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

| 日志里出现 | 是什么 | 怎么办 |
|---|---|---|
| `download failed: https://...` | 某个源没下下来，`fetch` 会直接停 | 贴出整行 URL，我换源或校验 URL；别自己改 `toolchain.conf` 里的哈希 |
| `self-check failed` 且上面有 `MISSING ...` | 内核树三处改动没落上 | 看是哪条 MISSING，连同上下文贴出来 |
| `fatal error: xxx.h: No such file or directory` / 大量 `error:` 出现在 `Compile kernel` | **4.4.302 与当前 SukiSU `main` 分支不兼容**——这是本工程唯一真正没验证过的环节 | 贴报错前 50 行，判断是缺 backport，还是该换 `builtin` 分支再手工打 hook |
| `No space left on device` | runner 磁盘被工具链和 `out/` 占满 | 贴日志，可以加清理步骤，不是你的操作问题 |
| `/usr/bin/python: bad interpreter` 或 GCC wrapper 报 python 语法错 | Ubuntu 22.04 上 python2 装不上 | 贴日志，我改 workflow 的兼容处理 |
| `MISSING manual hooks` | 只有选了 `builtin` 才会触发 | 换回 `main` 重跑；或先跑 `bash ./build.sh hooks` 打印你这棵树上的真实 hook 位置 |
| `unknown stage` | 阶段名拼错 | 只能用 `prepare` / `hooks` / `build` / `pack` / `all` / `clean` |

---

## 6. 边界，说清楚

- 这套脚本**没有端到端编译过**。它是在 Windows 主机上写的，本机 Bash 沙箱无外网（`curl` 返回 HTTP 000），也没有 Linux 内核工具链。所有 URL、哈希、defconfig 名、构建命令、AK3 属性都是从上游 raw 文件核实来的，但"能不能编到一起"只有第一次 Actions 运行能回答。
- 本地验证过的部分：`bash -n` 语法、配置变量展开、Kconfig 插入只出一行、Makefile 匹配、defconfig 去重追加逻辑、四个文件全是 LF 换行。
- `SUKISU_REF=builtin` 需要在 4.4 源码里手工打 4 个 hook，4.4 是 C89 风格，插错位置就编译失败。**零基础先别碰**，先把 `main` 跑出结果。
- 刷机有变砖风险。备份 `boot.img` 是唯一的一步回滚，别跳过。
