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

        winget install --id Microsoft.Git -e --source winget

        if( !(Get-Command "git" -ErrorAction Ignore) )
        {
            # Huh... perhaps the user canceled it or such.
            Write-Error @"
Could not find git after attempting install. Consider installing git manually, relaunching Terminal, and trying again:

winget install --id Microsoft.Git -e --source winget
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
# MIIniQYJKoZIhvcNAQcCoIInejCCJ3YCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAlyy80e8ppbrB0
# DvkSYiwpRTeScLubk1+u0J1xmBNmSaCCDagwggaGMIIEbqADAgECAhMTAiSYrbvN
# MpoZEcKPAAICJJitMA0GCSqGSIb3DQEBCwUAMBUxEzARBgNVBAMTCk1TSVQgQ0Eg
# WjEwHhcNMjMxMTAxMjAyNjE1WhcNMjQxMDMxMjAyNjE1WjCBiDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IENv
# cnBvcmF0aW9uIChJbnRlcm5hbCBVc2UgT25seSkwggEiMA0GCSqGSIb3DQEBAQUA
# A4IBDwAwggEKAoIBAQDm+TLalxnz8enAuCSZGVGpn8PqFzy1eWu8/l0vw2e1UioC
# NDfIQPwLEQ8PeIbt9FsGwP4Dj1t1rtT42cM1jiMZCXb6Lf0xtyoMQiYYTWJIHUmR
# 0xCgwYzGpFGiV2HfOLXjdAAfQd6MAZKLht7uPAfN6M80LyLPYSN8H4F5LLa6s/gJ
# ri53EucVBgIGUKFjSfXV4qioeWzgNHudFKuAx7rLHUrsjglsRWxo7sWQsRGYikl7
# rlrHMNxKs0WMKFDb7xLCWPBQdFdf0SgqLwHLegISemJSzgZP+YAP+4uQwZI0RrGQ
# cDK+zUHIPAn5l5tUBCq0yN0g0wrsGIEVQRYs8IaTAgMBAAGjggJZMIICVTALBgNV
# HQ8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwMwHQYDVR0OBBYEFFtztMUPMD6u
# w4yuhXkOGTsAjqwOMEUGA1UdEQQ+MDykOjA4MR4wHAYDVQQLExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xFjAUBgNVBAUTDTIzMDg1Nis1MDE3MzkwHwYDVR0jBBgwFoAU
# EBoXBhTSBgIdQfjhF3WMQhH4a6Iwgb4GA1UdHwSBtjCBszCBsKCBraCBqoYoaHR0
# cDovL2NvcnBwa2kvY3JsL01TSVQlMjBDQSUyMFoxKDIpLmNybIY/aHR0cDovL21z
# Y3JsLm1pY3Jvc29mdC5jb20vcGtpL21zY29ycC9jcmwvTVNJVCUyMENBJTIwWjEo
# MikuY3Jshj1odHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL21zY29ycC9jcmwv
# TVNJVCUyMENBJTIwWjEoMikuY3JsMIGLBggrBgEFBQcBAQR/MH0wNAYIKwYBBQUH
# MAKGKGh0dHA6Ly9jb3JwcGtpL2FpYS9NU0lUJTIwQ0ElMjBaMSgyKS5jcnQwRQYI
# KwYBBQUHMAKGOWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvbXNjb3JwL01T
# SVQlMjBDQSUyMFoxKDIpLmNydDA+BgkrBgEEAYI3FQcEMTAvBicrBgEEAYI3FQiH
# 2oZ1g+7ZAYLJhRuBtZ5hhfTrYIFdgZvHJ4aMmUcCAWQCAQwwGwYJKwYBBAGCNxUK
# BA4wDDAKBggrBgEFBQcDAzANBgkqhkiG9w0BAQsFAAOCAgEAklXYJ7Gf0nkhinVs
# bOUWoK8atSpw+3xfeR5bwk58T0Py1D0nlYbKO5dhi+lnC5dCrwbe+dE7Db2NvihI
# sKSGAtGGy/9HAGnj185K4arqlQHZ53zSNosCUeGmmEg3i6FimPcHFM4IrEf3o9+N
# C3P2i7nqColnCUO9A3sSR2GpZfc+xtc+LveTpoogSqiO5wE0vCPJq+JA7W69L+tI
# FNczX8DOWo02lTdhhJiOkFrZPMBUDFwZZ7CRp/wupesJAEjJlnwGrvTEZkP46mCo
# emwjb/AHAJLUPr3V+0c7pohYqCOJGwvXoom2yFzrOKN5eXaszjn7Smm9ORWpoook
# HKOImrRiCsnfvAle4UeGshTi8+5ppLIleITZMQQK94PxQERcobH2IO0zEWpKsT8J
# CYkqaeZnDGkqnETeLKa71xmLVZ5BjM1F6r8dbOaAkYn3C9mL+ltdJLIg1wO+/X3G
# m0KM3A7XwRYMJGzDev9vz380WXebTe89bE8B8iwgMPfK6yAaqv/PX79xDT2EimzH
# nFNZREPu6/7/Wi4W+56MX0wq3AkAAIouE9VEp5AfUBM2eeDM4NIG5wSMAgHSDwRv
# ix/CKUlxJnExlPggD9Xhr23CZVJMd1WA6MxFXIqGFOVdYAyjOIuUPjghl4Z0kAOS
# +1gOB0vDMPcOBo2cHNxkkKzhWu8wggcaMIIFAqADAgECAhNlAAAAYS/15SnDsI3s
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
# nCYhtUEHsxHuVnNlUl0+BVwnMYIZNzCCGTMCAQEwLDAVMRMwEQYDVQQDEwpNU0lU
# IENBIFoxAhMTAiSYrbvNMpoZEcKPAAICJJitMA0GCWCGSAFlAwQCAQUAoIGwMBkG
# CSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEE
# AYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDyV4HUgvhlTAUDYvonpdftdGQkTGZ56spB
# 5I+O1/NSwTBEBgorBgEEAYI3AgEMMTYwNKAUgBIATQBpAGMAcgBvAHMAbwBmAHSh
# HIAaaHR0cHM6Ly93d3cubWljcm9zb2Z0LmNvbSAwDQYJKoZIhvcNAQEBBQAEggEA
# VPTITdOaCuk/Dq3JOmDs8k/dV9cJygouN5jojrQu6XY8mTb8gDI9xD3/cnwegj0j
# XLgtHTgov+LELjF9PplcF4miPks7zSvTlj3PlLhmqY9ajHRKumtXj+2qYHWww9G9
# exXQJMabKJvFF4sUzYFjwd5IRWnjuzJaE2Kn/BX9iIpFphoYbNddMl0IJEeEoH2a
# wrmhVE5iBhQgzQC9Qq5wOedeB9x8yoMuwMs+1O+pCCNtv1Kwyl4B+jDJzKkhM07P
# tulTqmCNfN9hneI53Bt0K5CwHQFMn6BugtYkUvNeXx6ZpMl4Jj+3ucec0R4SmKgS
# Uq/0+/WVF7RSXg1fxNsyq6GCFykwghclBgorBgEEAYI3AwMBMYIXFTCCFxEGCSqG
# SIb3DQEHAqCCFwIwghb+AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFZBgsqhkiG9w0B
# CRABBKCCAUgEggFEMIIBQAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUA
# BCB1u2vMtbmHlDwUXI8JIkdWTtDd2ZHLsmL7AbBwsrj9pgIGZr4bGT2zGBMyMDI0
# MDgxNjIzNDAwNy41NjdaMASAAgH0oIHYpIHVMIHSMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBP
# cGVyYXRpb25zIExpbWl0ZWQxJjAkBgNVBAsTHVRoYWxlcyBUU1MgRVNOOkQwODIt
# NEJGRC1FRUJBMSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNl
# oIIReDCCBycwggUPoAMCAQICEzMAAAHcweCMwl9YXo4AAQAAAdwwDQYJKoZIhvcN
# AQELBQAwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwHhcNMjMxMDEyMTkw
# NzA2WhcNMjUwMTEwMTkwNzA2WjCB0jELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEtMCsGA1UECxMkTWljcm9zb2Z0IElyZWxhbmQgT3BlcmF0aW9u
# cyBMaW1pdGVkMSYwJAYDVQQLEx1UaGFsZXMgVFNTIEVTTjpEMDgyLTRCRkQtRUVC
# QTElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZTCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBAIvIsyA1sjg9kSKJzelrUWF5ShqYWL83
# amn3SE5JyIVPUC7F6qTcLphhHZ9idf21f0RaGrU8EHydF8NxPMR2KVNiAtCGPJa8
# kV1CGvn3beGB2m2ltmqJanG71mAywrkKATYniwKLPQLJ00EkXw5TSwfmJXbdgQLF
# lHyfA5Kg+pUsJXzqumkIvEr0DXPvptAGqkdFLKwo4BTlEgnvzeTfXukzX8vQtTAL
# fVJuTUgRU7zoP/RFWt3WagahZ6UloI0FC8XlBQDVDX5JeMEsx7jgJDdEnK44Y8gH
# uEWRDq+SG9Xo0GIOjiuTWD5uv3vlEmIAyR/7rSFvcLnwAqMdqcy/iqQPMlDOcd0A
# bniP8ia1BQEUnfZT3UxyK9rLB/SRiKPyHDlg8oWwXyiv3+bGB6dmdM61ur6nUtfD
# f51lPcKhK4Vo83pOE1/niWlVnEHQV9NJ5/DbUSqW2RqTUa2O2KuvsyRGMEgjGJA1
# 2/SqrRqlvE2fiN5ZmZVtqSPWaIasx7a0GB+fdTw+geRn6Mo2S6+/bZEwS/0IJ5gc
# KGinNbfyQ1xrvWXPtXzKOfjkh75iRuXourGVPRqkmz5UYz+R5ybMJWj+mfcGqz2h
# XV8iZnCZDBrrnZivnErCMh5Flfg8496pT0phjUTH2GChHIvE4SDSk2hwWP/uHB9g
# Es8p/9Pe/mt9AgMBAAGjggFJMIIBRTAdBgNVHQ4EFgQU6HPSBd0OfEX3uNWsdkSr
# aUGe3dswHwYDVR0jBBgwFoAUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXwYDVR0fBFgw
# VjBUoFKgUIZOaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWlj
# cm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3JsMGwGCCsGAQUF
# BwEBBGAwXjBcBggrBgEFBQcwAoZQaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgx
# KS5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAOBgNV
# HQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQADggIBANnrb8Ewr8eX/H1sKt3rnwTD
# x4AqgHbkMNQo+kUGwCINXS3y1GUcdqsK/R1g6Tf7tNx1q0NpKk1JTupUJfHdExKt
# kuhHA+82lT7yISp/Y74dqJ03RCT4Q+8ooQXTMzxiewfErVLt8WefebncST0i6ypK
# v87pCYkxM24bbqbM/V+M5VBppCUs7R+cETiz/zEA1AbZL/viXtHmryA0CGd+Pt9c
# +adsYfm7qe5UMnS0f/YJmEEMkEqGXCzyLK+dh+UsFi0d4lkdcE+Zq5JNjIHesX1w
# ztGVAtvX0DYDZdN2WZ1kk+hOMblUV/L8n1YWzhP/5XQnYl03AfXErn+1Eatylifz
# d3ChJ1xuGG76YbWgiRXnDvCiwDqvUJevVRY1qy4y4vlVKaShtbdfgPyGeeJ/YcSB
# ONOc0DNTWbjMbL50qeIEC0lHSpL2rRYNVu3hsHzG8n5u5CQajPwx9PzpsZIeFTNH
# yVF6kujI4Vo9NvO/zF8Ot44IMj4M7UX9Za4QwGf5B71x57OjaX53gxT4vzoHvEBX
# F9qCmHRgXBLbRomJfDn60alzv7dpCVQIuQ062nyIZKnsXxzuKFb0TjXWw6OFpG1b
# sjXpOo5DMHkysribxHor4Yz5dZjVyHANyKo0bSrAlVeihcaG5F74SZT8FtyHAW6I
# gLc5w/3D+R1obDhKZ21WMIIHcTCCBVmgAwIBAgITMwAAABXF52ueAptJmQAAAAAA
# FTANBgkqhkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUgQXV0
# aG9yaXR5IDIwMTAwHhcNMjEwOTMwMTgyMjI1WhcNMzAwOTMwMTgzMjI1WjB8MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNy
# b3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDCCAiIwDQYJKoZIhvcNAQEBBQADggIP
# ADCCAgoCggIBAOThpkzntHIhC3miy9ckeb0O1YLT/e6cBwfSqWxOdcjKNVf2AX9s
# SuDivbk+F2Az/1xPx2b3lVNxWuJ+Slr+uDZnhUYjDLWNE893MsAQGOhgfWpSg0S3
# po5GawcU88V29YZQ3MFEyHFcUTE3oAo4bo3t1w/YJlN8OWECesSq/XJprx2rrPY2
# vjUmZNqYO7oaezOtgFt+jBAcnVL+tuhiJdxqD89d9P6OU8/W7IVWTe/dvI2k45GP
# sjksUZzpcGkNyjYtcI4xyDUoveO0hyTD4MmPfrVUj9z6BVWYbWg7mka97aSueik3
# rMvrg0XnRm7KMtXAhjBcTyziYrLNueKNiOSWrAFKu75xqRdbZ2De+JKRHh09/SDP
# c31BmkZ1zcRfNN0Sidb9pSB9fvzZnkXftnIv231fgLrbqn427DZM9ituqBJR6L8F
# A6PRc6ZNN3SUHDSCD/AQ8rdHGO2n6Jl8P0zbr17C89XYcz1DTsEzOUyOArxCaC4Q
# 6oRRRuLRvWoYWmEBc8pnol7XKHYC4jMYctenIPDC+hIK12NvDMk2ZItboKaDIV1f
# MHSRlJTYuVD5C4lh8zYGNRiER9vcG9H9stQcxWv2XFJRXRLbJbqvUAV6bMURHXLv
# jflSxIUXk8A8FdsaN8cIFRg/eKtFtvUeh17aj54WcmnGrnu3tz5q4i6tAgMBAAGj
# ggHdMIIB2TASBgkrBgEEAYI3FQEEBQIDAQABMCMGCSsGAQQBgjcVAgQWBBQqp1L+
# ZMSavoKRPEY1Kc8Q/y8E7jAdBgNVHQ4EFgQUn6cVXQBeYl2D9OXSZacbUzUZ6XIw
# XAYDVR0gBFUwUzBRBgwrBgEEAYI3TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBMG
# A1UdJQQMMAoGCCsGAQUFBwMIMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsG
# A1UdDwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFNX2VsuP6KJc
# YmjRPZSQW9fOmhjEMFYGA1UdHwRPME0wS6BJoEeGRWh0dHA6Ly9jcmwubWljcm9z
# b2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIz
# LmNybDBaBggrBgEFBQcBAQROMEwwSgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cubWlj
# cm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3J0
# MA0GCSqGSIb3DQEBCwUAA4ICAQCdVX38Kq3hLB9nATEkW+Geckv8qW/qXBS2Pk5H
# ZHixBpOXPTEztTnXwnE2P9pkbHzQdTltuw8x5MKP+2zRoZQYIu7pZmc6U03dmLq2
# HnjYNi6cqYJWAAOwBb6J6Gngugnue99qb74py27YP0h1AdkY3m2CDPVtI1TkeFN1
# JFe53Z/zjj3G82jfZfakVqr3lbYoVSfQJL1AoL8ZthISEV09J+BAljis9/kpicO8
# F7BUhUKz/AyeixmJ5/ALaoHCgRlCGVJ1ijbCHcNhcy4sa3tuPywJeBTpkbKpW99J
# o3QMvOyRgNI95ko+ZjtPu4b6MhrZlvSP9pEB9s7GdP32THJvEKt1MMU0sHrYUP4K
# WN1APMdUbZ1jdEgssU5HLcEUBHG/ZPkkvnNtyo4JvbMBV0lUZNlz138eW0QBjloZ
# kWsNn6Qo3GcZKCS6OEuabvshVGtqRRFHqfG3rsjoiV5PndLQTHa1V1QJsWkBRH58
# oWFsc/4Ku+xBZj1p/cvBQUl+fpO+y/g75LcVv7TOPqUxUYS8vwLBgqJ7Fx0ViY1w
# /ue10CgaiQuPNtq6TPmb/wrpNPgkNWcr4A245oyZ1uEi6vAnQj0llOZ0dFtq0Z4+
# 7X6gMTN9vMvpe784cETRkPHIqzqKOghif9lwY1NNje6CbaUFEMFxBmoQtB1VM1iz
# oXBm8qGCAtQwggI9AgEBMIIBAKGB2KSB1TCB0jELMAkGA1UEBhMCVVMxEzARBgNV
# BAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEtMCsGA1UECxMkTWljcm9zb2Z0IElyZWxhbmQgT3Bl
# cmF0aW9ucyBMaW1pdGVkMSYwJAYDVQQLEx1UaGFsZXMgVFNTIEVTTjpEMDgyLTRC
# RkQtRUVCQTElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIj
# CgEBMAcGBSsOAwIaAxUAHDn/cz+3yRkIUCJfSbL3djnQEqaggYMwgYCkfjB8MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNy
# b3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQUFAAIFAOpp6v0w
# IhgPMjAyNDA4MTYyMzEzMDFaGA8yMDI0MDgxNzIzMTMwMVowdDA6BgorBgEEAYRZ
# CgQBMSwwKjAKAgUA6mnq/QIBADAHAgEAAgIOYTAHAgEAAgIWLzAKAgUA6ms8fQIB
# ADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQow
# CAIBAAIDAYagMA0GCSqGSIb3DQEBBQUAA4GBAGKQZUVWtW9Qh0f21mMVu9wYu11K
# 9eNesI6GubR9pJgtg16EWGiYoyee+rFVYGJg7NQIrr68GVN5bJuWP8fj778iMMqv
# yGoNIgu5XTNA4L/iPDUEYavIdO3OvcJ+4Sa64tPDov4NaXQbZrO4zixdSGBLs4sk
# sKa5A837jAj3/+XdMYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNV
# BAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAg
# UENBIDIwMTACEzMAAAHcweCMwl9YXo4AAQAAAdwwDQYJYIZIAWUDBAIBBQCgggFK
# MBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgRqQS
# KaGtaiHPCc1c4qlUtbj75Xg1wJytT9flcqutQM8wgfoGCyqGSIb3DQEJEAIvMYHq
# MIHnMIHkMIG9BCBTpxeKatlEP4y8qZzjuWL0Ou0IqxELDhX2TLylxIINNzCBmDCB
# gKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNV
# BAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAAB3MHgjMJfWF6O
# AAEAAAHcMCIEIPnnH7S8SkJlSDMbeuZ2QljcslFhhHbq2xiB/3vVeS+nMA0GCSqG
# SIb3DQEBCwUABIICAAqRgWnOha67DyjwRdL4fNB2xqR5Sm7ykCu8GKad7rtKa8qo
# klil3pt36KvBaB1fMUGah1SfeZgRJp3rIXMDBUy3Buogg2DEBpuwrQp3QZVz+Ne0
# J0QcksTjQNDCDz6vYBlDLwQfzUV7F7yd0sUow08CFj18GNp7gxMFdV2wzyo+DNI+
# LlTZshj7Z3Z0KGeEp4ZKw4or0UsbPzVAl0FVVaTWFnkVIKcaMLiO4AFr+IFfYvSS
# 3cAiNPpEWyyM59HyF5ovQDy8bryH7/PzxGWKmF29zB2iHHdh+j3o88b3TllQfpZu
# JaycMqNrrhv5zH8iF7afycVUM9mv9lN/wj1lrby7dqKUjY5WCVY3S4xtttYNID8d
# zxXuA71T+7zsKXABSrJeW92Q6XTxktsxa0dEnwQJ9ugoPsFZwx6PVaQ6RY17ek3A
# WtAvTiI7Gw89x+CbJmsCQBihTJvM5k7B3IwnJz60GW+6Mf8OWbmEdyGJxWEVVnm6
# +4MOtLQMoSgea28rHJX6eo4SklsjNJ39eParjj066YwBsFzV9jHB6t12y0PrY64J
# R658GukMEoQz36RRs2uXhH8ayLKDlbcEJCG47MREOQQg+sZrj2ZYsag3v40wEP4Y
# 5pp6dQbF5U1oWtnd4d8q/modJcakOmOW7y/O71S7tLQxy3J5ACHYgPSRGaN6
# SIG # End signature block
