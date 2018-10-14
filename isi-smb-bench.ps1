#
#  EMC Isilon ファイル転送時間測定スクリプト  create by yanagiyy  2018/10/04
# 

#共通設定
$MachineName=[Net.Dns]::GetHostName()　  #実行する端末名
$date=Get-Date -Format "yyyyMMddHHmmss" 
$ScriptPath=Split-Path -Parent ($MyInvocation.MyCommand.Path)
$LogFile="$ScriptPath\result-$date.txt"
$PSLOG=$ScriptPath+"\PSlog_"+$MachineName+"_"+$date+".log"


# 標準出力のログ取得開始する関数
function startlog() {
    start-transcript $PSLOG -append
}

# 標準出力のログ取得停止の関数
function endlog() {
    stop-transcript
}

#本来は、引数で乱数文字の使用を決めれるけど、ここではコメントアウトしておく。
function CreateRandomString(
            [int]$ByteSize             # 生成する文字数
            #[int]$ByteSize,             # 生成する文字数
            #[switch]$RejectExtendMark,  # 拡張記号を除く
            #[switch]$RejectBaseMark,    # 基本記号を除く
            #[switch]$RejectAlphabet     # アルファベットを除く
        ){
    # アセンブリロード
    Add-Type -AssemblyName System.Security

    # ランダム文字列にセットする値 コメント解除すると乱数に含むようになります。
    $BaseString = '1234567890'
    $Alphabet = 'ABCDEFGHIJKLNMOPQRSTUVWXYZabcdefghijklnmopqrstuvwxyz'
    #$BaseMark = '!.?+$%#&*=@'
    #$ExtendMark = "'`"``()-^~\|[]{};:<>,/_"

    # アルファベット
    if( $RejectAlphabet -ne $true ){
        $BaseString += $Alphabet
    }

    # 拡張記号
    #if( $RejectExtendMark -ne $true ){
    #    $BaseString += $ExtendMark
    #}

    # 基本記号
    #if( $RejectBaseMark -ne $true ){
    #    $BaseString += $BaseMark
    #}

    # 乱数格納配列
    [array]$RandomValue = New-Object byte[] $ByteSize

    # オブジェクト 作成
    $RNG = New-Object System.Security.Cryptography.RNGCryptoServiceProvider

    # 乱数の生成
    $RNG.GetBytes($RandomValue)

    # 乱数を文字列に変換
    $ReturnString = ""
    $Max = $BaseString.Length
    for($i = 0; $i -lt $ByteSize; $i++){
        $ReturnString += $BaseString[($RandomValue[$i] % $Max)]
    }

    # オブジェクト削除
    $RNG.Dispose()

    return $ReturnString
}

function QueryServerInfo(){
    $ReturnData = New-Object PSObject | Select-Object HostName,Manufacturer,Model,SN,CPUName,PhysicalCores,Sockets,MemorySize,OS

    $Win32_BIOS = Get-WmiObject Win32_BIOS
    $Win32_Processor = Get-WmiObject Win32_Processor
    $Win32_ComputerSystem = Get-WmiObject Win32_ComputerSystem
    $Win32_OperatingSystem = Get-WmiObject Win32_OperatingSystem

    # ホスト名
    $ReturnData.HostName = hostname

    # メーカー名
    $ReturnData.Manufacturer = $Win32_BIOS.Manufacturer

    # モデル名
    $ReturnData.Model = $Win32_ComputerSystem.Model

    # シリアル番号
    $ReturnData.SN = $Win32_BIOS.SerialNumber

    # CPU 名
    $ReturnData.CPUName = @($Win32_Processor.Name)[0]

    # 物理コア数
    $PhysicalCores = 0
    $Win32_Processor.NumberOfCores | % { $PhysicalCores += $_}
    $ReturnData.PhysicalCores = $PhysicalCores
    
    # ソケット数
    $ReturnData.Sockets = $Win32_ComputerSystem.NumberOfProcessors
    
    # メモリーサイズ(GB)
    $Total = 0
    Get-WmiObject -Class Win32_PhysicalMemory | % {$Total += $_.Capacity}
    $ReturnData.MemorySize = [int]($Total/1GB)
    
    # OS 
    $OS = $Win32_OperatingSystem.Caption
    $SP = $Win32_OperatingSystem.ServicePackMajorVersion
    if( $SP -ne 0 ){ $OS += "SP" + $SP }
    $ReturnData.OS = $OS
    
    return $ReturnData
}

