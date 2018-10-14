$host_name = (Get-WmiObject Win32_ComputerSystem).Name
$YYYYMMDD=date -format yyyyMMdd
$CommandPath = $MyInvocation.MyCommand.Path
$ScriptPath = Split-Path -Parent $CommandPath
$LOG=$ScriptPath+"\PSlog_VCS01Backup_"+$YYYYMMDD+".log"
#--------------------------------------
$ESXiList = @("172.23.25.1","172.23.25.2","172.23.25.3")
$VC = 172.23.25.131
$ESXiUser="root"
$VCUser = "administrator@vsphere.local"
$PASSWD = "saka1zzohng2012"
$VC_Default_Position = "172.23.25.2"
$UDP_USER="administrator"
# ====================  関数定義  ==================== #

# 標準出力のログ取得開始する関数
function startlog() {
    start-transcript $LOG -append
}

# ログ取得停止の関数
function endlog() {
    stop-transcript
}


#実施前確認
function VCSBACKUP_QUESTION(){
#選択肢コレクションの初期設定
    $typename = "System.Management.Automation.Host.ChoiceDescription"
    $yes = new-object $typename("&Yes","実行する")
    $no  = new-object $typename("&No","実行しない")

    #選択肢コレクションの作成
    $assembly= $yes.getType().AssemblyQualifiedName
    $choice = new-object "System.Collections.ObjectModel.Collection``1[[$assembly]]"
    $choice.add($yes)
    $choice.add($no)
    $answer = $host.ui.PromptForChoice("<実行確認>","ArcserveUDPのバックアップは実行されているか確認しましたか？",$choice,1)
        if ($answer -eq 1 ){
            echo "Arcserve UDPによるバックアップ実行中は本処理は行なえません。終了を確認してから再度実行してください。"
            return
        }elseif($answer -eq 0){
            echo "これよりrs-vcs01のバックアップ処理を開始します。"
        }
}

#ESXi/VC接続関数

#仮想マシン起動確認関数

#仮想マシン停止確認関数

#=========================================================================================
#main

startlog

VCSBACKUP_QUESTION


#VCに接続して、vcs01がいるESXiを突き止める
#VC_DEFAULT_POSITION以外にいたら、vMotionする

    $VM=Get-VM rs-vcs01
    # 選択した仮想マシンが所属しているESXiを取得する
    $ESX=Get-VMHost -Location  ($VM.ResourcePool).Name 
    # 選択したものを表示
    Write-Host "VirtualMachine:" $VM.Name
    Write-Host "Move from:" $VM.VMHost " to:" $ESX.Name
    # vMotionを実行
    Move-VM -VM $VM -Destination $ESX

#vcs01を止める
#UDPのプラン実行をする（コマンドの実行が成功するとリターン コード 0 が返り、失敗した場合はエラー メッセージが表示されます。）
"C:\Program Files\arcserve\Unified Data Protection\management\PowerCLI\UDPPowerCLI.ps1" -command backup -udpconsoleprotocol https -udpconsoleusername $UDP_USER -UDPConsolePassword $PASSWD -nodename ******

#バックアップできたら、VCS01を起動する

#起動確認

#接続をきる
Disconnect-VIServer

endlog