#Requires -Version 7.4
<#
.SYNOPSIS
    Tears the platform down in reverse dependency order.

.DESCRIPTION
    Order matters. Karpenter launches EC2 instances that Terraform does not track, so the
    NodePool must be deleted and its nodes allowed to terminate BEFORE terraform destroy.
    Otherwise those instances (and their network interfaces) block VPC deletion.

      App        helm uninstall sample-app
      Logging    delete Fluent Bit
      Karpenter  delete NodePool and EC2NodeClass, wait for Karpenter nodes to terminate
      Infra      terraform destroy

.EXAMPLE
    ./scripts/Teardown.ps1 -WhatIf
.EXAMPLE
    ./scripts/Teardown.ps1 -Phase App,Logging   # leave the cluster running
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('All', 'App', 'Logging', 'Karpenter', 'Infra')]
    [string[]] $Phase = 'All',

    [string] $AppNamespace = 'sample-app',

    [int] $NodeDrainTimeoutSeconds = 600,

    [switch] $AutoApprove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot     = Split-Path -Parent $PSScriptRoot
$terraformDir = Join-Path $repoRoot 'terraform'

function Invoke-Native {
    param([Parameter(Mandatory)][string] $Command, [string[]] $Arguments = @())
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "'$Command $($Arguments -join ' ')' failed with exit code $LASTEXITCODE."
    }
}

$run = if ($Phase -contains 'All') { @('App', 'Logging', 'Karpenter', 'Infra') } else { $Phase }

if ('App' -in $run -and $PSCmdlet.ShouldProcess('sample-app', 'helm uninstall')) {
    Write-Host '==> App: uninstall' -ForegroundColor Cyan
    & helm uninstall sample-app --namespace $AppNamespace --wait 2>$null
    & kubectl delete namespace $AppNamespace --ignore-not-found --wait=true | Out-Null
}

if ('Logging' -in $run -and $PSCmdlet.ShouldProcess('fluent-bit', 'delete')) {
    Write-Host '==> Logging: delete Fluent Bit' -ForegroundColor Cyan
    & kubectl delete namespace logging --ignore-not-found --wait=true | Out-Null
    & kubectl delete clusterrolebinding fluent-bit-read --ignore-not-found | Out-Null
    & kubectl delete clusterrole fluent-bit-read --ignore-not-found | Out-Null
}

if ('Karpenter' -in $run -and $PSCmdlet.ShouldProcess('Karpenter NodePool', 'delete and wait for nodes to terminate')) {
    Write-Host '==> Karpenter: delete NodePool and wait for nodes' -ForegroundColor Cyan
    & kubectl delete nodepool general --ignore-not-found | Out-Null

    $deadline = (Get-Date).AddSeconds($NodeDrainTimeoutSeconds)
    while ($true) {
        $nodes = @(& kubectl get nodes -l karpenter.sh/nodepool -o name 2>$null | Where-Object { $_ })
        if ($nodes.Count -eq 0) { break }
        if ((Get-Date) -gt $deadline) {
            throw "Karpenter nodes still present after ${NodeDrainTimeoutSeconds}s: $($nodes -join ', ')"
        }
        Write-Host "    waiting for $($nodes.Count) Karpenter node(s) to terminate..."
        Start-Sleep -Seconds 15
    }

    & kubectl delete ec2nodeclass default --ignore-not-found | Out-Null
}

if ('Infra' -in $run -and $PSCmdlet.ShouldProcess('terraform', 'destroy')) {
    Write-Host '==> Infra: terraform destroy' -ForegroundColor Cyan
    $destroyArgs = @("-chdir=$terraformDir", 'destroy', '-input=false')
    if ($AutoApprove) { $destroyArgs += '-auto-approve' }
    Invoke-Native terraform $destroyArgs
}

Write-Host 'Done.' -ForegroundColor Green
