<#
Migração do Bolão da Copa 2026 para Supabase.
Rode este script UMA vez, no PowerShell, depois de já ter rodado o schema.sql
no SQL Editor do Supabase.

Uso (digite você mesmo no terminal, substituindo os valores):
  powershell -ExecutionPolicy Bypass -File ".\migrate.ps1" -ServiceRoleKey "SUA_SERVICE_ROLE_KEY" -AdminPassword "sua-senha-de-admin"

Parâmetros opcionais: -AdminName, -AdminUsername, -SupabaseUrl (já vem com o valor certo por padrão).
#>
param(
  [Parameter(Mandatory=$true)][string]$ServiceRoleKey,
  [Parameter(Mandatory=$true)][string]$AdminPassword,
  [string]$SupabaseUrl = "https://tavgdsylqccinemkstuo.supabase.co",
  [string]$AdminName = "Harvey",
  [string]$AdminUsername = "harvey"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Get-ErrorBody($errRecord) {
  try {
    if ($errRecord.Exception.Response) {
      $stream = $errRecord.Exception.Response.GetResponseStream()
      $reader = New-Object System.IO.StreamReader($stream)
      $body = $reader.ReadToEnd()
      if ($body) { return $body }
    }
  } catch {}
  return $errRecord.Exception.Message
}

$NonBrowserUA = "migrate-script/1.0"

function Invoke-Supa {
  param([string]$Method, [string]$Path, $Body, [hashtable]$ExtraHeaders)
  $headers = @{ apikey = $ServiceRoleKey; Authorization = "Bearer $ServiceRoleKey" }
  if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] } }
  $uri = "$SupabaseUrl$Path"
  if ($null -ne $Body) {
    $json = $Body | ConvertTo-Json -Depth 10 -Compress
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -UserAgent $NonBrowserUA -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($json))
  } else {
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -UserAgent $NonBrowserUA
  }
}

$ACCENTS = @{ 'á'='a';'à'='a';'â'='a';'ã'='a';'ä'='a';'é'='e';'è'='e';'ê'='e';'ë'='e';'í'='i';'ì'='i';'î'='i';'ï'='i';'ó'='o';'ò'='o';'ô'='o';'õ'='o';'ö'='o';'ú'='u';'ù'='u';'û'='u';'ü'='u';'ç'='c';'ñ'='n' }
function Slugify([string]$s) {
  $lower = $s.ToLowerInvariant()
  $out = New-Object System.Text.StringBuilder
  foreach ($ch in $lower.ToCharArray()) {
    $k = [string]$ch
    if ($ACCENTS.ContainsKey($k)) { [void]$out.Append($ACCENTS[$k]) } else { [void]$out.Append($ch) }
  }
  $clean = ($out.ToString() -replace '[^a-z0-9]', '')
  if ($clean.Length -gt 20) { $clean = $clean.Substring(0,20) }
  return $clean
}

function New-RandomPassword([string]$name) {
  $first = Slugify(($name -split ' ')[0])
  if (-not $first) { $first = "part" }
  $digits = Get-Random -Minimum 1000 -Maximum 9999
  return "$first$digits"
}

function Parse-Kickoff([string]$h) {
  if (-not $h -or $h -eq "TBD") { return $null }
  if ($h -match '^(\d{2})/(\d{2})[·.](\d{1,2})h$') {
    $dd = $matches[1]; $mm = $matches[2]; $hh = $matches[3].PadLeft(2,'0')
    return "2026-$mm-${dd}T${hh}:00:00-03:00"
  }
  return $null
}

Write-Host "Carregando dados de .\data\..."
$games        = Get-Content "$scriptDir\data\games.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$participants = Get-Content "$scriptDir\data\participants.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$photos       = Get-Content "$scriptDir\data\photos.json" -Raw -Encoding UTF8 | ConvertFrom-Json

$credentials = New-Object System.Collections.Generic.List[object]

Write-Host "1/5 - Criando usuario admin..."
$adminUsernameSlug = Slugify($AdminUsername)
if (-not $adminUsernameSlug) { $adminUsernameSlug = "admin" }
$adminEmail = "$adminUsernameSlug@bolao.local"
try {
  $adminUser = Invoke-Supa -Method POST -Path "/auth/v1/admin/users" -Body @{ email = $adminEmail; password = $AdminPassword; email_confirm = $true }
  Invoke-Supa -Method POST -Path "/rest/v1/participants?on_conflict=username" -Body @(@{ user_id = $adminUser.id; username = $adminUsernameSlug; name = $AdminName; is_admin = $true }) -ExtraHeaders @{ Prefer = "resolution=merge-duplicates,return=minimal" } | Out-Null
  $credentials.Add([pscustomobject]@{ username = $adminUsernameSlug; password = $AdminPassword; name = "(admin) $AdminName" })
  Write-Host "   ok."
} catch {
  Write-Host "   aviso: $(Get-ErrorBody $_) (talvez o admin ja exista - ok se estiver rerodando)"
}

