@echo off
echo ============================================
echo DeepMemo 依赖安装脚本
echo ============================================
echo.

cd /d F:\VCP\VCPChat\VCPDistributedServer\Plugin\DeepMemo

echo [1/4] 清理旧的 node_modules...
if exist node_modules rmdir /s /q node_modules

echo [2/4] 安装纯 JS 依赖...
call npm install dotenv flexsearch cheerio axios --no-optional

echo [3/4] 安装 node-jieba (原生模块)...
call npm install node-jieba --no-optional

echo [4/4] 检查是否需要修复 Spectre 问题...
if exist "node_modules\node-jieba\build" (
    echo 发现编译产物，尝试修复 Spectre 配置...
    pushd node_modules\node-jieba
    call npx node-gyp configure --msvs_version=2022 >nul 2>&1
    for %%f in (build\*.vcxproj) do (
        powershell -NoProfile -Command "(Get-Content '%%f') -replace 'Spectre','false' | Set-Content '%%f'" 2>nul
    )
    call npm rebuild >nul 2>&1
    popd
)

echo.
echo ============================================
echo 安装完成！
echo ============================================
pause