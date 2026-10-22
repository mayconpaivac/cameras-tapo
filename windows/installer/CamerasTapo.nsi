; Instalador do Câmeras Tapo para Windows 10/11 (64 bits).
; Gerado por windows/build.sh (makensis). Instala o app e, opcionalmente,
; a ponte de acesso remoto (para o Mac ver as câmeras de fora de casa).

Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"

!define APPNAME   "Câmeras Tapo"
!define APPEXE    "CamerasTapo.exe"
!define PUBLISHER "Maycon Paiva"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\CamerasTapo"
!ifndef VERSION
  !define VERSION "1.0.0"
!endif
; 64-bit PowerShell even though the installer itself is a 32-bit process.
!define POWERSHELL "$WINDIR\SysNative\WindowsPowerShell\v1.0\powershell.exe"

Name "${APPNAME}"
OutFile "..\dist\CamerasTapo-Setup.exe"
InstallDir "$PROGRAMFILES64\Cameras Tapo"
InstallDirRegKey HKLM "${UNINSTKEY}" "InstallLocation"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
BrandingText "${APPNAME} ${VERSION}"
ShowInstDetails show
ShowUninstDetails show

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${APPNAME}"
VIAddVersionKey "CompanyName" "${PUBLISHER}"
VIAddVersionKey "FileDescription" "Instalador do ${APPNAME}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "${PUBLISHER}"

!define MUI_ICON "..\app\Assets\icon.ico"
!define MUI_UNICON "..\app\Assets\icon.ico"
!define MUI_ABORTWARNING
!define MUI_COMPONENTSPAGE_SMALLDESC
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_TEXT "Abrir o ${APPNAME}"
!define MUI_FINISHPAGE_RUN_FUNCTION LaunchApp
!define MUI_FINISHPAGE_SHOWREADME
!define MUI_FINISHPAGE_SHOWREADME_TEXT "Abrir o log da ponte"
!define MUI_FINISHPAGE_SHOWREADME_FUNCTION ShowBridgeLog
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "PortugueseBR"

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "O ${APPNAME} precisa do Windows 64 bits."
    Abort
  ${EndIf}
  SetRegView 64
FunctionEnd

Function un.onInit
  SetRegView 64
FunctionEnd

; Opens the app as the normal user (the installer runs as administrator).
Function LaunchApp
  Exec '"$WINDIR\explorer.exe" "$INSTDIR\${APPEXE}"'
FunctionEnd

Function ShowBridgeLog
  SetShellVarContext all
  ExecShell "open" "$APPDATA\CamerasTapo\ponte.log"
FunctionEnd

; The app locks its .exe and tcengine.dll while open: close it before copying.
!macro CloseApp
  DetailPrint "Fechando o ${APPNAME}, se estiver aberto…"
  nsExec::Exec '"$SYSDIR\taskkill.exe" /F /IM ${APPEXE}'
  Pop $0
  Sleep 1000
!macroend

Section "${APPNAME} (app)" SecApp
  SectionIn RO
  !insertmacro CloseApp
  SetOverwrite on
  SetOutPath "$INSTDIR"
  File "..\dist\publish\${APPEXE}"
  File "..\dist\publish\tcengine.dll"
  File "..\bridge\cameras-tapo.ps1"
  File "..\vendor\go2rtc\go2rtc.exe"
  File /oname=go2rtc-LICENSE.txt "..\vendor\go2rtc\LICENSE"
  File "..\app\Assets\icon.ico"
  WriteUninstaller "$INSTDIR\Desinstalar.exe"

  SetShellVarContext all
  CreateDirectory "$SMPROGRAMS\${APPNAME}"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk" "$INSTDIR\${APPEXE}" "" "$INSTDIR\icon.ico"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\Desinstalar.lnk" "$INSTDIR\Desinstalar.exe"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\Diagnóstico.lnk" "$SYSDIR\cmd.exe" '/k ""$INSTDIR\${APPEXE}" --diagnostico"' "$INSTDIR\icon.ico"
  CreateShortcut "$DESKTOP\${APPNAME}.lnk" "$INSTDIR\${APPEXE}" "" "$INSTDIR\icon.ico"

  WriteRegStr HKLM "${UNINSTKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${UNINSTKEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\icon.ico"
  WriteRegStr HKLM "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINSTKEY}" "UninstallString" '"$INSTDIR\Desinstalar.exe"'
  WriteRegDWORD HKLM "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINSTKEY}" "NoRepair" 1
  WriteRegDWORD HKLM "${UNINSTKEY}" "EstimatedSize" 56000
SectionEnd

Section "Ponte de acesso remoto (as câmeras deste PC aparecem no Mac)" SecBridge
  DetailPrint "Instalando a ponte de acesso remoto…"
  nsExec::ExecToLog '"${POWERSHELL}" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\cameras-tapo.ps1" -Install'
  Pop $0
  ${If} $0 != "0"
    MessageBox MB_ICONEXCLAMATION "A ponte não foi instalada (código $0).$\r$\nVeja os detalhes da instalação na tela. O app funciona normalmente em casa."
  ${Else}
    ; Confirm the bridge is answering (it starts in the background).
    DetailPrint "Testando a ponte…"
    nsExec::ExecToLog '"${POWERSHELL}" -NoProfile -Command "Start-Sleep 3; try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 http://127.0.0.1:20200/ping).Content; exit 0 } catch { Write-Host $$_.Exception.Message; exit 1 }"'
    Pop $0
    ${If} $0 == "0"
      DetailPrint "Ponte respondendo."
    ${Else}
      MessageBox MB_ICONEXCLAMATION "A ponte foi instalada mas ainda não respondeu.$\r$\nReinicie o PC; se continuar, mande o arquivo C:\ProgramData\CamerasTapo\ponte.log."
    ${EndIf}
  ${EndIf}

  ${IfNot} ${FileExists} "$PROGRAMFILES64\Tailscale\tailscale.exe"
    MessageBox MB_YESNO|MB_ICONINFORMATION "A ponte precisa do Tailscale neste PC para o Mac acessar de fora de casa.$\r$\n$\r$\nAbrir a página de download do Tailscale agora?" IDNO +2
      ExecShell "open" "https://tailscale.com/download/windows"
  ${EndIf}
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecApp} "O app para ver as câmeras neste PC."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecBridge} "As câmeras que você adicionar neste PC aparecem sozinhas no app do Mac. O PC retransmite o vídeo (go2rtc), então cada câmera recebe uma conexão só por lente, mesmo com vários apps abertos. Só aceita conexões do Tailscale."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Section "Uninstall"
  !insertmacro CloseApp
  SetShellVarContext all
  ${If} ${FileExists} "$APPDATA\CamerasTapo\cameras-tapo.ps1"
    DetailPrint "Removendo a ponte de acesso remoto…"
    nsExec::ExecToLog '"${POWERSHELL}" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\cameras-tapo.ps1" -Uninstall'
    Pop $0
  ${EndIf}

  Delete "$DESKTOP\${APPNAME}.lnk"
  RMDir /r "$SMPROGRAMS\${APPNAME}"
  Delete "$INSTDIR\${APPEXE}"
  Delete "$INSTDIR\tcengine.dll"
  Delete "$INSTDIR\cameras-tapo.ps1"
  Delete "$INSTDIR\go2rtc.exe"
  Delete "$INSTDIR\go2rtc-LICENSE.txt"
  Delete "$INSTDIR\icon.ico"
  Delete "$INSTDIR\Desinstalar.exe"
  RMDir "$INSTDIR"
  DeleteRegKey HKLM "${UNINSTKEY}"
SectionEnd
