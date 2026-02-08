<#
.SYNOPSIS
  Check local Windows PC readiness for:
    - Installing/using Python with virtual environments (.venv)
    - Calling a mini-LLM over HTTPS (API endpoint)

.DESCRIPTION
  This script checks:
    - OS version & architecture
    - PowerShell version
    - CPU model & core count
    - Installed RAM
    - Free disk space on system drive
    - Presence & version of Python (and whether it's 3.x)
    - Basic outbound HTTPS connectivity to a configurable API host

.PARAMETER TestApiHost
  Hostname of the API endpoint to test (no scheme, just the host).

.PARAMETER RequiredRamGB
  Minimum recommended RAM in GB (default 8).

.PARAMETER RequiredFreeDiskGB
  Minimum recommended free disk space in GB on system drive (default 20).

.EXAMPLE
  .\Check-PythonMiniLLMReadiness.ps1

.EXAMPLE
  .\Check-PythonMiniLLMReadiness.ps1 -TestApiHost "api.openai.com" -RequiredRamGB 12 -RequiredFreeDiskGB 40
#>

[CmdletBinding()]
param(
    [string]$TestApiHost = "api.openai.com",
    [int]$RequiredRamGB = 8,
    [int]$RequiredFreeDiskGB = 20
)

Write-Host "=== Python + Mini-LLM Readiness Check ===" -ForegroundColor Cyan
Write-Host ""

# Helper for PASS/FAIL text
function Write-Result {
    param(
        [string]$Label,
        [bool]$Ok,
        [string]$Detail
    )

    if ($Ok) {
        Write-Host ("[OK]   {0} - {1}" -f $Label, $Detail) -ForegroundColor Green
    } else {
        Write-Host ("[FAIL] {0} - {1}" -f $Label, $Detail) -ForegroundColor Red
    }
}

$overallOk = $true

# --- OS & PowerShell info ---
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $psVersion = $PSVersionTable.PSVersion
} catch {
    Write-Host "Error retrieving OS/PowerShell info: $_" -ForegroundColor Red
    $overallOk = $false
}

if ($os) {
    $is64Bit = $os.OSArchitecture -like "*64*"
    $osOk = $is64Bit
    $osDetail = "{0} ({1})" -f $os.Caption, $os.OSArchitecture
    Write-Result -Label "OS 64-bit" -Ok:$osOk -Detail:$osDetail
    if (-not $osOk) { $overallOk = $false }
}

if ($psVersion) {
    $psOk = ($psVersion.Major -ge 5)
    $psDetail = "PowerShell $psVersion"
    Write-Result -Label "PowerShell version >= 5" -Ok:$psOk -Detail:$psDetail
    if (-not $psOk) { $overallOk = $false }
}

# --- CPU info ---
try {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cpuCores = $cpu.NumberOfLogicalProcessors
    $cpuDetail = "{0} (Logical cores: {1})" -f $cpu.Name.Trim(), $cpuCores
    # No hard fail here; just report.
    Write-Host ("[INFO] CPU - {0}" -f $cpuDetail)
} catch {
    Write-Host "[WARN] Could not retrieve CPU information: $_" -ForegroundColor Yellow
}

# --- RAM ---
if ($os) {
    # TotalVisibleMemorySize is in KB
    $ramGB = [math]::Round(($os.TotalVisibleMemorySize / 1MB), 2)  # KB / (1024*1024) = GB
    $ramOk = ($ramGB -ge $RequiredRamGB)
    $ramDetail = "{0} GB (Required >= {1} GB)" -f $ramGB, $RequiredRamGB
    Write-Result -Label "Installed RAM" -Ok:$ramOk -Detail:$ramDetail
    if (-not $ramOk) { $overallOk = $false }
}

# --- Disk space on system drive ---
try {
    $systemDriveLetter = $env:SystemDrive.TrimEnd(':')
    $sysDrive = Get-PSDrive -Name $systemDriveLetter -ErrorAction Stop
    $freeGB = [math]::Round(($sysDrive.Free / 1GB), 2)
    $diskOk = ($freeGB -ge $RequiredFreeDiskGB)
    $diskDetail = "Free on $($env:SystemDrive): {0} GB (Required >= {1} GB)" -f $freeGB, $RequiredFreeDiskGB
    Write-Result -Label "System drive free space" -Ok:$diskOk -Detail:$diskDetail
    if (-not $diskOk) { $overallOk = $false }
} catch {
    Write-Host "[WARN] Could not retrieve disk information: $_" -ForegroundColor Yellow
    $overallOk = $false
}

# --- Python presence & version ---
$pythonOk = $false
$pythonVersionText = $null
$pythonPath = $null

