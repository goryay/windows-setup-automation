'=====================================================================
' build_avago.vbs  <config.txt>  [CHECK|DRYRUN|EXECUTE]  [simStorcliOutFile]
'
' Sobiraet avago/LSI MegaRAID massivy (SAS/SATA arhivnye) po SL-konfigu
' cherez storcli64.exe. Analog build_rst.vbs, no dlya kontrollera avago.
'
' Rezhimy:
'   CHECK   - tolko konfig (BEZ storcli). RESULT=NEEDED esli est hotya by odna
'             ne-NVMe gruppa s RAID-urovnem, inache RESULT=NONE.
'   DRYRUN  - konfig + storcli enum, pechataet PLAN. Nichego ne delaet.
'   EXECUTE - realno sozdaet massivy (add vd). Konfig avago dolzhen byt UZHE
'             ochischen (install.bat delaet storcli /c0/vall del pered etim).
'
' avago-gruppa = gruppa BEZ "NVME" v disk_form_factor (SATA/SAS za LSI/avago).
' Imya: SystemDisk (disk_system=TRUE) ili ArchiveDiskN (numeraciya kak v build_rst).
' Init ne zapuskaem - MegaRAID delaet background init sam pri sozdanii VD.
'
' Exit: 0 ok/plan/none | 2 bad args | 3 no storcli | 5 exec error
'=====================================================================
Option Explicit

Dim fso, shell
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

If WScript.Arguments.Count < 1 Then
    WScript.Echo "usage: build_avago.vbs <config.txt> [CHECK|DRYRUN|EXECUTE] [simStorcliOutFile]"
    WScript.Quit 2
End If
Dim cfgPath : cfgPath = WScript.Arguments(0)
Dim mode : mode = "DRYRUN"
If WScript.Arguments.Count >= 2 Then mode = UCase(Trim(WScript.Arguments(1)))
Dim simFile : simFile = ""
If WScript.Arguments.Count >= 3 Then simFile = WScript.Arguments(2)

If Not fso.FileExists(cfgPath) Then
    WScript.Echo "[avg] config not found: " & cfgPath
    WScript.Echo "RESULT=ERROR"
    WScript.Quit 2
End If

Dim CTRL : CTRL = "/c0"

' ---- module state ----
Dim grpLevel(16), grpName(16), grpQty(16), grpSize(16), grpSystem(16), grpNvme(16), grpMed(16), grpIntf(16)
Dim grpCount : grpCount = 0
Dim archiveIdx : archiveIdx = 0

Dim dId(256), dSize(256), dIntf(256), dMed(256), dState(256), dUsed(256)
Dim dCount : dCount = 0

Dim plan(64), planCount : planCount = 0
Dim storcli : storcli = ""

'--- 1) parse config groups ---
ParseConfig cfgPath

Dim avagoGroups : avagoGroups = 0
Dim i
For i = 1 To grpCount
    If (Not grpNvme(i)) And grpLevel(i) <> "" Then avagoGroups = avagoGroups + 1
Next

'--- CHECK mode: config-only, no storcli ---
If mode = "CHECK" Then
    WScript.Echo "[avg] CHECK: avago (SAS/SATA) RAID groups in config = " & avagoGroups
    If avagoGroups > 0 Then WScript.Echo "RESULT=NEEDED" Else WScript.Echo "RESULT=NONE"
    WScript.Quit 0
End If

' ---- DRYRUN / EXECUTE need storcli ----
storcli = FindStorcli()
If storcli = "" And simFile = "" Then
    WScript.Echo "[avg] storcli64.exe NOT found (Y:\common\SoftForTest\StorCLI, script dir, PATH)"
    WScript.Echo "RESULT=ERROR"
    WScript.Quit 3
End If
WScript.Echo "[avg] storcli: " & storcli
If simFile <> "" Then WScript.Echo "[avg] (SIM) storcli output from file: " & simFile
If mode = "EXECUTE" Then
    WScript.Echo "[avg] MODE = EXECUTE (arrays WILL be created)"
