<# :
@cls
@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([System.IO.File]::ReadAllText('%~f0', [System.Text.Encoding]::UTF8))"
exit /b %ERRORLEVEL%
#>

# ==============================================================================
# HLS 自动化加密切片脚本 (动态 GOP 锁定 / 绝对 6 秒切片 / HLS v6 规范)
# ==============================================================================

# ------------------------------------------------------------------------------
# 全局清理辅助函数（报错或中途取消时自动清理垃圾文件）
# ------------------------------------------------------------------------------
function Invoke-CleanupAndExit($dirPath, $message) {
    Write-Host ("`n🧹 [清理机制] " + $message) -ForegroundColor Red
    if (Test-Path $dirPath) {
        Write-Host "正在清理残留的输出文件夹与密钥文件..." -ForegroundColor Yellow
        Pop-Location -ErrorAction SilentlyContinue
        Remove-Item -Path $dirPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "✅ 清理完成！所有临时文件已安全擦除。" -ForegroundColor Green
    }
    Read-Host "`n👉 按 Enter 键退出脚本"
    exit
}

# ------------------------------------------------------------------------------
# 智能语言识别函数 (支持中/英文拓宽匹配，防误判)
# ------------------------------------------------------------------------------
function Parse-TrackLanguage {
    param (
        [string]$MetaLang,   # ffprobe 读出的 language 标签
        [string]$MetaTitle,  # ffprobe 读出的 title 标签
        [string]$FileName    # 文件名（外置文件/内置轨提取）
    )
    
    $targetText = "$MetaLang $MetaTitle $FileName".ToLower()

    # 正则边界：前后可以是 点(.)、下划线(_)、中划线(-)、空格、括号等
    $bStart = "(?:^|[\._\-\s\[\(\]])"
    $bEnd   = "(?:$|[\._\-\s\]\)\.])"

    # 1. 中文匹配模式 (拓宽)
    $zhPattern = "${bStart}(chi|zho|zh|cn|chs|cht|sc|tc|chinese|mandarin|zh-cn|zh-tw|zh-hk|zh-hans|zh-hant|中文|简体|繁體|国语|普通话)${bEnd}"
    
    # 2. 英文匹配模式 (拓宽)
    $enPattern = "${bStart}(eng|en|english|en-us|en-gb)${bEnd}"

    if ($targetText -match $zhPattern) {
        return @{ Code = "zh"; Name = "中文" }
    }
    elseif ($targetText -match $enPattern) {
        return @{ Code = "en"; Name = "English" }
    }
    else {
        return @{ Code = "und"; Name = "未知语言" }
    }
}

# ------------------------------------------------------------------------------
# 第一步：自动识别当前目录下的视频文件 (.mp4 / .mkv)
# ------------------------------------------------------------------------------
$videoFiles = Get-ChildItem -Path $PWD -File | Where-Object { $_.Extension -in '.mp4', '.mkv' }

if ($videoFiles.Count -eq 0) {
    Write-Host "❌ [错误] 当前目录下没有找到任何 .mp4 或 .mkv 视频文件！" -ForegroundColor Red
    Read-Host "`n👉 按 Enter 键退出脚本"
    exit
} elseif ($videoFiles.Count -eq 1) {
    $selectedFile = $videoFiles[0]
    Write-Host ("✅ 自动识别到唯一目标视频: " + $selectedFile.Name) -ForegroundColor Green
} else {
    $selectedFile = $null
    while ($null -eq $selectedFile) {
        Write-Host "`n🔍 识别到当前目录下有多个视频文件，请选择要处理的文件:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $videoFiles.Count; $i++) {
            Write-Host (" [{0}] {1}" -f ($i + 1), $videoFiles[$i].Name)
        }
        $fileChoice = Read-Host "请输入文件对应的序号 (1-$($videoFiles.Count))"
        
        $idx = 0
        if ([int]::TryParse($fileChoice, [ref]$idx) -and $idx -ge 1 -and $idx -le $videoFiles.Count) {
            $selectedFile = $videoFiles[$idx - 1]
            Write-Host ("✅ 已选择视频: " + $selectedFile.Name) -ForegroundColor Green
        } else {
            Write-Host ("⚠️ [输入错误] 无效的序号，请输入 1 到 {0} 之间的数字！" -f $videoFiles.Count) -ForegroundColor Red
        }
    }
}

