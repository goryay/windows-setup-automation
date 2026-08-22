'=====================================================================
' build_rst.vbs  <config.txt>  [CHECK|DRYRUN|EXECUTE]  [simRstcliOutFile]
'
' Sobiraet Intel RST (VMD) massivy po SL-konfigu cherez rstcli64.exe.
'
' Rezhimy:
'   CHECK   - tolko parsit konfig (BEZ rstcli). Vyvodit RESULT=NEEDED, esli est
'             hotya by odna NVMe-gruppa s RAID-urovnem, inache RESULT=NONE.
'             install.bat po etomu reshaet: chistit avago + stroit RST, ili net.
'   DRYRUN  - (po umolchaniyu) parsit konfig + rstcli -I, pechataet PLAN. Nichego ne delaet.
'   EXECUTE - realno vypolnyaet plan (udalyaet stariye tomа, sozdaet, iniciiruet).
'
' RST-gruppa = gruppa, u kotoroy disk_form_factor soderzhit "NVME" (NVMe-diski
' sidyat za Intel VMD, a ne za LSI/avago). Imya: SystemDisk (disk_system=TRUE) ili ArchiveDiskN.
'
' VAZHNO: konfig avago dolzhen byt ochischen (storcli) DO EXECUTE/DRYRUN, inache rstcli -I zависает/падает.
'
' simRstcliOutFile - (opc.) put k faylu s gotovym vyvodom "rstcli -I" dlya LOKALNOGO testa parsera.
'
' Exit: 0 ok/plan/none | 2 bad args | 3 no rstcli | 5 exec error
'=====================================================================
Option Explicit

Dim fso, shell
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

If WScript.Arguments.Count < 1 Then
    WScript.Echo "usage: build_rst.vbs <config.txt> [CHECK|DRYRUN|EXECUTE] [simRstcliOutFile]"
    WScript.Quit 2
End If
Dim cfgPath : cfgPath = WScript.Arguments(0)
Dim mode : mode = "DRYRUN"
If WScript.Arguments.Count >= 2 Then mode = UCase(Trim(WScript.Arguments(1)))
Dim simFile : simFile = ""
If WScript.Arguments.Count >= 3 Then simFile = WScript.Arguments(2)

If Not fso.FileExists(cfgPath) Then
    WScript.Echo "[rst] config not found: " & cfgPath
    WScript.Echo "RESULT=ERROR"
    WScript.Quit 2
End If

' ---- module-level state ----
Dim grpLevel(16), grpName(16), grpQty(16), grpSize(16), grpSystem(16), grpNvme(16)
Dim grpCount : grpCount = 0
Dim archiveIdx : archiveIdx = 0

Dim diskId(64), diskSize(64), diskIface(64), diskUsed(64)
Dim diskCount : diskCount = 0
Dim volName(32), volCount : volCount = 0

Dim plan(64), planCount : planCount = 0

Dim rstcli : rstcli = ""

'--- 1) parse config groups ---
ParseConfig cfgPath

Dim rstRaidGroups : rstRaidGroups = 0
Dim i
For i = 1 To grpCount
    If grpNvme(i) And grpLevel(i) <> "" Then rstRaidGroups = rstRaidGroups + 1
Next

'--- CHECK mode: config-only, no rstcli ---
If mode = "CHECK" Then
    WScript.Echo "[rst] CHECK: NVMe RAID groups in config = " & rstRaidGroups
    If rstRaidGroups > 0 Then WScript.Echo "RESULT=NEEDED" Else WScript.Echo "RESULT=NONE"
    WScript.Quit 0
End If

' ---- DRYRUN / EXECUTE need rstcli ----
rstcli = FindRstcli()
If rstcli = "" And simFile = "" Then
    WScript.Echo "[rst] rstcli64.exe NOT found (Y:\common\software, script dir, PATH)"
    WScript.Echo "RESULT=ERROR"
    WScript.Quit 3
End If
WScript.Echo "[rst] rstcli: " & rstcli
If simFile <> "" Then WScript.Echo "[rst] (SIM) rstcli -I output from file: " & simFile
If mode = "EXECUTE" Then
    WScript.Echo "[rst] MODE = EXECUTE (arrays WILL be created)"
