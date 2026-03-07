<#
.SYNOPSIS
  Installs prereq's, then shallow-clones the IxpTools repo and runs its install script.

  This script is intended to be run in legacy powershell.exe. It will make sure that pwsh
  and git are available before running the main IxpTools install script, and also check
  execution policy.

  It assumes winget is available, which should be a safe bet, as it's widely available
  now.
#>
[CmdletBinding( DefaultParameterSetName = '__AllParameterSets' )]
param(
    # Advanced: this specifies the branch of the repo that you would like to use. Unless
    # you have a specific reason to use a different branch, you should just use the
    # default.
    [string] $Branch,

    # Advanced: this specifies the directory where the IxpTools directory will be created
    # (which will be added to the PSModulePath environment variable). The default is
    # '%LOCALAPPDATA%\PowerShell\Modules'.
    [String] $DestinationParentDir,

    # The following three switches correspond to the install modes supported by winget.
    # Winget uses SilentWithProgress by default.
    [Parameter( Mandatory, ParameterSetName = 'SilentWithProgress' )]
    [Alias( 'SP' )]
    [switch] $SilentWithProgress,

    [Parameter( Mandatory, ParameterSetName = 'Silent' )]
    [Alias( 'S' )]
    [switch] $Silent,

    [Parameter( Mandatory, ParameterSetName = 'Interactive' )]
    [switch] $Interactive,

    [string] $UserDirsCloneDir
)

