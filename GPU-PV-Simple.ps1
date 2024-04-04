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
    [float]$RAMAmount=66.66

    # Automatically Set Resolution To Current HOST Resolution? If $false Then Defaults To "Max Hyper-V Supported" -> 1920/1080
    [bool]$ScreenResolutionAutoSet=$true

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

# ***Where The Magic Happens*** #
Set-VM -VMName $VMName -AutomaticCheckpointsEnabled $false -AutomaticStopAction TurnOff -CheckpointType Disabled -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace 3GB -HighMemoryMappedIoSpace $SplitRAM -StaticMemory -MemoryStartupBytes $SplitRAM
Set-VMHost -ComputerName $VMPartGPU.ComputerName -EnableEnhancedSessionMode $false
Set-VMVideo -VMName $VMName -HorizontalResolution $HorizonalResolution -VerticalResolution $VerticalResolution -ResolutionType Single
Remove-VMGpuPartitionAdapter -VMName $VMName 2>&1>$null
Add-VMGpuPartitionAdapter -VMName $VMName -MinPartitionCompute $SplitCompute -MinPartitionDecode $SplitDecode -MinPartitionEncode $SplitEncode -MinPartitionVRAM $SplitVRAM -MaxPartitionCompute $SplitCompute -MaxPartitionDecode $SplitDecode -MaxPartitionEncode $SplitEncode -MaxPartitionVRAM $SplitVRAM -OptimalPartitionCompute $SplitCompute -OptimalPartitionDecode $SplitDecode -OptimalPartitionEncode $SplitEncode -OptimalPartitionVRAM $SplitVRAM