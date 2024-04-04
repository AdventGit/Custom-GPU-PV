# PInvoke Type For Grabbing HOST Screen Resolution
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class PInvoke {
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr hdc, int nIndex);
}
"@

# ***Change Variables Here*** #

    # Virtual Machine Name
    [string]$VMName="VIRTUAL MACHINE NAME"

    # GUEST GPU Compute/Decode/Encode Percentage
    [int]$GPUProcSplitPercent=66

    # GUEST GPU VRAM Percentage
    [int]$GPUVRAMSplitPercent=75

    # GUEST RAM Amount Percentage
    [int]$RAMAmount=66.66

    # Automatically Set Resolution To Current HOST Resolution? If $false Then Defaults To "Max Hyper-V Supported" -> 1920/1080
    [bool]$ScreenResolutionAutoSet=$true

    # Location Of Your VM VHDX File
    [string]$VHDXLoc="C:\PATH\TO\FILE\FILENAME.vhdx"

# ***No Touch Below*** #
if($ScreenResolutionAutoSet){
    [IntPtr]$hdc=[PInvoke]::GetDC([IntPtr]::Zero)
    [int]$HorizonalResolution=[PInvoke]::GetDeviceCaps($hdc,118)
    [int]$VerticalResolution=[PInvoke]::GetDeviceCaps($hdc,117)
}else{
    [int]$HorizonalResolution=1920
    [int]$VerticalResolution=1080
}
[float]$GPUProcSplit=[math]::round($(100/$GPUProcSplitPercent),2)
[long]$SplitRAM=([math]::Ceiling(((((Get-WmiObject Win32_PhysicalMemory).Capacity | Measure-Object -Sum).Sum/1048576)/[math]::round($(100/$RAMAmount),2))/2)*2)*1MB
[Microsoft.HyperV.PowerShell.VirtualizationObject]$VMPartGPU=(Get-VMPartitionableGPU)
[uint64]$SplitCompute=([math]::round($($VMPartGPU.MaxPartitionCompute/$GPUProcSplit)))
[uint64]$SplitDecode=([math]::round($($VMPartGPU.MaxPartitionDecode/$GPUProcSplit)))
[uint64]$SplitEncode=([math]::round($($VMPartGPU.MaxPartitionEncode/$GPUProcSplit)))
[uint64]$SplitVRAM=([math]::round($($VMPartGPU.MaxPartitionVRAM/[math]::round($(100/$GPUVRAMSplitPercent),2))))
[string]$GPUFuzzyInstancePath="PCI\$($VMPartGPU.Name.Substring(8))"
[string]$GPUFuzzyInstancePath=$GPUFuzzyInstancePath.Substring(0, $GPUFuzzyInstancePath.IndexOf("&") + 1 + $GPUFuzzyInstancePath.Substring($GPUFuzzyInstancePath.IndexOf("&") + 1).IndexOf("&"))
[CimInstance]$GPU=Get-PnpDevice | Where-Object {($_.DeviceID -like "$GPUFuzzyInstancePath*") -and ($_.Status -eq "OK")} | Select-Object -First 1
[string]$GPUFriendlyName=$($GPU.FriendlyName)
Write-Host "Copying The Driver Files For HOST $GPUFriendlyName To VM..."
Mount-DiskImage -ImagePath $VHDXLoc 2>&1>$null
[string]$VHDXDriveLetter="$((Get-Partition (Get-DiskImage -ImagePath $VHDXLoc).Number | Get-Volume).DriveLetter):".Replace(" ","")
New-Item -ItemType Directory -Path "$VHDXDriveLetter\Windows\System32\HostDriverStore" -Force 2>&1>$null
[string]$ServicePath=(Get-WmiObject Win32_SystemDriver | Where-Object {$_.Name -eq "$($GPU.Service)"}).Pathname
[string]$ServiceDriverDest=("$VHDXDriveLetter"+"\"+$($ServicePath.split('\')[1..5] -join('\'))).Replace("DriverStore","HostDriverStore")
if(!(Test-Path $ServiceDriverDest)){
    Copy-item -path "$($ServicePath.split('\')[0..5] -join('\'))" -Destination "$ServiceDriverDest" -Recurse 2>&1>$null
}
foreach($d in Get-WmiObject Win32_PNPSignedDriver | Where-Object {$_.DeviceName -eq "$GPUFriendlyName"}){
    if($d.DeviceName -like "NVIDIA*"){New-Item -ItemType Directory -Path "$VHDXDriveLetter\Windows\System32\drivers\NVIDIA Corporation\" -Force 2>&1>$null}
    foreach($i in (Get-WmiObject Win32_PNPSignedDriverCIMDataFile | Where-Object {$_.Antecedent -eq "\\"+$VMPartGPU.ComputerName+"\ROOT\cimv2:Win32_PNPSignedDriver.DeviceID=""$($d.DeviceID -replace `"\\`",`"\\`")"""}).Dependent){
        [string]$NewPath=$i.Split("=",2)[1].Trim('"') -replace '\\\\','\'
        if($NewPath -like "c:\windows\system32\driverstore\*"){
            [string]$DriverDest=("$VHDXDriveLetter"+"\"+$($NewPath.split('\')[1..5] -join('\'))).Replace("driverstore","HostDriverStore")
            if(!(Test-Path $DriverDest)){
                [string]$DriverDir=$NewPath.split('\')[0..5] -join('\')
                Copy-item -path "$DriverDir" -Destination "$DriverDest" -Recurse 2>&1>$null
            }
        }else{
            [string]$ParseDestination=$NewPath.Replace("c:","$VHDXDriveLetter")
            [string]$Destination=$ParseDestination.Substring(0,$ParseDestination.LastIndexOf('\'))
            if(!$(Test-Path -Path $Destination)){New-Item -ItemType Directory -Path $Destination -Force 2>&1>$null}
            Copy-Item $NewPath -Destination $Destination -Force 2>&1>$null
        }
    }
}
Write-Host "Defragging VHDX..."
Optimize-Volume -DriveLetter $VHDXDriveLetter[0] -Defrag 2>&1>$null
Dismount-VHD $VHDXLoc 2>&1>$null
Mount-VHD $VHDXLoc -ReadOnly 2>&1>$null
[string]$VHDXDriveLetter="$((Get-Partition (Get-DiskImage -ImagePath $VHDXLoc).Number | Get-Volume).DriveLetter):".Replace(" ","")
Write-Host "Optimizing VHDX..."
Optimize-VHD $VHDXLoc -Mode Quick 2>&1>$null
Dismount-VHD $VHDXLoc 2>&1>$null
Write-Host "Attaching HOST $GPUFriendlyName to $VMName..."
Set-VM -VMName $VMName -AutomaticCheckpointsEnabled $false -AutomaticStopAction TurnOff -CheckpointType Disabled -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace 3GB -HighMemoryMappedIoSpace $SplitRAM -StaticMemory -MemoryStartupBytes $SplitRAM
Set-VMHost -ComputerName $VMPartGPU.ComputerName -EnableEnhancedSessionMode $false
Set-VMVideo -VMName $VMName -HorizontalResolution $HorizonalResolution -VerticalResolution $VerticalResolution -ResolutionType Single
Remove-VMGpuPartitionAdapter -VMName $VMName 2>&1>$null
Add-VMGpuPartitionAdapter -VMName $VMName -MinPartitionCompute $SplitCompute -MinPartitionDecode $SplitDecode -MinPartitionEncode $SplitEncode -MinPartitionVRAM $SplitVRAM -MaxPartitionCompute $SplitCompute -MaxPartitionDecode $SplitDecode -MaxPartitionEncode $SplitEncode -MaxPartitionVRAM $SplitVRAM -OptimalPartitionCompute $SplitCompute -OptimalPartitionDecode $SplitDecode -OptimalPartitionEncode $SplitEncode -OptimalPartitionVRAM $SplitVRAM
Write-Host "Done!"