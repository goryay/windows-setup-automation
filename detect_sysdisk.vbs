'=====================================================================
' detect_sysdisk.vbs  <config.txt>  [disksfile]
'
' Auto-detects disk ROLES from the SL config for the PXE install:
'   - the Windows SYSTEM disk (where Setup installs), and
'   - the DATA/ARCHIVE disks (to protect from the "clean extra disks" step).
'
' Reads the config, computes each RAID group's usable size, then matches
' groups to the INTERNAL (non-USB) physical disks by size.
'
' Machine-parseable lines for install.bat:
'   RESULT=<index>     exactly one disk matched the SYSTEM group -> auto-select
'   RESULT=NONE        no unique system match (install.bat -> manual)
'   RESULT=AMBIGUOUS   >1 system-size match (manual)
'   RESULT=ERROR       config unreadable
'   PROTECT=<i,i,...>   disks that are system/data/archive (protect from wipe)
'
' [disksfile] optional TEST input (replaces WMI). One disk per line:
'   Index|SizeBytes|Model|InterfaceType[|PNPDeviceID[|MediaType]]
'
' WinPE (PXE install) has no powershell.exe -> cscript. Output kept ASCII;
' install.bat adds the Russian framing.
'=====================================================================
Option Explicit

Dim fso, cfgPath, disksFile
Dim cfg, sysN, sysType, sysSizeStr, sysQty, oneGB, expectedGB
Dim disks, tolLo, tolHi, matchIdx, matchCount, sysIdx
Dim dataSizes, dataCount
Dim key, d, gi

Set fso = CreateObject("Scripting.FileSystemObject")

If WScript.Arguments.Count < 1 Then
    WScript.Echo "usage: detect_sysdisk.vbs <config.txt> [disksfile]"
    WScript.Echo "RESULT=ERROR"
    WScript.Echo "PROTECT="
    WScript.Quit 2
End If
cfgPath = WScript.Arguments(0)
disksFile = ""
If WScript.Arguments.Count >= 2 Then disksFile = WScript.Arguments(1)

Set cfg = ReadConfig(cfgPath)
If cfg Is Nothing Then
    WScript.Echo "[detect] config not readable: " & cfgPath
    WScript.Echo "RESULT=ERROR"
    WScript.Echo "PROTECT="
    WScript.Quit 3
End If

' --- SYSTEM group (disk_system=TRUE) + expected size ---
sysN = -1
For gi = 1 To 32
    If cfg.Exists("group_" & gi & "_disk_system") Then
        If UCase(Trim(cfg("group_" & gi & "_disk_system"))) = "TRUE" Then
            sysN = gi
            Exit For
        End If
    End If
Next

expectedGB = 0
If sysN <> -1 Then
    sysType    = "" & cfg("group_" & sysN & "_type")
    sysSizeStr = "" & cfg("group_" & sysN & "_disk_size")
    sysQty     = CLng("0" & OnlyDigits("" & cfg("group_" & sysN & "_disk_quantity")))
    If sysQty < 1 Then sysQty = 1
    oneGB      = SizeToGB(sysSizeStr)
    expectedGB = RaidUsableGB(sysType, oneGB, sysQty)
    WScript.Echo "[detect] SYSTEM group: group_" & sysN & "  Type=" & sysType & _
        "  " & sysQty & " x " & CLng(oneGB) & " GB  -> expected ~" & CLng(expectedGB) & " GB"
Else
    WScript.Echo "[detect] no group with disk_system=TRUE in config."
End If

' --- DATA/ARCHIVE groups (disk_system<>TRUE) -> expected sizes ---
Dim gt, gs, gq, ge
ReDim dataSizes(31)
dataCount = 0
For gi = 1 To 32
    If cfg.Exists("group_" & gi & "_disk_system") Then
        If UCase(Trim(cfg("group_" & gi & "_disk_system"))) <> "TRUE" Then
            gt = "" & cfg("group_" & gi & "_type")
            gs = SizeToGB("" & cfg("group_" & gi & "_disk_size"))
            gq = CLng("0" & OnlyDigits("" & cfg("group_" & gi & "_disk_quantity")))
            If gq < 1 Then gq = 1
            ge = RaidUsableGB(gt, gs, gq)
            If ge >= 1 Then
                dataSizes(dataCount) = ge
                dataCount = dataCount + 1
                WScript.Echo "[detect] DATA group:   group_" & gi & "  Type=" & gt & _
                    "  -> expected ~" & CLng(ge) & " GB"
            End If
        End If
    End If
Next

Set disks = EnumDisks(disksFile)