Else
    mode = "DRYRUN"
    WScript.Echo "[avg] MODE = DRY-RUN (plan only)"
End If

If avagoGroups = 0 Then
    WScript.Echo "[avg] no avago RAID groups in config - nothing to build."
    WScript.Echo "RESULT=NONE"
    WScript.Quit 0
End If
WScript.Echo "[avg] avago RAID groups in config: " & avagoGroups

'--- 2) storcli enum disks ---
EnumAvago
WScript.Echo "[avg] avago disks found: " & dCount
For i = 0 To dCount - 1
    WScript.Echo "  disk " & dId(i) & "  " & dSize(i) & "GB  " & dIntf(i) & " " & dMed(i) & "  [" & dState(i) & "]"
Next

'--- 3) build plan: create per avago group ---
Dim g, ids, picked, warn
For g = 1 To grpCount
    If (Not grpNvme(g)) And grpLevel(g) <> "" Then
        warn = ""
        ids = PickAvagoDisks(grpQty(g), grpSize(g), grpMed(g), grpIntf(g), picked, warn)
        If picked < grpQty(g) Then
            WScript.Echo "[avg] group " & g & " (" & grpName(g) & "): need " & grpQty(g) & " " & _
                         grpIntf(g) & " " & grpMed(g) & " ~" & grpSize(g) & "GB, found " & picked & " - SKIP."
        Else
            If warn <> "" Then WScript.Echo "[avg] " & warn
            AddPlan Quote(storcli) & " " & CTRL & " add vd type=raid" & grpLevel(g) & _
                    " name=" & grpName(g) & " drives=" & ids & PdPer(grpLevel(g))
        End If
    End If
Next

'--- 3c) report unallocated avago disks (TZ str.54) ---
Dim anyFree : anyFree = False
For i = 0 To dCount - 1
    If Not dUsed(i) Then
        If Not anyFree Then
            WScript.Echo "[avg] NERASPREDELENNYE avago-diski (ne voshli ni v odnu gruppu):"
            anyFree = True
        End If
        WScript.Echo "  disk " & dId(i) & "  " & dSize(i) & "GB  " & dIntf(i) & " " & dMed(i)
    End If
Next

'--- 4) show / execute ---
WScript.Echo "[avg] === PLAN (" & planCount & " command(s)) ==="
For i = 0 To planCount - 1
    WScript.Echo "  " & plan(i)
Next

If mode <> "EXECUTE" Then
    WScript.Echo "[avg] DRY-RUN - nothing executed. Re-run with EXECUTE to apply."
    WScript.Echo "RESULT=PLAN"
    WScript.Quit 0
End If

If planCount = 0 Then
    WScript.Echo "[avg] nothing to create (no disks matched). RESULT=NONE"
    WScript.Echo "RESULT=NONE"
    WScript.Quit 0
End If

Dim rc, anyfail : anyfail = 0
For i = 0 To planCount - 1
    WScript.Echo "[avg] RUN: " & plan(i)
    rc = RunAndEcho(plan(i))
    WScript.Echo "[avg]   exit=" & rc
    If rc <> 0 Then anyfail = anyfail + 1
Next
If anyfail > 0 Then
    WScript.Echo "[avg] DONE with " & anyfail & " failure(s)."
    WScript.Echo "RESULT=ERROR"
    WScript.Quit 5
End If
WScript.Echo "[avg] DONE - avago arrays built."
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

Function PdPer(level)
    ' RAID-10 trebuet pdperarray. Pary po 2 diska.
    If level = "10" Then
        PdPer = " pdperarray=2"
    Else
        PdPer = ""
    End If
End Function

Function FindStorcli()
    Dim cands, k, c
    cands = Array( _
        "Y:\common\SoftForTest\StorCLI\storcli64.exe", _
        fso.GetParentFolderName(WScript.ScriptFullName) & "\storcli64.exe", _
        "X:\storcli64.exe")
    For k = 0 To UBound(cands)
        c = cands(k)
        If fso.FileExists(c) Then
            FindStorcli = c
            Exit Function
        End If
    Next
    FindStorcli = ""
