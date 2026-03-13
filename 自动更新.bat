@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul

echo ========================================
echo VCPChat 前端更新脚本 (Nova 优化版 v3.1)
echo ========================================
echo.

cd /d "%~dp0"

REM 排除列表文件路径
set "EXCLUDE_FILE=%~dp0.update-exclude.txt"

REM 创建排除列表文件（如果不存在）
if not exist "!EXCLUDE_FILE!" (
    echo # VCPChat 更新排除列表> "!EXCLUDE_FILE!"
    echo # 以下文件/目录的修改不会被提交到 custom 仓库>> "!EXCLUDE_FILE!"
    echo # 每行一个路径>> "!EXCLUDE_FILE!"
    echo.>> "!EXCLUDE_FILE!"
    echo # === 核心配置 ===>> "!EXCLUDE_FILE!"
    echo config.env>> "!EXCLUDE_FILE!"
    echo .update-exclude.txt>> "!EXCLUDE_FILE!"
    echo 自动更新.bat>> "!EXCLUDE_FILE!"
    echo.>> "!EXCLUDE_FILE!"
    echo # === 用户数据 ===>> "!EXCLUDE_FILE!"
    echo AppData/>> "!EXCLUDE_FILE!"
    echo.>> "!EXCLUDE_FILE!"
    echo # === 运行时产物 ===>> "!EXCLUDE_FILE!"
    echo VCPDistributedServer/Plugin/PTYShellExecutor/reports/>> "!EXCLUDE_FILE!"
    echo VCPDistributedServer/Plugin/BladeGame/game_state.json>> "!EXCLUDE_FILE!"
)

REM 确保关键排除项始终存在（兼容旧版 .update-exclude.txt）
call :ENSURE_EXCLUDE_ENTRY "config.env"
call :ENSURE_EXCLUDE_ENTRY ".update-exclude.txt"
call :ENSURE_EXCLUDE_ENTRY "自动更新.bat"

REM ====================================
REM 阶段 0: 环境与安全检查
REM ====================================

REM 确保 upstream 存在
git remote get-url upstream >nul 2>&1
if !errorlevel! neq 0 (
    echo [错误] 未检测到 upstream 远程。
    echo        请先执行: git remote add upstream https://github.com/lioensky/VCPChat.git
    echo.
    goto :END
)

for /f "tokens=*" %%i in ('git rev-parse --abbrev-ref HEAD') do set CURRENT_BRANCH=%%i
if /i not "!CURRENT_BRANCH!"=="custom" (
    echo [提示] 当前分支不是 custom，正在切换...
    git checkout custom
    if !errorlevel! neq 0 (
        echo [错误] 切换到 custom 分支失败。
        goto :END
    )
)

REM 检查未提交修改
git diff --name-only > "%TEMP%\vcpchat_unstaged.txt" 2>nul
git diff --cached --name-only > "%TEMP%\vcpchat_staged.txt" 2>nul
git ls-files --others --exclude-standard > "%TEMP%\vcpchat_untracked.txt" 2>nul

REM 合并所有修改
type "%TEMP%\vcpchat_unstaged.txt" > "%TEMP%\vcpchat_all_changes.txt" 2>nul
type "%TEMP%\vcpchat_staged.txt" >> "%TEMP%\vcpchat_all_changes.txt" 2>nul
type "%TEMP%\vcpchat_untracked.txt" >> "%TEMP%\vcpchat_all_changes.txt" 2>nul
sort "%TEMP%\vcpchat_all_changes.txt" /unique /o "%TEMP%\vcpchat_all_changes.txt" 2>nul

REM 统计文件数量
set FILE_COUNT=0
for /f "usebackq tokens=*" %%a in ("%TEMP%\vcpchat_all_changes.txt") do (
    if not "%%a"=="" set /a FILE_COUNT+=1
)