' --- pass 1: count SYSTEM-size matches among internal (non-USB) disks ---
matchIdx = -1 : matchCount = 0 : sysIdx = -1
tolLo = 0 : tolHi = 0
If expectedGB >= 1 Then
    tolLo = expectedGB * 0.75
    tolHi = expectedGB * 1.25
    For Each key In disks.Keys
        Set d = disks(key)
        If Not IsUsbDisk(d) Then
            If d.SizeGB >= tolLo And d.SizeGB <= tolHi Then
                matchIdx = d.Idx
                matchCount = matchCount + 1
            End If
        End If
    Next
    If matchCount = 1 Then sysIdx = matchIdx
End If

' --- pass 2: classify each disk, print roles, build PROTECT list ---
Dim protect, role, bt
protect = ""
WScript.Echo "[detect] Disks and roles:"
For Each key In disks.Keys
    Set d = disks(key)
    bt = d.Iface
    If IsUsbDisk(d) Then
        If UCase(d.Iface) = "USB" Then bt = "USB" Else bt = d.Iface & "/USB"
        role = "USB flash (skipped)"
    ElseIf d.Idx = sysIdx Then
        role = "SYSTEM <-- install target"
        protect = protect & d.Idx & ","
    ElseIf IsDataDisk(d.SizeGB) Then
        role = "DATA/ARCHIVE (protected from wipe)"
        protect = protect & d.Idx & ","
    ElseIf expectedGB >= 1 And d.SizeGB >= tolLo And d.SizeGB <= tolHi Then
        role = "system-size candidate (ambiguous)"
    Else
        role = "other"
    End If
    WScript.Echo "[detect]   Disk " & d.Idx & ": " & d.Model & _
        "  " & CLng(d.SizeGB) & " GB  [" & bt & "]  -> " & role
Next
If Len(protect) > 0 Then protect = Left(protect, Len(protect) - 1)

' --- result ---
If sysIdx <> -1 Then
    WScript.Echo "[detect] Matched SYSTEM disk index: " & sysIdx
    WScript.Echo "RESULT=" & sysIdx
ElseIf matchCount = 0 Then
    WScript.Echo "[detect] No unique SYSTEM disk - manual entry needed."
    WScript.Echo "RESULT=NONE"
Else
    WScript.Echo "[detect] " & matchCount & " system-size disks - ambiguous, manual entry."
    WScript.Echo "RESULT=AMBIGUOUS"
End If
WScript.Echo "PROTECT=" & protect
WScript.Quit 0

'===================== helpers =====================

Function ReadConfig(path)
    Dim f, line, eqPos, k, v, dct
    Set ReadConfig = Nothing
    If Not fso.FileExists(path) Then Exit Function
    Set dct = CreateObject("Scripting.Dictionary")
    dct.CompareMode = vbTextCompare
    On Error Resume Next
    Set f = fso.OpenTextFile(path, 1, False)
    If Err.Number <> 0 Then On Error GoTo 0 : Exit Function
    On Error GoTo 0
    Do Until f.AtEndOfStream
        line = Trim(f.ReadLine)
        If line <> "" And Left(line, 1) <> "#" Then
            eqPos = InStr(line, "=")
            If eqPos > 1 Then
                k = Trim(Left(line, eqPos - 1))
                v = Trim(Mid(line, eqPos + 1))
                dct(k) = v
            End If
        End If
    Loop
    f.Close
    Set ReadConfig = dct
End Function

Function OnlyDigits(s)
    Dim i, c, o
    o = ""
    For i = 1 To Len(s)
        c = Mid(s, i, 1)
        If c >= "0" And c <= "9" Then o = o & c
    Next
    OnlyDigits = o
End Function

' "240Gb" -> 240 ; "0,24Tb"/"0.24Tb" -> 240 ; "16Tb" -> 16000 (GB, decimal)
Function SizeToGB(s)
    Dim re, m, numStr, unit, num, dotPos, frac
    SizeToGB = 0
    If IsNull(s) Or s = "" Then Exit Function
    s = Replace(s, ",", ".")
    Set re = New RegExp
    re.Pattern = "([0-9]+(\.[0-9]+)?)\s*([TtGg])"
    re.Global = False
    If Not re.Test(s) Then Exit Function
    Set m = re.Execute(s)
    numStr = m(0).SubMatches(0)          ' e.g. "0.48" or "480"
    unit   = UCase(m(0).SubMatches(2))
    ' Locale-independent parse: CDbl honours the system decimal separator, so on
    ' a RU locale CDbl("0.48") fails. Split on the dot and add the fraction by hand
    ' (CDbl on pure-integer strings is locale-safe).
    dotPos = InStr(numStr, ".")
    If dotPos > 0 Then
        frac = Mid(numStr, dotPos + 1)
        num = CDbl(Left(numStr, dotPos - 1)) + CDbl(frac) / (10 ^ Len(frac))
    Else
        num = CDbl(numStr)
    End If
    If unit = "T" Then SizeToGB = num * 1000 Else SizeToGB = num
