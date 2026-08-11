Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class CursorHelper
{
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT point);
}
"@

Write-Host "Move your mouse over the Teams button to inspect..."
Write-Host "Inspecting in 5 seconds..."

Start-Sleep -Seconds 5

$point = New-Object CursorHelper+POINT
[CursorHelper]::GetCursorPos([ref]$point) | Out-Null

$automationPoint = New-Object System.Windows.Point($point.X, $point.Y)
$element = [System.Windows.Automation.AutomationElement]::FromPoint($automationPoint)

Write-Host "`nElement under cursor:"

$level = 0

while ($element -and $level -lt 10) {

    try {
        $patterns = @(
            $element.GetSupportedPatterns() |
            ForEach-Object { $_.ProgrammaticName }
        ) -join ", "

        [PSCustomObject]@{
            Level        = $level
            Name         = $element.Current.Name
            ControlType  = $element.Current.ControlType.ProgrammaticName
            AutomationId = $element.Current.AutomationId
            ClassName    = $element.Current.ClassName
            ProcessId    = $element.Current.ProcessId
            Enabled      = $element.Current.IsEnabled
            Patterns     = $patterns
        } | Format-List
    }
    catch {
        Write-Host "Could not inspect level $level"
    }

    try {
        $element = [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($element)
    }
    catch {
        break
    }

    $level++
}
