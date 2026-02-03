REM ====================================
REM 阶段 0: 环境检查
REM ====================================
for /f "tokens=*" %%i in ('git rev-parse --abbrev-ref HEAD') do set CURRENT_BRANCH=%%i
if not "!CURRENT_BRANCH!"=="custom" (
    echo [提示] 当前不在 custom 分支，正在切换...
    git checkout custom >nul 2>&1
)

git diff --quiet
if !errorlevel! neq 0 (
    echo [状态] 发现本地未提交修改，正在自动保存...
    git add -A
    git commit -m "Auto-save: 自动保存本地更改" >nul
)

echo [状态] 环境检查通过
echo.

REM ====================================
REM 阶段 1/4: 同步官方仓库
REM ====================================
echo [阶段 1/4] 检查更新
echo ----------------------------------------

git fetch upstream main >nul 2>&1

for /f %%i in ('git rev-list --count custom..upstream/main 2^>nul') do set NEW_COMMITS=%%i

if "!NEW_COMMITS!"=="0" (
    echo [提示] 当前已是最新版本，无需更新。
    goto :CHECK_DEPS
)

echo [发现新版本] 有 !NEW_COMMITS! 个新提交。
echo.

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

choice /C YN /T 30 /D Y /N /M "是否合并更新? (Y/N, 30秒默认Y) "
if errorlevel 2 goto :END

for /f "tokens=*" %%i in ('git rev-parse HEAD') do set BEFORE_MERGE=%%i

REM ====================================
REM 阶段 2/4: 执行合并
REM ====================================
echo.
echo [阶段 2/4] 执行合并
echo ----------------------------------------

git merge upstream/main --no-edit >nul 2>&1

set "FOUND_CONFLICTS="
for /f "tokens=*" %%i in ('git diff --name-only --diff-filter=U') do (
    set "FOUND_CONFLICTS=%%i"
)

if defined FOUND_CONFLICTS (
    echo.
    echo [重要警告] 检测到文件冲突！
    echo ----------------------------------------
    echo [冲突文件列表]
    git diff --name-only --diff-filter=U
    echo ----------------------------------------
    echo [请手动处理]
    echo 1. 保持 VCP 运行，询问 Nova 分析冲突
    echo 2. 在 VS Code 终端执行 Nova 给出的命令
    echo 3. 处理完成后: git add . 和 git commit -m "解决冲突"
    echo ----------------------------------------
    pause
    exit /b
)
echo [成功] 合并完成，无冲突！
echo.

REM ====================================
REM 阶段 3/4: 依赖检查 (v2.0 修复版)
REM ====================================
:CHECK_DEPS
echo [阶段 3/4] 依赖检查
echo ----------------------------------------

set NEED_NPM_INSTALL=0
set NEED_PIP_INSTALL=0

if defined BEFORE_MERGE (
    if exist "package.json" (
        git diff --quiet !BEFORE_MERGE! HEAD -- package.json
        if !errorlevel! neq 0 (
            echo [检测到] package.json 有变化！
            set NEED_NPM_INSTALL=1
        )
    )
    
    if exist "requirements.txt" (
        git diff --quiet !BEFORE_MERGE! HEAD -- requirements.txt
        if !errorlevel! neq 0 (
            echo [检测到] requirements.txt 有变化！
            set NEED_PIP_INSTALL=1
        )
    )
) else (
    if not exist "node_modules" (
        echo [检测到] node_modules 目录不存在
        set NEED_NPM_INSTALL=1
    )
    
    python -c "import flask, gevent, sounddevice" 2>nul
    if !errorlevel! neq 0 (
        echo [检测到] Python 音频引擎依赖缺失
        set NEED_PIP_INSTALL=1
    )
)

if !NEED_NPM_INSTALL! equ 1 (
    choice /C YN /N /M "检测到 Node.js 依赖变更，是否安装? (Y/N) "
    if !errorlevel! equ 1 (
        echo [执行] 正在安装 Node.js 依赖...
        call npm install
    )
)

if !NEED_PIP_INSTALL! equ 1 (
    choice /C YN /N /M "检测到 Python 依赖变更，是否安装? (Y/N) "
    if !errorlevel! equ 1 (
        echo [执行] 正在安装 Python 依赖...
        pip install -r requirements.txt
    )
)

if !NEED_NPM_INSTALL! equ 0 if !NEED_PIP_INSTALL! equ 0 (
    echo [提示] 依赖无变化，跳过安装。
)

echo.

REM ====================================
REM 阶段 4/4: 推送备份
REM ====================================
echo [阶段 4/4] 推送备份
echo ----------------------------------------

choice /C YN /N /M "是否推送到个人 GitHub? (Y/N) "
if !errorlevel! equ 1 (
    git push origin custom
    echo [成功] 备份已推送
)

echo.
echo ========================================
echo        全部完成
echo ========================================

:END
pause
exit /b