End Function

' Usable size of an array, by RAID level (works for system and data groups).
Function RaidUsableGB(t, sizeGB, qty)
    Dim n
    n = UCase(Replace(Replace(Replace("" & t, " ", ""), "-", ""), "_", ""))
    Select Case n
        Case "RAID0":  RaidUsableGB = sizeGB * qty
        Case "RAID1":  RaidUsableGB = sizeGB
        Case "RAID5":  RaidUsableGB = sizeGB * (qty - 1)
        Case "RAID6":  RaidUsableGB = sizeGB * (qty - 2)
        Case "RAID10": RaidUsableGB = sizeGB * (qty \ 2)
        Case Else:     RaidUsableGB = sizeGB   ' single disk / wo_RAID
    End Select
    If RaidUsableGB < 1 Then RaidUsableGB = sizeGB
End Function

' DATA/ARCHIVE if it's clearly a large array (>=4 TB, no OS is that big) or its
' size matches a config DATA group. Used to protect the disk from the wipe step.
Function IsDataDisk(sizeGB)
    Dim i
    IsDataDisk = False
    If sizeGB >= 4000 Then IsDataDisk = True : Exit Function
    For i = 0 To dataCount - 1
        If sizeGB >= dataSizes(i) * 0.75 And sizeGB <= dataSizes(i) * 1.25 Then
            IsDataDisk = True : Exit Function
        End If
    Next
End Function

' USB/removable if the interface says USB, OR it enumerates under USBSTOR, OR
' MediaType is removable, OR the model names a USB flash line. Reliable even
' when WMI mislabels a stick as a fixed SCSI disk. Never pick these as SYSDISK.
Function IsUsbDisk(d)
    Dim p, m, med
    p   = UCase(Trim("" & d.Pnp))
    m   = UCase("" & d.Model)
    med = UCase("" & d.Media)
    IsUsbDisk = (UCase(d.Iface) = "USB") _
        Or (Left(p, 8) = "USBSTOR\") _
        Or (InStr(med, "REMOVABLE") > 0) _
        Or (InStr(m, "USB DEVICE") > 0) _
        Or (InStr(m, "USB DISK") > 0) _
        Or (InStr(m, "USB FLASH") > 0) _
        Or (InStr(m, "JETFLASH") > 0) _
        Or (InStr(m, "DATATRAVELER") > 0) _
        Or (InStr(m, "CRUZER") > 0)
End Function

' Returns dictionary idx -> DiskInfo. Source: a test file if given, else WMI.
Function EnumDisks(testFile)
    Dim dct, di, tf, ln, parts, wmi, col, item
    Set dct = CreateObject("Scripting.Dictionary")
    If testFile <> "" And fso.FileExists(testFile) Then
        Set tf = fso.OpenTextFile(testFile, 1, False)
        Do Until tf.AtEndOfStream
            ln = Trim(tf.ReadLine)
            If ln <> "" And Left(ln, 1) <> "#" Then
                parts = Split(ln, "|")
                If UBound(parts) >= 3 Then
                    Set di = New DiskInfo
                    di.Idx = CLng(parts(0))
                    di.SizeGB = CDbl(parts(1)) / 1000000000.0
                    di.Model = Trim(parts(2))
                    di.Iface = Trim(parts(3))
                    If UBound(parts) >= 4 Then di.Pnp = Trim(parts(4))
                    If UBound(parts) >= 5 Then di.Media = Trim(parts(5))
                    If Not dct.Exists(di.Idx) Then dct.Add di.Idx, di
                End If
            End If
        Loop
        tf.Close
    Else
        Set wmi = GetObject("winmgmts:\\.\root\cimv2")
        Set col = wmi.ExecQuery("SELECT Index,Size,Model,InterfaceType,PNPDeviceID,MediaType FROM Win32_DiskDrive")
        For Each item In col
            Set di = New DiskInfo
            di.Idx = CLng(item.Index)
            If IsNull(item.Size) Then di.SizeGB = 0 Else di.SizeGB = CDbl(item.Size) / 1000000000.0
            di.Model = "" & item.Model
            di.Iface = "" & item.InterfaceType
            di.Pnp = "" & item.PNPDeviceID
            di.Media = "" & item.MediaType
            If Not dct.Exists(di.Idx) Then dct.Add di.Idx, di
        Next
    End If
    Set EnumDisks = dct
End Function

Class DiskInfo
    Public Idx
    Public SizeGB
    Public Model
    Public Iface
    Public Pnp
    Public Media
End Class