if !FILE_COUNT! gtr 0 (
    echo.
    echo [状态] 检测到 !FILE_COUNT! 个未提交修改
    echo.
    echo 当前排除列表（不会提交）：
    echo ----------------------------------------
    set EXCLUDE_COUNT=0
    for /f "usebackq tokens=*" %%a in ("!EXCLUDE_FILE!") do (
        set "LINE=%%a"
        REM Trim trailing spaces from exclude entry
        call :TRIM_LINE
        if not "!LINE!"=="" if not "!LINE:~0,1!"=="#" (
            echo   [已排除] !LINE!
            set /a EXCLUDE_COUNT+=1
        )
    )
    if !EXCLUDE_COUNT! equ 0 echo   (无)
    echo ----------------------------------------
    echo.
    
    echo 修改的文件列表：
    echo ----------------------------------------
    set INDEX=0
    for /f "usebackq tokens=*" %%a in ("%TEMP%\vcpchat_all_changes.txt") do (
        if not "%%a"=="" (
            set /a INDEX+=1
            set "CHECK_FILE=%%a"
            call :CHECK_EXCLUDED
            if !IS_EXCLUDED! equ 1 (
                echo   !INDEX!. [已排除] %%a
            ) else (
                echo   !INDEX!. %%a
            )
            set "FILE_!INDEX!=%%a"
        )
    )
    echo ----------------------------------------
    echo.
    
    choice /C YN /N /M "是否需要添加文件到排除列表? (Y/N) "
    if !errorlevel! equ 1 (
        echo.
        echo 输入要排除的文件编号（空格分隔，如: 1 3 5）
        echo 输入 0 取消，输入 all 排除全部
        set /p EXCLUDE_INPUT="排除编号: "
        
        if not "!EXCLUDE_INPUT!"=="0" (
            if /i "!EXCLUDE_INPUT!"=="all" (
                for /f "usebackq tokens=*" %%a in ("%TEMP%\vcpchat_all_changes.txt") do (
                    if not "%%a"=="" echo %%a>> "!EXCLUDE_FILE!"
                )
                echo [完成] 已排除所有文件
            ) else (
                for %%n in (!EXCLUDE_INPUT!) do (
                    if defined FILE_%%n (
                        set "TARGET_FILE=!FILE_%%n!"
                        set "CHECK_FILE=!TARGET_FILE!"
                        call :CHECK_EXCLUDED
                        if !IS_EXCLUDED! equ 0 (
                            echo !TARGET_FILE!>> "!EXCLUDE_FILE!"
                            echo   [已添加排除] !TARGET_FILE!
                        ) else (
                            echo   [已存在] !TARGET_FILE!
                        )
                    )
                )
            )
        )
        echo.
    )
    
    REM 计算需要提交的文件
    set COMMIT_COUNT=0
    for /f "usebackq tokens=*" %%a in ("%TEMP%\vcpchat_all_changes.txt") do (
        if not "%%a"=="" (
            set "CHECK_FILE=%%a"
            call :CHECK_EXCLUDED
            if !IS_EXCLUDED! equ 0 set /a COMMIT_COUNT+=1
        )
    )
    
    if !COMMIT_COUNT! gtr 0 (
        echo [选择] 如何处理 !COMMIT_COUNT! 个未排除的文件?
        echo   1^) 提交到 custom 仓库
        echo   2^) Stash（暂存但不提交）
        echo   3^) 取消更新
        echo.
        choice /C 123 /N /M "请选择 (1/2/3): "
        if !errorlevel! equ 3 goto :END
        if !errorlevel! equ 2 (
            git stash push -u -m "Auto-stash before update"
            if !errorlevel! neq 0 (
                echo [错误] stash 失败
                goto :END
            )
            set DID_STASH=1
        )
        if !errorlevel! equ 1 (
            REM 只添加未排除的文件
            for /f "usebackq tokens=*" %%a in ("%TEMP%\vcpchat_all_changes.txt") do (
                if not "%%a"=="" (
                    set "CHECK_FILE=%%a"
                    call :CHECK_EXCLUDED
                    if !IS_EXCLUDED! equ 0 git add "%%a" >nul 2>&1
                )
            )
            git commit -m "Auto-save: before merge upstream"
        )
    ) else (
        echo [提示] 所有修改均已排除，无需提交
    )
)

echo.
echo [状态] 安全检查通过
echo.

REM ====================================
REM 阶段 1/4: 同步上游并预览
REM ====================================
echo [阶段 1/4] 拉取上游更新
echo ----------------------------------------