$inputFileFull = $selectedFile.FullName
$folderName = $selectedFile.BaseName
$outputDir = Join-Path $PWD $folderName

# ------------------------------------------------------------------------------
# 第二步：选择转码模式
# ------------------------------------------------------------------------------
$modeChoice = ""
$validChoices = @("1", "2", "3", "4")

while ($modeChoice -notIn $validChoices) {
    Write-Host "`n=========================================" -ForegroundColor Cyan
    Write-Host "         请选择 HLS 转码模式            " -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "[1] 单码率模式 (1080P)"
    Write-Host "[2] 多码率组合: 480P + 720P + 1080P"
    Write-Host "[3] 多码率组合: 360P + 480P + 720P + 1080P"
    Write-Host "[4] 多码率组合: 360P + 480P + 720P + 1080P + 1440P + 4K"

    $modeChoice = Read-Host "`n请输入模式选项 (1-4)"

    if ($modeChoice -notIn $validChoices) {
        Write-Host "⚠️ [输入错误] 选项无效！请重新输入数字 1、2、3 或 4。" -ForegroundColor Red
    }
}

# ------------------------------------------------------------------------------
# 第三步：媒体深度探查与 GOP 动态计算
# ------------------------------------------------------------------------------
Write-Host "`n🔍 正在深入探查媒体流 (音轨/字幕/帧率) 及硬件环境..." -ForegroundColor Cyan

# 1. 使用 ffprobe 探测媒体流
$probeJsonRaw = & ffprobe -v error -show_streams -print_format json -i $inputFileFull 2>&1 | Out-String
$probeData = $probeJsonRaw | ConvertFrom-Json

$embeddedAudio = @($probeData.streams | Where-Object { $_.codec_type -eq 'audio' })
$embeddedSubs  = @($probeData.streams | Where-Object { $_.codec_type -eq 'subtitle' -and $_.codec_name -notmatch 'pgs|dvd|sup' })

# 2. 动态获取视频 FPS 并精确计算 6 秒 GOP 帧数
$videoStream = $probeData.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
$rawFps = $videoStream.r_frame_rate

if ($rawFps -match "(\d+)/(\d+)") {
    $fps = [double]$matches[1] / [double]$matches[2]
} else {
    $fps = [double]$rawFps
}
$gop = [math]::Round($fps * 6)

Write-Host ("🎬 [帧率检测] 原视频帧率: {0:F2} fps -> 锁定 6 秒精确 GOP: {1} 帧" -f $fps, $gop) -ForegroundColor Green

# 3. 扫描外置音字幕
$extAudioFiles = Get-ChildItem -Path $PWD -File | Where-Object { 
    $_.BaseName -like "$folderName*" -and $_.Extension -in '.mp3', '.aac', '.m4a' -and $_.FullName -ne $inputFileFull 
}
$extSubFiles   = Get-ChildItem -Path $PWD -File | Where-Object { 
    $_.BaseName -like "$folderName*" -and $_.Extension -in '.srt', '.vtt' 
}

$totalAudioCount = $embeddedAudio.Count + $extAudioFiles.Count
$totalSubCount   = $embeddedSubs.Count + $extSubFiles.Count

Write-Host ("🎵 [音频探查] 检测到 {0} 条音轨 (内置: {1}, 外置: {2})" -f $totalAudioCount, $embeddedAudio.Count, $extAudioFiles.Count) -ForegroundColor Green
Write-Host ("📝 [字幕探查] 检测到 {0} 条文本字幕 (内置: {1}, 外置: {2})" -f $totalSubCount, $embeddedSubs.Count, $extSubFiles.Count) -ForegroundColor Green