$participantProps = $participants.PSObject.Properties
$participantCount = ($participantProps | Measure-Object).Count
Write-Host "2/5 - Criando $participantCount usuarios de participantes..."
foreach ($prop in $participantProps) {
  $legacyId = $prop.Name
  $p = $prop.Value
  $nome = $p.name
  $username = (Slugify($nome)) + $legacyId
  $password = New-RandomPassword($nome)
  $email = "$username@bolao.local"
  try {
    $user = Invoke-Supa -Method POST -Path "/auth/v1/admin/users" -Body @{ email = $email; password = $password; email_confirm = $true }
  } catch {
    Write-Host "   aviso: falha ao criar $nome ($username): $(Get-ErrorBody $_)"
    continue
  }
  try {
    Invoke-Supa -Method POST -Path "/rest/v1/participants?on_conflict=legacy_id" -Body @(@{ legacy_id = [int]$legacyId; user_id = $user.id; username = $username; name = $nome; is_admin = $false }) -ExtraHeaders @{ Prefer = "resolution=merge-duplicates,return=minimal" } | Out-Null
  } catch {
    Write-Host "   aviso: usuario $nome criado mas falhou ao inserir participante: $(Get-ErrorBody $_)"
    continue
  }
  $credentials.Add([pscustomobject]@{ username = $username; password = $password; name = $nome })
  Write-Host "   $nome -> $username"
}

Write-Host "3/5 - Inserindo jogos..."
$gamesPayload = $games | ForEach-Object {
  [pscustomobject]@{ id = $_.id; t1 = $_.t1; t2 = $_.t2; s1 = $_.s1; s2 = $_.s2; played = [bool]$_.played; fase = $_.fase; kickoff_at = (Parse-Kickoff $_.h) }
}
$batchSize = 50
try {
  for ($i = 0; $i -lt $gamesPayload.Count; $i += $batchSize) {
    $end = [Math]::Min($i + $batchSize - 1, $gamesPayload.Count - 1)
    $chunk = $gamesPayload[$i..$end]
    Invoke-Supa -Method POST -Path "/rest/v1/games?on_conflict=id" -Body $chunk -ExtraHeaders @{ Prefer = "resolution=merge-duplicates,return=minimal" } | Out-Null
  }
  Write-Host "   $($gamesPayload.Count) jogos inseridos."
} catch {
  Write-Host "   ERRO ao inserir jogos: $(Get-ErrorBody $_)"
  throw
}

Write-Host "4/5 - Inserindo palpites..."
$partsFromDb = Invoke-Supa -Method GET -Path "/rest/v1/participants?select=id,legacy_id"
$legacyToUuid = @{}
foreach ($p in $partsFromDb) { if ($null -ne $p.legacy_id) { $legacyToUuid["$($p.legacy_id)"] = $p.id } }

$betsPayload = New-Object System.Collections.Generic.List[object]
foreach ($prop in $participantProps) {
  $legacyId = $prop.Name
  $uuid = $legacyToUuid["$legacyId"]
  if (-not $uuid) { continue }
  foreach ($betProp in $prop.Value.bets.PSObject.Properties) {
    $gid = $betProp.Name
    $b = $betProp.Value
    $betsPayload.Add([pscustomobject]@{ participant_id = $uuid; game_id = [int]$gid; g1 = $b.g1; g2 = $b.g2 })
  }
}
$batchSize = 500
try {
  for ($i = 0; $i -lt $betsPayload.Count; $i += $batchSize) {
    $end = [Math]::Min($i + $batchSize - 1, $betsPayload.Count - 1)
    $chunk = $betsPayload.GetRange($i, $end - $i + 1)
    Invoke-Supa -Method POST -Path "/rest/v1/bets?on_conflict=participant_id,game_id" -Body $chunk -ExtraHeaders @{ Prefer = "resolution=merge-duplicates,return=minimal" } | Out-Null
  }
} catch {
  Write-Host "   ERRO ao inserir palpites: $(Get-ErrorBody $_)"
  throw
}
Write-Host "   $($betsPayload.Count) palpites inseridos."

Write-Host "5/5 - Subindo fotos..."
foreach ($prop in $photos.PSObject.Properties) {
  $legacyId = $prop.Name
  $dataUrl = $prop.Value
  if ($dataUrl -notmatch '^data:(.*?);base64,(.*)$') { continue }
  $mime = $matches[1]
  $b64 = $matches[2]
  $bytes = [Convert]::FromBase64String($b64)
  $ext = (($mime -split '/')[1]) -replace 'jpeg', 'jpg'
  $path = "p_$legacyId.$ext"
  $uploadHeaders = @{ apikey = $ServiceRoleKey; Authorization = "Bearer $ServiceRoleKey"; "x-upsert" = "true" }
  try {
    Invoke-RestMethod -Method POST -Uri "$SupabaseUrl/storage/v1/object/photos/$path" -Headers $uploadHeaders -UserAgent $NonBrowserUA -ContentType $mime -Body $bytes | Out-Null
  } catch {
    Write-Host "   aviso: falha na foto do participante $legacyId : $(Get-ErrorBody $_)"
    continue
  }
  $publicUrl = "$SupabaseUrl/storage/v1/object/public/photos/$path"
  try {
    Invoke-Supa -Method PATCH -Path "/rest/v1/participants?legacy_id=eq.$legacyId" -Body @{ photo_url = $publicUrl } -ExtraHeaders @{ Prefer = "return=minimal" } | Out-Null
    Write-Host "   foto $legacyId ok"
  } catch {
    Write-Host "   aviso: foto $legacyId subiu mas falhou ao salvar link: $(Get-ErrorBody $_)"
  }
}

$credFile = Join-Path $scriptDir "credenciais.csv"
$credentials | Export-Csv -Path $credFile -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "Migracao concluida!"
Write-Host "Credenciais salvas em: $credFile"
Write-Host "Guarde esse arquivo com cuidado (tem a senha de todo mundo) e depois apague."
