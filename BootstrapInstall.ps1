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

    $acceptablePolicies = @( 'Bypass', 'Unrestricted', 'RemoteSigned' )

    $gpPolicy = 'MachinePolicy', 'UserPolicy' | ForEach-Object { Get-ExecutionPolicy -Scope $_ } | Where-Object { $_ -ne 'Undefined' } | Select-Object -First 1

    if( $gpPolicy -and ($acceptablePolicies -notcontains $gpPolicy) )
    {
        Write-Host "Your current execution policy, '" -Fore Red -NoNewline
        Write-Host $gpPolicy -Fore Yellow -NoNewline
        Write-Host "', is configured by Group Policy, and will not allow $Name to run." -Fore Red
        Write-Host "For more info, search for 'about_Execution_Policies'.`n" -Fore DarkGray
        Write-Host ""

        Write-Error "You need to fix your Group Policy settings to allow local, unsigned scripts to run."
        return
    }

    $execPolicy = 'CurrentUser', 'LocalMachine' | ForEach-Object { Get-ExecutionPolicy -Scope $_ } | Where-Object { $_ -ne 'Undefined' } | Select-Object -First 1

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
            Write-Host "We are setting your PowerShell 'ExecutionPolicy' to 'RemoteSigned' so that we can run scripts."
            Write-Host "For more info, search for 'about_Execution_Policies'.`n" -Fore DarkGray
        }
        else
        {
            Write-Host "Your current execution policy, '" -Fore Red -NoNewline
            Write-Host $execPolicy -Fore Yellow -NoNewline
            Write-Host "', will not allow $Name to run." -Fore Red
            Write-Host "For more info, search for 'about_Execution_Policies'.`n" -Fore DarkGray

            $response = Read-Host "Change execution policy to 'RemoteSigned'? (y|N)"
            if( $response -ne 'y' )
            {
                Write-Error "You need to change ExecutionPolicy to allow (local, unsigned) scripts to run. See about_Execution_Policies."
                return
            }
        }

        Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
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
# MIIn9AYJKoZIhvcNAQcCoIIn5TCCJ+ECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCcFMexmqCvRgeT
# RoNCvW6rDDl/xXjcPNT7UBjqJ/4dx6CCDagwggaGMIIEbqADAgECAhMTAco/dC5Q
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
# nCYhtUEHsxHuVnNlUl0+BVwnMYIZojCCGZ4CAQEwLDAVMRMwEQYDVQQDEwpNU0lU
# IENBIFoxAhMTAco/dC5QcPJI+xeWAAIByj90MA0GCWCGSAFlAwQCAQUAoIGwMBkG
# CSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEE
# AYI3AgEVMC8GCSqGSIb3DQEJBDEiBCALwKIxa1AWblQnE4gMyMS3//wddXQGHZmt
# g6rQr65wxTBEBgorBgEEAYI3AgEMMTYwNKAUgBIATQBpAGMAcgBvAHMAbwBmAHSh
# HIAaaHR0cHM6Ly93d3cubWljcm9zb2Z0LmNvbSAwDQYJKoZIhvcNAQEBBQAEggEA
# fuWaPixpjrlgE84gkIWd9Wd2XVIthvDI3P7ZUcj16sQfF9QOKLHBGojnldXBBmvN
# K4GnF63f9fCh3zj7ZmBbUS1cNcXUbHVggAXd+AFdJql0NqOIHRBjXLeMWjqTu7aJ
# C90m478DD30IkJKio+FmYbSArDt77VtOAd1LK8AzbZ+wn9ISkoYsWsdlA/D1U6a+
# MvIBjeQUN96H9ktaGgFpexK+phbP3N3Q54Bp+mDiErCSf+QKWWuRjX0H2l32knFH
# jdpbCYMDtTmXqxoyFW9d318sW+sV/uxULLqOLId7leCk8NFO5WlE4hncmtKCWzVb
# UdEmhfMCkkqhtcnqYHtEj6GCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wGCSqG
# SIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0B
# CRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUA
# BCBCBzzhjGMvAJ+UwwnIMSngYE5TomXKCuqg3aqYejlaJAIGZVbCLIawGBMyMDIz
# MTEzMDAyNDUwNS4xNzJaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBP
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTQwMC0wNUUwLUQ5
# NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHqMIIH
# IDCCBQigAwIBAgITMwAAAdYnaf9yLVbIrgABAAAB1jANBgkqhkiG9w0BAQsFADB8
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1N
# aWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yMzA1MjUxOTEyMzRaFw0y
# NDAyMDExOTEyMzRaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYD
# VQQLEx5uU2hpZWxkIFRTUyBFU046QTQwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4IC
# DwAwggIKAoICAQDPLM2Om8r5u3fcbDEOXydJtbkW5U34KFaftC+8QyNqplMIzSTC
# 1ToE0zcweQCvPIfpYtyPB3jt6fPRprvhwCksUw9p0OfmZzWPDvkt40BUStu813Ql
# rloRdplLz2xpk29jIOZ4+rBbKaZkBPZ4R4LXQhkkHne0Y/Yh85ZqMMRaMWkBM6nU
# wV5aDiwXqdE9Jyl0i1aWYbCqzwBRdN7CTlAJxrJ47ov3uf/lFg9hnVQcqQYgRrRF
# pDNFMOP0gwz5Nj6a24GZncFEGRmKwImL+5KWPnVgvadJSRp6ZqrYV3FmbBmZtsF0
# hSlVjLQO8nxelGV7TvqIISIsv2bQMgUBVEz8wHFyU3863gHj8BCbEpJzm75fLJsL
# 3P66lJUNRN7CRsfNEbHdX/d6jopVOFwF7ommTQjpU37A/7YR0wJDTt6ZsXU+j/wY
# lo9b22t1qUthqjRs32oGf2TRTCoQWLhJe3cAIYRlla/gEKlbuDDsG3926y4EMHFx
# TjsjrcZEbDWwjB3wrp11Dyg1QKcDyLUs2anBolvQwJTN0mMOuXO8tBz20ng/+Xw+
# 4w+W9PMkvW1faYi435VjKRZsHfxIPjIzZ0wf4FibmVPJHZ+aTxGsVJPxydChvvGC
# f4fe8XfYY9P5lbn9ScKc4adTd44GCrBlJ/JOsoA4OvNHY6W+XcKVcIIGWwIDAQAB
# o4IBSTCCAUUwHQYDVR0OBBYEFGGaVDY7TQBiMCKg2+j/zRTcYsZOMB8GA1UdIwQY
# MBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUt
# U3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYB
# BQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWlj
# cm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB
# /wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0G
# CSqGSIb3DQEBCwUAA4ICAQDUv+RjNidwJxSbMk1IvS8LfxNM8VaVhpxR1SkW+FRY
# 6AKkn2s3On29nGEVlatblIv1qVTKkrUxLYMZ0z+RA6mmfXue2Y7/YBbzM5kUeUgU
# 2y1Mmbin6xadT9DzECeE7E4+3k2DmZxuV+GLFYQsqkDbe8oy7+3BSiU29qyZAYT9
# vRDALPUC5ZwyoPkNfKbqjl3VgFTqIubEQr56M0YdMWlqCqq0yVln9mPbhHHzXHOj
# aQsurohHCf7VT8ct79po34Fd8XcsqmyhdKBy1jdyknrik+F3vEl/90qaon5N8KTZ
# oGtOFlaJFPnZ2DqQtb2WWkfuAoGWrGSA43Myl7+PYbUsri/NrMvAd9Z+J9FlqsMw
# XQFxAB7ujJi4hP8BH8j6qkmy4uulU5SSQa6XkElcaKQYSpJcSjkjyTDIOpf6LZBT
# aFx6eeoqDZ0lURhiRqO+1yo8uXO89e6kgBeC8t1WN5ITqXnjocYgDvyFpptsUDgn
# RUiI1M/Ql/O299VktMkIL72i6Qd4BBsrj3Z+iLEnKP9epUwosP1m3N2v9yhXQ1Hi
# usJl63IfXIyfBJaWvQDgU3Jk4eIZSr/2KIj4ptXt496CRiHTi011kcwDpdjQLAQi
# Cvoj1puyhfwVf2G5ZwBptIXivNRba34KkD5oqmEoF1yRFQ84iDsf/giyn/XIT7YY
# /zCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQEL
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
# 0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNNMIICNQIB
# ATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
# EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UE
# CxMeblNoaWVsZCBUU1MgRVNOOkE0MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNy
# b3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQD5r3DVRpAG
# Qo9sTLUHeBC87NpK+qCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAy
# MDEwMA0GCSqGSIb3DQEBCwUAAgUA6RJizTAiGA8yMDIzMTEzMDAxMjQyOVoYDzIw
# MjMxMjAxMDEyNDI5WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDpEmLNAgEAMAcC
# AQACAilVMAcCAQACAhONMAoCBQDpE7RNAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwG
# CisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQEL
# BQADggEBAA6v4a+yYKIrsbjjvQbVSHtgdZeScHaw5c87CTWXOqP99FG7n0qJRFbw
# xoegYsMQiGPFE8mFOF1O/HbBqvJUZmK49pWzPCF5uiZxCjs970o5wygQTc0Q5E96
# bbJ1pqvWnHi/zOHLp9fXAWunXf93kCm3OxjMSa8Fm9Jv8reOX5xxmuts8YSABgqZ
# hC701660OStpVLgdlts5sgK/u5OKgVt1zHGH4fLjcw/LsG/SNQyCF3uY4C78s/9W
# FwsgOjwmhV64imxUdgP0p8vRdlGt120TYcUImIOKkbRaRYwFJNxfRzyPvPloXM/y
# aqx3D2905wscaa+Z4AbFh/nVEqVM/VYxggQNMIIECQIBATCBkzB8MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQg
# VGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAdYnaf9yLVbIrgABAAAB1jANBglghkgB
# ZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3
# DQEJBDEiBCDNPiyatdk+L8WKS2S8AeRKklpDXVX5fB3O8Fbqt4PNgTCB+gYLKoZI
# hvcNAQkQAi8xgeowgecwgeQwgb0EINbLTQ1XeNM+EBinOEJMjZd0jMNDur+AK+O8
# P12j5ST8MIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMA
# AAHWJ2n/ci1WyK4AAQAAAdYwIgQg3iZOyTvt2Eltf+np0MSOnu2CRPHStJqWyx2r
# 1o+ByKYwDQYJKoZIhvcNAQELBQAEggIAQpd54P+oESM3r5Pvw8RcQmBY43bbmA16
# Br2THPTsCoetXm58p5j0/7vuwzKQZR9BtJ0qlqXX+ilXUAXmQZLZk/kwQIPs5zyI
# bAmnnLOB5/ToTIDwp9NeJqncvCGMoGmgZchTY3l0kohEBQfkANFsSmkdPs26sWIw
# RtWqp/z07qFVADmByFEk3CrexAa0ALf0l34Ce20odp88Oy93EycErx8ATh0Cpisk
# G3/8nIPzUuGwBtEr+kfyaa6SNM1MowWnPRJQhBou6DD4y8aA5Xjoui//eKNy2Sce
# p4s3IcuB6RCK9tWTbXshtPNZDyrA6N0i1Lu9KBS1lubZDv8TnUpCB4WG7YW7t/E7
# EkvR9yhAx2pLRsirbt7Q3ukgiLTKDeT0t3QMLN+wTKfDHpztfQbUN2kUtBvVN144
# sRBXL9WL9b145G46nxZZauD6YvAirqmRzXk9PUXfBHM8CtRUZL79DTyafHGsajJu
# poNNeFvaBVybeqYOXeEpLWuCSQiRfPcfq2Oap38Nfha/4GeJnX2NmC6e8W/8Fq+M
# vWfpFvO059fu7m5VxtUaMR20UYKCZMXu2WofRCuGF5tScxS6qBOsi1bpkB256Mcr
# va5qdMYjLan1CxduQZyDhQLmBWdbBpZJ0JQGRGX+a9y8Y/uXTjkt5JzjIoTg86BY
# o1iOOExYwq0=
# SIG # End signature block
