<#
.SYNOPSIS
  Shallow-clones the IxpTools repo and runs its install script.
#>
[CmdletBinding()]
param(
    # Advanced: this specifies the branch of the repo that you would like to use. Unless
    # you have a specific reason to use a different branch, you should just use the
    # default.
    [string] $Branch,

    # Advanced: this specifies the directory where the IxpTools directory will be created
    # (which will be added to the PSModulePath environment variable). The default is
    # ~\Documents\PSModules.
    [String] $DestinationParentDir
)

try
{
    Set-StrictMode -Version Latest

    $Name = 'IxpTools'
    $Source = 'https://microsoft.visualstudio.com/DefaultCollection/IXPTools/_git/IXPTools'
    $ScriptInRepo = 'Install-IxpTools.ps1'

    # Winget wrapper stuff taken from: https://github.com/microsoft/winget-cli/issues/549
    function winget
    {
        # This wrapper is a straight "pass-through" to winget.exe, and then after running
        # an install, it will update your in-process Path environment variables (in your
        # current shell).
        #
        # N.B. This is a "simple function" (as opposed to an "advanced function") (no
        # "[CmdletBinding()]" attribute). This is important so that the PowerShell
        # parameter binder does not get involved, and we can pass everything straight to
        # winget.exe as-is.

        try
        {
            $pathBefore = ''
            $psModulePathBefore = ''
            if( $args -and ($args.Length -gt 0) -and ($args[ 0 ] -eq 'install') )
            {
                $pathBefore = GetStaticPathFromRegistry 'PATH'
                $psModulePathBefore = GetStaticPathFromRegistry 'PSModulePath'
            }

            winget.exe @args

            if( $pathBefore )
            {
                UpdateCurrentProcessPathBasedOnDiff 'PATH' $pathBefore
                UpdateCurrentProcessPathBasedOnDiff 'PSModulePath' $psModulePathBefore
            }
        }
        catch
        {
            Write-Error $_
        }
    }

    # Split out for mocking.
    function GetEnvVar
    {
        [CmdletBinding()]
        param( $EnvVarName, $Target )

        # (the cast is so that a null return value gets converted to an empty string)
        return [string] ([System.Environment]::GetEnvironmentVariable( $EnvVarName, $Target ))
    }

    # Gets the "static" (as stored in the registry) value of a specified PATH-style
    # environment variable (combines the Machine and User values with ';'). Note that this may
    # be significantly different than the "live" environment value in the memory of the
    # current process.
    function GetStaticPathFromRegistry
    {
        [CmdletBinding()]
        param( $EnvVarName )

        (@( 'Machine', 'User' ) | ForEach-Object { GetEnvVar $EnvVarName $_ }) -join ';'
    }

    # Split out for mocking.
    function UpdateCurrentProcessPath
    {
        [CmdletBinding()]
        param( $EnvVarName, $Additions )

        Set-Content Env:\$EnvVarName -Value ((Get-Content Env:\$EnvVarName) + ';' + $additions)
    }

    function UpdateCurrentProcessPathBasedOnDiff
    {
        [CmdletBinding()]
        param( $EnvVarName, $Before )

        $pathAfter = GetStaticPathFromRegistry $EnvVarName

        $additions = CalculateAdditions $EnvVarName $Before $pathAfter

        if( $additions )
        {
            UpdateCurrentProcessPath $EnvVarName $additions
        }
    }

    # Given two strings representing PATH-like environment variables (a set of strings
    # separated by ';'), returns the PATHs that are present in the second ($After) but not in
    # the first ($Before) and not in the current (in-memory) variable, in PATH format (joined
    # by ';'). (Does not do anything about removals or reordering.)
    function CalculateAdditions
    {
        [CmdletBinding()]
        param( [string] $EnvVarName, [string] $Before, [string] $After )

        try
        {
            $additions = @()
            $setBefore = @( $Before.Split( ';' ) )
            $currentInMemory = @( (GetEnvVar $EnvVarName 'Process').Split( ';' ) )

            foreach( $p in $After.Split( ';' ) )
            {
                if( ($setBefore -notcontains $p) -and ($currentInMemory -notcontains $p) )
                {
                    $additions += $p
                }
            }

            return $additions -join ';'
        }
        finally { }
    }

    #
    # (end of winget wrapper stuff)
    #

    #
    # Check some prerequisites:
    #

    if( $PSVersionTable.PSVersion.Major -eq 6 )
    {
        # v6 does not honor $env:PSModulePath, and perhaps there are other
        # incompatabilities as well. Nobody has a reason to be stuck on v6, so we'll just
        # block it to keep things simple.
        Write-Error "You are on a really old version of pwsh. Please upgrade to pwsh 7 or later."

        Write-Host ''
        Write-Host 'To install ' -NoNewLine
        Write-Host 'PowerShell Core' -Fore Green -NoNewLine
        Write-Host ', run the following command:'
        Write-Host ''
        Write-Host '   iex "& { $(irm https://aka.ms/install-powershell.ps1) } -UseMSI"' -Fore Cyan
        Write-Host ''
        Write-Host "(and then relaunch your console to pick up the updated PATH so you can run '" -Fore DarkGray -NoNewLine
        Write-Host 'pwsh' -Fore DarkGreen -NoNewLine
        Write-Host "')" -Fore DarkGray

        return
    }

    if( !(Get-Command "git" -ErrorAction Ignore) )
    {
        Write-Host "`nGit is required.`n" -Fore Red
        $response = Read-Host "Would you like me to install it for you? (y|N)"

        if( $response -ne 'y' )
        {
            Write-Error "git is required"
            return
        }

        winget install --id Git.Git -e --source winget

        if( !(Get-Command "git" -ErrorAction Ignore) )
        {
            # Huh... perhaps the user canceled it or such.
            Write-Error @"
Could not find git after attempting install. Consider installing git manually, relaunching Terminal, and trying again:

winget install --id Git.Git -e --source winget
"@
            return
        }
    }

    $gitVersionOutput = git --version
    if( $gitVersionOutput -match 'git version (?<ShortVer>\d+\.\d+).*' )
    {
        # I haven't actually tested on version 2.22... but I know that we use at least one
        # feature ("git branch --show-current") that was introduced in 2.22, so we need at
        # least 2.22, if not later.
        $minVer = [Version]::Parse( '2.22' )
        $gitVer = [Version]::Parse( $Matches.ShortVer )

        if( $gitVer -lt $minVer )
        {
            Write-Error "This module requires a newer version of git (at least $minVer or newer). Please upgrade your git."
            return
        }
    }
    else
    {
        Write-Error "Could not determine git version."
        return
    }

    $execPolicy = 'CurrentUser', 'LocalMachine', 'UserPolicy', 'MachinePolicy' | ForEach-Object { Get-ExecutionPolicy -Scope $_ } | Where-Object { $_ -ne 'Undefined' } | Select-Object -First 1

    $acceptablePolicies = @( 'Bypass', 'Unrestricted', 'RemoteSigned' )
    if( $acceptablePolicies -contains $execPolicy )
    {
        Write-Verbose "Existing execution policy is acceptable ($execPolicy)."
    }
    else
    {
        if( !$execPolicy )
        {
            # The user has no policy set at all. In that case, we will choose for them.
            Write-Host "`nNOTE: " -Fore Yellow -NoNewline
            Write-Host "We are setting your PowerShell 'ExecutionPolicy' to 'Bypass' so that we can run scripts."
            Write-Host "For more info, search for 'about_Execution_Policies'.`n" -Fore DarkGray
        }
        else
        {
            Write-Host "Your current execution policy, '" -Fore Red -NoNewline
            Write-Host $execPolicy -Fore Yellow -NoNewline
            Write-Host "', will not allow $Name to run." -Fore Red
            Write-Host "For more info, search for 'about_Execution_Policies'.`n" -Fore DarkGray

            $response = Read-Host "Change execution policy to 'Bypass'? (y|N)"
            if( $response -ne 'y' )
            {
                Write-Error "You need to change ExecutionPolicy to allow scripts to run. See about_Execution_Policies."
                return
            }
        }

        Set-ExecutionPolicy Bypass -Scope CurrentUser
    }

    #
    # (end prereq checking)
    #

    # It is not sufficient to download only the specified script file, because the install
    # script may depend on other scripts in the module. So it's a little goofy to download
    # the entire repo to a temp location just so we can run the install script (which will
    # download it again, to a more suitable location), but them's the breaks.

    [string] $cloneDest = Join-Path $env:TEMP ('_' + $Name + 'Installer')

    if( !(Test-Path $env:TEMP) )
    {
        $null = mkdir $env:TEMP
    }
    elseif( Test-Path $cloneDest )
    {
        Remove-Item -Force -Recurse $cloneDest
    }

    $branchArg = @()
    if( $Branch )
    {
        Write-Host "(using branch: $Branch)"
        $branchArg = @( '--branch', $Branch )
    }

    Write-Host "Downloading $Name install script from: " -NoNewline
    Write-Host $Source -Fore Blue
    Write-Host "To: $cloneDest"

    git clone --quiet --depth 1 @branchArg $Source $cloneDest

    if( $LASTEXITCODE ) { throw "git clone failed ($LASTEXITCODE)" }

    #
    # Time to run the REAL install script!
    #

    $optionalParams = @{}
    if( $Branch )
    {
        $optionalParams[ 'Branch' ] = $Branch
    }

    if( $DestinationParentDir )
    {
        $optionalParams[ 'DestinationParentDir' ] = $DestinationParentDir
    }

    & (Join-Path $cloneDest $ScriptInRepo) @optionalParams

    Remove-Item -Force -Recurse $cloneDest
}
finally { } # ensure terminating errors are terminating


