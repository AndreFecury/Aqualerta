<#
  Publica uma versão nova do AquaAlerta para a atualização dentro do app.

  O que faz:
    1. Lê a versão do pubspec.yaml (ex.: 4.7.0+47). O número depois do "+"
       precisa ser MAIOR que o da versão publicada, senão para.
    2. Gera a APK release (mesma assinatura de sempre).
    3. Calcula o SHA-256 e o tamanho.
    4. Atualiza a branch gh-pages (o site): app/aqualerta.apk + versao.json,
       mantendo a página inicial e a Política de Privacidade. A branch é
       reescrita com um único commit (força) para o repositório não crescer
       56 MB a cada versão. A branch main nunca é tocada.

  Uso (PowerShell, dentro da pasta aqualerta_app do clone):
    .\tool\publicar_versao.ps1 -Notas "Correções no mapa"
  Opções:
    -Defines  arquivo com GOOGLE_WEB_CLIENT_ID (padrão:
              Downloads\aqualerta_app_corrigido\build-defines-publico.json).
              NÃO pode ter MAPTILER_KEY: a APK fica pública no site; o app
              recebe a chave do mapa do Supabase depois do login.
    -SemBuild usa a APK já gerada em build\app\outputs\flutter-apk
#>
param(
  [Parameter(Mandatory = $true)][string]$Notas,
  [string]$Defines = "$env:USERPROFILE\Downloads\aqualerta_app_corrigido\build-defines-publico.json",
  [string]$Flutter = "$env:USERPROFILE\Downloads\flutter\bin\flutter.bat",
  [string]$Repo = "https://github.com/AndreFecury/Aqualerta.git",
  [string]$Site = "https://andrefecury.github.io/Aqualerta",
  [switch]$SemBuild
)
$ErrorActionPreference = 'Stop'

# 1. Versão
$linha = (Select-String -Path pubspec.yaml -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
if ($linha -notmatch '^(\d+\.\d+\.\d+)\+(\d+)$') { throw "versão inválida no pubspec: $linha" }
$versao = $Matches[1]; $codigo = [int]$Matches[2]
$publicada = 0
try {
  $atual = Invoke-RestMethod "$Site/versao.json?t=$(Get-Date -UFormat %s)" -TimeoutSec 15
  $publicada = [int]$atual.codigo
} catch { Write-Host "Nenhuma versão publicada ainda (ou site fora do ar)." }
if ($codigo -le $publicada) {
  throw "O pubspec está em +$codigo, mas o site já tem +$publicada. Aumente o número depois do '+' em pubspec.yaml."
}
Write-Host "Publicando $versao (+$codigo); no site hoje: +$publicada"

# 2. Build
$apk = "build\app\outputs\flutter-apk\app-release.apk"
if (-not $SemBuild) {
  if (-not (Test-Path $Defines)) { throw "Arquivo de defines não encontrado: $Defines" }
  if ((Get-Content $Defines -Raw) -match 'MAPTILER_KEY') {
    throw "O arquivo $Defines tem MAPTILER_KEY. A APK publicada não pode levar a chave do mapa."
  }
  & $Flutter build apk --release "--dart-define-from-file=$Defines"
  if ($LASTEXITCODE -ne 0) { throw "flutter build falhou" }
}
if (-not (Test-Path $apk)) { throw "APK não encontrada: $apk" }
if ($SemBuild) { Write-Host "Atenção: -SemBuild usa a APK existente; confira que ela foi gerada sem MAPTILER_KEY." }

# 3. SHA-256 e tamanho
$sha = (Get-FileHash $apk -Algorithm SHA256).Hash.ToLower()
$tamanho = (Get-Item $apk).Length

# 4. Site (gh-pages)
$tmp = Join-Path $env:TEMP ("aqualerta-site-" + [guid]::NewGuid())
git clone -q --depth 1 --branch gh-pages $Repo $tmp
if ($LASTEXITCODE -ne 0) { throw "não consegui baixar a branch gh-pages" }
New-Item -ItemType Directory -Force (Join-Path $tmp 'app') | Out-Null
Copy-Item $apk (Join-Path $tmp 'app\aqualerta.apk') -Force
$manifesto = [ordered]@{
  codigo     = $codigo
  versao     = $versao
  apk        = "$Site/app/aqualerta.apk?v=$codigo"
  sha256     = $sha
  tamanho    = $tamanho
  notas      = $Notas
  publicadoEm = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
# UTF-8 sem BOM (o app lê JSON puro)
[IO.File]::WriteAllText((Join-Path $tmp 'versao.json'), ($manifesto | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))

Push-Location $tmp
try {
  git checkout -q --orphan publicar
  git add -A
  git -c user.name=AndreFecury -c user.email=fecury.andre5@gmail.com commit -q -m "AquaAlerta $versao (+$codigo): $Notas"
  git push -q -f origin publicar:gh-pages
  if ($LASTEXITCODE -ne 0) { throw "push da gh-pages falhou" }
} finally { Pop-Location; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "Publicado: $versao (+$codigo), $([math]::Round($tamanho/1MB)) MB, SHA-256 $sha"
Write-Host "O GitHub Pages leva ~1 minuto. Conferir: $Site/versao.json"
