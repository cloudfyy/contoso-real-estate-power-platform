# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
$commonEnvironmentScript = Join-Path -Path $PSScriptRoot -ChildPath '..\..\scripts\common\environment-variables.ps1'
. $commonEnvironmentScript

function GetEnvironmentVariables {
    param (
        [string]$azureEnv
    )
    return GetRepositoryEnvironmentVariables -azureEnv $azureEnv -scriptDirectory $PSScriptRoot
}