git fetch upstream main
if !errorlevel! neq 0 (
    echo [错误] git fetch upstream main 失败。
    goto :RESTORE_AND_END
)

for /f %%i in ('git rev-list --count custom..upstream/main 2^>nul') do set NEW_COMMITS=%%i

if "!NEW_COMMITS!"=="0" (
    echo [提示] 当前已是上游最新版本，无需合并。
    goto :CHECK_DEPS
)

echo [发现新版本] 共 !NEW_COMMITS! 条提交
echo.

echo ----------------------------------------
echo [更新概览] 提交列表:
echo ----------------------------------------
git --no-pager log custom..upstream/main --oneline --no-decorate
echo.

echo ----------------------------------------
echo [更新概览] 变动文件:
echo ----------------------------------------
git --no-pager diff custom..upstream/main --stat
echo.
echo ----------------------------------------

choice /C YN /T 30 /D Y /N /M "是否开始合并? (Y/N, 30秒默认Y) "
if errorlevel 2 goto :RESTORE_AND_END

for /f "tokens=*" %%i in ('git rev-parse HEAD') do set BEFORE_MERGE=%%i

REM ====================================
REM 阶段 2/4: 执行合并
REM ====================================
echo.
echo [阶段 2/4] 执行合并
echo ----------------------------------------

git merge upstream/main --no-edit
if !errorlevel! neq 0 (
    echo.
    echo [注意] 合并返回非 0，可能存在冲突或需要手工处理。
)

set "FOUND_CONFLICTS="
for /f "tokens=*" %%i in ('git diff --name-only --diff-filter=U') do (
    set "FOUND_CONFLICTS=%%i"
)

if defined FOUND_CONFLICTS (
    echo.
    echo [需要处理] 检测到文件冲突:
    echo ----------------------------------------
    git diff --name-only --diff-filter=U
    echo ----------------------------------------
    echo [处理方式建议]
    echo 1. 在 VS Code 中解决冲突
    echo 2. 完成后执行: git add .
    echo 3. 然后执行: git commit -m "Resolve merge conflicts"
    echo ----------------------------------------
    pause
    goto :RESTORE_AND_END
)

echo [成功] 合并完成，无冲突
echo.

REM ====================================
REM 阶段 3/4: 依赖检查
REM ====================================
:CHECK_DEPS
echo [阶段 3/4] 检查依赖
echo ----------------------------------------

set NEED_NPM_INSTALL=0
set NEED_PIP_INSTALL=0

if defined BEFORE_MERGE (
    if exist "package.json" (
        git diff --quiet !BEFORE_MERGE! HEAD -- package.json
        if !errorlevel! neq 0 (
            echo [检测到] package.json 有变化
            set NEED_NPM_INSTALL=1
        )
    )

    if exist "requirements.txt" (
        git diff --quiet !BEFORE_MERGE! HEAD -- requirements.txt
        if !errorlevel! neq 0 (
            echo [检测到] requirements.txt 有变化
            set NEED_PIP_INSTALL=1
        )
    )
) else (
    if exist "package.json" (
        if not exist "node_modules" (
            echo [检测到] node_modules 不存在
            set NEED_NPM_INSTALL=1
        )
    )

    if exist "requirements.txt" (
        python -c "import flask, gevent, sounddevice, pyautogui, uiautomation" 2>nul
        if !errorlevel! neq 0 (
            echo [检测到] Python 依赖可能缺失或不完整
            set NEED_PIP_INSTALL=1
        )
    )
)

if !NEED_NPM_INSTALL! equ 1 (
    choice /C YN /N /M "检测到 Node.js 依赖可能需要更新，是否执行 npm install? (Y/N) "
    if !errorlevel! equ 1 (
        echo [执行] npm install ...
        call npm install
    )
)

if !NEED_PIP_INSTALL! equ 1 (
    choice /C YN /N /M "检测到 Python 依赖可能需要更新，是否执行 pip install -r requirements.txt? (Y/N) "
    if !errorlevel! equ 1 (
        echo [执行] pip install -r requirements.txt ...
        pip install -r requirements.txt
    )
)

if !NEED_NPM_INSTALL! equ 0 if !NEED_PIP_INSTALL! equ 0 (
    echo [提示] 依赖无变化 / 已满足，无需安装
)