# 4. 检测 GPU 硬件加速
$hasNvenc = $false
try {
    $encoders = & ffmpeg -hide_banner -encoders 2>&1 | Out-String
    if ($encoders -match "h264_nvenc") { $hasNvenc = $true }
} catch { $hasNvenc = $false }

if ($hasNvenc) {
    Write-Host "⚡ [硬件加速] 成功检测到 NVIDIA NVENC GPU 加速 (预设: p4)！" -ForegroundColor Green
} else {
    Write-Host "💻 [软件编码] 未检测到可用 GPU，采用 CPU 软压 (全分辨率预设: fast)。" -ForegroundColor Yellow
}

# ------------------------------------------------------------------------------
# 第四步：初始化输出文件夹与密钥（随机 Key + 随机 IV 写入 key.info）
# ------------------------------------------------------------------------------
Write-Host ("`n📁 创建输出文件夹: [" + $folderName + "]...") -ForegroundColor Yellow
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }

Push-Location $outputDir

$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

# 生成 16 字节随机密钥
$keyBytes = [byte[]]::new(16)
$rng.GetBytes($keyBytes)
[System.IO.File]::WriteAllBytes("$outputDir\enc.key", $keyBytes)

# 生成 16 字节随机 IV (转成 32 位大写十六进制字符串)
$ivBytes = [byte[]]::new(16)
$rng.GetBytes($ivBytes)
$ivHex = ($ivBytes | ForEach-Object { $_.ToString("X2") }) -join ""

# 写入 key.info (第1行: m3u8中的URI, 第2行: ffmpeg读取的本地路径, 第3行: 随机IV)
$keyInfoContent = "../enc.key`nenc.key`n$ivHex"
[System.IO.File]::WriteAllText("$outputDir\key.info", $keyInfoContent)

# 动态预建子文件夹
$resCountMap = @{ "1"=1; "2"=3; "3"=4; "4"=6 }
$vCount = $resCountMap[$modeChoice]

for ($i = 0; $i -lt $vCount; $i++) { New-Item -ItemType Directory -Path "v$i" -ErrorAction SilentlyContinue | Out-Null }
for ($i = 0; $i -lt $totalAudioCount; $i++) { New-Item -ItemType Directory -Path "a$i" -ErrorAction SilentlyContinue | Out-Null }
for ($i = 0; $i -lt $totalSubCount; $i++) { New-Item -ItemType Directory -Path "s$i" -ErrorAction SilentlyContinue | Out-Null }

Write-Host "✅ 根目录 AES 随机密钥与随机 IV (key.info) 初始化完成！" -ForegroundColor Green

$startConfirm = Read-Host "`n👉 按 Enter 键开始压片 (取消请输入 Q)"
if ($startConfirm -eq "Q" -or $startConfirm -eq "q") {
    Invoke-CleanupAndExit $outputDir "用户在压片前选择取消"
}

# ------------------------------------------------------------------------------
# 第五步：第一阶段——音视频 AES-128 加密切片 (FFmpeg)
# ------------------------------------------------------------------------------
Write-Host "`n🚀 [阶段 1/2] 正在启动 FFmpeg 执行音视频加密切片...\n" -ForegroundColor Yellow

function Get-PadFilter($w, $h) {
    return "scale=w=${w}:h=${h}:force_original_aspect_ratio=decrease,pad=w='if(between(a,1.32,1.35),iw,${w})':h='if(between(a,1.32,1.35),ih,${h})':x='(ow-iw)/2':y='(oh-ih)/2'"
}

$vcodec = if ($hasNvenc) { "h264_nvenc" } else { "libx264" }
$preset = if ($hasNvenc) { "p4" } else { "fast" }

# 1. 组装输入源
$ffmpegInputs = @('-i', $inputFileFull)
foreach ($aFile in $extAudioFiles) { $ffmpegInputs += @('-i', $aFile.FullName) }

