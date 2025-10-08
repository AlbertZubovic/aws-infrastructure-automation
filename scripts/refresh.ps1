$ErrorActionPreference = "Stop"

$KeyName      = "a2-key3"
$Region       = "us-east-1"
$Profile      = "academy"
$PemPathWin   = "$HOME\.ssh\$KeyName.pem"
$LinuxKeyPath = "~/.ssh/$KeyName.pem"

$env:AWS_PROFILE         = $Profile
$env:AWS_DEFAULT_REGION  = $Region
$env:AWS_SDK_LOAD_CONFIG = "1"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$tf   = Join-Path $root "..\terraform"
$ans  = Join-Path $root "..\ansible"
$invPath = Join-Path $ans "inventory.ini"

function Convert-ToWslPath([string]$p) {
  $d = $p.Substring(0,1).ToLower()
  $r = $p.Substring(2).Replace('\','/')
  "/mnt/$d/$r"
}

Push-Location $tf
terraform init -input=false | Out-Null

& terraform apply -refresh-only -auto-approve -input=false -var "key_name=$KeyName" | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Warning "terraform refresh only failed (likely creds missing/expired)."
}

try { $ip = terraform output -raw app_public_ip } catch { $ip = $null }
Pop-Location

if (-not $ip -and (Test-Path $invPath)) {
  $ip = (Get-Content $invPath | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}\b' } |
        ForEach-Object { ($_ -split '\s+')[0] } | Select-Object -First 1)
}

if (-not $ip) { throw "Could not determine app_public_ip." }

if (Test-Path $PemPathWin) {
  $pemWsl = Convert-ToWslPath $PemPathWin
  wsl mkdir -p ~/.ssh | Out-Null
  wsl cp "$pemWsl" ~/.ssh/ 2>$null
  wsl chmod 600 ~/.ssh/$KeyName.pem 2>$null
}

$inv = @"
[app]
$ip ansible_user=ec2-user ansible_ssh_private_key_file=$LinuxKeyPath ansible_python_interpreter=/usr/bin/python3 ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
"@
Set-Content -NoNewline -Path $invPath -Value $inv

"EC2 IP: $ip"
"Inventory written to $invPath"