End Function

Sub ParseConfig(path)
    Dim f, line, key, val, pos, gi, maxG
    Dim tType(16), tFF(16), tSize(16), tQty(16), tSys(16), tDT(16)
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
                    If InStr(key, "_disk_type") > 0 Then tDT(gi) = val
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
        grpMed(j) = MedOf(tDT(j))
        grpIntf(j) = IntfOf(tFF(j))
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
    Select Case u
        Case "RAID0":  RaidLevel = "0"
        Case "RAID1":  RaidLevel = "1"
        Case "RAID5":  RaidLevel = "5"
        Case "RAID6":  RaidLevel = "6"
        Case "RAID10": RaidLevel = "10"
        Case Else:     RaidLevel = ""
    End Select
End Function

Function MedOf(t)
    Dim u : u = UCase(Trim(t))
    If InStr(u, "SSD") > 0 Then
        MedOf = "SSD"
    ElseIf InStr(u, "HDD") > 0 Then
        MedOf = "HDD"
    Else
        MedOf = ""
    End If
End Function

Function IntfOf(t)
    Dim u : u = UCase(Trim(t))
    If InStr(u, "SAS") > 0 Then
        IntfOf = "SAS"
    ElseIf InStr(u, "SATA") > 0 Then
        IntfOf = "SATA"
    Else
        IntfOf = ""
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
    ' "480Gb", "0,48Tb", "1Tb", "5.457 TB" -> GB int. Locale-safe (, or . separator).
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
            ' skip
        Else
            Exit For
        End If
    Next
    If intp = "" Then intp = "0"
    v = CDbl(intp)
    If frac <> "" Then v = v + CDbl(frac) / (10 ^ Len(frac))
    SizeToGB = CLng(v * mult)
End Function

Sub EnumAvago()
    Dim lines(4000), n, f, exec, line, i9, toks, id, st, szIdx, sizeGB, intf, med
    n = 0
    If simFile <> "" Then
        Set f = fso.OpenTextFile(simFile, 1, False)
        Do While Not f.AtEndOfStream
            If n <= 4000 Then lines(n) = f.ReadLine Else f.ReadLine
            n = n + 1
        Loop
        f.Close
    Else
        ' shell.Exec: storcli read directly (no cmd -> no quote-stripping bug)
        Set exec = shell.Exec(Quote(storcli) & " " & CTRL & " /eall /sall show")
        Do While Not exec.StdOut.AtEndOfStream
            If n <= 4000 Then lines(n) = exec.StdOut.ReadLine Else exec.StdOut.ReadLine
            n = n + 1
        Loop
        Do While exec.Status = 0
            WScript.Sleep 20
        Loop
    End If
    If n > 4000 Then n = 4001
    For i9 = 0 To n - 1
        line = lines(i9)
        toks = SplitWS(line)
        If UBound(toks) >= 3 Then
            id = toks(0)
            If IsEidSlt(id) Then
                st = toks(2)
                szIdx = FindSizeIdx(toks)
                If szIdx >= 0 Then
                    sizeGB = SizeToGB(toks(szIdx) & " " & toks(szIdx + 1))
                    intf = "" : med = ""
                    If szIdx + 2 <= UBound(toks) Then intf = toks(szIdx + 2)
                    If szIdx + 3 <= UBound(toks) Then med = toks(szIdx + 3)
                    dId(dCount) = id
                    dSize(dCount) = sizeGB
                    dIntf(dCount) = intf
                    dMed(dCount) = med
                    dState(dCount) = st
                    dUsed(dCount) = False
                    dCount = dCount + 1
                End If
            End If
        End If
    Next
End Sub