# 2. 组装分辨率与码率配置
$vConfigs = @()
switch ($modeChoice) {
    "1" { $vConfigs += @{ w=1920; h=1080; b="5000k"; max="5350k"; buf="7500k" } }
    "2" {
        $vConfigs += @{ w=854;  h=480;  b="1400k"; max="1500k"; buf="2100k" }
        $vConfigs += @{ w=1280; h=720;  b="2800k"; max="3000k"; buf="4200k" }
        $vConfigs += @{ w=1920; h=1080; b="5000k"; max="5350k"; buf="7500k" }
    }
    "3" {
        $vConfigs += @{ w=640;  h=360;  b="800k";  max="850k";  buf="1200k" }
        $vConfigs += @{ w=854;  h=480;  b="1400k"; max="1500k"; buf="2100k" }
        $vConfigs += @{ w=1280; h=720;  b="2800k"; max="3000k"; buf="4200k" }
        $vConfigs += @{ w=1920; h=1080; b="5000k"; max="5350k"; buf="7500k" }
    }
    "4" {
        $vConfigs += @{ w=640;  h=360;  b="800k";  max="850k";  buf="1200k" }
        $vConfigs += @{ w=854;  h=480;  b="1400k"; max="1500k"; buf="2100k" }
        $vConfigs += @{ w=1280; h=720;  b="2800k"; max="3000k"; buf="4200k" }
        $vConfigs += @{ w=1920; h=1080; b="5000k"; max="5350k"; buf="7500k" }
        $vConfigs += @{ w=2560; h=1440; b="9000k"; max="9500k"; buf="13500k" }
        $vConfigs += @{ w=3840; h=2160; b="15000k";max="16000k";buf="22500k" }
    }
}

$splits = ($vConfigs.Count)
$filterComplexParts = @("[0:v]split=$splits" + ((0..($splits-1)) | ForEach-Object { "[v$_]" }) -join "")
for ($i = 0; $i -lt $vConfigs.Count; $i++) {
    $cfg = $vConfigs[$i]
    $filterComplexParts += "[v$i]" + (Get-PadFilter $cfg.w $cfg.h) + "[v${i}out]"
}
$filterComplexStr = $filterComplexParts -join "; "

# 3. 智能解析音频轨道并确定中文优先默认轨
$allAudioTracksObj = @()
for ($i = 0; $i -lt $embeddedAudio.Count; $i++) {
    $langObj = Parse-TrackLanguage -MetaLang $embeddedAudio[$i].tags.language -MetaTitle $embeddedAudio[$i].tags.title
    $allAudioTracksObj += [PSCustomObject]@{ Lang = $langObj.Code; Name = $langObj.Name }
}
foreach ($aFile in $extAudioFiles) {
    $langObj = Parse-TrackLanguage -FileName $aFile.Name
    $allAudioTracksObj += [PSCustomObject]@{ Lang = $langObj.Code; Name = $langObj.Name }
}

$zhAudioFound = ($allAudioTracksObj | Where-Object { $_.Lang -eq "zh" }) -ne $null

$varMapList = @()
$mapArgs    = @()

for ($i = 0; $i -lt $vConfigs.Count; $i++) {
    $cfg = $vConfigs[$i]
    $vTag = "v:$i,name:v$i"
    if ($totalAudioCount -gt 0) { $vTag += ",agroup:audio_main" }
    $varMapList += $vTag

    $mapArgs += @(
        '-map', "[v${i}out]", "-c:v:$i", $vcodec, "-preset:v:$i", $preset,
        "-b:v:$i", $cfg.b, "-maxrate:v:$i", $cfg.max, "-bufsize:v:$i", $cfg.buf
    )
}

$aIdx = 0
for ($i = 0; $i -lt $embeddedAudio.Count; $i++) {
    $track = $allAudioTracksObj[$aIdx]
    $isDefault = if ($zhAudioFound) { $track.Lang -eq "zh" } else { $aIdx -eq 0 }
    $defStr = if ($isDefault) { "YES" } else { "NO" }
    
    # 规范化音轨目录名为 a0, a1 ...
    $varMapList += "a:$aIdx,agroup:audio_main,name:a$aIdx,language:$($track.Lang),default:$defStr"
    $mapArgs += @('-map', "0:a:$i", "-c:a:$aIdx", 'aac', "-b:a:$aIdx", '128k')
    $aIdx++
}

