@echo off
setlocal enabledelayedexpansion

echo ========================================
echo VCPChat 前端更新脚本 (Nova优化版)
echo ========================================
echo.

cd /d "%~dp0"

REM ====================================
REM 阶段 0: 环境检查
REM ====================================
REM 检查分支
for /f "tokens=*" %%i in ('git rev-parse --abbrev-ref HEAD') do set CURRENT_BRANCH=%%i
if not "!CURRENT_BRANCH!"=="custom" (
    echo [警告] 当前不在 custom 分支，正在切换...
    git checkout custom >nul 2>&1
)

REM 检查未提交更改
git diff --quiet
if !errorlevel! neq 0 (
    echo [状态] 发现本地配置修改，正在自动保存...
    git add -A
    git commit -m "Auto-save: 自动保存配置" >nul
)

echo [状态] 环境检查通过
echo.

REM ====================================
REM 阶段 1: 同步官方代码
REM ====================================
echo [阶段 1/4] 检查更新
echo ----------------------------------------

REM 获取更新
git fetch upstream main >nul 2>&1

REM 检查新提交数量
for /f %%i in ('git rev-list --count custom..upstream/main 2^>nul') do set NEW_COMMITS=%%i

if "!NEW_COMMITS!"=="0" (
    echo [提示] 当前已是最新版本，无需更新。
    goto :CHECK_DEPS
)

echo [发现新版本] 有 !NEW_COMMITS! 个新提交。
echo.

REM ========== Nova优化：显示具体更新内容 ==========
echo ----------------------------------------
echo [更新详情] 新提交列表:
echo ----------------------------------------
git log custom..upstream/main --oneline --no-decorate
echo.

echo ----------------------------------------
echo [更新详情] 改动的文件:
echo ----------------------------------------
git diff custom..upstream/main --stat
echo.
echo ----------------------------------------
REM ========== 优化结束 ==========

REM 询问是否合并（改为30秒，给用户更多时间看）
choice /C YN /T 30 /D Y /N /M "是否合并更新? (Y/N, 30秒默认Y) "
if errorlevel 2 goto :END

REM 记录更新前的状态
for /f "tokens=*" %%i in ('git rev-parse HEAD') do set BEFORE_MERGE=%%i

REM ====================================
REM 阶段 2: 执行合并
REM ====================================
echo.
echo [阶段 2/4] 执行合并
echo ----------------------------------------

git merge upstream/main --no-edit >nul 2>&1
set MERGE_EXIT=!errorlevel!

REM 检查冲突
git diff --name-only --diff-filter=U >nul 2>&1
set HAS_CONFLICT=!errorlevel!

if !HAS_CONFLICT! equ 0 (
    echo.
    echo [严重警告] 检测到文件冲突！
    echo ----------------------------------------
    echo [冲突文件列表]
    git diff --name-only --diff-filter=U
    echo ----------------------------------------
    echo [请手动处理]
    echo 1. 保持 VCP 运行，询问 Nova 分析冲突
    echo 2. 在 VS Code 终端执行 Nova 给出的命令
    echo 3. 处理完后运行: git add . 和 git commit -m "解决冲突"
    echo ----------------------------------------
    pause
    exit /b
)

echo [成功] 合并完成。
echo.

REM ====================================
REM 阶段 3: 依赖检查
REM ====================================
:CHECK_DEPS
echo [阶段 3/4] 依赖检查
echo ----------------------------------------

set NEED_INSTALL=0

if defined BEFORE_MERGE (
    if exist "package.json" (
        git diff !BEFORE_MERGE! HEAD -- package.json >nul 2>&1
        if !errorlevel! equ 0 (
            echo [注意] package.json 发生变化。
            set NEED_INSTALL=1
        )
    )
)

if !NEED_INSTALL! equ 1 (
    choice /C YN /N /M "检测到依赖变更，是否安装依赖? (Y/N) "
    if !errorlevel! equ 1 (
        echo [执行] 正在安装依赖...
        call npm install
    )
) else (
    echo [提示] 依赖无变化，跳过安装。
)

echo.

REM ====================================
REM 阶段 4: 推送备份
REM ====================================
echo [阶段 4/4] 推送备份
echo ----------------------------------------

choice /C YN /N /M "是否推送到你的 GitHub? (Y/N) "
if !errorlevel! equ 1 (
    git push origin custom
    echo [成功] 推送完成
)

echo.
echo ========================================
echo        全部完成
echo ========================================

:END
pause
exit /b