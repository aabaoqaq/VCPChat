@echo off
setlocal enabledelayedexpansion

echo ========================================
echo VCPChat 前端更新脚本 (后端同款逻辑版)
echo ========================================
echo.

cd /d "%~dp0"

REM ====================================
REM 阶段 0: 环境检查与保护
REM ====================================
echo [阶段 0/4] 环境检查
echo ----------------------------------------

REM 检查当前分支
for /f "tokens=*" %%i in ('git rev-parse --abbrev-ref HEAD') do set CURRENT_BRANCH=%%i
if not "!CURRENT_BRANCH!"=="custom" (
    echo [警告] 当前不在 custom 分支，正在切换...
    git checkout custom >nul 2>&1
    if !errorlevel! neq 0 (
        echo [错误] 无法切换到 custom 分支
        pause
        exit /b 1
    )
    echo [状态] 已切换到 custom 分支
)

REM 检查未提交的更改
git diff --quiet
if !errorlevel! neq 0 (
    echo.
    echo [警告] 检测到未提交的更改：
    git status --short
    echo.
    choice /C YNC /N /M "是否提交这些更改? (Y=提交 N=忽略 C=取消) "
    if errorlevel 3 goto :END
    if errorlevel 2 (
        echo [提示] 你选择了忽略本地更改...
    ) else (
        git add -A
        set /p COMMIT_MSG="请输入提交说明: "
        if "!COMMIT_MSG!"=="" set COMMIT_MSG=本地配置保存
        git commit -m "!COMMIT_MSG!"
        echo [状态] 本地更改已提交
    )
)

echo [状态] 环境准备就绪
echo.

REM ====================================
REM 阶段 1: 同步远程仓库
REM ====================================
echo [阶段 1/4] 同步远程仓库
echo ----------------------------------------

echo [1/2] 获取官方更新 (Upstream)...
git fetch upstream main >nul 2>&1
if !errorlevel! neq 0 (
    echo [错误] 无法连接官方仓库，请检查网络
    pause
    exit /b 1
)

echo [2/2] 检查更新状态...
REM 检查是否有新提交
for /f %%i in ('git rev-list --count custom..upstream/main 2^>nul') do set NEW_COMMITS=%%i

if "!NEW_COMMITS!"=="0" (
    echo [提示] 当前已是最新版本，无需更新
    goto :UPDATE_DEPS
)

echo.
echo [发现新提交] !NEW_COMMITS! 个
echo [官方更新日志]
git log custom..upstream/main --oneline --graph -5
echo.

choice /C YN /T 10 /D Y /N /M "确认要合并官方更新吗? (Y=是 N=否, 10秒自动选是) "
if errorlevel 2 goto :END
echo.

REM 记录合并前的 commit hash，用于后续比对依赖
for /f "tokens=*" %%i in ('git rev-parse HEAD') do set BEFORE_MERGE=%%i

REM ====================================
REM 阶段 2: 合并与冲突处理 (核心)
REM ====================================
echo [阶段 2/4] 合并更新
echo ----------------------------------------

echo [执行] 正在合并 upstream/main...
git merge upstream/main --no-edit >nul 2>&1
set MERGE_EXIT=!errorlevel!

REM 检查是否有冲突 (这是你最想要的逻辑)
git diff --name-only --diff-filter=U >nul 2>&1
set HAS_CONFLICT=!errorlevel!

if !HAS_CONFLICT! equ 0 (
    echo.
    echo ========================================
    echo [警告] 检测到文件冲突！自动合并已暂停。
    echo ========================================
    echo.
    echo [冲突文件列表]
    git status --short | findstr "^UU"
    echo.
    echo [请按以下步骤手动处理]
    echo   1. 打开 VS Code，在左侧源代码管理中查看冲突文件。
    echo   2. 决定保留哪个版本：
    echo      - 保留你的配置: git checkout --ours 文件名
    echo      - 使用官方代码: git checkout --theirs 文件名
    echo   3. 处理完所有文件后:
    echo      git add .
    echo      git commit -m "解决冲突"
    echo.
    echo 脚本已停止，请手动解决冲突后再运行。
    pause
    exit /b 1
)

echo [成功] 代码合并完成，无冲突。
echo.

REM ====================================
REM 阶段 3: 依赖更新 (智能检查)
REM ====================================
:UPDATE_DEPS
echo [阶段 3/4] 检查依赖变化
echo ----------------------------------------

set DEP_UPDATED=0

REM 如果刚才进行了合并，检查 package.json 是否变动
if defined BEFORE_MERGE (
    if exist "package.json" (
        git diff !BEFORE_MERGE! HEAD -- package.json >nul 2>&1
        if !errorlevel! equ 0 (
            echo [发现] package.json 发生变化，依赖可能需要更新。
            choice /C YN /T 10 /D Y /N /M "是否更新 Node.js 依赖? (Y/N, 10秒自动选是) "
            if !errorlevel! equ 1 (
                echo [执行] 正在安装依赖 (npm install)...
                call npm install
                if !errorlevel! equ 0 (
                    set DEP_UPDATED=1
                    echo [成功] 依赖安装完成
                ) else (
                    echo [警告] 依赖安装出现错误，请手动检查。
                )
            )
        ) else (
            echo [提示] package.json 未变化，跳过安装。
        )
    )
) else (
    echo [提示] 未进行代码合并，跳过依赖检查。
)

echo.

REM ====================================
REM 阶段 4: 推送至 GitHub
REM ====================================
echo [阶段 4/4] 推送至 GitHub
echo ----------------------------------------

choice /C YN /N /M "是否将最新代码推送到你的 GitHub? (Y/N) "
if !errorlevel! equ 1 (
    echo [执行] 正在推送...
    git push origin custom
    if !errorlevel! equ 0 (
        echo [成功] 推送完成
    ) else (
        echo [失败] 推送失败，请检查网络或权限
    )
) else (
    echo [提示] 已跳过推送。
)

echo.
echo ========================================
echo        更新流程结束
echo ========================================
echo [当前版本]
git log --oneline -1
echo.

:END
pause