$curAudioInputIdx = 1
foreach ($aFile in $extAudioFiles) {
    $track = $allAudioTracksObj[$aIdx]
    $isDefault = if ($zhAudioFound) { $track.Lang -eq "zh" } else { $aIdx -eq 0 }
    $defStr = if ($isDefault) { "YES" } else { "NO" }
    
    # 规范化音轨目录名为 a0, a1 ...
    $varMapList += "a:$aIdx,agroup:audio_main,name:a$aIdx,language:$($track.Lang),default:$defStr"
    $mapArgs += @('-map', "${curAudioInputIdx}:a:0", "-c:a:$aIdx", 'aac', "-b:a:$aIdx", '128k')
    $aIdx++
    $curAudioInputIdx++
}

$varStreamMapStr = $varMapList -join " "

# 4. 组装底层 GOP 强制锁定参数 (彻底消除 10 秒切片 Bug)
$gopArgs = @(
    '-g', "$gop",
    '-keyint_min', "$gop",
    '-force_key_frames', 'expr:gte(t,n_forced*6)'
)

if ($hasNvenc) {
    $gopArgs += @('-forced-idr', '1', '-no-scenecut', '1')
} else {
    $gopArgs += @('-sc_threshold', '0')
}

# 5. 组装完整的 FFmpeg 命令行
$ffmpegArgs = $ffmpegInputs + @('-filter_complex', $filterComplexStr) + $mapArgs + $gopArgs + @(
    '-f', 'hls', '-hls_time', '6', '-hls_playlist_type', 'vod',
    '-hls_key_info_file', 'key.info',
    '-hls_segment_filename', '%v/slice_%03d.ts',
    '-master_pl_name', 'master.m3u8',
    '-var_stream_map', $varStreamMapStr,
    '%v/prog_index.m3u8'
)

# 执行转码
& ffmpeg $ffmpegArgs

if ($LASTEXITCODE -ne 0) {
    Invoke-CleanupAndExit $outputDir "FFmpeg 音视频转码过程中发生严重错误！"
}

# ------------------------------------------------------------------------------
# 第六步：第二阶段—— master.m3u8 协议升级 (v6) + WebVTT 字幕缝合
# ------------------------------------------------------------------------------
$subMetaList = @()
if ($totalSubCount -gt 0) {
    Write-Host "`n📝 [阶段 2/2] 正在提取与生成 WebVTT 字幕并缝合主索引..." -ForegroundColor Yellow
    
    $allSubTracksObj = @()
    for ($i = 0; $i -lt $embeddedSubs.Count; $i++) {
        $langObj = Parse-TrackLanguage -MetaLang $embeddedSubs[$i].tags.language -MetaTitle $embeddedSubs[$i].tags.title
        $allSubTracksObj += [PSCustomObject]@{ Lang = $langObj.Code; Name = $langObj.Name }
    }
    foreach ($sFile in $extSubFiles) {
        $langObj = Parse-TrackLanguage -FileName $sFile.Name
        $allSubTracksObj += [PSCustomObject]@{ Lang = $langObj.Code; Name = $langObj.Name }
    }
    
    $zhSubFound = ($allSubTracksObj | Where-Object { $_.Lang -eq "zh" }) -ne $null
    $sIdx = 0

    for ($i = 0; $i -lt $embeddedSubs.Count; $i++) {
        $track = $allSubTracksObj[$sIdx]
        $isDefault = if ($zhSubFound) { $track.Lang -eq "zh" } else { $sIdx -eq 0 }
        $defStr = if ($isDefault) { "YES" } else { "NO" }
        
        $subDir = Join-Path $outputDir "s$sIdx"
        $vttPath = Join-Path $subDir "sub.vtt"

        & ffmpeg -hide_banner -loglevel error -y -i $inputFileFull -map "0:s:$i" $vttPath
        
        $subM3u8Content = "#EXTM3U`n#EXT-X-VERSION:6`n#EXT-X-TARGETDURATION:7200`n#EXT-X-MEDIA-SEQUENCE:0`n#EXTINF:7200.000,`nsub.vtt`n#EXT-X-ENDLIST"
        [System.IO.File]::WriteAllText((Join-Path $subDir "prog_index.m3u8"), $subM3u8Content)

        $subMetaList += "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=""subs_main"",NAME=""$($track.Name)"",DEFAULT=$defStr,AUTOSELECT=YES,LANGUAGE=""$($track.Lang)"",URI=""s$sIdx/prog_index.m3u8"""
        $sIdx++
    }

    foreach ($sFile in $extSubFiles) {
        $track = $allSubTracksObj[$sIdx]
        $isDefault = if ($zhSubFound) { $track.Lang -eq "zh" } else { $sIdx -eq 0 }
        $defStr = if ($isDefault) { "YES" } else { "NO" }
        
        $subDir = Join-Path $outputDir "s$sIdx"
        $vttPath = Join-Path $subDir "sub.vtt"

        & ffmpeg -hide_banner -loglevel error -y -i $sFile.FullName $vttPath

        $subM3u8Content = "#EXTM3U`n#EXT-X-VERSION:6`n#EXT-X-TARGETDURATION:7200`n#EXT-X-MEDIA-SEQUENCE:0`n#EXTINF:7200.000,`nsub.vtt`n#EXT-X-ENDLIST"
        [System.IO.File]::WriteAllText((Join-Path $subDir "prog_index.m3u8"), $subM3u8Content)

        $subMetaList += "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=""subs_main"",NAME=""$($track.Name)"",DEFAULT=$defStr,AUTOSELECT=YES,LANGUAGE=""$($track.Lang)"",URI=""s$sIdx/prog_index.m3u8"""
        $sIdx++
    }
}

