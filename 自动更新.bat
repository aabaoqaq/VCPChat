@echo off
setlocal enabledelayedexpansion
REM 切换到 UTF-8 编码，防止中文乱码
chcp 65001 >nul 2>&1

echo ========================================
echo        VCPChat 前端自动更新 (防覆盖版)
echo ========================================
echo.

cd /d "%~dp0"

REM ----------------------------------------
REM 1. 确保在 custom 分支
REM ----------------------------------------
for /f "tokens=*" %%i in ('git rev-parse --abbrev-ref HEAD') do set CURRENT_BRANCH=%%i
if not "!CURRENT_BRANCH!"=="custom" (
    echo [状态] 当前在 !CURRENT_BRANCH! 分支，正在切换到 custom...
    git checkout custom 2>nul
    if !errorlevel! neq 0 (
        echo [错误] 无法切换分支，请先尝试手动运行: git checkout -b custom
        pause
        exit /b
    )
)

REM ----------------------------------------
REM 2. 保护你的本地修改 (放入保险箱)
REM ----------------------------------------
git diff --quiet
if !errorlevel! neq 0 (
    echo [保护] 检测到你有修改配置文件，正在自动保存...
    git add -A
    git commit -m "Auto-save: 自动保存本地配置" >nul
    echo [成功] 本地配置已保存。
)

REM ----------------------------------------
REM 3. 获取官方最新代码
REM ----------------------------------------
echo.
echo [1/3] 正在获取官方更新...
git fetch upstream main

REM ----------------------------------------
REM 4. 合并代码 (冲突时优先保留你的)
REM ----------------------------------------
echo [2/3] 正在合并更新...
git merge upstream/main --no-edit 2>nul
set MERGE_EXIT=!errorlevel!

if !MERGE_EXIT! neq 0 (
    echo.
    echo [注意] 发现配置文件冲突！
    echo [处理] 正在强制保留你的配置...
    
    REM === 核心魔法：遇到冲突，强制保留“我”的版本 ===
    git checkout --ours .
    git add .
    git commit -m "Merge fix: 强制保留本地配置" >nul
    
    echo [成功] 已解决冲突，你的配置未被覆盖。
) else (
    echo [成功] 代码合并完成，无冲突。
)

REM ----------------------------------------
REM 5. 更新依赖 (npm install)
REM ----------------------------------------
echo.
echo [3/3] 检查依赖库...
if exist "package.json" (
    echo 正在运行 npm install...
    call npm install
)

REM ----------------------------------------
REM 6. 备份到你的 GitHub
REM ----------------------------------------
echo.
echo [同步] 正在推送到你的 GitHub...
git push origin custom

echo.
echo ========================================
echo        更新完毕！
echo ========================================
pause