Function SplitWS(line)
    Dim s, parts, out, n, k, t
    s = Replace(line, vbTab, " ")
    parts = Split(Trim(s), " ")
    ReDim out(UBound(parts))
    n = 0
    For k = 0 To UBound(parts)
        t = parts(k)
        If Len(t) > 0 Then
            out(n) = t
            n = n + 1
        End If
    Next
    If n = 0 Then
        ReDim out(0)
        out(0) = ""
    Else
        ReDim Preserve out(n - 1)
    End If
    SplitWS = out
End Function

Function IsEidSlt(v)
    IsEidSlt = False
    If Len(v) = 0 Then Exit Function
    Dim c : c = Left(v, 1)
    If (c >= "0" And c <= "9") And InStr(v, ":") > 0 Then IsEidSlt = True
End Function

Function FindSizeIdx(toks)
    ' Token = chislo, sleduyushchiy = TB/GB/MB. Vozvraschaem indeks chisla.
    Dim k, u
    FindSizeIdx = -1
    For k = 1 To UBound(toks) - 1
        If IsNumericTok(toks(k)) Then
            u = UCase(toks(k + 1))
            If u = "TB" Or u = "GB" Or u = "MB" Then
                FindSizeIdx = k
                Exit Function
            End If
        End If
    Next
End Function

Function IsNumericTok(s)
    Dim k, c, seen
    IsNumericTok = False
    seen = False
    For k = 1 To Len(s)
        c = Mid(s, k, 1)
        If c >= "0" And c <= "9" Then
            seen = True
        ElseIf c = "." Or c = "," Then
            ' ok
        Else
            Exit Function
        End If
    Next
    IsNumericTok = seen
End Function

Function PickAvagoDisks(need, sz, wantMed, wantIntf, ByRef picked, ByRef warn)
    Dim k, lo, hi, idx(256), icount, res
    warn = ""
    ' Pass 1: tip (Med+Intf) + razmer +-25%
    icount = 0
    lo = sz - sz * 0.25
    hi = sz + sz * 0.25
    For k = 0 To dCount - 1
        If (Not dUsed(k)) And MedMatch(dMed(k), wantMed) And IntfMatch(dIntf(k), wantIntf) Then
            If sz > 0 And dSize(k) >= lo And dSize(k) <= hi Then
                idx(icount) = k
                icount = icount + 1
                If icount >= need Then Exit For
            End If
        End If
    Next
    If icount >= need Then
        picked = need
        PickAvagoDisks = MarkAndJoin(idx, need)
        Exit Function
    End If
    ' Pass 2 (TZ str.52): razmer ne sovpal, no kol-vo+tip est -> berem po tipu, preduprezhdaem
    icount = 0
    For k = 0 To dCount - 1
        If (Not dUsed(k)) And MedMatch(dMed(k), wantMed) And IntfMatch(dIntf(k), wantIntf) Then
            idx(icount) = k
            icount = icount + 1
            If icount >= need Then Exit For
        End If
    Next
    If icount >= need Then
        warn = "gruppa " & wantIntf & " " & wantMed & " ~" & sz & "GB: tochnyy razmer ne nayden, " & _
               "beru " & need & " diskov po tipu i kol-vu (trebuet podtverzhdeniya operatora)."
        picked = need
        PickAvagoDisks = MarkAndJoin(idx, need)
        Exit Function
    End If
    picked = icount
    PickAvagoDisks = ""
End Function

Function MarkAndJoin(idx, need)
    Dim k, res : res = ""
    For k = 0 To need - 1
        dUsed(idx(k)) = True
        If res = "" Then res = dId(idx(k)) Else res = res & "," & dId(idx(k))
    Next
    MarkAndJoin = res
End Function

Function MedMatch(have, want)
    If want = "" Then
        MedMatch = True
    Else
        MedMatch = (UCase(Trim(have)) = UCase(Trim(want)))
    End If
End Function

Function IntfMatch(have, want)
    If want = "" Then
        IntfMatch = True
    Else
        IntfMatch = (UCase(Trim(have)) = UCase(Trim(want)))
    End If
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