Else
    mode = "DRYRUN"
    WScript.Echo "[rst] MODE = DRY-RUN (plan only)"
End If

If rstRaidGroups = 0 Then
    WScript.Echo "[rst] no NVMe RAID groups in config - nothing to build."
    WScript.Echo "RESULT=NONE"
    WScript.Quit 0
End If
WScript.Echo "[rst] NVMe RAID groups in config: " & rstRaidGroups

'--- 2) rstcli -I -> disks + existing volumes ---
EnumRst
WScript.Echo "[rst] Intel disks found: " & diskCount
For i = 0 To diskCount - 1
    WScript.Echo "  disk " & diskId(i) & "  " & diskSize(i) & "GB  " & diskIface(i)
Next
WScript.Echo "[rst] existing RST volumes: " & volCount
For i = 0 To volCount - 1
    WScript.Echo "  volume " & volName(i)
Next

'--- 3) build plan ---
' 3a) wipe ALL existing RST metadata (frees disks). "-Z --no-sync" allowed only in WinPE.
'     Cleaner than per-volume -D: no leftover empty arrays blocking create.
If volCount > 0 Then
    AddPlan Quote(rstcli) & " --manage --delete-all-metadata --no-sync --disableVersionCheck"
End If
For i = 0 To diskCount - 1
    diskUsed(i) = False
Next
' 3b) create + init per RST group
Dim g, ids, picked
For g = 1 To grpCount
    If grpNvme(g) And grpLevel(g) <> "" Then
        ids = PickDisks(grpQty(g), grpSize(g), picked)
        If picked < grpQty(g) Then
            WScript.Echo "[rst] group " & g & " (" & grpName(g) & "): need " & grpQty(g) & _
                         " NVMe ~" & grpSize(g) & "GB, found " & picked & " - SKIP."
        Else
            AddPlan Quote(rstcli) & " -C -l " & grpLevel(g) & " -n " & grpName(g) & " " & ids & " --disableVersionCheck"
            ' Initialize sinhroniziruet izbytochnost (mirror/parity). RAID-0 ee ne imeet
            ' -> initialize daet DEVICE_STATE_INVALID. Delaem init tolko dlya 1/5/10.
            If grpLevel(g) <> "0" Then
                AddPlan Quote(rstcli) & " --manage --initialize " & grpName(g) & " --disableVersionCheck"
            End If
        End If
    End If
Next

'--- 3c) report unallocated Intel disks (TZ str.54) ---
Dim anyFree : anyFree = False
For i = 0 To diskCount - 1
    If Not diskUsed(i) Then
        If Not anyFree Then
            WScript.Echo "[rst] NERASPREDELENNYE NVMe-diski (ne voshli ni v odnu gruppu):"
            anyFree = True
        End If
        WScript.Echo "  disk " & diskId(i) & "  " & diskSize(i) & "GB  " & diskIface(i)
    End If
Next

'--- 4) show / execute ---
WScript.Echo "[rst] === PLAN (" & planCount & " command(s)) ==="
For i = 0 To planCount - 1
    WScript.Echo "  " & plan(i)
Next

If mode <> "EXECUTE" Then
    WScript.Echo "[rst] DRY-RUN - nothing executed. Re-run with EXECUTE to apply."
    WScript.Echo "RESULT=PLAN"
    WScript.Quit 0
End If

Dim rc, anyfail : anyfail = 0
For i = 0 To planCount - 1
    WScript.Echo "[rst] RUN: " & plan(i)
    rc = RunAndEcho(plan(i))
    WScript.Echo "[rst]   exit=" & rc
    If rc <> 0 Then anyfail = anyfail + 1
Next
If anyfail > 0 Then
    WScript.Echo "[rst] DONE with " & anyfail & " failure(s)."
    WScript.Echo "RESULT=ERROR"
    WScript.Quit 5
End If
WScript.Echo "[rst] DONE - RST arrays built."
WScript.Echo "RESULT=OK"
WScript.Quit 0

'====================== helpers ======================

Function Quote(s)
    Quote = """" & s & """"
End Function

Sub AddPlan(cmd)
    plan(planCount) = cmd
    planCount = planCount + 1
End Sub

