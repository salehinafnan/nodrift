# PowerShell Script to Sync V5_utils.js with the inlined sections in V5.html and V5.test.html
# This lets you keep all utility functions in one place (V5_utils.js) during development, 
# and compile them into 100% self-contained single files with a single double-click.

$UtilsPath = Join-Path $PSScriptRoot "utils.js"
if (-not (Test-Path $UtilsPath)) {
    $UtilsPath = Join-Path $PSScriptRoot "V5_utils.js"
}
$AppPath = Join-Path $PSScriptRoot "index.html"
if (-not (Test-Path $AppPath)) {
    $AppPath = Join-Path $PSScriptRoot "V5.html"
}
$TestPath = Join-Path $PSScriptRoot "index.test.html"
if (-not (Test-Path $TestPath)) {
    $TestPath = Join-Path $PSScriptRoot "V5.test.html"
}

if (-not (Test-Path $UtilsPath)) {
    Write-Error "V5_utils.js not found!"
    exit 1
}

# Read utility content
$UtilsContent = Get-Content -Raw -Path $UtilsPath
# Normalize line endings to Windows style CR-LF
$UtilsContent = $UtilsContent -replace "\r?\n", "`r`n"

# Define the replacement pattern
# Matches everything between the start comment block and the closing script tag
$StartBlock = "// ==========================================[\s\S]*?// V5 UTILITY FUNCTIONS \(INLINED\)[\s\S]*?// =========================================="
$Pattern = "(?s)($StartBlock).*?(?=\s*<\/script>)"

function Sync-File {
    param (
        [string]$FilePath
    )
    if (Test-Path $FilePath) {
        $FileContent = Get-Content -Raw -Path $FilePath
        if ($FileContent -match $StartBlock) {
            # Inject the utility code directly
            $NewContent = [System.Text.RegularExpressions.Regex]::Replace($FileContent, $Pattern, "`$1`r`n$UtilsContent")
            Set-Content -Path $FilePath -Value $NewContent -NoNewline
            Write-Host "Successfully synced inlined utilities in: $(Split-Path $FilePath -Leaf)" -ForegroundColor Green
        } else {
            Write-Warning "No inlined utility block found in: $(Split-Path $FilePath -Leaf)"
        }
    }
}

Sync-File -FilePath $AppPath
Sync-File -FilePath $TestPath
