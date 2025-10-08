param(
  [string]$KeyName = "a2-key3",
  [string]$Profile = "academy",
  [string]$Region  = "us-east-1",
  [switch]$Plan,
  [switch]$DeleteKeyPair
)

$ErrorActionPreference = "Stop"

$env:AWS_PROFILE         = $Profile
$env:AWS_DEFAULT_REGION  = $Region
$env:AWS_SDK_LOAD_CONFIG = "1"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$tf   = Join-Path $root "..\terraform"
$localPem = Join-Path $HOME ".ssh\$KeyName.pem"

Push-Location $tf
try {
  terraform init -input=false | Out-Null

  if ($Plan) {
    Write-Host "--Dry Run--" -ForegroundColor Yellow
    terraform plan -destroy -var "key_name=$KeyName"
  }
  else {
    Write-Host "--Real Destroy--" -ForegroundColor Red
    terraform destroy -auto-approve -var "key_name=$KeyName"
  }
}
finally {
  Pop-Location
}

if ($DeleteKeyPair -and -not $Plan) {
  Write-Host "Deleting AWS EC2 key pair '$KeyName'..." -ForegroundColor Yellow
  try { aws ec2 delete-key-pair --key-name $KeyName | Out-Null } catch { Write-Warning $_ }

  if (Test-Path $localPem) {
    Write-Host "Removing local PEM: $localPem" -ForegroundColor Yellow
    Remove-Item -Force $localPem
  }
}

Write-Host "Done." -ForegroundColor Green
