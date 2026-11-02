# install.ps1 - Windows entry point for install.sh.
#
# Finds Git Bash (Git\bin\bash.exe, never the WSL `bash` on PATH) and runs
# install.sh with it, passing every argument through:
#
#   .\install.ps1
#   .\install.ps1 --model claude-sonnet-5-5
#   .\install.ps1 --bash-exe "D:\Tools\Git\bin\bash.exe"
#   .\install.ps1 --uninstall --purge
#
# Works in Windows PowerShell 5.1 and PowerShell 7.

$ErrorActionPreference = 'Stop'

function Find-GitBash {
    # Standard install locations first, so a `git` shim earlier on PATH cannot
    # point the installer at an unexpected bash.exe.
    foreach ($root in @($env:ProgramFiles, $env:ProgramW6432, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs")) {
        if (-not $root) { continue }
        $candidate = Join-Path $root 'Git\bin\bash.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    # Custom locations: walk up from git.exe (Git\cmd, Git\bin, Git\mingw64\bin).
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $dir = Split-Path $git.Source -Parent
        for ($i = 0; $i -lt 4 -and $dir; $i++) {
            $candidate = Join-Path $dir 'bin\bash.exe'
            if ((Test-Path -LiteralPath $candidate) -and (Test-Path -LiteralPath (Join-Path $dir 'usr\bin'))) {
                return $candidate
            }
            $dir = Split-Path $dir -Parent
        }
    }
    return $null
}

$bash = $null
$userBash = [array]::IndexOf($args, '--bash-exe')
if ($userBash -ge 0 -and $userBash + 1 -lt $args.Count) {
    $bash = $args[$userBash + 1]
} else {
    $bash = Find-GitBash
}
if (-not $bash -or -not (Test-Path -LiteralPath $bash)) {
    Write-Error 'Git Bash not found. Install Git for Windows (https://git-scm.com/download/win) or pass --bash-exe <path to Git\bin\bash.exe>.'
    exit 1
}

$installer = (Join-Path $PSScriptRoot 'install.sh') -replace '\\', '/'
Write-Host "Using Git Bash: $bash"

if ($userBash -ge 0 -or $args -contains '--uninstall') {
    & $bash $installer @args
} else {
    & $bash $installer --bash-exe ($bash -replace '\\', '/') @args
}
exit $LASTEXITCODE
