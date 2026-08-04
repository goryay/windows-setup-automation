'=====================================================================
' patch_diskid.vbs  <autounattend.xml>  <diskid>  [testMinutes]  [productKey]
'
' 1) Replaces every <DiskID>N</DiskID> with <DiskID><diskid></DiskID>.
'    Pass diskid = "SKIP" (case-insensitive) to leave <DiskID> untouched
'    (used when the operator chose SKIP - autounattend picks the disk).
' 2) If the optional 3rd arg is given, replaces every __TEST_MINUTES__
'    placeholder with that value (operator-chosen stress-test duration,
'    in minutes). Absence of the placeholder is NOT an error - older
'    autounattend files simply have nothing to replace.
' 3) If the optional 4th arg is given, replaces every __PRODUCT_KEY__
'    placeholder with it (Windows 11 Pro key entered in WinPE; only the
'    win11 template carries this placeholder). Absence = nothing to do.
'    Args 3 and 4 may be passed as "" to keep positions when only a later
'    arg is set.
'
' Why this exists: install.bat lets the operator pick the Windows target
' disk (SYSDISK) and the test duration at runtime, but autounattend.xml
' carries a hardcoded <DiskID> and a __TEST_MINUTES__ placeholder. If the
' DiskID disagrees with SYSDISK, Setup cannot find the target partition,
' <WillShowUI>OnError</WillShowUI> fires and Setup drops into the FULL
' interactive wizard - which also discards <SetupUILanguage> and the rest
' of the unattend settings. So the DiskID patch must succeed.
'
' PXE WinPE has no powershell.exe, so install.bat calls this script as a
' fallback. Needs WinPE-Scripting (cscript.exe) in the PXE boot.wim.
'
' Encoding: prefers ADODB.Stream (true UTF-8, BOM stripped on write) when
' WinPE-MDAC is present; otherwise falls back to FileSystemObject. The
' fallback is safe because autounattend.xml is kept pure ASCII on purpose.
'
' Exit codes: 0 ok | 2 bad args | 3 read fail | 4 no DiskID | 5 write fail
'=====================================================================
Option Explicit

Dim xmlPath, newId, testMin, prodKey, content, patched, re, re2, re3, skipDisk

If WScript.Arguments.Count < 2 Then
    WScript.Echo "usage: patch_diskid.vbs <autounattend.xml> <diskid|SKIP> [testMinutes] [productKey]"
    WScript.Quit 2
End If

xmlPath = WScript.Arguments(0)
newId   = WScript.Arguments(1)
testMin = ""
If WScript.Arguments.Count >= 3 Then testMin = WScript.Arguments(2)
prodKey = ""
If WScript.Arguments.Count >= 4 Then prodKey = WScript.Arguments(3)

skipDisk = (UCase(newId) = "SKIP")

content = ReadFileText(xmlPath)
If IsNull(content) Then
    WScript.Echo "patch_diskid: cannot read " & xmlPath
    WScript.Quit 3
End If

patched = content

' --- 1) DiskID (skipped when newId = SKIP) ---
If Not skipDisk Then
    Set re = New RegExp
    re.Pattern    = "<DiskID>\s*\d+\s*</DiskID>"
    re.Global     = True
    re.IgnoreCase = True

    If Not re.Test(patched) Then
        WScript.Echo "patch_diskid: no <DiskID> element found in " & xmlPath
        WScript.Quit 4
    End If

    patched = re.Replace(patched, "<DiskID>" & newId & "</DiskID>")
End If

' --- 2) Test duration placeholder (optional, best-effort) ---
If Len(testMin) > 0 Then
    Set re2 = New RegExp
    re2.Pattern    = "__TEST_MINUTES__"
    re2.Global     = True
    re2.IgnoreCase = False
    patched = re2.Replace(patched, testMin)
End If

' --- 3) Product key placeholder (optional, win11/Pro only) ---
If Len(prodKey) > 0 Then
    Set re3 = New RegExp
    re3.Pattern    = "__PRODUCT_KEY__"
    re3.Global     = True
    re3.IgnoreCase = False
    patched = re3.Replace(patched, prodKey)
End If

If Not WriteFileText(xmlPath, patched) Then
    WScript.Echo "patch_diskid: write failed for " & xmlPath
    WScript.Quit 5
End If

If skipDisk Then
    WScript.Echo "patch_diskid: DiskID left as-is (SKIP)"
Else
    WScript.Echo "patch_diskid: DiskID set to " & newId
End If
If Len(testMin) > 0 Then WScript.Echo "patch_diskid: TestMinutes set to " & testMin
If Len(prodKey) > 0 Then WScript.Echo "patch_diskid: ProductKey set"
WScript.Quit 0

'---------------------------------------------------------------------
' Read whole file. Returns Null on failure.
'---------------------------------------------------------------------
Function ReadFileText(path)
    Dim st, fso, f
    ReadFileText = Null

    On Error Resume Next

    Set st = CreateObject("ADODB.Stream")
    If Err.Number = 0 Then
        st.Type = 2
        st.Charset = "utf-8"
        st.Open
        st.LoadFromFile path
        If Err.Number = 0 Then
            ReadFileText = st.ReadText
            st.Close
            On Error GoTo 0
            Exit Function
        End If
    End If
    Err.Clear

    Set fso = CreateObject("Scripting.FileSystemObject")
    Set f = fso.OpenTextFile(path, 1, False)
    If Err.Number <> 0 Then
        On Error GoTo 0
        Exit Function
    End If
    ReadFileText = f.ReadAll
    f.Close

    On Error GoTo 0
End Function

'---------------------------------------------------------------------
' Write whole file. Returns True on success.
'---------------------------------------------------------------------
Function WriteFileText(path, text)
    Dim st, bin, fso, f
    WriteFileText = False

    On Error Resume Next

    Set st = CreateObject("ADODB.Stream")
    If Err.Number = 0 Then
        st.Type = 2
        st.Charset = "utf-8"
        st.Open
        st.WriteText text
        If Err.Number = 0 Then
            ' ADODB prepends a UTF-8 BOM. Re-read as binary from offset 3
            ' to drop it, so Setup sees the same BOM-less file as before.
            st.Position = 0
            st.Type = 1
            st.Position = 3
            Set bin = CreateObject("ADODB.Stream")
            bin.Type = 1
            bin.Open
            st.CopyTo bin
            bin.SaveToFile path, 2
            If Err.Number = 0 Then
                bin.Close
                st.Close
                WriteFileText = True
                On Error GoTo 0
                Exit Function
            End If
        End If
    End If
    Err.Clear

    Set fso = CreateObject("Scripting.FileSystemObject")
    Set f = fso.CreateTextFile(path, True, False)
    If Err.Number <> 0 Then
        On Error GoTo 0
        Exit Function
    End If
    f.Write text
    f.Close
    WriteFileText = True

    On Error GoTo 0
End Function