Function FindRstcli()
    Dim cands, k, c
    cands = Array( _
        "Y:\common\software\rstcli64.exe", _
        fso.GetParentFolderName(WScript.ScriptFullName) & "\rstcli64.exe", _
        "X:\rstcli64.exe")
    For k = 0 To UBound(cands)
        c = cands(k)
        If fso.FileExists(c) Then
            FindRstcli = c
            Exit Function
        End If
    Next
    FindRstcli = ""
End Function

Sub ParseConfig(path)
    Dim f, line, key, val, pos, gi, maxG
    Dim tType(16), tFF(16), tSize(16), tQty(16), tSys(16)
    maxG = 0
    Set f = fso.OpenTextFile(path, 1, False)
    Do While Not f.AtEndOfStream
        line = f.ReadLine
        pos = InStr(line, "=")
        If pos > 0 Then
            key = Trim(Left(line, pos - 1))
            val = Trim(Mid(line, pos + 1))
            If Left(key, 6) = "group_" Then
                gi = GroupIndex(key)
                If gi > 0 And gi <= 16 Then
                    If gi > maxG Then maxG = gi
                    If Right(key, 5) = "_Type" Then tType(gi) = val
                    If InStr(key, "_disk_form_factor") > 0 Then tFF(gi) = val
                    If InStr(key, "_disk_size") > 0 Then tSize(gi) = val
                    If InStr(key, "_disk_quantity") > 0 Then tQty(gi) = val
                    If InStr(key, "_disk_system") > 0 Then tSys(gi) = val
                End If
            End If
        End If
    Loop
    f.Close
    grpCount = maxG
    Dim j
    For j = 1 To maxG
        grpLevel(j) = RaidLevel(tType(j))
        grpQty(j) = ToInt(tQty(j))
        grpSize(j) = SizeToGB(tSize(j))
        grpSystem(j) = (UCase(Trim(tSys(j))) = "TRUE")
        grpNvme(j) = (InStr(UCase(tFF(j)), "NVME") > 0)
        If grpSystem(j) Then
            grpName(j) = "SystemDisk"
        Else
            archiveIdx = archiveIdx + 1
            grpName(j) = "ArchiveDisk" & archiveIdx
        End If
    Next
End Sub

Function GroupIndex(key)
    Dim rest, p
    rest = Mid(key, 7)
    p = InStr(rest, "_")
    If p = 0 Then p = Len(rest) + 1
    GroupIndex = ToInt(Left(rest, p - 1))
End Function

Function RaidLevel(t)
    Dim u : u = UCase(Trim(t))
    u = Replace(u, "-", "")
    If u = "RAID0" Then
        RaidLevel = "0"
    ElseIf u = "RAID1" Then
        RaidLevel = "1"
    ElseIf u = "RAID5" Then
        RaidLevel = "5"
    ElseIf u = "RAID10" Then
        RaidLevel = "10"
    Else
        RaidLevel = ""
    End If
End Function

Function ToInt(s)
    Dim t, k, c, r
    t = Trim(s) : r = ""
    For k = 1 To Len(t)
        c = Mid(t, k, 1)
        If c >= "0" And c <= "9" Then r = r & c Else Exit For
    Next
    If r = "" Then ToInt = 0 Else ToInt = CLng(r)
End Function

Function SizeToGB(s)
    ' "480Gb", "0,48Tb", "1Tb", "477 GB" -> GB int. Locale-safe (, or . as separator).
    Dim t, u, k, c, intp, frac, mult, seenSep, v
    t = Trim(s) : u = UCase(t)
    mult = 1
    If InStr(u, "TB") > 0 Then mult = 1000
    intp = "" : frac = "" : seenSep = False
    For k = 1 To Len(t)
        c = Mid(t, k, 1)
        If c >= "0" And c <= "9" Then
            If seenSep Then frac = frac & c Else intp = intp & c
        ElseIf c = "," Or c = "." Then
            seenSep = True
        ElseIf c = " " Then
            ' skip spaces
        Else
            Exit For
        End If
    Next
    If intp = "" Then intp = "0"
    v = CDbl(intp)
    If frac <> "" Then v = v + CDbl(frac) / (10 ^ Len(frac))
    SizeToGB = CLng(v * mult)
