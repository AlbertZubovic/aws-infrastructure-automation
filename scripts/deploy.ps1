$ErrorActionPreference = "Stop"

$KeyName = "a2-key3"
$Region = "us-east-1"
$Profile = "academy"
$PemPathWin = "$HOME\.ssh\$KeyName.pem"
$LinuxKeyPath = "~/.ssh/$KeyName.pem"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$tf   = Join-Path $root "..\terraform"
$ans  = Join-Path $root "..\ansible"

function Convert-ToWslPath([string]$winPath) {
  if (-not $winPath) { throw "Empty path" }
  if ($winPath.Length -lt 3 -or $winPath[1] -ne ':') { throw "Not a drive path: $winPath" }
  $drive = $winPath.Substring(0,1).ToLower()
  $rest  = $winPath.Substring(2).Replace('\','/')
  return "/mnt/$drive/$rest"
}

Push-Location $tf
terraform init -input=false | Out-Null
terraform apply -auto-approve -input=false -var "key_name=$KeyName" | Out-Null
$ip = terraform output -raw app_public_ip
Pop-Location

if (-not (Test-Path $PemPathWin)) { throw "Missing PEM at $PemPathWin" }

$PemPathWsl = Convert-ToWslPath $PemPathWin
wsl mkdir -p ~/.ssh
wsl cp "$PemPathWsl" ~/.ssh/
wsl chmod 600 ~/.ssh/$KeyName.pem

wsl bash -lc "test -f ~/.ssh/$KeyName.pem"
if ($LASTEXITCODE -ne 0) {
  throw "PEM not found in WSL after copy: ~/.ssh/$KeyName.pem"
}

$inventory = @"
[app]
$ip ansible_user=ec2-user ansible_ssh_private_key_file=$LinuxKeyPath ansible_python_interpreter=/usr/bin/python3 ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
"@
$invPath = Join-Path $ans "inventory.ini"
Set-Content -NoNewline -Path $invPath -Value $inventory

Write-Host "EC2 IP: $ip"
Write-Host "Inventory written to $invPath"