try
{
    Set-StrictMode -Version Latest

    # These switches are intended for use by a winget package, if we ever decide to do
    # that (they are the three winget install modes).
    if( $Interactive )
    {
        Write-Verbose "(install mode: Interactive)"
    }
    elseif( $Silent )
    {
        Write-Verbose "(install mode: Silent)"
    }
    else
    {
        if( !$SilentWithProgress )
        {
            Write-Verbose "(install mode: Silent)"
        }
        $SilentWithProgress = $true
    }

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
    # Check some prerequisites: first, make sure we have git and pwsh.
    #

    function InstallViaWinget
    {
        [CmdletBinding()]
        param( [Parameter( Mandatory, Position = 0 )]
               [string] $CmdToProbe,

               [Parameter( Mandatory, Position = 1 )]
               [string] $DisplayName,

               [Parameter( Mandatory, Position = 2 )]
               [string] $PackageId,

               [Parameter(            Position = 3 )]
               [string[]] $ExtraInstallArgs = @(),

               [Parameter(            Position = 4 )]
               [ScriptBlock] $PostInstall
        )

        if( $Interactive )
        {
            $ExtraInstallArgs += '--interactive'
        }
        elseif( $Silent )
        {
            $ExtraInstallArgs += '--silent'
        }

        winget install --id $PackageId --accept-package-agreements --accept-source-agreements @ExtraInstallArgs

        if( $PostInstall )
        {
            . $PostInstall
        }

        if( !(Get-Command $CmdToProbe -EA Ignore) )
        {
            # Huh... perhaps the user canceled it or such.
            Write-Error @"
Could not find $CmdToProbe after attempting install. Consider installing $DisplayName manually, relaunching Terminal, and trying again.
"@
            return
        }
    }

    $prereqs = @(
        @{ CmdToProbe = 'git.exe'
           DisplayName = 'Git'
           PackageId = 'Microsoft.Git'
           ExtraInstallArgs = @('--scope', 'user') # As of 2026/02, this does not avoid a UAC prompt. :(
           PostInstall = {
               # If we are installing git for them, let's set them up with some better
               # defaults.

               # Leave line endings alone, kthx
               git config --global core.autocrlf false

               # Other stuff from: https://blog.gitbutler.com/how-git-core-devs-configure-git/

               # Don't make me pass all the extra stuff to set up the branch on the
               # remote:
               git config --global push.autoSetupRemote true

               # Better diffs:
               git config --global diff.algorithm histogram

               # More useful sorting of `git branch`:
               git config --global branch.sort -committerdate
           } },

        @{ CmdToProbe = 'pwsh.exe'
           DisplayName = 'PowerShell'
           PackageId = 'Microsoft.PowerShell'
           ExtraInstallArgs = @('--scope', 'user') }
    )

    $stillNeed = @($prereqs | Where-Object {
        if( Get-Command $_.CmdToProbe -EA Ignore )
        {
            Write-Host "(already have $($_.DisplayName))" -Fore DarkGray
        }
        else
        {
            $true
        }
    })

    if( $stillNeed )
    {
        Write-Host "This module requires the following:" -Fore Cyan
        Write-Host ""
        $stillNeed | %{ Write-Host "   $($_.DisplayName)" -Fore Cyan }
        Write-Host ""

        if( $Interactive )
        {
            $response = Read-Host "Would you like me to install these for you? (Y|n)"

            if( $response -and ($response -ne 'y') )
            {
                Write-Error "Required commands ($($stillNeed.DisplayName -join ', ')) missing."
                return
            }
        }

        foreach( $prereq in $stillNeed )
        {
            InstallViaWinget @prereq
        }
    }

    # Make sure we have decent versions of our prereqs. If we don't, this script just
    # errors out.
    #
    # TODO: we could probably just reuse the "install" code to update, but I don't have
    # time to test that right now, so we'll take the easy road for now.

    function CheckVersion
    {
        [CmdletBinding()]
        param( $CmdName, $VerCmdArgs, $VerRegex, [Version] $MinVer )

        $verOutput = & $CmdName $VerCmdArgs
        if( $verOutput -match $VerRegex )
        {
            $installedVer = [Version]::Parse( $Matches.ShortVer )

            if( $installedVer -lt $MinVer )
            {
                throw "You need a newer version of $CmdName (better than $MinVer)."
            }
        }
        else
        {
            throw "Could not determine $CmdName version."
        }
    }

    CheckVersion -CmdName 'git' `
                 -VerCmdArgs '--version' `
                 -VerRegex 'git version (?<ShortVer>\d+\.\d+).*' `
                 -MinVer '2.22'

    CheckVersion -CmdName 'pwsh' `
                 -VerCmdArgs '--version' `
                 -VerRegex 'PowerShell (?<ShortVer>\d+\.\d+).*' `
                 -MinVer '7.4'

    #
    # Check PS execution policy.
    #

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

            if( $Interactive )
            {
                $response = Read-Host "Change execution policy to 'RemoteSigned'? (y|N)"
                if( $response -ne 'y' )
                {
                    Write-Error "You need to change ExecutionPolicy to allow (local, unsigned) scripts to run. See about_Execution_Policies."
                    return
                }
            }

            Write-Host "Updating execution policy to 'RemoteSigned'..." -Fore Cyan
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

    if( $UserDirsCloneDir )
    {
        $optionalParams[ 'UserDirsCloneDir' ] = $UserDirsCloneDir
    }

    if( $Interactive )
    {
        $nonInteractiveParam = ''
    }
    else
    {
        $nonInteractiveParam = '-NonInteractive'
        $optionalParams[ 'NonInteractive' ] = $true
    }

    if( $VerbosePreference -eq 'Continue' )
    {
        $verboseParam = '-Verbose'
    }
    else
    {
        $verboseParam = ''
    }

    # If someone is running this interactively, we would like them to be able to
    # immediately start a fresh pwsh, in this window, and start using IxpTools. But to do
    # that, we need to update $env:PSModulePath. The main install script will do that, but
    # it will be in the child pwsh process (that we are about to launch); in order to pick
    # it up here, we'll need to refresh that var here in this process as well.

    $psModulePathBefore = GetStaticPathFromRegistry 'PSModulePath'

    # Using -File instead of -Command gets us better fidelity exit codes.
    pwsh -NoProfile `
         $nonInteractiveParam `
         -ExecutionPolicy RemoteSigned `
         -File $(Join-Path $cloneDest $ScriptInRepo) `
         @optionalParams `
         $verboseParam

    $installExitCode = $LASTEXITCODE

    UpdateCurrentProcessPathBasedOnDiff 'PSModulePath' $psModulePathBefore

    Remove-Item -Force -Recurse $cloneDest

    if( $installExitCode )
    {
        Write-Error "Main install script failed, error code: $installExitCode"
    }
    else
    {
        if( $PSVersionTable.PSVersion.Major -eq 5 )
        {
            [bool] $isRazzle = !!(${env:build.nttree})
            $theCmd = 'pwsh'
            if( $isRazzle )
            {
                $theCmd = 'psrazzle'
            }

            Write-Host "(The current shell is legacy Windows PowerShell (5.1). To start" -Fore DarkGray
            Write-Host "using IxpTools, run " -Fore DarkGray -NoNewline ; Write-Host $theCmd -Fore Green -NoNewline ; Write-Host ")" -Fore DarkGray
            Write-Host ""
        }
    }
}
finally { } # ensure terminating errors are terminating