Function Get-FileName($initialDirectory) 
{   
  [System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms") |  Out-Null
 
    $OpenFileDialog = New-Object System.Windows.Forms.OpenFileDialog 
    $OpenFileDialog.initialDirectory = $initialDirectory 
    $OpenFileDialog.filter = "All files (*.*)| *.*" 
    $OpenFileDialog.ShowDialog() | Out-Null 
    $OpenFileDialog.filename
}

#Windows10の場合SMB1.0が有効であること(IQ12000xなど古いSMBでの接続が必要な場合。設定後再起動要)
#Set-SmbServerConfiguration -EnableSMB1Protocol $true   #設定
#Get-SmbServerConfiguration | Select EnableSMB1Protocol #確認

# ---------------User Setting---------------------
# 測定ストレージ接続IP
#$ISILN = "192.168.1.62"  
$ISILN = "192.168.100.62"  

#接続するストレージのユーザ
$STORAGE_User="root"
$STORAGE_PW="root"
#$STORAGE_PW="a"

$DistDir = "\\$ISILN\smb-dev\$MachineName" #検証データ保存先
$LocalDir= "$env:tmp\$MachineName" #検証データローカル保存先
$FindTestDir = "\\$ISILN\smb-dev\searchtest" #FIND検証ルートDIR

$RunCycle = 10 #繰り返す回数
$ColdTime = 20 #sec

# 転送方向の反転（0: 端末からストレージへ, 1:ストレージから端末へ)
$ReverseMode = 0 

# OpenReadテスト(ファイルをGet-Contentsで読み込みます)
#なお、ファイルサイズは1GB以下のみ対応です(Get-Contentコマンドの制約)
$OpenRead = 0 

# 転送するファイルにランダム文字列を付与して、新規複製コピー処理をします。
#但し、$ReverseModeが有効の場合は、このモードは処理中に強制OFFになります。
$RandMode = 0

#Findモードの場合は対象ディレクトリ配下全てを対象とします。
#このモード時は他のモード制御はほぼ無効化されます。
$FindMode = 1

if ($FindMode -eq 1 ){
    #共有ドライブにする際のドライブ文字を定義します。既に使用済みの場合はエラーになるので注意
    $ShareDriveName="V"
    $ShareDrive=$ShareDriveName + ":"
}

##変数初期化
$throughput = 0 
$time = 0       
$Times = 0      
$TPSs = 0
$TimeAve = 0
$TPSAve = 0

# 認証情報のインスタンスを生成する
$securePass = ConvertTo-SecureString $STORAGE_PW -AsPlainText -Force;
$cred = New-Object System.Management.Automation.PSCredential "$ISILN\$STORAGE_User", $securePass;

# ------------------------------------------

#実行ログ取得開始
startlog

# スクリプトを実行するPC情報
echo "#  Computer Info  #"
QueryServerInfo
echo "#  ------------   #"
"`n"

#転送先にマシン名のフォルダがなければ作る。ReverseModeのときはローカルの指定されている場所にフォルダを作る。
#フォルダスキャンモードの場合は、選択プロンプト出さない
if ($FindMode -eq 0 ){
    echo "FindMode"
    if ($ReverseMode -eq 1 ){
        if (!(test-path $LocalDir)) {
              New-Item -ItemType Directory -Force -Path $LocalDir
              echo "転送先にフォルダを作成しました : $LocalDir"
        }
    } elseif (!(test-path $DistDir)) {
              New-Item -ItemType Directory -Force -Path $DistDir
              echo "転送先にフォルダを作成しました : $DistDir"
    }
}
   
# 転送する基準ファイルを選択してください。
#フォルダスキャンモードの場合は本処理はSkipされます

if ($FindMode -eq 0 ){
    echo "# TestFile Select"
    if ($ReverseMode -eq 1 ){
        $working_dir= $DistDir.Substring(0,($DistDir.Length - $MachineName.Length))
    }else{
        $working_dir="C:\Users\Documents"
    }

    $sourceFile=Get-FileName -initialDirectory "$working_dir"
    $sourceFileName=Split-Path $sourceFile -Leaf

    if ([string]::IsNullOrEmpty($sourceFile)){
        echo "No Select SourcesFile. Program Stop"
        exit

    } else {
        echo "SourceFile: $sourceFile"
        #Show File Size   
        $size = [int]($(Get-ChildItem $sourceFile).Length / 1MB)
        echo "File size: $size MB"

        #Log Header
        echo "#cycle,time(sec),throughput(MB/sec)"|  Out-File $LogFile -Encoding UTF8
        echo "#FileSize:$size MB, ColdTime:$ColdTime(sec)"|  Out-File $LogFile -Encoding UTF8 -Append
        echo "DistServer:$ISILN"
    }
} else{
        #Log Header(FindMode専用)
        echo "#cycle,time(sec),DistServer:$ISILN, ColdTime:$ColdTime(sec)" |  Out-File $LogFile -Encoding UTF8
}

for ($i=1; $i -le $RunCycle; $i++){
    # Run Command 
    if ($FindMode -eq 1 ){
        #対象の共有フォルダをマウントします。
        echo "接続先:$FindTestDir"
            echo "定義済みでも接続先の状態によってはパスワードが求められますので入力ください。"
            try{
                New-PSDrive -Name $ShareDriveName -PSProvider FileSystem -Root $FindTestDir -Credential $cred -ErrorAction stop
                #対象フォルダのルートディレクトリ以下全階層にFindをします。
                $command = "Get-ChildItem -Recurse $ShareDrive"
                echo "FindMode"           
            }Catch{
                echo "共有フォルダをマウントできませんでした。終了します。"
                exit
            }
    }elseif ($OpenRead -eq 1 ){
        $command = "Get-Content $sourceFile"
        echo "FileOpenReadMode"
    }elseif ($ReverseMode -eq 1 ){
        $RandMode = 0 
        $command = "Copy-Item -Path $sourceFile -Destination $LocalDir -Force"
        echo "ReverseCopyMode"
    }elseif ($RandMode -eq 1 ){
        $random_key = CreateRandomString 12 #ランダム文字列の生成数
    #RandModeが有効だと、コピーする際にファイル名にランダム文字列を付与して指定先にコピーする
        $command = "Copy-Item -Path $sourceFile -Destination $DistDir\$sourceFileName-$random_key -Force"
        echo "RandomFilemode"
    }else{
        $command = "Copy-Item -Path $sourceFile -Destination $DistDir -Force"
        echo "OverwriteMode"
    }
    echo "Command: $command"
    echo "TestCycle: $RunCycle"
    "`n"
        
    echo "# Program Run @ $i Cycle"

    # Execute command
    $time = [int]$(Measure-Command {Invoke-Expression $command}).TotalSeconds

    if ($time -eq 0) {$throughput = "N/A"} else {$throughput = [int]($size /$time)}
    $Times = $Times + $time
    echo "Time: $time seconds"
    if ($FindMode -eq 1 ){
        echo "$i,$time"|  Out-File $LogFile -Encoding UTF8 -Append
        #共有を切断します。
        Get-PSDrive $ShareDriveName | Remove-PSDrive
    }else{
        $TPSs = $TPSs +  $throughput
        echo "Throughtput: $throughput MB/sec" 
        echo "$i,$time,$throughput"|  Out-File $LogFile -Encoding UTF8 -Append
   }
   "`n"
                
        #ColdTime(near RampDown)
        echo "# Cold Time: $ColdTime (secs)"
        "`n"

        sleep -s $ColdTime
    }   
    
    echo "#  -----(Average @ $RunCycle Cycle)-------   #"
    $TimeAve = $Times / $RunCycle
    $TPSAve = $TPSs / $RunCycle
    if ($FindMode -eq 1 ){
        echo "Time(Ave): $TimeAve  seconds"
    }else{
        echo "Time(Ave): $TimeAve  seconds"
        echo "Throughtput(Ave): $TPSAve MB/sec"
    }

#結果ファイルに終了時刻を記載しておく
echo "End:$date"　|  Out-File $LogFile -Encoding UTF8 -Append

#実行ログ取得終了
endlog