# SIG # Begin signature block
# MIIn9wYJKoZIhvcNAQcCoIIn6DCCJ+QCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCqkc8+6pDJCGJe
# naQKzT440VtEpZs8TnWUwDEKJL35/aCCDagwggaGMIIEbqADAgECAhMTAco/dC5Q
# cPJI+xeWAAIByj90MA0GCSqGSIb3DQEBCwUAMBUxEzARBgNVBAMTCk1TSVQgQ0Eg
# WjEwHhcNMjMwMzE1MTgzMjAzWhcNMjQwMzE0MTgzMjAzWjCBiDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IENv
# cnBvcmF0aW9uIChJbnRlcm5hbCBVc2UgT25seSkwggEiMA0GCSqGSIb3DQEBAQUA
# A4IBDwAwggEKAoIBAQCQYBfKibbl9ijRUzADGwC6KHKeiLth59ys4HUa8RhK8IvW
# Kbl3o4xtynwFVek/HQSf6mqSLnCZN1w+ywxO5soFhN191qc6RGUxylW2RPlYnwfV
# fpAv2qmHjzL6bDRo+HJAvRXIfM0jHPK0Y4AmcYURlPv2vwgWzLOlG7HiWqUNOSir
# sz8Fz5O6koqPxaeiHTXHvr31Fsqq6xkk51xVDlOrpbBCJdiAhuBwfBvK9sf8mxr1
# hhYDv1ddQEJ06yLX9kkjR16azvxlnEwIHIK73lgWiSFC/gsy2BkE4qpRLxkO62le
# yiYMcRGs+GICsmvfMJw02rWKOQgyz/B5LipwwUC5AgMBAAGjggJZMIICVTALBgNV
# HQ8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwMwHQYDVR0OBBYEFCMX8ABN4YKA
# 2VmKCpidrwZFcbZhMEUGA1UdEQQ+MDykOjA4MR4wHAYDVQQLExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xFjAUBgNVBAUTDTIzMDg1Nis1MDA0MzYwHwYDVR0jBBgwFoAU
# EBoXBhTSBgIdQfjhF3WMQhH4a6Iwgb4GA1UdHwSBtjCBszCBsKCBraCBqoYoaHR0
# cDovL2NvcnBwa2kvY3JsL01TSVQlMjBDQSUyMFoxKDIpLmNybIY/aHR0cDovL21z
# Y3JsLm1pY3Jvc29mdC5jb20vcGtpL21zY29ycC9jcmwvTVNJVCUyMENBJTIwWjEo
# MikuY3Jshj1odHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL21zY29ycC9jcmwv
# TVNJVCUyMENBJTIwWjEoMikuY3JsMIGLBggrBgEFBQcBAQR/MH0wNAYIKwYBBQUH
# MAKGKGh0dHA6Ly9jb3JwcGtpL2FpYS9NU0lUJTIwQ0ElMjBaMSgyKS5jcnQwRQYI
# KwYBBQUHMAKGOWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvbXNjb3JwL01T
# SVQlMjBDQSUyMFoxKDIpLmNydDA+BgkrBgEEAYI3FQcEMTAvBicrBgEEAYI3FQiH
# 2oZ1g+7ZAYLJhRuBtZ5hhfTrYIFdgZvHJ4aMmUcCAWQCAQwwGwYJKwYBBAGCNxUK
# BA4wDDAKBggrBgEFBQcDAzANBgkqhkiG9w0BAQsFAAOCAgEAY9O9M5muekwNj6Fn
# x0yRoVkQD4X2fe8Iwq/QqUgGLqg12O+C0qQEvT5znQ1KdqL3K+JkazSL2JnxVtlZ
# bdKezIrMpjowW8OCB2137KHIQekUymGvO8AsK2ObaXl93ddhg6G+e+ctjUA02HBp
# qHHHycIHtX92YacyKILAYAYknV/xoW9S/Psc6+Y0N0B5ECrHjnaOgcE8E7dzGzcO
# 0gjtLpSu7wCuMfb6t6uXKWPU0KKeAZ8zogmdFYherPy7LO7bHhz9ImvmWG5K5o4O
# loWY/LQi+e6UZlfG8IOx3uJaV5yW7MbyGZN3ID4Iwt0KXD0L0ckOtHuj8usQJa24
# Chlc3YIFg8IDD2TI/x1rCKVHjcvsnDZgKS4THfYK/zc7tZWw5OAukIqrwN84Rcle
# +biCRGsRCubf4ybONKBLauIjsx9SvRatUVmrFb9/b6Q2Jh6bOyVdjNIVSre0OaZh
# C0F/+5sko9pAUKRslaxUcSBpgTZnJm+W1zJlvp3gY7v1gZo6lGjdf9mgDX57UOXx
# Yf5N9/Q3QAmFOpVoTCqCawa3taIsFDnUcZkqiqhGhoy6JhW+AIwE//qNCcAInFXR
# NPT9NjOEIti+moXvYqNHh46nxnhp/ZLSmTageyCatRoVC+em6bEeVhqpw6otrsxN
# SCdFOk8WtaZMPyPMKT0vQ+OaNYwwggcaMIIFAqADAgECAhNlAAAAYS/15SnDsI3s
# AAAAAABhMA0GCSqGSIb3DQEBCwUAMCwxKjAoBgNVBAMTIU1pY3Jvc29mdCBJbnRl
# cm5hbCBDb3Jwb3JhdGUgUm9vdDAeFw0yMTAzMDQwMzEyMzBaFw0yNTAyMjAwMzEy
# MzBaMBUxEzARBgNVBAMTCk1TSVQgQ0EgWjEwggIiMA0GCSqGSIb3DQEBAQUAA4IC
# DwAwggIKAoICAQDcG7XWS6S9JjSbgAy37HubeIGQ8RUr6gXMizTC+jSfuEHu+xKP
# 9YJoiMKtb6z5vHXEboCpJyNPAb9JFl1W4Bhyu/ZMSlo3zuyHBFNef2nHmXwalNig
# W86m8SmzQDOJ9ahqLP7TbH2RD4a9RV2Poizk6ZlGVEbajNmsWSSocZAZayxcvSvv
# zpicgJ124X+EQ5I27GJX0DtMEVBqp4ZvZFBjn9CiKsVpJtX4MM1IPTj8tCnm8Iql
# qnYo2g3sjoUbTJxa7GevdFrc8AsVOe+ZtKNi1n0zvjHSQzz2b8fnpkqGpclX8LGA
# CrE5FHnheikdpbnuQayzc8CCz/bDps3hpG8V6z9APPrWsePJeW++zcuw9RYw4bYk
# Sy6SgnMvbJhnOIbNvWprEOs1qzrbw1Ebnt/fWOlQqglCJzkQMLW9Gye1dm1Fl6+m
# wCwvDf5SfSoBHARhjaYPFE0MRMaf3ancmfwns4kebYkzzYVbZ+d2utcADdR58+Eq
# 5X52ZPSHw7AkXXNTbecLjBQf+M/CAuJLctwiIkbbO7VHedkCqQtL5/NVl7MKerIh
# CHUMwoOV7c4SfSJLr0nqmuA9h0pHnTyL0k8YDmStD7DVTbhGtD0GAZRazE/zeWB4
# II5o4ldoz1/+QsChP4x/WNGCCnEMLtKH/Gtim0Z39Yvqs9uxX+IkWq/TFwIDAQAB
# o4ICSjCCAkYwEgYJKwYBBAGCNxUBBAUCAwIAAjAjBgkrBgEEAYI3FQIEFgQU2DMF
# WZrs3wWqsEuDdm8BPtZJoeowHQYDVR0OBBYEFBAaFwYU0gYCHUH44Rd1jEIR+Gui
# MGkGA1UdJQRiMGAGCCsGAQUFBwMDBggrBgEFBQcDDgYIKwYBBQUHAwEGBysGAQUC
# AwUGCisGAQQBgjcUAgIGCSsGAQQBgjcVBQYIKwYBBQUHAwIGCisGAQQBgjcqAgUG
# CisGAQQBgjcqAgYwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQD
# AgGGMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU2+wKZKjOwA7piFQO
# 6cjexHhLemEwgaYGA1UdHwSBnjCBmzCBmKCBlaCBkoYgaHR0cDovL2NvcnBwa2kv
# Y3JsL21zaW50Y3JjYS5jcmyGN2h0dHA6Ly9tc2NybC5taWNyb3NvZnQuY29tL3Br
# aS9tc2NvcnAvY3JsL21zaW50Y3JjYS5jcmyGNWh0dHA6Ly9jcmwubWljcm9zb2Z0
# LmNvbS9wa2kvbXNjb3JwL2NybC9tc2ludGNyY2EuY3JsMHsGCCsGAQUFBwEBBG8w
# bTAsBggrBgEFBQcwAoYgaHR0cDovL2NvcnBwa2kvYWlhL21zaW50Y3JjYS5jcnQw
# PQYIKwYBBQUHMAKGMWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvbXNjb3Jw
# L21zaW50Y3JjYS5jcnQwDQYJKoZIhvcNAQELBQADggIBAHMsjcOQsc8T41D5KWfg
# aox36kg4ax0UliRTA7TXnlthAen26d+RSY7Vi3RXoZb+u4Y2EwnXjAO8iEfN9tqr
# MAQRT8Mmg4bON3nkuAxPK5yEPbBfu5kMgw1k41zKg8q/zE7TMHefAlPPsSWUHHCy
# kAQNDV5WFnm89uoqF8GOGu4gq2Q5MsHWNrwd13EopVLNYaAVmHff2tTI+e29x7QM
# 8P5WJu3O01E1WiY0yZU9lzFy7Hf4MvuLYINKLDXJBg9F2BYpxWeAgVE7tkoQO+Ga
# oaAsMY81YE7uCNW4xTiLmuyg9J7CtXuRUxkLzzzwavW79a2z/GsQUfAX7gUyC5mb
# 2hIWo0cyYpcI5uKjdFaRX5LTJZBBDEVpyn51mcOSD9YWDAZWCoZY94fobcpJJ0sE
# V5J/9fWtRn5KvELUznMCZS+JUgMv9hymkK/uozJCs984743NYM0213EpvvQkVJk1
# ZFSVrG/suG80YO6UaxR/ssLupUaMRWNswvMy30+D0lsYrDfCRUSmOyX5mxqk0X/9
# H6AKhPP6xTL4QtupBbIRI+Sm6jyHnZCMYolkINh1HjC/ASwD0toHPt+2hD8xFrZW
# vFxtQl41vXtZbvyV/b3zQqpfejiaEId2npQA32W6oEdu4DBDnAMrVlvc0q9fIK/i
# nCYhtUEHsxHuVnNlUl0+BVwnMYIZpTCCGaECAQEwLDAVMRMwEQYDVQQDEwpNU0lU
# IENBIFoxAhMTAco/dC5QcPJI+xeWAAIByj90MA0GCWCGSAFlAwQCAQUAoIGwMBkG
# CSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEE
# AYI3AgEVMC8GCSqGSIb3DQEJBDEiBCB7iVeElCZ9xyW6wD/qmGvR4IPM7L+91uqY
# xVNJLhv64zBEBgorBgEEAYI3AgEMMTYwNKAUgBIATQBpAGMAcgBvAHMAbwBmAHSh
# HIAaaHR0cHM6Ly93d3cubWljcm9zb2Z0LmNvbSAwDQYJKoZIhvcNAQEBBQAEggEA
# Nbl19LVwYmuxXuwD+CJX33wQiUi17nn3/DAXxWbebdks+GVk5htdZh5N9RFug3Gw
# 2g/hh29mQbj4yJ4Ir2fJaSLfmekRan8H2Xnr5ySaZBXeefDA5ZzHiLqJSGs7Tpot
# UhzGVNMCY6iXiiGz5QqdyDZijegZPU6CkcFNOE9KM3pYF1KPA5gyfeedQ6IRqbwk
# tLwX4ShdAbDZQZfkakNupxSA98Xa0h5u0XxB8Ln/tOlKoHv7nep1q5kDWSZMCgqk
# dCsIRt2caXdjznlBDPevdZKxVn21YbDuIfcHlRJUPJn63Bb2rpSprjqs8IiDMxqX
# hRsTHciXJUHA6h5X0MUv+KGCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCCF38GCSqG
# SIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0B
# CRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUA
# BCBoHXlgWLi/QNEe051srh7nezaggNj6YA3MKc76XjZxNwIGZSie817gGBMyMDIz
# MTExMzIxMTUwMy40NzdaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBP
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046MzcwMy0wNUUwLUQ5
# NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHtMIIH
# IDCCBQigAwIBAgITMwAAAdTk6QMvwKxprAABAAAB1DANBgkqhkiG9w0BAQsFADB8
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1N
# aWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yMzA1MjUxOTEyMjdaFw0y
# NDAyMDExOTEyMjdaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYD
# VQQLEx5uU2hpZWxkIFRTUyBFU046MzcwMy0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4IC
# DwAwggIKAoICAQCYU94tmwIkl353SWej1ybWcSAbu8FLwTEtOvw3uXMpa1DnDXDw
# btkLc+oT8BNti8t+38TwktfgoAM9N/BOHyT4CpXB1Hwn1YYovuYujoQV9kmyU6D6
# QttTIKN7fZTjoNtIhI5CBkwS+MkwCwdaNyySvjwPvZuxH8RNcOOB8ABDhJH+vw/j
# ev+G20HE0Gwad323x4uA4tLkE0e9yaD7x/s1F3lt7Ni47pJMGMLqZQCK7UCUeWau
# WF9wZINQ459tSPIe/xK6ttLyYHzd3DeRRLxQP/7c7oPJPDFgpbGB2HRJaE0puRRD
# oiDP7JJxYr+TBExhI2ulZWbgL4CfWawwb1LsJmFWJHbqGr6o0irW7IqDkf2qEbMR
# T1WUM15F5oBc5Lg18lb3sUW7kRPvKwmfaRBkrmil0H/tv3HYyE6A490ZFEcPk6dz
# YAKfCe3vKpRVE4dPoDKVnCLUTLkq1f/pnuD/ZGHJ2cbuIer9umQYu/Fz1DBreC8C
# Rs3zJm48HIS3rbeLUYu/C93jVIJOlrKAv/qmYRymjDmpfzZvfvGBGUbOpx+4ofwq
# BTLuhAfO7FZz338NtsjDzq3siR0cP74p9UuNX1Tpz4KZLM8GlzZLje3aHfD3mulr
# PIMipnVqBkkY12a2slsbIlje3uq8BSrj725/wHCt4HyXW4WgTGPizyExTQIDAQAB
# o4IBSTCCAUUwHQYDVR0OBBYEFDzajMdwtAZ6EoB5Hedcsru0DHZJMB8GA1UdIwQY
# MBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUt
# U3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYB
# BQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWlj
# cm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB
# /wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0G
# CSqGSIb3DQEBCwUAA4ICAQC0xUPP+ytwktdRhYlZ9Bk4/bLzLOzq+wcC7VAaRQHG
# RS+IPyU/8OLiVoXcoyKKKiRQ7K9c90OdM+qL4PizKnStLDBsWT+ds1hayNkTwnhV
# cZeA1EGKlNZvdlTsCUxJ5C7yoZQmA+2lpk04PGjcFhH1gGRphz+tcDNK/CtKJ+Pr
# EuNj7sgmBop/JFQcYymiP/vr+dudrKQeStcTV9W13cm2FD5F/XWO37Ti+G4Tg1Bk
# U25RA+t8RCWy/IHug3rrYzqUcdVRq7UgRl40YIkTNnuco6ny7vEBmWFjcr7Skvo/
# QWueO8NAvP2ZKf3QMfidmH1xvxx9h9wVU6rvEQ/PUJi3popYsrQKuogphdPqHZ5j
# 9OoQ+EjACUfgJlHnn8GVbPW3xGplCkXbyEHheQNd/a3X/2zpSwEROOcy1YaeQquf
# lGilAf0y40AFKqW2Q1yTb19cRXBpRzbZVO+RXUB4A6UL1E1Xjtzr/b9qz9U4UNV8
# wy8Yv/07bp3hAFfxB4mn0c+PO+YFv2YsVvYATVI2lwL9QDSEt8F0RW6LekxPfvbk
# mVSRwP6pf5AUfkqooKa6pfqTCndpGT71HyiltelaMhRUsNVkaKzAJrUoESSj7sTP
# 1ZGiS9JgI+p3AO5fnMht3mLHMg68GszSH4Wy3vUDJpjUTYLtaTWkQtz6UqZPN7WX
# hjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQEL
# BQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNV
# BAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4X
# DTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM
# 57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm
# 95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzB
# RMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBb
# fowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCO
# Mcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYw
# XE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW
# /aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/w
# EPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPK
# Z6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2
# BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfH
# CBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYB
# BAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8v
# BO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYM
# KwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEF
# BQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYD
# VR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBW
# BgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2Ny
# bC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUH
# AQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtp
# L2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsF
# AAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518Jx
# Nj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+
# iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2
# pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefw
# C2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7
# T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFO
# Ry3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhL
# mm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3L
# wUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5
# m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE
# 0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNQMIICOAIB
# ATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
# EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UE
# CxMeblNoaWVsZCBUU1MgRVNOOjM3MDMtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNy
# b3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQAtM12Wjo2x
# xA5sduzB/3HdzZmiSKCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAy
# MDEwMA0GCSqGSIb3DQEBCwUAAgUA6PyjUTAiGA8yMDIzMTExMzEzMjk1M1oYDzIw
# MjMxMTE0MTMyOTUzWjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDo/KNRAgEAMAoC
# AQACAiGkAgH/MAcCAQACAhNqMAoCBQDo/fTRAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBADTkJQ59WCdw2OGeQm0VBOMJ3f4QZQ8W9IFtV4fj5lXdf/uxCzrw
# xBdlLwezzabE2U0H49GwH8cQGLB5wNUF+tmdbA0/Ho19O+8PdnCPcWnhP+Bj6ZIT
# 9+yGdhnW+jUoeTkKuebbkaIOcJH3Xbx/R0vuk0RbAZJtzpCX+2nFVUhmbbtkSgXN
# CeBiZroTeb5yUpu+gT7+cQQwNTrpgxbE4F51QI2dc4WPSxgvKZ3zPxy0N83jVvPB
# Ha03SjIC1SeA8vd0RxnrCJ40NMUqNAiauFeb9qEY0GesG01lBNLOSTE1dZn6sIuV
# EhE5UG5TzMBV0r3ZegS0QGzm0tQ/hGU7cr4xggQNMIIECQIBATCBkzB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAdTk6QMvwKxprAABAAAB1DANBglg
# hkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqG
# SIb3DQEJBDEiBCC3Vgx0LLx+S12gCGLB3DNyQ/js6zkc1nyqwGI0kCyYtzCB+gYL
# KoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIMzqh/rYFKXOlzvWS5xCtPi9aU+fBUkx
# IriXp2WTPWI3MIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAHU5OkDL8CsaawAAQAAAdQwIgQg9PWZD+kB6amKI59nl0aHTfhOMXueis+f
# DLqJlYQq8Q8wDQYJKoZIhvcNAQELBQAEggIAOCc0138l67rAqmNoXh8d/6a5JiYB
# Tu/3drD1Inr4mYoiSe+LxtT8urBwSZK4i8M1zl7zK9SVafn5ynHMHg5pdjCFO5xn
# zHQR6baEnrmQxzaw3eq+urtiWFxQqeG6maPoExGYHbpJdP9lqMW/zpWVqS1R2TPy
# Ece6+t11XIqf9eY5ZbQ0V3vqLtjYNn09rQhxwONgGNyaje99YQsf0PKrKPaul7Sx
# sekchCf1iqO8bLlgXznat7VsVXipuj27CiMdjIxfS/yGqEx9+8sFeufltXl9GMtv
# TTPzn2VRalgBtUt+GiXlktSbr08bk4h9wo1CMupGojAofM2PwfvTdBrKddelFWy3
# 3UTZKouPJGl3hDtunfFo2C/De86Vc8UjjbPocwjuRGyP4/2/POCtH0RVTaU+HDs1
# XguSoNC+rWykred3WoKGVrfCHOAJaaCiVHv+3+DcmI+jTLPvdy0MGZTYZJii6WPp
# Dl/pqioDmTfDrBNcWI5fqcknFWgm4hOmd08EOAahvyTsCZXphbPwp/clawjHq9kH
# TKLL3lS+LZA2eQVEl++FASYDwRmO+12CUan7CN/vS+tNy3JL6It1QvKN7hli9eNc
# y59DE/zmJp23Etw1KW0WYJtD6j9QPJ8l5tc5UZHCWASsOPvhsb0nqrt7cnhzhpv9
# PU84yQ7N1vmggL8=
# SIG # End signature block
