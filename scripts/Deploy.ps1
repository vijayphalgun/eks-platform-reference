#Requires -Version 7.4
<#
.SYNOPSIS
    Deploys the EKS reference platform in ordered, re-runnable phases.

.DESCRIPTION
    Phases run in dependency order and each one is idempotent, so a failed run can be
    resumed by re-running the same phase:

      Infra      terraform apply (VPC, EKS, Karpenter controller, metrics-server, log bucket)
      Karpenter  EC2NodeClass and NodePool, rendered from Terraform outputs
      Logging    Fluent Bit (Kustomize AWS overlay) shipping logs to S3
      App        sample-app Helm chart

.EXAMPLE
    ./scripts/Deploy.ps1                       # everything
.EXAMPLE
    ./scripts/Deploy.ps1 -Phase Karpenter,App  # just these phases
.EXAMPLE
    ./scripts/Deploy.ps1 -WhatIf               # show what would run
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('All', 'Infra', 'Karpenter', 'Logging', 'App')]
    [string[]] $Phase = 'All',

    [string] $AppNamespace = 'sample-app',

    [switch] $AutoApprove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot     = Split-Path -Parent $PSScriptRoot
$terraformDir = Join-Path $repoRoot 'terraform'

function Invoke-Native {
    param([Parameter(Mandatory)][string] $Command, [string[]] $Arguments = @())
    Write-Verbose "$Command $($Arguments -join ' ')"
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "'$Command $($Arguments -join ' ')' failed with exit code $LASTEXITCODE."
    }
}

function Assert-Tool {
    param([string[]] $Name)
    foreach ($tool in $Name) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "Required tool '$tool' was not found on PATH."
        }
    }
}

function Get-TerraformOutputs {
    $json = & terraform "-chdir=$terraformDir" output -json
    if ($LASTEXITCODE -ne 0) { throw 'Could not read Terraform outputs. Run the Infra phase first.' }
    $raw = $json | ConvertFrom-Json -AsHashtable
    $outputs = @{}
    foreach ($key in $raw.Keys) { $outputs[$key] = $raw[$key].value }
    return $outputs
}

function Expand-Template {
    param([string] $Text, [hashtable] $Values)
    foreach ($key in $Values.Keys) {
        $Text = $Text.Replace("`${$key}", [string] $Values[$key])
    }
    if ($Text -match '\$\{[A-Z_]+\}') {
        throw "Unresolved placeholder in template: $($Matches[0])"
    }
    return $Text
}

function Invoke-KubectlApply {
    param([string] $Manifest)
    $Manifest | & kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { throw 'kubectl apply failed.' }
}

$run = if ($Phase -contains 'All') { @('Infra', 'Karpenter', 'Logging', 'App') } else { $Phase }

Assert-Tool -Name terraform, aws, kubectl, helm

if ('Infra' -in $run -and $PSCmdlet.ShouldProcess('terraform', 'init and apply')) {
    Write-Host '==> Infra: terraform apply' -ForegroundColor Cyan
    Invoke-Native terraform @("-chdir=$terraformDir", 'init', '-input=false')
    $applyArgs = @("-chdir=$terraformDir", 'apply', '-input=false')
    if ($AutoApprove) { $applyArgs += '-auto-approve' }
    Invoke-Native terraform $applyArgs
}

$tf = $null
if ($run | Where-Object { $_ -ne 'Infra' }) {
    $tf = Get-TerraformOutputs
    if ($PSCmdlet.ShouldProcess($tf.cluster_name, 'update kubeconfig')) {
        Invoke-Native aws @('eks', 'update-kubeconfig', '--region', $tf.region, '--name', $tf.cluster_name)
    }
}

if ('Karpenter' -in $run -and $PSCmdlet.ShouldProcess('karpenter/*.yaml', 'apply EC2NodeClass and NodePool')) {
    Write-Host '==> Karpenter: EC2NodeClass and NodePool' -ForegroundColor Cyan
    Invoke-Native kubectl @('-n', 'kube-system', 'rollout', 'status', 'deployment/karpenter', '--timeout=5m')

    $values = @{ CLUSTER_NAME = $tf.cluster_name; KARPENTER_NODE_ROLE = $tf.karpenter_node_role_name }
    foreach ($file in 'ec2nodeclass.yaml', 'nodepool.yaml') {
        $template = Get-Content -Raw -Path (Join-Path $repoRoot "karpenter/$file")
        Invoke-KubectlApply (Expand-Template -Text $template -Values $values)
    }
}

if ('Logging' -in $run -and $PSCmdlet.ShouldProcess('logging/fluent-bit/overlays/aws', 'apply Fluent Bit')) {
    Write-Host '==> Logging: Fluent Bit to S3' -ForegroundColor Cyan
    $rendered = (& kubectl kustomize (Join-Path $repoRoot 'logging/fluent-bit/overlays/aws')) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'kubectl kustomize failed.' }
    Invoke-KubectlApply (Expand-Template -Text $rendered -Values @{ LOGS_BUCKET = $tf.logs_bucket; AWS_REGION = $tf.region })
    Invoke-Native kubectl @('-n', 'logging', 'rollout', 'status', 'daemonset/fluent-bit', '--timeout=5m')
}

if ('App' -in $run -and $PSCmdlet.ShouldProcess('charts/sample-app', 'helm upgrade --install')) {
    Write-Host '==> App: sample-app' -ForegroundColor Cyan
    Invoke-Native helm @(
        'upgrade', '--install', 'sample-app', (Join-Path $repoRoot 'charts/sample-app'),
        '--namespace', $AppNamespace, '--create-namespace', '--wait', '--timeout', '10m'
    )
}

Write-Host 'Done.' -ForegroundColor Green
