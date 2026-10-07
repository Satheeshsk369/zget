$ProgressPreference = 'SilentlyContinue'

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

switch ($env:PROCESSOR_ARCHITECTURE) { "AMD64" { $arch = "x86_64" } "ARM64" { $arch = "aarch64" } "x86" { $arch = "x86" } default { throw "Unsupported architecture: $($env:PROCESSOR_ARCHITECTURE)" } }

$releases = Invoke-RestMethod -Uri "https://api.github.com/repos/Satheeshsk369/zget/releases" -Headers @{ "User-Agent" = "zget-installer" }
if ($releases -is [string]) { $releases = ConvertFrom-Json $releases }

$tag = $null
$binaryName = "zget-$arch-windows.exe"

foreach ($rel in $releases) {
    if ($null -ne $rel.assets) {
        foreach ($asset in $rel.assets) {
            if ($asset.name -eq $binaryName) {
                $tag = $rel.tag_name
                break
            }
        }
    }
    if ($null -ne $tag) { break }
}

if (-not $tag) { throw "Failed to find a release tag with compiled binary: $binaryName" }

$url    = "https://github.com/Satheeshsk369/zget/releases/download/$tag/$binaryName"

$binDir    = Join-Path $env:LOCALAPPDATA "zget\bin"
$dataDir   = Join-Path $env:LOCALAPPDATA "zget"
$configDir = Join-Path $env:APPDATA "zget"
$cacheDir  = Join-Path $env:LOCALAPPDATA "zget\cache"
$dest      = Join-Path $binDir "zget.exe"

New-Item -ItemType Directory -Path $binDir -Force | Out-Null
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
New-Item -ItemType Directory -Path $configDir -Force | Out-Null
New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

$cleanTag = $tag.TrimStart('v')
if (Test-Path $dest) {
    try {
        $installedVer = (& $dest version 2>&1 | Out-String).Trim().TrimStart('v')
        if ($installedVer -and ($installedVer -eq $cleanTag)) {
            Write-Host "zget is already up to date ($installedVer)"
            exit 0
        }
    } catch {}
}

Write-Host "Downloading zget $tag ($arch)"
Invoke-WebRequest -Uri $url -OutFile $dest

$rawUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($null -eq $rawUserPath) {
    $rawUserPath = ""
}

$userPathList = $rawUserPath -split ";" | Where-Object { $_ } | ForEach-Object {
    $pathItem = $_
    try {
        $expanded = [Environment]::ExpandEnvironmentVariables($pathItem).Trim().TrimEnd('\')
        if ($expanded -and [System.IO.Path]::IsPathRooted($expanded)) {
            [System.IO.Path]::GetFullPath($expanded)
        } else {
            $expanded
        }
    } catch {
        $pathItem.Trim().TrimEnd('\')
    }
}
$resolvedBinDir = $binDir.TrimEnd('\')

if ($userPathList -notcontains $resolvedBinDir) {
    $newPath = if ($rawUserPath -eq "") { $binDir } else { $rawUserPath.TrimEnd(';') + ";" + $binDir }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    $env:PATH += ";$binDir"
    
    $signature = '[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
    $type = Add-Type -MemberDefinition $signature -Name "Win32SendMessage" -Namespace "Win32" -PassThru
    $result = [UIntPtr]::Zero
    $type::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$result) | Out-Null
}
Write-Host "zget installed. Open a new terminal or run: zget help"
