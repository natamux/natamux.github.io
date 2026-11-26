# Installs or updates the Natamux desktop app on Windows.
# Usage, in PowerShell: irm https://natamux.github.io/install.ps1 | iex
# A fixed version: $env:NATAMUX_VERSION = 'v1.1.0' first, then the same command.
# macOS, Debian and Ubuntu: curl -fsSL https://natamux.github.io/install.sh | sh
# Source: https://github.com/lenhatthanh20/natamux/blob/main/site/public/install.ps1

# Get-Sum <file name> <SHA256SUMS.txt>: the expected hash, $null when the file has no line.
function Get-Sum($name, $sums) {
  foreach ($line in Get-Content $sums) {
    $parts = $line -split '\s+', 2
    if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -ceq $name) { return $parts[0].ToLower() }
  }
}

function Test-Signature($sums, $sig, $signer, $tag) {
  $out = & minisign -Vm $sums -x $sig -P $signer 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0) { throw "The signature of SHA256SUMS.txt is not valid. Nothing was installed. $out" }
  if ($out -notcontains "Trusted comment: natamux $tag") {
    throw "SHA256SUMS.txt is signed for another version, not $tag. Nothing was installed."
  }
}

# The CPU type of Windows itself. RuntimeInformation.OSArchitecture is empty in Windows
# PowerShell 5.1 on some Windows 11 PCs. PROCESSOR_ARCHITEW6432 is set in a 32-bit PowerShell.
function Get-OSArch {
  if ($env:PROCESSOR_ARCHITEW6432) { return $env:PROCESSOR_ARCHITEW6432 }
  $env:PROCESSOR_ARCHITECTURE
}

# Smart App Control blocks every unsigned program, with no "Run anyway". 1 = on.
function Get-SmartAppControl {
  try { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction Stop).VerifiedAndReputablePolicyState }
  catch { $null }
}

$SmartAppControlHelp = 'Natamux is not code signed yet, and Smart App Control blocks unsigned apps. ' +
  'Turn it off in Windows Security > App & browser control > Smart App Control, then run the command again. ' +
  'See https://natamux.github.io/docs/help/troubleshooting/#smart-app-control-blocks-natamux'

function Install-Natamux {
  $ErrorActionPreference = 'Stop'
  # Windows PowerShell 5.1 downloads many times slower while it draws the progress bar.
  $ProgressPreference = 'SilentlyContinue'
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $repo = 'https://github.com/lenhatthanh20/natamux'
  # The same key as RELEASE_SIGNER in crates/natamux-update/src/signature.rs.
  $signer = 'RWSgtwsXHppEP5n4kgg1Q3yNIYODQNGsMQBKF93tjSRwzL1BrjeGoBpo'
  $file = 'Natamux-win-x64.exe'

  $build = [Environment]::OSVersion.Version.Build
  if ($build -lt 17763) { throw "Natamux needs Windows 10 version 1809 or later. This is build $build." }
  $arch = Get-OSArch
  if ($arch -eq 'ARM64') { Write-Warning 'Windows on Arm runs the x64 app. It is not tested.' }
  elseif ($arch -ne 'AMD64') { throw "Natamux needs 64-bit Windows. This is $arch." }
  if ((Get-SmartAppControl) -eq 1) { throw "Smart App Control is on. $SmartAppControlHelp" }
  if (Get-Process natamux-app -ErrorAction SilentlyContinue) { throw 'Quit Natamux, then run the command again.' }

  # One tag for every file, so a release published during the run cannot mix two versions.
  if ($env:NATAMUX_VERSION) { $tag = $env:NATAMUX_VERSION }
  else { $tag = (Invoke-RestMethod 'https://api.github.com/repos/lenhatthanh20/natamux/releases/latest').tag_name }
  if ($tag -cnotmatch '^v\d+\.\d+\.\d+$') { throw "Unexpected release tag '$tag'. NATAMUX_VERSION must look like v1.1.0." }
  $base = "$repo/releases/download/$tag"
  $tmp = Join-Path ([IO.Path]::GetTempPath()) "natamux-install-$([guid]::NewGuid())"
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    $exe = Join-Path $tmp $file
    $sums = Join-Path $tmp 'SHA256SUMS.txt'
    Write-Host "Downloading $file of Natamux $tag..."
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$file" -OutFile $exe
    Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS.txt" -OutFile $sums
    if (Get-Command minisign -ErrorAction SilentlyContinue) {
      $sig = "$sums.minisig"
      Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS.txt.minisig" -OutFile $sig
      Test-Signature $sums $sig $signer $tag
      Write-Host 'Signature checked.'
    } else {
      Write-Warning 'The release signature was not checked, because minisign is not installed (scoop install minisign).'
    }
    $want = Get-Sum $file $sums
    if (-not $want) { throw "SHA256SUMS.txt has no line for $file." }
    if ((Get-FileHash $exe -Algorithm SHA256).Hash.ToLower() -ne $want) {
      throw "$file does not match SHA256SUMS.txt. Nothing was installed."
    }
    Write-Host 'Checksum checked.'
    # The Windows twin of the macOS quarantine flag: SmartScreen stops a file that has it.
    Unblock-File $exe
    try { $run = Start-Process -FilePath $exe -ArgumentList '/S' -Wait -PassThru }
    catch {
      if ("$_" -match 'Application Control') { throw "Windows blocked the installer. $SmartAppControlHelp" }
      throw
    }
    if ($run.ExitCode -ne 0) { throw "The installer stopped with exit code $($run.ExitCode)." }
    $app = Join-Path $env:LOCALAPPDATA 'Programs\Natamux\natamux-app.exe'
    Write-Host "Natamux $tag is installed in $app. Start it from the Start menu."
  } finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
}

# All code above is functions, so a download cut short runs nothing. CI sets
# NATAMUX_INSTALL_DRY to test the functions.
if ($env:NATAMUX_INSTALL_DRY -ne '1') { Install-Natamux }