try {
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd) {
        $pythonPath = $pythonCmd.Source
        $pythonVersionText = (& python --version 2>$null)
    } else {
        # Try 'py' launcher (common on Windows)
        $pyCmd = Get-Command py -ErrorAction SilentlyContinue
        if ($pyCmd) {
            $pythonPath = $pyCmd.Source
            $pythonVersionText = (& py -3 --version 2>$null)
        }
    }
} catch {
    # ignore; handled by checks below
}

if ($pythonVersionText) {
    # Expect something like "Python 3.11.7"
    $match = [regex]::Match($pythonVersionText, "Python\s+(\d+)\.(\d+)\.(\d+)")
    if ($match.Success) {
        $major = [int]$match.Groups[1].Value
        $minor = [int]$match.Groups[2].Value
        $patch = [int]$match.Groups[3].Value

        $pythonOk = ($major -ge 3)
        $pyDetail = "{0} at {1}" -f $pythonVersionText.Trim(), $pythonPath
        Write-Result -Label "Python installed (3.x)" -Ok:$pythonOk -Detail:$pyDetail
    } else {
        Write-Result -Label "Python installed (3.x)" -Ok:$false -Detail:("Unrecognised version string: {0}" -f $pythonVersionText)
    }
} else {
    Write-Result -Label "Python installed (3.x)" -Ok:$false -Detail:"Python not found in PATH (try installing from python.org or Microsoft Store / winget)"
}

if (-not $pythonOk) { $overallOk = $false }

# --- venv module check (if Python present) ---
$venvOk = $false
if ($pythonOk) {
    try {
        # Try a dry-run help call for venv (no environment created)
        $venvHelp = & python -m venv -h 2>$null
        if ($LASTEXITCODE -eq 0 -and $venvHelp) {
            $venvOk = $true
        }
    } catch {
        $venvOk = $false
    }

    $venvDetail = if ($venvOk) { "python -m venv is available." } else { "python -m venv not available or failed test." }
    Write-Result -Label "Python venv support" -Ok:$venvOk -Detail:$venvDetail
    if (-not $venvOk) { $overallOk = $false }
} else {
    Write-Host "[INFO] Skipping venv test because Python 3 is not detected."
}

# --- Basic HTTPS/API connectivity test ---
$apiOk = $false
$apiDetail = ""

if ($TestApiHost -and $TestApiHost.Trim() -ne "") {
    Write-Host ""
    Write-Host "Testing outbound HTTPS connectivity to $TestApiHost:443 ..." -ForegroundColor Cyan
    try {
        # Test-NetConnection is available on Win10+ / Server 2012+
        $tnc = Test-NetConnection -ComputerName $TestApiHost -Port 443 -WarningAction SilentlyContinue
        if ($tnc.TcpTestSucceeded) {
            $apiOk = $true
            $apiDetail = "TCP 443 reachable (RoundTripTime: {0} ms)" -f $tnc.PingReplyDetails.RoundtripTime
        } else {
            $apiOk = $false
            $apiDetail = "TCP 443 NOT reachable (remote host or firewall may block HTTPS)."
        }
    } catch {
        # Fallback simple web request if Test-NetConnection fails
        try {
            $response = Invoke-WebRequest -Uri ("https://{0}" -f $TestApiHost) -Method Head -UseBasicParsing -TimeoutSec 10
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                $apiOk = $true
                $apiDetail = "HTTPS reachable (StatusCode: {0})" -f $response.StatusCode
            } else {
                $apiOk = $false
                $apiDetail = "HTTPS test returned StatusCode: {0}" -f $response.StatusCode
            }
        } catch {
            $apiOk = $false
            $apiDetail = "HTTPS test failed: $_"
        }
    }

    Write-Result -Label "HTTPS connectivity to $TestApiHost" -Ok:$apiOk -Detail:$apiDetail
    if (-not $apiOk) { $overallOk = $false }
} else
{
    Write-Host "[INFO] Skipping API connectivity test (no TestApiHost provided)."
}

Write-Host ""
if ($overallOk) {
    Write-Host "Overall readiness: PASS" -ForegroundColor Green
    Write-Host "You should be able to install Python, create .venv environments, and call a mini-LLM API from this machine (subject to provider-specific requirements)." -ForegroundColor Green
} else {
    Write-Host "Overall readiness: FAIL" -ForegroundColor Red
    Write-Host "Review the FAILED checks above and address them (RAM, disk, Python install, venv, or network) before relying on this machine for mini-LLM work." -ForegroundColor Red
}

Write-Host ""
Write-Host "Tip: After installing Python 3, you can create a virtual environment with:" -ForegroundColor Cyan
Write-Host "  python -m venv .venv" -ForegroundColor Yellow
Write-Host "  .\.venv\Scripts\Activate.ps1" -ForegroundColor Yellow
