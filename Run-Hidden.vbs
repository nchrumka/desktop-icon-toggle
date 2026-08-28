' Starts a command with no window. Used by Desktop Icon Toggle shortcuts.
Option Explicit
If WScript.Arguments.Count < 1 Then WScript.Quit 1
CreateObject("WScript.Shell").Run WScript.Arguments(0), 0, False
