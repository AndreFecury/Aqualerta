<#
.SYNOPSIS
  Exporta um backup do banco do AquaAlerta (Supabase) para uma pasta FORA do repositório.

.DESCRIPTION
  O plano Free do Supabase não tem backup automático. Este script, rodado à mão
  no PC do dono, faz um pg_dump (formato custom, restaurável com pg_restore):

    padrão     só a configuração: regiões, estações, estações de chuva, config
               do ar, sensores OpenAQ e limites da saúde. Sem dado pessoal.
    -Completo  o schema public inteiro (estrutura + dados), menos os dados de
               chuva_ped_token (credencial) e spatial_ref_sys. CONTÉM DADOS
               PESSOAIS (perfis, tokens de push, regiões seguidas): guarde com
               cuidado e não suba para lugar nenhum.

  A senha do banco é digitada na hora (não aparece na tela), vai só para o
  processo do pg_dump pela variável PGPASSWORD e é apagada no fim. Nada é
  gravado no repositório.

  Usa o pg_dump local se houver um da versão 17 ou mais nova; senão, roda a
  imagem oficial postgres:17-alpine no Docker.

.PARAMETER Servidor
  Host do "Session pooler" (painel do Supabase > Connect > Session pooler),
  algo como aws-0-<região>.pooler.supabase.com. A conexão direta
  (db.<ref>.supabase.co) é só IPv6 no plano Free.

.EXAMPLE
  .\tool\exportar_backup.ps1 -Servidor aws-0-sa-east-1.pooler.supabase.com
  .\tool\exportar_backup.ps1 -Servidor aws-0-sa-east-1.pooler.supabase.com -Completo
#>
param(
  [Parameter(Mandatory = $true)][string]$Servidor,
  [int]$Porta = 5432,
  [string]$Usuario = 'postgres.gayykjlkdtmmzovdbjkb',
  [string]$Banco = 'postgres',
  [string]$Destino = (Join-Path $env:USERPROFILE 'Documents\AquaAlerta-backups'),
  [switch]$Completo,
  # Só para o teste local: roda o pg_dump do Docker na rede de outro contêiner.
  [string]$RedeDocker
)
$ErrorActionPreference = 'Stop'

$tabelasConfig = @(
  'monitored_regions', 'hydro_stations', 'chuva_estacoes', 'ar_config',
  'ar_regiao', 'ar_aviso_sensor', 'openaq_sensores', 'saude_cfg'
)

# 1. A saída nunca fica dentro do repositório.
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$destinoAbs = [IO.Path]::GetFullPath($Destino)
if (($destinoAbs + '\').StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw "O destino ($destinoAbs) está dentro do repositório ($repo). Escolha outra pasta."
}
New-Item -ItemType Directory -Force $destinoAbs | Out-Null
$carimbo = Get-Date -Format 'yyyy-MM-dd_HHmm'
$tipo = if ($Completo) { 'completo' } else { 'config' }
$nome = "aqualerta_${tipo}_$carimbo.dump"
$arquivo = Join-Path $destinoAbs $nome

# 2. Qual pg_dump usar.
$local = Get-Command pg_dump -ErrorAction SilentlyContinue
$usarLocal = $false
if ($local) {
  $v = & $local.Source --version
  if ($v -match '(\d+)\.' -and [int]$Matches[1] -ge 17) { $usarLocal = $true }
}
if (-not $usarLocal -and -not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw 'Precisa de pg_dump 17+ instalado ou do Docker Desktop aberto.'
}

$argsDump = @('-h', $Servidor, '-p', "$Porta", '-U', $Usuario, '-d', $Banco,
              '--format=custom', '--no-owner', '--no-privileges')
if ($Completo) {
  $argsDump += @('--schema=public', '--exclude-table-data=public.chuva_ped_token',
                 '--exclude-table-data=public.spatial_ref_sys')
} else {
  foreach ($t in $tabelasConfig) { $argsDump += "--table=public.$t" }
}

# 3. Senha digitada agora; só o processo do pg_dump a recebe.
$seguro = Read-Host -AsSecureString "Senha do banco ($Usuario)"
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seguro)
try {
  $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  $env:PGSSLMODE = if ($RedeDocker) { 'disable' } else { 'require' }
  if ($usarLocal) {
    & $local.Source @argsDump --file=$arquivo
  } else {
    $rede = if ($RedeDocker) { @('--network', "container:$RedeDocker") } else { @() }
    # -e NOME sem valor: o Docker copia do ambiente; a senha não vai na linha de comando.
    & docker run --rm @rede -e PGPASSWORD -e PGSSLMODE -v "${destinoAbs}:/saida" `
        postgres:17-alpine pg_dump @argsDump "--file=/saida/$nome"
  }
  if ($LASTEXITCODE -ne 0) { throw "pg_dump terminou com código $LASTEXITCODE" }
} finally {
  Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
  Remove-Item Env:PGSSLMODE -ErrorAction SilentlyContinue
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

$tam = [math]::Round((Get-Item $arquivo).Length / 1KB, 1)
Write-Host "Backup salvo: $arquivo ($tam KB)"
if ($Completo) { Write-Host 'Atenção: este arquivo tem dados pessoais. Guarde fora da nuvem pública.' }
Write-Host "Para conferir: pg_restore --list `"$arquivo`""