End Function

Sub EnumRst()
    Dim lines(4000), n, f, exec, line, section, curId, curSize, curIface, pos, key, val, i9
    n = 0
    If simFile <> "" Then
        Set f = fso.OpenTextFile(simFile, 1, False)
        Do While Not f.AtEndOfStream
            If n <= 4000 Then lines(n) = f.ReadLine Else f.ReadLine
            n = n + 1
        Loop
        f.Close
    Else
        ' shell.Exec: rstcli read directly (no cmd -> no quote-stripping bug)
        Set exec = shell.Exec(Quote(rstcli) & " -I --disableVersionCheck")
        Do While Not exec.StdOut.AtEndOfStream
            If n <= 4000 Then lines(n) = exec.StdOut.ReadLine Else exec.StdOut.ReadLine
            n = n + 1
        Loop
    End If
    If n > 4000 Then n = 4001
    section = "" : curId = "" : curSize = 0 : curIface = ""
    For i9 = 0 To n - 1
        line = lines(i9)
        If InStr(line, "--CONTROLLER INFORMATION--") > 0 Then
            section = "CTRL"
        ElseIf InStr(line, "--ARRAY INFORMATION--") > 0 Then
            section = "ARRAY"
        ElseIf InStr(line, "--VOLUME INFORMATION--") > 0 Then
            section = "VOL"
        ElseIf InStr(line, "--END DEVICE INFORMATION--") > 0 Then
            FlushDisk curId, curSize, curIface
            curId = "" : section = "DEV"
        ElseIf InStr(line, "--NON-RST CONTROLLER") > 0 Then
            FlushDisk curId, curSize, curIface
            curId = "" : section = "NONRST"
        Else
            pos = InStr(line, ":")
            If pos > 0 Then
                key = Trim(Left(line, pos - 1))
                val = Trim(Mid(line, pos + 1))
                If section = "VOL" And key = "Name" Then
                    volName(volCount) = val : volCount = volCount + 1
                ElseIf section = "DEV" Then
                    If key = "ID" And IsDiskId(val) Then
                        FlushDisk curId, curSize, curIface
                        curId = val : curSize = 0 : curIface = ""
                    ElseIf key = "Size" And curId <> "" Then
                        curSize = SizeToGB(val)
                    ElseIf key = "Port Interface" And curId <> "" Then
                        curIface = val
                    End If
                End If
            End If
        End If
    Next
    FlushDisk curId, curSize, curIface
End Sub

Sub FlushDisk(id, sz, iface)
    If id = "" Then Exit Sub
    diskId(diskCount) = id
    diskSize(diskCount) = sz
    diskIface(diskCount) = iface
    diskUsed(diskCount) = False
    diskCount = diskCount + 1
End Sub

Function IsDiskId(v)
    IsDiskId = False
    If Len(v) = 0 Then Exit Function
    Dim c : c = Left(v, 1)
    If (c >= "0" And c <= "9") And InStr(v, "-") > 0 Then IsDiskId = True
End Function

Function PickDisks(need, sz, ByRef picked)
    Dim res, k, cnt, lo, hi
    res = "" : cnt = 0
    lo = sz - sz * 0.25
    hi = sz + sz * 0.25
    For k = 0 To diskCount - 1
        If (Not diskUsed(k)) And InStr(UCase(diskIface(k)), "NVME") > 0 Then
            If diskSize(k) >= lo And diskSize(k) <= hi Then
                diskUsed(k) = True
                If res = "" Then res = diskId(k) Else res = res & " " & diskId(k)
                cnt = cnt + 1
                If cnt >= need Then Exit For
            End If
        End If
    Next
    picked = cnt
    PickDisks = res
End Function

Function RunAndEcho(cmd)
    Dim exec
    Set exec = shell.Exec(cmd)
    Do While Not exec.StdOut.AtEndOfStream
        WScript.Echo "    | " & exec.StdOut.ReadLine
    Loop
    Do While Not exec.StdErr.AtEndOfStream
        WScript.Echo "    ! " & exec.StdErr.ReadLine
    Loop
    Do While exec.Status = 0
        WScript.Sleep 30
    Loop
    RunAndEcho = exec.ExitCode
End Function