echo.

REM ====================================
REM 阶段 4/4: 推送（可选）
REM ====================================
echo [阶段 4/4] 备份 / 推送（可选）
echo ----------------------------------------

echo [选择] 更新完成后你要做什么?
echo   1^) 仅本地备份（创建本地标签，不推送）
echo   2^) 推送到 origin/custom
echo   3^) 跳过（不备份不推送）
echo.
choice /C 123 /N /M "请选择 (1/2/3): "
if !errorlevel! equ 3 (
    echo [提示] 已跳过备份与推送
)
if !errorlevel! equ 2 (
    git push origin custom
    if !errorlevel! neq 0 (
        echo [错误] 推送失败，请检查网络/权限。
        goto :RESTORE_AND_END
    )
    echo [成功] 推送完成
)
if !errorlevel! equ 1 (
    for /f %%i in ('powershell -NoProfile -Command "(Get-Date).ToString(\"yyyyMMdd-HHmmss\")"') do set "BACKUP_TS=%%i"
    set "BACKUP_TAG=backup/custom-!BACKUP_TS!"
    git tag "!BACKUP_TAG!" >nul 2>&1
    if !errorlevel! neq 0 (
        echo [错误] 创建本地备份标签失败，请检查 git 状态。
        goto :RESTORE_AND_END
    )
    echo [成功] 已创建本地备份标签: !BACKUP_TAG!
    echo [恢复示例] git checkout !BACKUP_TAG!
)

:RESTORE_AND_END
if defined DID_STASH (
    echo.
    echo [提示] 你之前做了 stash。合并完成后如需恢复，请执行:
    echo        git stash list
    echo        git stash pop
)

echo.
echo ========================================
echo            全部完成
echo ========================================

REM 清理临时文件
del "%TEMP%\vcpchat_*.txt" 2>nul

echo.
echo [当前版本]
git --no-pager log --oneline -1
echo.
echo [排除列表位置] !EXCLUDE_FILE!
echo.

:END
pause
exit /b

REM ====================================
REM 子函数: 检查文件是否在排除列表中
REM 输入: CHECK_FILE 变量
REM 输出: IS_EXCLUDED 变量 (0 或 1)
REM ====================================
:CHECK_EXCLUDED
set "IS_EXCLUDED=0"
for /f "usebackq tokens=*" %%b in ("!EXCLUDE_FILE!") do (
    set "EX_LINE=%%b"
    REM Trim trailing spaces
    call :TRIM_EX
    if not "!EX_LINE!"=="" if not "!EX_LINE:~0,1!"=="#" (
        REM Check if exclude entry ends with / (directory prefix)
        if "!EX_LINE:~-1!"=="/" (
            REM Directory prefix match: check if file path starts with this prefix
            echo !CHECK_FILE! | findstr /B /C:"!EX_LINE!" >nul 2>&1
            if !errorlevel! equ 0 set "IS_EXCLUDED=1"
        ) else (
            REM Exact match
            if "!CHECK_FILE!"=="!EX_LINE!" set "IS_EXCLUDED=1"
        )
    )
)
goto :EOF

REM ====================================
REM 子函数: Trim trailing spaces from EX_LINE
REM ====================================
:TRIM_EX
if "!EX_LINE!"=="" goto :EOF
if "!EX_LINE:~-1!"==" " (
    set "EX_LINE=!EX_LINE:~0,-1!"
    goto :TRIM_EX
)
goto :EOF

REM ====================================
REM 子函数: Trim trailing spaces from LINE
REM ====================================
:TRIM_LINE
if "!LINE!"=="" goto :EOF
if "!LINE:~-1!"==" " (
    set "LINE=!LINE:~0,-1!"
    goto :TRIM_LINE
)
goto :EOF

REM ====================================
REM 子函数: 确保排除项存在（不存在则追加）
REM 输入: %~1 条目内容
REM ====================================
:ENSURE_EXCLUDE_ENTRY
set "ENTRY=%~1"
findstr /X /C:"%~1" "!EXCLUDE_FILE!" >nul 2>&1
if !errorlevel! neq 0 (
    echo %~1>> "!EXCLUDE_FILE!"
)
goto :EOF