# 规范化重构 master.m3u8 (自动将标准化目录名 a0/a1 的显示名称重写为 中文/English)
$masterPath = Join-Path $outputDir "master.m3u8"
if (Test-Path $masterPath) {
    $masterLines = [System.IO.File]::ReadAllLines($masterPath)
    $newMaster = @()

    foreach ($line in $masterLines) {
        if ($line -like "#EXT-X-VERSION:*") {
            $newMaster += "#EXT-X-VERSION:6"
            $newMaster += "#EXT-X-INDEPENDENT-SEGMENTS"
            if ($subMetaList.Count -gt 0) {
                foreach ($subTag in $subMetaList) {
                    $newMaster += $subTag
                }
            }
            continue
        }

        # 将 FFmpeg 自动生成的 NAME="a0" / NAME="a1" 替换为真实识别的友好名称（如中文、English）
        if ($line -like "#EXT-X-MEDIA:TYPE=AUDIO*") {
            for ($k = 0; $k -lt $allAudioTracksObj.Count; $k++) {
                $targetFolder = "a$k"
                $friendlyName = $allAudioTracksObj[$k].Name
                if ($line -like "*URI=`"$targetFolder/prog_index.m3u8`"*") {
                    $line = $line -replace 'NAME="[^"]+"', "NAME=`"$friendlyName`""
                }
            }
        }

        if ($line -like "#EXT-X-STREAM-INF:*") {
            if ($totalSubCount -gt 0 -and $line -notmatch 'SUBTITLES=') {
                $line = $line + ',SUBTITLES="subs_main"'
            }
        }

        $newMaster += $line
    }
    [System.IO.File]::WriteAllLines($masterPath, $newMaster)
    Write-Host "✅ 已规范化目录与 master.m3u8 协议，VLC 播放兼容性修复完成！" -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# 第七步：善后清理与成功提示
# ------------------------------------------------------------------------------
$tempKeyInfo = Join-Path $outputDir "key.info"
if (Test-Path $tempKeyInfo) { Remove-Item -Path $tempKeyInfo -Force }

Pop-Location

Write-Host "`n=========================================" -ForegroundColor Green
Write-Host "[成功] HLS 多流解耦加密切片全部完成！" -ForegroundColor Green
Write-Host ("输出路径: " + $outputDir) -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green

Read-Host "`n👉 请按 Enter 键退出脚本"